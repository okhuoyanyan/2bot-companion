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

/// GPS / 网络定位地理位置模型 (v1.3.0 新增)
class LocationInfo {
  final double latitude;
  final double longitude;
  final double? accuracy;
  final double? altitude;
  final double? speed;
  final double? bearing;
  final String? provider;
  final int? time;

  LocationInfo({
    required this.latitude,
    required this.longitude,
    this.accuracy,
    this.altitude,
    this.speed,
    this.bearing,
    this.provider,
    this.time,
  });

  Map<String, dynamic> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    if (accuracy != null) 'accuracy': accuracy,
    if (altitude != null) 'altitude': altitude,
    if (speed != null) 'speed': speed,
    if (bearing != null) 'bearing': bearing,
    if (provider != null) 'provider': provider,
    if (time != null) 'time': time,
  };

  factory LocationInfo.fromJson(Map<String, dynamic> json) {
    return LocationInfo(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      accuracy: (json['accuracy'] as num?)?.toDouble(),
      altitude: (json['altitude'] as num?)?.toDouble(),
      speed: (json['speed'] as num?)?.toDouble(),
      bearing: (json['bearing'] as num?)?.toDouble(),
      provider: json['provider'] as String?,
      time: (json['time'] as num?)?.toInt(),
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

  // v1.3.0 新增地理位置字段
  final LocationInfo? location;

  // Convenience getters
  int get batteryLevel => battery.level;
  bool get isCharging => battery.isCharging;

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
    this.location,
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
    if (location != null) 'location': location!.toJson(),
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
      location: json['location'] != null
          ? LocationInfo.fromJson(Map<String, dynamic>.from(json['location'] as Map))
          : null,
    );
  }

  @override
  String toString() {
    return 'DeviceTelemetry(battery: ${battery.level}%, charging: ${battery.isCharging}, wifi: ${wifi.ssid.isNotEmpty ? wifi.ssid : "None"}, screenLocked: $screenLocked, app: $foregroundApp, stepsToday: $stepsToday, ringer: $ringerMode, dnd: $isDnd, music: $isMusicActive, btAudio: $isBluetoothAudio, nextAlarm: ${nextAlarm?['formatted']}, screenTime: ${screenTimeMinutes}m, batteryOptIgnored: $isIgnoringBatteryOptimizations, usagePerm: $hasUsagePermission, location: $location)';
  }
}
