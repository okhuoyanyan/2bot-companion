import 'dart:async';

import '../models/app_settings.dart';
import '../models/device_telemetry.dart';
import 'storage_service.dart';
import 'telemetry_collector_service.dart';
import 'telemetry_uploader_service.dart';

/// 上报触发事件类型 (WO-37 §1)
enum TelemetryTrigger {
  unlock('unlock', '屏幕解锁'),
  lock('lock', '屏幕锁屏'),
  appSwitch('app_switch', '前台应用切换'),
  location('location', '到家/离家'),
  power('power', '充放电切换'),
  batteryThreshold('battery_threshold', '电量跨档'),
  batteryFull('battery_full', '充电完成'),
  music('music', '音乐启停'),
  bluetooth('bluetooth', '蓝牙连接'),
  steps('steps', '步数里程碑'),
  silenceTimeout('silence_timeout', '静默保活超时'),
  serviceRestart('service_restart', '服务启动/重启'),
  manual('manual', '手动触发');

  final String key;
  final String label;
  const TelemetryTrigger(this.key, this.label);
}

/// WO-37 事件驱动与节流调度器 (本单核心模块)
///
/// 核心契约：
/// 1. 白名单事件（到家/离家、电量低至 20%/10%、服务启动、手动）：立即发送；
/// 2. 非白名单事件：窗口内合并为 1 次，距上次上报 >= T 秒（90/180/600）才发；
/// 3. 发送失败：沿用既有退避，连续失败仅记录并等下次事件，**严禁引入定时重试**；
/// 4. 静默超时：无事件超过 N 小时触发单次保活，重排单发到期检查，**严禁周期 tick**；
/// 5. 每项事件具备独立配置开关；
/// 6. 支持依赖注入以进行纯 Dart 单元测试。
class TelemetryThrottleScheduler {
  static final TelemetryThrottleScheduler _instance =
      TelemetryThrottleScheduler._internal();
  static TelemetryThrottleScheduler get instance => _instance;

  TelemetryThrottleScheduler._internal();

  // 依赖注入钩子 (供单测 mock)
  Future<DeviceTelemetry> Function({bool isAppForeground})? snapshotCollector;
  Future<UploadResult> Function(DeviceTelemetry)? uploader;
  void Function(int hours)? silenceScheduler;
  void Function(String text)? notificationUpdater;

  DateTime? _lastSendTime;
  bool _isDirty = false;
  TelemetryTrigger? _lastDirtyTrigger;
  int? _lastDirtyBatteryLevel;
  Timer? _coalesceTimer;
  Timer? _silenceTimer;
  int _consecutiveFailures = 0;
  bool _isSending = false;

  // 状态追踪器 (用于差分触发检测)
  int? _lastReportedBatteryLevel;
  bool? _lastReportedCharging;
  bool? _lastReportedScreenLocked;
  String? _lastReportedForegroundApp;
  String? _lastReportedWifiSsid;
  bool? _lastReportedMusicActive;
  bool? _lastReportedBtAudio;
  int? _lastReportedSteps;

  DateTime? get lastSendTime => _lastSendTime;
  bool get isDirty => _isDirty;
  int get consecutiveFailures => _consecutiveFailures;

  /// 重置调度器内部状态（单测隔离使用）
  void resetForTest() {
    _coalesceTimer?.cancel();
    _coalesceTimer = null;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _lastSendTime = null;
    _isDirty = false;
    _lastDirtyTrigger = null;
    _lastDirtyBatteryLevel = null;
    _consecutiveFailures = 0;
    _isSending = false;
    _lastReportedBatteryLevel = null;
    _lastReportedCharging = null;
    _lastReportedScreenLocked = null;
    _lastReportedForegroundApp = null;
    _lastReportedWifiSsid = null;
    _lastReportedMusicActive = null;
    _lastReportedBtAudio = null;
    _lastReportedSteps = null;
  }

  /// 判定该触发是否属于白名单（立即发，不受限流窗口约束）
  bool isWhitelisted(TelemetryTrigger trigger, {int? batteryLevel}) {
    if (trigger == TelemetryTrigger.manual ||
        trigger == TelemetryTrigger.serviceRestart) {
      return true;
    }
    if (trigger == TelemetryTrigger.location) {
      return true;
    }
    if (trigger == TelemetryTrigger.batteryThreshold) {
      if (batteryLevel != null && batteryLevel <= 20) {
        return true;
      }
    }
    return false;
  }

  /// 检查某事件是否在设置中启用
  bool isTriggerEnabled(TelemetryTrigger trigger, AppSettings settings) {
    if (trigger == TelemetryTrigger.manual ||
        trigger == TelemetryTrigger.serviceRestart) {
      return true;
    }
    return settings.eventSwitches[trigger.key] ?? true;
  }

  /// 触发事件入口
  Future<void> triggerEvent(
    TelemetryTrigger trigger, {
    int? batteryLevel,
    AppSettings? settingsOverride,
  }) async {
    final settings = settingsOverride ?? StorageService.loadSettings();

    // 1. 检查事件开关
    if (!isTriggerEnabled(trigger, settings)) {
      return;
    }

    final whitelisted = isWhitelisted(trigger, batteryLevel: batteryLevel);
    final throttleWindow = Duration(seconds: settings.throttleIntervalSeconds);
    final now = DateTime.now();

    // 2. 白名单事件：立即发送
    if (whitelisted) {
      _coalesceTimer?.cancel();
      _coalesceTimer = null;
      _isDirty = false;
      await _dispatchReport(trigger: trigger, settings: settings);
      return;
    }

    // 3. 非白名单事件：检查节流窗口
    _isDirty = true;
    _lastDirtyTrigger = trigger;
    _lastDirtyBatteryLevel = batteryLevel;

    if (_lastSendTime == null || now.difference(_lastSendTime!) >= throttleWindow) {
      // 距上次上报已超出窗口 -> 立即发
      _coalesceTimer?.cancel();
      _coalesceTimer = null;
      _isDirty = false;
      await _dispatchReport(trigger: trigger, settings: settings);
    } else {
      // 处于限流窗口内 -> 标脏并在窗口剩余时间结束时合并发一次
      if (_coalesceTimer == null) {
        final elapsed = now.difference(_lastSendTime!);
        final remaining = throttleWindow - elapsed;
        _coalesceTimer = Timer(
          remaining > Duration.zero ? remaining : Duration.zero,
          () async {
            _coalesceTimer = null;
            if (_isDirty) {
              final trig = _lastDirtyTrigger ?? trigger;
              _isDirty = false;
              await _dispatchReport(
                trigger: trig,
                settings: settingsOverride ?? StorageService.loadSettings(),
              );
            }
          },
        );
      }
    }
  }

  /// 执行快照采集与上报
  Future<UploadResult?> _dispatchReport({
    required TelemetryTrigger trigger,
    required AppSettings settings,
  }) async {
    if (_isSending) return null;
    _isSending = true;

    try {
      final collector = snapshotCollector ??
          TelemetryCollectorService.collectSnapshot;
      final uploaderFunc = uploader ?? TelemetryUploaderService.upload;

      final snapshot = await collector(isAppForeground: false);
      final result = await uploaderFunc(snapshot);

      if (result.success) {
        _lastSendTime = DateTime.now();
        _consecutiveFailures = 0;
        _updateLastState(snapshot);

        // 重排单发静默保活到期检查 (WO-37 §2.2 & 裁定 2)
        _rearmSilenceTimeout(settings.silenceTimeoutHours);

        notificationUpdater?.call(
          '上报成功 [${trigger.label}] (${DateTime.now().toLocal().toString().split(" ")[1].split(".")[0]})',
        );
      } else {
        _consecutiveFailures++;
        // 失败仅记录，等下次事件再试 —— 严禁引入定时重试
      }
      return result;
    } catch (_) {
      _consecutiveFailures++;
      return null;
    } finally {
      _isSending = false;
    }
  }

  /// 更新状态快照比对基线
  void _updateLastState(DeviceTelemetry snapshot) {
    _lastReportedBatteryLevel = snapshot.battery.level;
    _lastReportedCharging = snapshot.battery.isCharging;
    _lastReportedScreenLocked = snapshot.screenLocked;
    _lastReportedForegroundApp = snapshot.foregroundApp;
    _lastReportedWifiSsid = snapshot.wifi.ssid;
    _lastReportedMusicActive = snapshot.isMusicActive;
    _lastReportedBtAudio = snapshot.isBluetoothAudio;
    _lastReportedSteps = snapshot.stepsToday;
  }

  /// 重排单发静默保活检查 (无事件超过 N 小时上报一次，0=关闭)
  void _rearmSilenceTimeout(int hours) {
    _silenceTimer?.cancel();
    _silenceTimer = null;

    if (hours <= 0) {
      // 0 = 关闭静默超时上报
      silenceScheduler?.call(0);
      return;
    }

    // 1. Dart 内存单发定时器
    _silenceTimer = Timer(Duration(hours: hours), () {
      triggerEvent(TelemetryTrigger.silenceTimeout);
    });

    // 2. 原生 AlarmManager.setAndAllowWhileIdle 硬件唤醒兜底 (加固项 1)
    final sched = silenceScheduler ??
        TelemetryCollectorService.scheduleSilenceKeepalive;
    sched(hours);
  }

  /// 状态差分扫描器（供前台保活服务每 30s 周期性调用，检测事件状态翻转）
  Future<void> evaluateStateChange(DeviceTelemetry current) async {
    final settings = StorageService.loadSettings();

    // 1. 解锁 / 锁屏翻转
    if (_lastReportedScreenLocked != null &&
        current.screenLocked != _lastReportedScreenLocked) {
      final trig = current.screenLocked
          ? TelemetryTrigger.lock
          : TelemetryTrigger.unlock;
      await triggerEvent(trig, settingsOverride: settings);
    }

    // 2. 前台应用切换
    if (_lastReportedForegroundApp != null &&
        current.foregroundApp != _lastReportedForegroundApp &&
        current.foregroundApp != 'None') {
      await triggerEvent(TelemetryTrigger.appSwitch, settingsOverride: settings);
    }

    // 3. 到家 / 离家 (WiFi SSID 切换)
    if (_lastReportedWifiSsid != null &&
        current.wifi.ssid != _lastReportedWifiSsid) {
      await triggerEvent(TelemetryTrigger.location, settingsOverride: settings);
    }

    // 4. 充放电状态切换
    if (_lastReportedCharging != null &&
        current.battery.isCharging != _lastReportedCharging) {
      await triggerEvent(TelemetryTrigger.power, settingsOverride: settings);
    }

    // 5. 充电完成 (100% 且充电中)
    if (current.battery.isCharging &&
        current.battery.level == 100 &&
        _lastReportedBatteryLevel != 100) {
      await triggerEvent(TelemetryTrigger.batteryFull, settingsOverride: settings);
    }

    // 6. 电量跨档 (80 / 20 / 10)
    if (_lastReportedBatteryLevel != null) {
      final prev = _lastReportedBatteryLevel!;
      final cur = current.battery.level;
      final thresholds = [80, 20, 10];
      for (final t in thresholds) {
        if (prev > t && cur <= t) {
          await triggerEvent(
            TelemetryTrigger.batteryThreshold,
            batteryLevel: cur,
            settingsOverride: settings,
          );
          break;
        }
      }
    }

    // 7. 音乐启停
    if (_lastReportedMusicActive != null &&
        current.isMusicActive != _lastReportedMusicActive) {
      await triggerEvent(TelemetryTrigger.music, settingsOverride: settings);
    }

    // 8. 蓝牙音频接断
    if (_lastReportedBtAudio != null &&
        current.isBluetoothAudio != _lastReportedBtAudio) {
      await triggerEvent(TelemetryTrigger.bluetooth, settingsOverride: settings);
    }

    // 9. 步数里程碑 (每跨过 500 步)
    if (_lastReportedSteps != null && current.stepsToday != null) {
      final prevMilestone = _lastReportedSteps! ~/ 500;
      final curMilestone = current.stepsToday! ~/ 500;
      if (curMilestone > prevMilestone) {
        await triggerEvent(TelemetryTrigger.steps, settingsOverride: settings);
      }
    }
  }
}
