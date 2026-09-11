import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/device_telemetry.dart';

/// 设备物理状态采集服务
class TelemetryCollectorService {
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
    );
  }

  /// 动态申请 Android WiFi SSID 所需的位置权限
  static Future<bool> requestLocationPermission() async {
    final status = await Permission.location.request();
    return status.isGranted;
  }
}
