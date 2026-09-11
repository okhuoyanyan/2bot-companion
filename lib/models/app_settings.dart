import '../utils/constants.dart';

/// 应用配置与状态持久化模型
class AppSettings {
  String relayUrl;
  String deviceToken;
  int intervalMinutes;
  bool isServiceEnabled;
  DateTime? lastReportTime;
  String? lastReportStatus;
  String? lastErrorMessage;

  AppSettings({
    this.relayUrl = AppConstants.defaultRelayUrl,
    this.deviceToken = AppConstants.defaultDeviceToken,
    this.intervalMinutes = AppConstants.defaultIntervalMinutes,
    this.isServiceEnabled = false,
    this.lastReportTime,
    this.lastReportStatus,
    this.lastErrorMessage,
  });

  AppSettings copyWith({
    String? relayUrl,
    String? deviceToken,
    int? intervalMinutes,
    bool? isServiceEnabled,
    DateTime? lastReportTime,
    String? lastReportStatus,
    String? lastErrorMessage,
  }) {
    return AppSettings(
      relayUrl: relayUrl ?? this.relayUrl,
      deviceToken: deviceToken ?? this.deviceToken,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      isServiceEnabled: isServiceEnabled ?? this.isServiceEnabled,
      lastReportTime: lastReportTime ?? this.lastReportTime,
      lastReportStatus: lastReportStatus ?? this.lastReportStatus,
      lastErrorMessage: lastErrorMessage ?? this.lastErrorMessage,
    );
  }
}
