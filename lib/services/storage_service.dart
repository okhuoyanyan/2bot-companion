import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:meta/meta.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cross_isolate_lock.dart';

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

  /// 测试辅助：清空静态缓存（WO-69 单测隔离用；生产代码严禁调用）
  @visibleForTesting
  static void resetForTest() {
    _prefs = null;
    _mailAuthCode = '';
    _mailCryptKey = '';
  }

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

    Map<String, bool>? eventSwitches;
    final switchesJson = p.getString(AppConstants.keyEventSwitches);
    if (switchesJson != null && switchesJson.isNotEmpty) {
      try {
        final decoded = json.decode(switchesJson) as Map<String, dynamic>;
        eventSwitches = decoded.map((k, v) => MapEntry(k, v == true));
      } catch (_) {}
    }

    Map<String, String>? placeLabels;
    final placeLabelsJson = p.getString(AppConstants.keyPlaceLabels);
    if (placeLabelsJson != null && placeLabelsJson.isNotEmpty) {
      try {
        final decoded = json.decode(placeLabelsJson) as Map<String, dynamic>;
        placeLabels = decoded.map((k, v) => MapEntry(k, v.toString()));
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
      throttleIntervalSeconds: p.getInt(AppConstants.keyThrottleSeconds) ?? AppConstants.defaultThrottleSeconds,
      silenceTimeoutHours: p.getInt(AppConstants.keySilenceTimeoutHours) ?? AppConstants.defaultSilenceTimeoutHours,
      eventSwitches: eventSwitches,
      placeLabels: placeLabels,
      calendarSyncEnabled:
          p.getBool(AppConstants.keyCalendarSyncEnabled) ?? false,
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

  /// 保存 WO-37 节流调度与事件开关配置
  static Future<void> saveThrottleAndEventConfig({
    required int throttleIntervalSeconds,
    required int silenceTimeoutHours,
    required Map<String, bool> eventSwitches,
  }) async {
    final p = prefs;
    await p.setInt(AppConstants.keyThrottleSeconds, throttleIntervalSeconds);
    await p.setInt(AppConstants.keySilenceTimeoutHours, silenceTimeoutHours);
    await p.setString(AppConstants.keyEventSwitches, json.encode(eventSwitches));
  }

  /// 保存 WO-37 地点标注字典（SSID -> 地点标签）
  static Future<void> savePlaceLabels(Map<String, String> placeLabels) async {
    final p = prefs;
    await p.setString(AppConstants.keyPlaceLabels, json.encode(placeLabels));
  }

  /// 记录发现的 WiFi SSID（带首次与末次出现时间，用于地点标注点选列表）
  static Future<void> recordSsidSeen(String ssid) async {
    final trimmed = ssid.trim();
    if (trimmed.isEmpty || trimmed == '<unknown ssid>' || trimmed == '0x') {
      return;
    }
    final p = prefs;
    Map<String, dynamic> records = {};
    final raw = p.getString(AppConstants.keyRecordedSsids);
    if (raw != null && raw.isNotEmpty) {
      try {
        records = json.decode(raw) as Map<String, dynamic>;
      } catch (_) {}
    }

    final nowIso = DateTime.now().toIso8601String();
    if (records.containsKey(trimmed)) {
      final item = Map<String, dynamic>.from(records[trimmed] as Map);
      item['lastSeen'] = nowIso;
      records[trimmed] = item;
    } else {
      records[trimmed] = {
        'firstSeen': nowIso,
        'lastSeen': nowIso,
      };
    }
    await p.setString(AppConstants.keyRecordedSsids, json.encode(records));
  }

  /// 读取已记录的 WiFi SSID 列表
  static Map<String, dynamic> getRecordedSsids() {
    final raw = prefs.getString(AppConstants.keyRecordedSsids);
    if (raw != null && raw.isNotEmpty) {
      try {
        return json.decode(raw) as Map<String, dynamic>;
      } catch (_) {}
    }
    return {};
  }

  // ============================================================
  // WO-69 日历自动同步：开关 / UID 水位线 / 同步状态 / 幂等版本台账
  // （凭据零新增：授权码复用既有 secKeyMailAuthCode，绝不另存副本）
  // ============================================================

  /// 更新日历自动同步开关
  static Future<void> setCalendarSyncEnabled(bool enabled) async {
    await prefs.setBool(AppConstants.keyCalendarSyncEnabled, enabled);
  }

  /// 读取 UID 水位线；缺失/损坏一律回落全量首扫语义（与 NAS 侧同口径）
  static ({int? uidValidity, int lastProcessedUid}) loadCalendarWatermark() {
    final raw = prefs.getString(AppConstants.keyCalendarWatermark);
    if (raw == null || raw.isEmpty) {
      return (uidValidity: null, lastProcessedUid: 0);
    }
    try {
      final decoded = json.decode(raw) as Map<String, dynamic>;
      return (
        uidValidity: decoded['uidValidity'] == null
            ? null
            : int.tryParse('${decoded['uidValidity']}'),
        lastProcessedUid: int.tryParse('${decoded['lastProcessedUid']}') ?? 0,
      );
    } catch (_) {
      return (uidValidity: null, lastProcessedUid: 0);
    }
  }

  /// 原子写水位线（单键整体覆写；SharedPreferences 无 tmp+rename，靠单键不变式保一致）
  static Future<void> saveCalendarWatermark({
    required int? uidValidity,
    required int lastProcessedUid,
  }) async {
    await prefs.setString(
      AppConstants.keyCalendarWatermark,
      json.encode({
        'uidValidity': uidValidity,
        'lastProcessedUid': lastProcessedUid,
      }),
    );
  }

  /// 读取同步状态（设置页展示：上次同步时间/结果）
  static Map<String, dynamic> loadCalendarSyncState() {
    final raw = prefs.getString(AppConstants.keyCalendarSyncState);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = json.decode(raw);
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return {};
    }
  }

  static Future<void> saveCalendarSyncState(Map<String, dynamic> state) async {
    await prefs.setString(
      AppConstants.keyCalendarSyncState,
      json.encode(state),
    );
  }

  /// 读取幂等版本台账 {uid: {sequence, lastModifiedMs, cancelled}}
  static Map<String, Map<String, dynamic>> loadCalendarEventLedger() {
    final raw = prefs.getString(AppConstants.keyCalendarEventLedger);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = json.decode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) =>
          MapEntry(k, (v as Map).cast<String, dynamic>()));
    } catch (_) {
      return {};
    }
  }

  static Future<void> saveCalendarEventLedger(
      Map<String, Map<String, dynamic>> ledger) async {
    await prefs.setString(
      AppConstants.keyCalendarEventLedger,
      json.encode(ledger),
    );
  }

  // ============================================================
  // WO-69 驳回整改：遥测闸门判定记录（设置页可见：尝试时间/原因/闸门）
  // 写入走各 isolate 缓存；读取一律走 SharedPreferencesAsync（直读平台层，
  // 跨 isolate 一致——旧版页面读到昨天旧状态正是缓存隔离所致）
  // ============================================================
  static const String keyTelemetryAttempts = 'pref_telemetry_attempts';

  static Future<void> recordTelemetryAttempt({
    required String trigger,
    required String gate,
    String? detail,
    required DateTime at,
  }) async {
    // P3（第三轮整改）：写端原走本 isolate 缓存单例 → 双 isolate 并发丢更新；
    // 现统一 SharedPreferencesAsync + 与 SMTP 会话闸【共用同一把 OS 级锁】
    //（读-改-写全程持锁，跨 isolate 真互斥）
    // 闸门记录是可丢弃观测数据：任何失败（平台未初始化/锁不可用）不得影响上报主链
    try {
      await crossIsolateSynchronized('smtp-gate', () async {
      final asyncPrefs = SharedPreferencesAsync();
      List<dynamic> list = [];
      final raw = await asyncPrefs.getString(keyTelemetryAttempts);
      if (raw != null && raw.isNotEmpty) {
        try {
          list = json.decode(raw) as List<dynamic>;
        } catch (_) {}
      }
      list.insert(0, {
        'at': at.toIso8601String(),
        'trigger': trigger,
        'gate': gate,
        if (detail != null) 'detail': detail,
      });
      if (list.length > 8) list = list.sublist(0, 8);
      await asyncPrefs.setString(keyTelemetryAttempts, json.encode(list));
      });
    } catch (_) {}
  }

  /// UI 读取：直读平台层（SharedPreferencesAsync），绕过本 isolate 缓存
  static Future<List<Map<String, dynamic>>> loadTelemetryAttempts() async {
    try {
      final asyncPrefs = SharedPreferencesAsync();
      final raw = await asyncPrefs.getString(keyTelemetryAttempts);
      if (raw == null || raw.isEmpty) return [];
      final decoded = json.decode(raw);
      if (decoded is List) {
        return decoded.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
      }
    } catch (_) {}
    return [];
  }

  /// 日历同步状态 UI 读取：同上直读平台层（驳回缺陷三：旧缓存导致页面显示昨日状态）
  static Future<Map<String, dynamic>> loadCalendarSyncStateFresh() async {
    try {
      final asyncPrefs = SharedPreferencesAsync();
      final raw = await asyncPrefs.getString(AppConstants.keyCalendarSyncState);
      if (raw == null || raw.isEmpty) return {};
      final decoded = json.decode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return {};
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
