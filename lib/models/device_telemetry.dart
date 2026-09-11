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

  // v1.1.0 新增原生拓展字段 (全部支持可空回退)
  final int? stepsToday;
  final String? ringerMode; // 'normal' | 'vibrate' | 'silent'
  final bool? isDnd;
  final bool? isMusicActive;
  final bool? isBluetoothAudio;
  final Map<String, dynamic>? nextAlarm; // {'triggerTime': int, 'formatted': String}
  final int? screenTimeMinutes;
  final bool? isIgnoringBatteryOptimizations;
  final bool? hasUsagePermission;

  DeviceTelemetry({
    required this.battery,
    required this.wifi,
    required this.screenLocked,
    required this.foregroundApp,
    required this.timestamp,
    this.stepsToday,
    this.ringerMode,
    this.isDnd,
    this.isMusicActive,
    this.isBluetoothAudio,
    this.nextAlarm,
    this.screenTimeMinutes,
    this.isIgnoringBatteryOptimizations,
    this.hasUsagePermission,
  });

  Map<String, dynamic> toJson() => {
    'battery': battery.toJson(),
    'wifi': wifi.toJson(),
    'screenLocked': screenLocked,
    'foregroundApp': foregroundApp,
    'timestamp': timestamp,
    if (stepsToday != null) 'stepsToday': stepsToday,
    if (ringerMode != null) 'ringerMode': ringerMode,
    if (isDnd != null) 'isDnd': isDnd,
    if (isMusicActive != null) 'isMusicActive': isMusicActive,
    if (isBluetoothAudio != null) 'isBluetoothAudio': isBluetoothAudio,
    if (nextAlarm != null) 'nextAlarm': nextAlarm,
    if (screenTimeMinutes != null) 'screenTimeMinutes': screenTimeMinutes,
    if (isIgnoringBatteryOptimizations != null)
      'isIgnoringBatteryOptimizations': isIgnoringBatteryOptimizations,
    if (hasUsagePermission != null) 'hasUsagePermission': hasUsagePermission,
  };

  factory DeviceTelemetry.fromJson(Map<String, dynamic> json) {
    return DeviceTelemetry(
      battery: BatteryInfo.fromJson(json['battery'] as Map<String, dynamic>? ?? {}),
      wifi: WifiInfo.fromJson(json['wifi'] as Map<String, dynamic>? ?? {}),
      screenLocked: json['screenLocked'] as bool? ?? false,
      foregroundApp: json['foregroundApp'] as String? ?? 'None',
      timestamp: (json['timestamp'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      stepsToday: (json['stepsToday'] as num?)?.toInt(),
      ringerMode: json['ringerMode'] as String?,
      isDnd: json['isDnd'] as bool?,
      isMusicActive: json['isMusicActive'] as bool?,
      isBluetoothAudio: json['isBluetoothAudio'] as bool?,
      nextAlarm: json['nextAlarm'] != null
          ? Map<String, dynamic>.from(json['nextAlarm'] as Map)
          : null,
      screenTimeMinutes: (json['screenTimeMinutes'] as num?)?.toInt(),
      isIgnoringBatteryOptimizations: json['isIgnoringBatteryOptimizations'] as bool?,
      hasUsagePermission: json['hasUsagePermission'] as bool?,
    );
  }

  @override
  String toString() {
    return 'DeviceTelemetry(battery: ${battery.level}%, charging: ${battery.isCharging}, wifi: ${wifi.ssid.isNotEmpty ? wifi.ssid : "None"}, screenLocked: $screenLocked, app: $foregroundApp, stepsToday: $stepsToday, ringer: $ringerMode, dnd: $isDnd, music: $isMusicActive, btAudio: $isBluetoothAudio, nextAlarm: ${nextAlarm?['formatted']}, screenTime: ${screenTimeMinutes}m, batteryOptIgnored: $isIgnoringBatteryOptimizations, usagePerm: $hasUsagePermission)';
  }
}
