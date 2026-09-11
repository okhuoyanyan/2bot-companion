import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:intl/intl.dart';
import '../utils/constants.dart';
import 'storage_service.dart';
import 'telemetry_collector_service.dart';
import 'telemetry_uploader_service.dart';

/// 必须在顶级作用域声明的后台任务回调入口
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(CompanionTaskHandler());
}

/// 前台常驻保活任务处理器
class CompanionTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // 确保子 Isolate 内部存储已初始化
    await StorageService.init();
    // 启动即刻执行一次保底上报
    await _executePeriodicReport();
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    await _executePeriodicReport();
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    // 任务销毁清理
  }

  /// 执行后台静默周期上报
  Future<void> _executePeriodicReport() async {
    try {
      final snapshot = await TelemetryCollectorService.collectSnapshot(
        isAppForeground: false,
      );
      final result = await TelemetryUploaderService.upload(snapshot);

      final timeStr = DateFormat('HH:mm:ss').format(DateTime.now());
      final statusDesc = result.success ? '成功上报' : '上报失败';
      
      // 动态刷新常驻通知内容
      await FlutterForegroundTask.updateService(
        notificationTitle: AppConstants.notificationTitle,
        notificationText: '电量: ${snapshot.battery.level}% | $statusDesc ($timeStr)',
      );
    } catch (_) {}
  }
}

/// 前台保活与双驱动服务管理类
class BackgroundTaskService {
  /// 初始化前台任务基础配置
  static void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: AppConstants.notificationChannelId,
        channelName: AppConstants.notificationChannelName,
        channelDescription: AppConstants.notificationDesc,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(
          AppConstants.defaultIntervalMinutes * 60 * 1000,
        ),
        autoRunOnBoot: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// 启动前台常驻服务
  static Future<bool> startService(int intervalMinutes) async {
    // 重新根据用户配置的周期刷新 interval
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: AppConstants.notificationChannelId,
        channelName: AppConstants.notificationChannelName,
        channelDescription: AppConstants.notificationDesc,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(
          intervalMinutes * 60 * 1000,
        ),
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
