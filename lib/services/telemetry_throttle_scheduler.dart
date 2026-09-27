import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/device_telemetry.dart';
import 'storage_service.dart';
import 'telemetry_collector_service.dart';
import 'telemetry_uploader_service.dart';

/// WO-69 追补：载荷指纹（FNV-1a 64，零依赖；去重窗口内防碰撞够用）。
/// **必须剔除 timestamp**——快照每次采集都换新时间戳，不去除则同状态永不命中去重。
String fnv1a64Hex(String s) {
  var h = 0xcbf29ce484222325;
  for (final cu in s.codeUnits) {
    h ^= cu & 0xff;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    h ^= (cu >> 8) & 0xff;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(16, '0');
}

String telemetryFingerprint(DeviceTelemetry t) {
  final json = t.toJson()..remove('timestamp');
  return fnv1a64Hex(jsonEncode(json));
}

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

  /// 跨 isolate 投递指纹持久化键（SharedPreferencesAsync 直读平台层）
  static const String _keyLastDeliveredFp = 'pref_last_delivered_fp';
  static const String _keyLastDeliveredAtMs = 'pref_last_delivered_at_ms';

  TelemetryThrottleScheduler._internal();

  // 依赖注入钩子 (供单测 mock)
  Future<DeviceTelemetry> Function({bool isAppForeground})? snapshotCollector;
  Future<UploadResult> Function(DeviceTelemetry)? uploader;
  void Function(int hours)? silenceScheduler;
  void Function(String text)? notificationUpdater;

  /// WO-69 追补：时钟注入（单测不真等冷却）
  @visibleForTesting
  DateTime Function() nowProvider = DateTime.now;

  DateTime? _lastSendTime;
  bool _isDirty = false;
  TelemetryTrigger? _lastDirtyTrigger;
  int? _lastDirtyBatteryLevel;
  Timer? _coalesceTimer;
  Timer? _silenceTimer;
  int _consecutiveFailures = 0;
  bool _isSending = false;

  // ── WO-69 追补整改（架构师急件 2026-09-27）──────────────────────
  // 真机确证：开日历同步 → 遥测同秒 4 封突发簇（日历通道写失败 → 水位线卡死 →
  // IMAP 重试风暴 → QQ 风控 → 遥测 SMTP 535 → 失败不推进水位自锁）。三道闸：
  //   闸1 载荷去重：同一状态快照（剔除 timestamp 后指纹一致）窗口内绝不重复投递；
  //       指纹经 SharedPreferencesAsync 跨 isolate 共享（主/任务 isolate 双入口同闸）；
  //   闸2 失败有界冷却：尝试时间即记录，连续失败按 30s/60s/120s（封顶 300s）冷却，
  //       期间只标脏不发送——杜绝 535 自锁环；
  //   闸3 发送层最小会话间隔（SmtpMailer.minSessionGap=3s，transport 层）。
  static const Duration dedupWindow = Duration(minutes: 10);
  static const Duration minDeliverGap = Duration(seconds: 5);
  final Map<String, DateTime> _recentPayloadFingerprints = <String, DateTime>{};
  DateTime? _lastAttemptTime;
  int dedupSkippedCount = 0;
  int cooldownSkippedCount = 0;

  /// WO-69 驳回缺陷一：白名单事件（location/batteryThreshold）在 WiFi/电量抖动下
  /// 内容各不相同（去重天然拦不住）且不受 90s 窗口约束 → 5-30 秒一封。
  /// 有界限频：同类白名单事件 60s 内只立即发一次，其余并入合并路径。
  static const Duration whitelistMinGap = Duration(seconds: 60);
  final Map<String, DateTime> _lastWhitelistAt = <String, DateTime>{};

  /// 闸门判定记录（驳回硬性条件①：设置页可见 本次尝试时间/发送原因/闸门判定）
  Future<void> _recordGate(String gate, TelemetryTrigger trigger,
      {String? detail}) async {
    try {
      await StorageService.recordTelemetryAttempt(
        trigger: trigger.label,
        gate: gate,
        detail: detail,
        at: nowProvider(),
      );
    } catch (_) {
      // 观测记录是可丢弃数据：失败静默，绝不影响上报主链
    }
  }

  /// 有界冷却时长：连续失败 1/2/3+ 次 → 30s/60s/120s（封顶 300s，防 535 期间猛打）
  Duration cooldownFor(int consecutiveFailures) {
    if (consecutiveFailures <= 0) return Duration.zero;
    if (consecutiveFailures == 1) return const Duration(seconds: 30);
    if (consecutiveFailures == 2) return const Duration(seconds: 60);
    return const Duration(seconds: 120);
  }

  /// 处于失败冷却期（尝试后未成功的保护窗）？
  bool _inFailureCooldown(DateTime now) {
    final last = _lastAttemptTime;
    if (last == null || _consecutiveFailures <= 0) return false;
    final cooldown = cooldownFor(_consecutiveFailures);
    return now.difference(last) < cooldown;
  }

  /// 前台事件驱动刷新入口（home_screen 电池/网络流监听专用）。
  /// WO-69 追补：原 `_triggerSilentReport` **裸调 upload 绕过调度器**——充放电时
  /// 电量流秒级连跳 → 每跳一封。现统一收口到节流/去重/冷却纪律下（非白名单路径）。
  Future<void> triggerTelemetryRefresh() async {
    await triggerEvent(TelemetryTrigger.appSwitch, skipEventSwitchCheck: true);
  }

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
    _recentPayloadFingerprints.clear();
    _persistedDeliveredFingerprint = null;
    _lastWhitelistAt.clear();
    _lastAttemptTime = null;
    dedupSkippedCount = 0;
    cooldownSkippedCount = 0;
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
    bool skipEventSwitchCheck = false,
  }) async {
    final settings = settingsOverride ?? StorageService.loadSettings();

    // 跨 isolate 投递标记懒加载（闸1 的另一半：主/任务 isolate 双入口同闸）
    // ignore: unawaited_futures
    ensureCrossIsolateMarkLoaded();

    // 1. 检查事件开关（内部刷新入口跳过——它不是独立事件，是状态刷新）
    if (!skipEventSwitchCheck && !isTriggerEnabled(trigger, settings)) {
      return;
    }

    final whitelisted = isWhitelisted(trigger, batteryLevel: batteryLevel);
    final throttleWindow = Duration(seconds: settings.throttleIntervalSeconds);
    // 时钟统一走 nowProvider（WO-69 追补：窗口/去重/冷却同一注入时钟，测试可快进）
    final now = nowProvider();

    // 2. 白名单事件：立即发送——但同类事件受 60s 有界限频（驳回缺陷一：
    //    WiFi SSID / 电量阈值抖动时内容各不相同，去重拦不住，必须限频）
    if (whitelisted) {
      final lastWl = _lastWhitelistAt[trigger.key];
      final flapProne = trigger == TelemetryTrigger.location ||
          trigger == TelemetryTrigger.batteryThreshold;
      if (flapProne &&
          lastWl != null &&
          now.difference(lastWl) < whitelistMinGap) {
        _recordGate('whitelist-gap', trigger,
            detail: '同类白名单事件 ${now.difference(lastWl).inSeconds}s 前已发，并入合并路径');
        // 落入下方非白名单合并路径（标脏 + 窗口合并），不立即发
      } else {
        if (flapProne) _lastWhitelistAt[trigger.key] = now;
        _coalesceTimer?.cancel();
        _coalesceTimer = null;
        _isDirty = false;
        await _dispatchReport(
            trigger: trigger, settings: settings, whitelisted: true);
        return;
      }
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
      await _dispatchReport(
          trigger: trigger, settings: settings, whitelisted: whitelisted);
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
                whitelisted: isWhitelisted(trig, batteryLevel: _lastDirtyBatteryLevel),
              );
            }
          },
        );
      }
    }
  }

  /// 执行快照采集与上报（WO-69 追补：闸1 去重 + 闸2 冷却统一收口于此）
  Future<UploadResult?> _dispatchReport({
    required TelemetryTrigger trigger,
    required AppSettings settings,
    bool whitelisted = false,
  }) async {
    if (_isSending) return null;
    final now = nowProvider();

    // ── 闸2：失败有界冷却 ── 连续失败期间只标脏 + 延后到冷却结束（单发延后，
    // 非周期重试），杜绝「535 → 不推进水位 → 每次事件都立即发」的自锁环。
    if (_inFailureCooldown(now)) {
      cooldownSkippedCount++;
      _recordGate('cooldown', trigger,
          detail: '连续失败 $_consecutiveFailures 次，冷却期内延后');
      _isDirty = true;
      _lastDirtyTrigger = trigger;
      final last = _lastAttemptTime!;
      var remaining = cooldownFor(_consecutiveFailures) - now.difference(last);
      if (remaining < Duration.zero) remaining = Duration.zero;
      _coalesceTimer?.cancel();
      _coalesceTimer = Timer(remaining, () async {
        _coalesceTimer = null;
        if (_isDirty) {
          final trig = _lastDirtyTrigger ?? trigger;
          _isDirty = false;
          await _dispatchReport(
            trigger: trig,
            settings: settings,
            whitelisted: whitelisted,
          );
        }
      });
      return null;
    }

    // ── 闸1a：载荷去重（本 isolate 内存槽，快路径）──
    _isSending = true;
    _lastAttemptTime = now; // 尝试即记录（成败都算），冷却只对「未成功」生效
    DeviceTelemetry snapshot;
    try {
      final collector = snapshotCollector ??
          TelemetryCollectorService.collectSnapshot;
      snapshot = await collector(isAppForeground: false);

      final fingerprint = telemetryFingerprint(snapshot);
      // 手动上报 / 静默保活豁免去重：保活的本意就是「无变化也要报」，
      // 否则 NAS 无法区分手机安静与通道离线（WO-37 契约）
      if (_dedupApplies(trigger, whitelisted) &&
          _isDuplicatePayload(fingerprint, now)) {
        dedupSkippedCount++;
        _recordGate('dedup', trigger, detail: '同载荷指纹 ${fingerprint.substring(0, 8)} 窗口内已投递');
        _lastSendTime = now; // 内容已在信箱：视同已上报，推进窗口基线
        _updateLastState(snapshot);
        notificationUpdater?.call('载荷未变化，去重跳过发送');
        return UploadResult(
          success: true,
          statusCode: 200,
          message: '去重跳过（同载荷窗口内已投递）',
        );
      }

      final uploaderFunc = uploader ?? TelemetryUploaderService.upload;
      _recordGate('sending', trigger, detail: '载荷 ${fingerprint.substring(0, 8)}');
      final result = await uploaderFunc(snapshot);

      if (result.success) {
        _recordGate('sent', trigger, detail: result.message);
        _lastSendTime = nowProvider();
        _consecutiveFailures = 0;
        _updateLastState(snapshot);
        // 指纹跨 isolate 持久化（SharedPreferencesAsync 直读平台层，绕过每 isolate 缓存）
        await _persistDeliveredFingerprint(fingerprint, nowProvider());

        // 重排单发静默保活到期检查 (WO-37 §2.2 & 裁定 2)
        _rearmSilenceTimeout(settings.silenceTimeoutHours);

        notificationUpdater?.call(
          '上报成功 [${trigger.label}] (${DateTime.now().toLocal().toString().split(" ")[1].split(".")[0]})',
        );
      } else {
        _consecutiveFailures++;
        _recordGate('send-failed', trigger, detail: result.message);
        // 失败仅记录 + 闸2 冷却，等下次事件再试 —— 严禁引入定时重试
      }
      return result;
    } catch (e) {
      _consecutiveFailures++;
      _recordGate('dispatch-error', trigger, detail: e.toString());
      return null;
    } finally {
      _isSending = false;
    }
  }

  /// 命中既有去重指纹？内存槽 → 跨 isolate 持久层顺序检查。
  bool _isDuplicatePayload(String fingerprint, DateTime now) {
    final memAt = _recentPayloadFingerprints[fingerprint];
    if (memAt != null && now.difference(memAt) < dedupWindow) return true;
    final persisted = _persistedDeliveredFingerprint;
    if (persisted != null &&
        persisted.fp == fingerprint &&
        now.difference(persisted.at) < dedupWindow) {
      return true;
    }
    return false;
  }

  /// 去重适用面：**仅非白名单合并路径**。
  /// 白名单事件（location/电量阈值≤20/manual/serviceRestart）语义上必须送达
  /// （SSID 翻转/跨档/重启信号），判定须用调用点带 batteryLevel 的结果；
  /// 静默保活豁免——保活的本意就是「无变化也要报」，否则 NAS 无法区分
  /// 手机安静与通道离线（WO-37 契约）。
  bool _dedupApplies(TelemetryTrigger trigger, bool whitelisted) =>
      !whitelisted && trigger != TelemetryTrigger.silenceTimeout;

  ({String fp, DateTime at})? _persistedDeliveredFingerprint;

  Future<void> _persistDeliveredFingerprint(String fp, DateTime at) async {
    _recentPayloadFingerprints[fp] = at;
    // 有界化（防长期运行内存爬升）
    while (_recentPayloadFingerprints.length > 16) {
      final oldest = _recentPayloadFingerprints.entries
          .reduce((a, b) => a.value.isBefore(b.value) ? a : b);
      _recentPayloadFingerprints.remove(oldest.key);
    }
    _persistedDeliveredFingerprint = (fp: fp, at: at);
    try {
      // SharedPreferencesAsync：每次读写直通平台层——跨 isolate（主/任务）一致可见
      final asyncPrefs = SharedPreferencesAsync();
      await asyncPrefs.setString(_keyLastDeliveredFp, fp);
      await asyncPrefs.setInt(
          _keyLastDeliveredAtMs, at.millisecondsSinceEpoch);
    } catch (_) {
      // 持久层不可用仅退化为本 isolate 内存去重，不阻断上报
    }
  }

  /// 发送前读取跨 isolate 投递标记（懒加载一次；发送频率低，代价可忽略）
  Future<void> ensureCrossIsolateMarkLoaded() async {
    if (_persistedDeliveredFingerprint != null) return;
    try {
      final asyncPrefs = SharedPreferencesAsync();
      final fp = await asyncPrefs.getString(_keyLastDeliveredFp);
      final ms = await asyncPrefs.getInt(_keyLastDeliveredAtMs);
      if (fp != null && ms != null) {
        _persistedDeliveredFingerprint =
            (fp: fp, at: DateTime.fromMillisecondsSinceEpoch(ms));
      }
    } catch (_) {}
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
  Future<void> evaluateStateChange(
    DeviceTelemetry current, {
    AppSettings? settingsOverride,
  }) async {
    AppSettings settings;
    if (settingsOverride != null) {
      settings = settingsOverride;
    } else {
      try {
        settings = StorageService.loadSettings();
      } catch (_) {
        settings = AppSettings();
      }
    }

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
