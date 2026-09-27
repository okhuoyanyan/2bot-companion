import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../utils/constants.dart';
import 'calendar_sync_service.dart';
import 'storage_service.dart';
import 'telemetry_collector_service.dart';
import 'telemetry_throttle_scheduler.dart';

/// 必须在顶级作用域声明的后台任务回调入口
@pragma('vm:entry-point')
void startCallback() {
  // WO-70 §7：本 isolate 是【唯一的发送者】（SMTP/OS 锁等待只在这里异步发生）
  TelemetryThrottleScheduler.instance.isBackgroundOwner = true;
  // WO-70 §7 闪屏验证：后台 isolate 未捕获异常 → 显式打印（logcat 可见）+ 落状态。
  // 架构师怀疑 +13 闪屏 = 后台 isolate 崩溃重启循环，此监听用于真机/模拟器实锤。
  Isolate.current.addErrorListener(RawReceivePort((pair) async {
    final List<Object> err = pair as List<Object>;
    final msg = '后台 isolate 异常: ${err[0]} | ${err[1]}';
    debugPrint('[WO70] $msg');
    try {
      final st = StorageService.loadCalendarSyncState();
      st['bgError'] = msg;
      await StorageService.saveCalendarSyncState(st);
    } catch (_) {}
  }).sendPort);
  FlutterForegroundTask.setTaskHandler(CompanionTaskHandler());
}

/// 前台常驻保活任务处理器 (WO-37: 取消周期回调，接入节流调度器与 30s 状态扫描)
class CompanionTaskHandler extends TaskHandler {
  Timer? _statePollTimer;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // 确保子 Isolate 内部存储已初始化
    await StorageService.init();

    // 绑定常驻通知更新回调
    TelemetryThrottleScheduler.instance.notificationUpdater = (text) {
      FlutterForegroundTask.updateService(
        notificationTitle: AppConstants.notificationTitle,
        notificationText: text,
      );
    };

    // 启动即刻执行一次"服务重启"事件上报 (白名单立即发，WO-37 §2.2)
    try {
      await TelemetryThrottleScheduler.instance.triggerEvent(
        TelemetryTrigger.serviceRestart,
      );
    } catch (_) {}

    // WO-70：启动即跑一次日历 tick（服务/同步随开关即刻生效，不等首个 30s）
    try {
      if (await StorageService.takeTelemetryPendingKick()) {
        final kickSnap = await TelemetryCollectorService.collectSnapshot(
          isAppForeground: false,
        );
        await TelemetryThrottleScheduler.instance
            .evaluateStateChange(kickSnap);
      }
    } catch (_) {}
    try {
      await CalendarSyncService.instance.tick();
    } catch (_) {}

    // 启动 30 秒周期状态差分扫描（检测解锁/锁屏、前台应用、WiFi、电量、蓝牙等事件）
    _statePollTimer?.cancel();
    _statePollTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
      try {
        final snapshot = await TelemetryCollectorService.collectSnapshot(
          isAppForeground: false,
        );
        await TelemetryThrottleScheduler.instance.evaluateStateChange(snapshot);
      } catch (_) {}

      // WO-70：前台置「待发」标记 → 本 tick 立即评估一次（前台事件 ≤30s 接力）
      try {
        if (await StorageService.takeTelemetryPendingKick()) {
          final snap0 = await TelemetryCollectorService.collectSnapshot(
            isAppForeground: false,
          );
          await TelemetryThrottleScheduler.instance
              .evaluateStateChange(snap0);
        }
      } catch (_) {}

      // WO-69 日历自动同步 tick（独立 try/catch：任何异常绝不影响遥测主线）
      try {
        await CalendarSyncService.instance.tick();
      } catch (_) {}
    });
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    // WO-37：全面取消定时周期回调；eventAction 设为 nothing()
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    _statePollTimer?.cancel();
    _statePollTimer = null;
    try {
      await CalendarSyncService.instance.stop();
    } catch (_) {}
  }
}

/// 前台保活与双驱动服务管理类
class BackgroundTaskService {
  /// 初始化前台任务基础配置 (WO-37: 改为 eventAction.nothing())
  static void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: AppConstants.notificationChannelId,
        channelName: AppConstants.notificationChannelName,
        channelDescription: AppConstants.notificationDesc,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// 启动前台常驻服务 (WO-37: 取消定时，改为 eventAction.nothing())
  static Future<bool> startService([int intervalMinutes = 0]) async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: AppConstants.notificationChannelId,
        channelName: AppConstants.notificationChannelName,
        channelDescription: AppConstants.notificationDesc,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    final reqResult = await FlutterForegroundTask.requestNotificationPermission();
    if (reqResult == NotificationPermission.denied) {
      return false;
    }

    final isRunning = await FlutterForegroundTask.isRunningService;
    if (isRunning) {
      await FlutterForegroundTask.restartService();
    } else {
      await FlutterForegroundTask.startService(
        serviceId: 200,
        notificationTitle: AppConstants.notificationTitle,
        notificationText: '2BOT 状态同步引擎运行中...',
        callback: startCallback,
      );
    }

    await StorageService.setServiceEnabled(true);
    return true;
  }

  /// 停止前台常驻服务
  static Future<void> stopService() async {
    await FlutterForegroundTask.stopService();
    await StorageService.setServiceEnabled(false);
  }

  /// 检查当前是否正在运行
  static Future<bool> isRunning() async {
    return await FlutterForegroundTask.isRunningService;
  }
}
