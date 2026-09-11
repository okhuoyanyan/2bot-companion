/// 电池信息模型
class BatteryInfo {
  final int level;
  final bool isCharging;

  BatteryInfo({
    required this.level,
    required this.isCharging,
  });

  Map<String, dynamic> toJson() => {
    'level': level,
    'isCharging': isCharging,
  };

  factory BatteryInfo.fromJson(Map<String, dynamic> json) {
    return BatteryInfo(
      level: (json['level'] as num?)?.toInt() ?? 100,
      isCharging: json['isCharging'] as bool? ?? false,
    );
  }
}

/// WiFi 网络信息模型
class WifiInfo {
  final bool connected;
  final String ssid;

  WifiInfo({
    required this.connected,
    required this.ssid,
  });

  Map<String, dynamic> toJson() => {
    'connected': connected,
    'ssid': ssid,
  };

  factory WifiInfo.fromJson(Map<String, dynamic> json) {
    return WifiInfo(
      connected: json['connected'] as bool? ?? false,
      ssid: json['ssid'] as String? ?? '',
    );
  }
}

/// 2BOT 官方标准设备快照模型 (SSOT)
class DeviceTelemetry {
  final BatteryInfo battery;
  final WifiInfo wifi;
  final bool screenLocked;
  final String foregroundApp;
  final int timestamp;

  DeviceTelemetry({
    required this.battery,
    required this.wifi,
    required this.screenLocked,
    required this.foregroundApp,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'battery': battery.toJson(),
    'wifi': wifi.toJson(),
    'screenLocked': screenLocked,
    'foregroundApp': foregroundApp,
    'timestamp': timestamp,
  };

  factory DeviceTelemetry.fromJson(Map<String, dynamic> json) {
    return DeviceTelemetry(
      battery: BatteryInfo.fromJson(json['battery'] as Map<String, dynamic>? ?? {}),
      wifi: WifiInfo.fromJson(json['wifi'] as Map<String, dynamic>? ?? {}),
      screenLocked: json['screenLocked'] as bool? ?? false,
      foregroundApp: json['foregroundApp'] as String? ?? 'None',
      timestamp: (json['timestamp'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  String toString() {
    return 'DeviceTelemetry(battery: ${battery.level}%, charging: ${battery.isCharging}, wifi: ${wifi.ssid.isNotEmpty ? wifi.ssid : "None"}, screenLocked: $screenLocked, app: $foregroundApp)';
  }
}
