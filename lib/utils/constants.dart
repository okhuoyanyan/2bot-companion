/// 2BOT 官方伴侣端核心全局常量与默认配置
class AppConstants {
  // 默认中继服务地址（安全通用占位符，需替换为您自己部署的中继域名）
  static const String defaultRelayUrl = 'https://your-relay-service.vercel.app';
  
  // 默认设备鉴权密钥（初始为空，强制引导用户在设置中配置私有密钥）
  static const String defaultDeviceToken = '';

  // 默认定时上报频率（分钟）
  static const int defaultIntervalMinutes = 10;

  // 上报频率可选列表（分钟）
  static const List<int> availableIntervals = [5, 10, 15, 30];

  // ============================================================
  // WO-36 传输层双模：relay（旧 HTTP 中继，原样保留 = 回滚能力）/ mail（QQ 邮箱信道）
  // ============================================================
  static const String transportRelay = 'relay';
  static const String transportMail = 'mail';

  /// 邮件主题前缀，须与 NAS 侧 config.deviceTelemetry.mail.subjectPrefix 逐字一致
  static const String defaultSubjectPrefix = 'X-2BOT-TEL';
  static const String defaultSmtpHost = 'smtp.qq.com';
  static const int defaultSmtpPort = 465;

  // ============================================================
  // WO-37 上报体系重构：事件驱动、节流调度器与地点标注常量
  // ============================================================
  static const int defaultThrottleSeconds = 90;
  static const List<int> availableThrottleSeconds = [90, 180, 600];

  static const int defaultSilenceTimeoutHours = 6;

  // SharedPreferences 键名（非敏感配置）
  static const String keyRelayUrl = 'pref_relay_url';
  static const String keyDeviceToken = 'pref_device_token';
  static const String keyIntervalMinutes = 'pref_interval_minutes';
  static const String keyThrottleSeconds = 'pref_throttle_seconds';
  static const String keySilenceTimeoutHours = 'pref_silence_timeout_hours';
  static const String keyEventSwitches = 'pref_event_switches';
  static const String keyPlaceLabels = 'pref_place_labels';
  static const String keyRecordedSsids = 'pref_recorded_ssids';
  static const String keyServiceEnabled = 'pref_service_enabled';
  static const String keyLastReportTime = 'pref_last_report_time';
  static const String keyLastReportStatus = 'pref_last_report_status';
  static const String keyLastErrorMessage = 'pref_last_error_message';
  static const String keyTransportMode = 'pref_transport_mode';
  static const String keyMailAccount = 'pref_mail_account';
  static const String keyMailRecipient = 'pref_mail_recipient';
  static const String keyMailSubjectPrefix = 'pref_mail_subject_prefix';

  // 安全存储键名（flutter_secure_storage；**授权码与加密密钥严禁明文落 SharedPreferences**）
  static const String secKeyMailAuthCode = 'sec_mail_auth_code';
  static const String secKeyMailCryptKey = 'sec_mail_crypt_key';

  // 前台服务通知配置
  static const String notificationChannelId = '2bot_companion_channel';
  static const String notificationChannelName = '2BOT 伴侣后台保活服务';
  static const String notificationTitle = '2BOT 伴侣正在守护中...';
  static const String notificationDesc = '设备状态感知与生命脉搏双驱动保活中';
}
