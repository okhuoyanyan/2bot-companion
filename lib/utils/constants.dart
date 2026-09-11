/// 2BOT 官方伴侣端核心全局常量与默认配置
class AppConstants {
  // 默认中继服务地址（官方 Vercel Serverless 中继）
  static const String defaultRelayUrl = 'https://2bot-relay.vercel.app';
  
  // 默认设备鉴权密钥
  static const String defaultDeviceToken = 'telemetry_sec_8848';

  // 默认定时上报频率（分钟）
  static const int defaultIntervalMinutes = 10;

  // 上报频率可选列表（分钟）
  static const List<int> availableIntervals = [5, 10, 15, 30];

  // SharedPreferences 键名
  static const String keyRelayUrl = 'pref_relay_url';
  static const String keyDeviceToken = 'pref_device_token';
  static const String keyIntervalMinutes = 'pref_interval_minutes';
  static const String keyServiceEnabled = 'pref_service_enabled';
  static const String keyLastReportTime = 'pref_last_report_time';
  static const String keyLastReportStatus = 'pref_last_report_status';
  static const String keyLastErrorMessage = 'pref_last_error_message';

  // 前台服务通知配置
  static const String notificationChannelId = '2bot_companion_channel';
  static const String notificationChannelName = '2BOT 伴侣后台保活服务';
  static const String notificationTitle = '2BOT 伴侣正在守护中...';
  static const String notificationDesc = '设备状态感知与生命脉搏双驱动保活中';
}
