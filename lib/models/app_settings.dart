import '../utils/constants.dart';

/// 应用配置与状态持久化模型
///
/// WO-36：新增传输层双模（relay / mail）。relay 旧字段全部原样保留 = 配置级回滚能力。
/// **凭据纪律**：`mailAuthCode` / `mailCryptKey` 仅存于 flutter_secure_storage，
/// 绝不写入明文 SharedPreferences（本模型只在内存中持有）。
class AppSettings {
  String relayUrl;
  String deviceToken;
  int intervalMinutes;
  bool isServiceEnabled;
  DateTime? lastReportTime;
  String? lastReportStatus;
  String? lastErrorMessage;

  /// 传输模式：'relay'（默认，旧路径）/ 'mail'（WO-36 邮箱信道）
  String transportMode;

  /// 邮箱账号（收发同源）
  String mailAccount;

  /// 收件地址；留空则默认等于 mailAccount
  String mailRecipient;

  /// 邮件主题前缀（须与 NAS 侧一致）
  String mailSubjectPrefix;

  /// SMTP 授权码（安全存储；内存态）
  String mailAuthCode;

  /// AES-256-GCM 密钥，64 个 hex 字符（安全存储；内存态）
  String mailCryptKey;

  AppSettings({
    this.relayUrl = AppConstants.defaultRelayUrl,
    this.deviceToken = AppConstants.defaultDeviceToken,
    this.intervalMinutes = AppConstants.defaultIntervalMinutes,
    this.isServiceEnabled = false,
    this.lastReportTime,
    this.lastReportStatus,
    this.lastErrorMessage,
    this.transportMode = AppConstants.transportRelay,
    this.mailAccount = '',
    this.mailRecipient = '',
    this.mailSubjectPrefix = AppConstants.defaultSubjectPrefix,
    this.mailAuthCode = '',
    this.mailCryptKey = '',
  });

  /// 当前是否走邮箱信道
  bool get isMailMode => transportMode == AppConstants.transportMail;

  /// 邮箱信道的有效收件地址（留空回落到发信账号 = 单邮箱自发自收）
  String get effectiveMailRecipient =>
      mailRecipient.trim().isEmpty ? mailAccount.trim() : mailRecipient.trim();

  /// 64 位十六进制字符串正则（AES-256-GCM 密钥，32 字节）
  static final RegExp _hex64Regex = RegExp(r'^[0-9a-fA-F]{64}$');

  /// 当前选定通信信道是否已配置就绪（UI 引导横幅显隐与健康度判定标准）
  ///
  /// - mail 模式：mailAccount 与 mailAuthCode 非空；若配置了 mailCryptKey，必须为 64 位 hex
  /// - relay 模式：维持既有口径（deviceToken 非空 且 relayUrl 非默认占位且非空）
  bool get isChannelReady {
    if (isMailMode) {
      if (mailAccount.trim().isEmpty || mailAuthCode.trim().isEmpty) {
        return false;
      }
      final key = mailCryptKey.trim();
      if (key.isNotEmpty && !_hex64Regex.hasMatch(key)) {
        return false;
      }
      return true;
    } else {
      final token = deviceToken.trim();
      final url = relayUrl.trim();
      return token.isNotEmpty &&
          url.isNotEmpty &&
          !url.contains('your-relay-service');
    }
  }

  AppSettings copyWith({
    String? relayUrl,
    String? deviceToken,
    int? intervalMinutes,
    bool? isServiceEnabled,
    DateTime? lastReportTime,
    String? lastReportStatus,
    String? lastErrorMessage,
    String? transportMode,
    String? mailAccount,
    String? mailRecipient,
    String? mailSubjectPrefix,
    String? mailAuthCode,
    String? mailCryptKey,
  }) {
    return AppSettings(
      relayUrl: relayUrl ?? this.relayUrl,
      deviceToken: deviceToken ?? this.deviceToken,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      isServiceEnabled: isServiceEnabled ?? this.isServiceEnabled,
      lastReportTime: lastReportTime ?? this.lastReportTime,
      lastReportStatus: lastReportStatus ?? this.lastReportStatus,
      lastErrorMessage: lastErrorMessage ?? this.lastErrorMessage,
      transportMode: transportMode ?? this.transportMode,
      mailAccount: mailAccount ?? this.mailAccount,
      mailRecipient: mailRecipient ?? this.mailRecipient,
      mailSubjectPrefix: mailSubjectPrefix ?? this.mailSubjectPrefix,
      mailAuthCode: mailAuthCode ?? this.mailAuthCode,
      mailCryptKey: mailCryptKey ?? this.mailCryptKey,
    );
  }
}
