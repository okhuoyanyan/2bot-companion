import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../utils/constants.dart';

/// 本地持久化配置服务
///
/// WO-36 凭据纪律：非敏感配置走 SharedPreferences；
/// **授权码与加密密钥一律走 flutter_secure_storage**（Android Keystore 加密），严禁明文落盘。
/// 安全存储读取为异步，故在 [init] 期一次性载入内存缓存，保持 [loadSettings] 的同步契约不变
/// （既有调用点 background_task_service / home_screen 零改动）。
class StorageService {
  static SharedPreferences? _prefs;
  static const FlutterSecureStorage _secure = FlutterSecureStorage();
  static String _mailAuthCode = '';
  static String _mailCryptKey = '';

  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    try {
      _mailAuthCode = await _secure.read(key: AppConstants.secKeyMailAuthCode) ?? '';
      _mailCryptKey = await _secure.read(key: AppConstants.secKeyMailCryptKey) ?? '';
    } catch (_) {
      // 安全存储不可用（极旧机型/未初始化）时保持空串：mail 模式会被发送前置校验拦下并提示，
      // 绝不静默降级为明文存储。
      _mailAuthCode = '';
      _mailCryptKey = '';
    }
  }

  static SharedPreferences get prefs {
    if (_prefs == null) {
      throw StateError('StorageService 必须先调用 init() 初始化！');
    }
    return _prefs!;
  }

  /// 加载所有已保存的配置项（含安全存储中的凭据缓存）
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
      transportMode: p.getString(AppConstants.keyTransportMode) ?? AppConstants.transportRelay,
      mailAccount: p.getString(AppConstants.keyMailAccount) ?? '',
      mailRecipient: p.getString(AppConstants.keyMailRecipient) ?? '',
      mailSubjectPrefix: p.getString(AppConstants.keyMailSubjectPrefix) ?? AppConstants.defaultSubjectPrefix,
      mailAuthCode: _mailAuthCode,
      mailCryptKey: _mailCryptKey,
    );
  }

  /// 保存核心基础配置（relay 旧字段 + WO-36 传输模式与邮箱参数）
  ///
  /// 凭据（授权码 / 加密密钥）写入安全存储并同步刷新内存缓存；
  /// 传 null 表示「不修改该凭据」（避免 UI 留空时误清空已存凭据）。
  static Future<void> saveConfig({
    required String relayUrl,
    required String deviceToken,
    required int intervalMinutes,
    String? transportMode,
    String? mailAccount,
    String? mailRecipient,
    String? mailSubjectPrefix,
    String? mailAuthCode,
    String? mailCryptKey,
  }) async {
    final p = prefs;
    await p.setString(AppConstants.keyRelayUrl, relayUrl.trim());
    await p.setString(AppConstants.keyDeviceToken, deviceToken.trim());
    await p.setInt(AppConstants.keyIntervalMinutes, intervalMinutes);

    if (transportMode != null) {
      await p.setString(AppConstants.keyTransportMode, transportMode.trim());
    }
    if (mailAccount != null) {
      await p.setString(AppConstants.keyMailAccount, mailAccount.trim());
    }
    if (mailRecipient != null) {
      await p.setString(AppConstants.keyMailRecipient, mailRecipient.trim());
    }
    if (mailSubjectPrefix != null && mailSubjectPrefix.trim().isNotEmpty) {
      await p.setString(AppConstants.keyMailSubjectPrefix, mailSubjectPrefix.trim());
    }
    if (mailAuthCode != null) {
      _mailAuthCode = mailAuthCode.trim();
      await _secure.write(key: AppConstants.secKeyMailAuthCode, value: _mailAuthCode);
    }
    if (mailCryptKey != null) {
      _mailCryptKey = mailCryptKey.trim();
      await _secure.write(key: AppConstants.secKeyMailCryptKey, value: _mailCryptKey);
    }
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
