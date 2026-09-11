import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_settings.dart';
import '../utils/constants.dart';

/// 本地持久化配置服务
class StorageService {
  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  static SharedPreferences get prefs {
    if (_prefs == null) {
      throw StateError('StorageService 必须先调用 init() 初始化！');
    }
    return _prefs!;
  }

  /// 加载所有已保存的配置项
  static AppSettings loadSettings() {
    final p = prefs;
    final lastReportIso = p.getString(AppConstants.keyLastReportTime);
    DateTime? lastReportTime;
    if (lastReportIso != null && lastReportIso.isNotEmpty) {
      try {
        lastReportTime = DateTime.parse(lastReportIso);
      } catch (_) {}
    }

    return AppSettings(
      relayUrl: p.getString(AppConstants.keyRelayUrl) ?? AppConstants.defaultRelayUrl,
      deviceToken: p.getString(AppConstants.keyDeviceToken) ?? AppConstants.defaultDeviceToken,
      intervalMinutes: p.getInt(AppConstants.keyIntervalMinutes) ?? AppConstants.defaultIntervalMinutes,
      isServiceEnabled: p.getBool(AppConstants.keyServiceEnabled) ?? false,
      lastReportTime: lastReportTime,
      lastReportStatus: p.getString(AppConstants.keyLastReportStatus),
      lastErrorMessage: p.getString(AppConstants.keyLastErrorMessage),
    );
  }

  /// 保存核心基础配置
  static Future<void> saveConfig({
    required String relayUrl,
    required String deviceToken,
    required int intervalMinutes,
  }) async {
    final p = prefs;
    await p.setString(AppConstants.keyRelayUrl, relayUrl.trim());
    await p.setString(AppConstants.keyDeviceToken, deviceToken.trim());
    await p.setInt(AppConstants.keyIntervalMinutes, intervalMinutes);
  }

  /// 更新前台服务运行开关
  static Future<void> setServiceEnabled(bool enabled) async {
    await prefs.setBool(AppConstants.keyServiceEnabled, enabled);
  }

  /// 记录上报状态与时间
  static Future<void> recordReportResult({
    required bool success,
    required String statusText,
    String? errorMessage,
  }) async {
    final p = prefs;
    final now = DateTime.now();
    await p.setString(AppConstants.keyLastReportTime, now.toIso8601String());
    await p.setString(AppConstants.keyLastReportStatus, statusText);
    if (errorMessage != null) {
      await p.setString(AppConstants.keyLastErrorMessage, errorMessage);
    } else {
      await p.remove(AppConstants.keyLastErrorMessage);
    }
  }
}
