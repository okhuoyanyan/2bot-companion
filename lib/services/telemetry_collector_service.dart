import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/device_telemetry.dart';

/// 设备物理状态采集服务
class TelemetryCollectorService {
  static const MethodChannel _channel =
      MethodChannel('com.twobot.companion/native_sensors');

  static final Battery _battery = Battery();
  static final Connectivity _connectivity = Connectivity();
  static final NetworkInfo _networkInfo = NetworkInfo();

  /// 采集当前全量设备快照
  static Future<DeviceTelemetry> collectSnapshot({
    bool isAppForeground = true,
  }) async {
    // 1. 采集电池信息
    int batteryLevel = 100;
    bool isCharging = false;
    try {
      batteryLevel = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      isCharging = (state == BatteryState.charging || state == BatteryState.full);
    } catch (_) {}

    // 2. 采集网络与 WiFi SSID 信息
    bool wifiConnected = false;
    String wifiSsid = '';

    try {
      final connectivityResult = await _connectivity.checkConnectivity();
      wifiConnected = connectivityResult.contains(ConnectivityResult.wifi);

      if (wifiConnected) {
        // Android 10+ 需具备定位权限方能提取 SSID
        final hasLocationPerm = await Permission.location.isGranted;
        if (hasLocationPerm) {
          final rawSsid = await _networkInfo.getWifiName();
          if (rawSsid != null) {
            // 清理 Android 可能包裹的双引号以及异常未知标识
            wifiSsid = rawSsid.replaceAll('"', '').trim();
            if (wifiSsid == '<unknown ssid>' || wifiSsid == '0x') {
              wifiSsid = '';
            }
          }
        }
      }
    } catch (_) {}

    // 3. 锁屏状态推断 (前台活跃为 false，后台运行且锁屏广播为 true)
    final bool screenLocked = !isAppForeground;

    // 4. 前台应用名称（纯血开源零侵入，默认上报 None 或自身）
    final String foregroundApp = isAppForeground ? '2bot-companion' : 'None';

    // 5. 采集 Android 原生底层传感器与系统状态 (v1.1.0 新增)
    int? stepsToday;
    String? ringerMode;
    bool? isDnd;
    bool? isMusicActive;
    bool? isBluetoothAudio;
    Map<String, dynamic>? nextAlarm;
    int? screenTimeMinutes;
    bool? isIgnoringBatteryOptimizations;
    bool? hasUsagePermission;
    LocationInfo? location;

    try {
      final nativeData =
          await _channel.invokeMapMethod<String, dynamic>('getNativeSensors');
      if (nativeData != null) {
        stepsToday = (nativeData['stepsToday'] as num?)?.toInt();
        ringerMode = nativeData['ringerMode'] as String?;
        isDnd = nativeData['isDnd'] as bool?;
        isMusicActive = nativeData['isMusicActive'] as bool?;
        isBluetoothAudio = nativeData['isBluetoothAudio'] as bool?;
        if (nativeData['nextAlarm'] != null) {
          nextAlarm =
              Map<String, dynamic>.from(nativeData['nextAlarm'] as Map);
        }
        screenTimeMinutes = (nativeData['screenTimeMinutes'] as num?)?.toInt();
        isIgnoringBatteryOptimizations =
            nativeData['isIgnoringBatteryOptimizations'] as bool?;
        hasUsagePermission = nativeData['hasUsagePermission'] as bool?;

        // 6. 原生双轨 WiFi SSID 兜底 (若 network_info_plus 获取失败，使用 Android 原生提取)
        final nativeSsid = nativeData['nativeWifiSsid'] as String?;
        if (wifiSsid.isEmpty && nativeSsid != null && nativeSsid.isNotEmpty) {
          wifiSsid = nativeSsid;
        }

        // 7. GPS 经纬度位置信息解析 (v1.3.0)
        if (nativeData['location'] != null) {
          try {
            location = LocationInfo.fromJson(
              Map<String, dynamic>.from(nativeData['location'] as Map),
            );
          } catch (_) {}
        }
      }
    } catch (_) {
      // 优雅静默降级为 null，确保原有电量、WiFi、屏幕状态 100% 稳定采集
    }

    return DeviceTelemetry(
      battery: BatteryInfo(
        level: batteryLevel,
        isCharging: isCharging,
      ),
      wifi: WifiInfo(
        connected: wifiConnected,
        ssid: wifiSsid,
      ),
      screenLocked: screenLocked,
      foregroundApp: foregroundApp,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      stepsToday: stepsToday,
      ringerMode: ringerMode,
      isDnd: isDnd,
      isMusicActive: isMusicActive,
      isBluetoothAudio: isBluetoothAudio,
      nextAlarm: nextAlarm,
      screenTimeMinutes: screenTimeMinutes,
      isIgnoringBatteryOptimizations: isIgnoringBatteryOptimizations,
      hasUsagePermission: hasUsagePermission,
      location: location,
    );
  }

  /// 动态申请 Android WiFi SSID 所需的位置权限
  static Future<bool> requestLocationPermission() async {
    final status = await Permission.location.request();
    return status.isGranted;
  }

  /// 检查是否拥有屏幕与软件使用情况访问权限
  static Future<bool> hasUsagePermission() async {
    try {
      final res = await _channel.invokeMethod<bool>('hasUsagePermission');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 一键触发系统电池优化白名单申请弹窗
  static Future<void> requestIgnoreBatteryOptimizations() async {
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }

  /// 打开系统使用情况授权页面 (屏幕使用时长)
  static Future<void> openUsageSettings() async {
    try {
      await _channel.invokeMethod('openUsageSettings');
    } catch (_) {}
  }

  /// 动态申请 Android 10+ 健身运动/步数权限
  static Future<bool> requestActivityPermission() async {
    try {
      final status = await Permission.activityRecognition.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// 动态申请 Android 13+ 通知权限 (常驻保活必需)
  static Future<bool> requestNotificationPermission() async {
    try {
      final status = await Permission.notification.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }
}
