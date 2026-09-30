import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:meta/meta.dart';

import '../models/app_settings.dart';
import '../utils/constants.dart';
import 'calendar_local_service.dart';
import 'calendar_mail_extract.dart';
import 'ics_min_parser.dart';
import 'imap_idle_client.dart';
import 'storage_service.dart';

/// ============================================================================
/// WO-82-R1: 日历邮件正文内联标记契约（与 NAS 端 plugins/core/calendar.js 严格对齐）
/// ============================================================================
const String calInlineBegin = '=====2BOT-CAL-BEGIN=====';
const String calInlineEnd = '=====2BOT-CAL-END=====';

/// 从纯文本中寻找内联 ICS 标记段。
/// 找不到返回 null；残缺（有 begin 无 end，或内容不含 BEGIN:VCALENDAR）返回 null。
String? _extractInlineIcsFromText(String text) {
  final beginIdx = text.indexOf(calInlineBegin);
  if (beginIdx < 0) return null;
  final afterBegin = beginIdx + calInlineBegin.length;
  final endIdx = text.indexOf(calInlineEnd, afterBegin);
  if (endIdx < 0) {
    // 标记残缺：有 begin 却无 end
    return null;
  }
  final content = text.substring(afterBegin, endIdx).trim();
  if (!content.contains('BEGIN:VCALENDAR')) {
    // 标记残缺/内容损坏
    return null;
  }
  return content;
}

/// WO-82-R1: 双形态日历正文提取（解析增正文标记段，附件/内联都认，并存时标记段优先，残缺降级）
///
/// 1. 优先提取正文内联标记段（=====2BOT-CAL-BEGIN===== ... =====2BOT-CAL-END=====）
/// 2. 标记段残缺（例如有 BEGIN 缺 END）或未匹配时，降级提取附件（extractIcsFromMail）
/// 3. 并存时标记段优先
String? extractIcsFromMailDual(String raw) {
  // A. 直接从原始报文中尝试提取内联标记段
  if (raw.contains(calInlineBegin)) {
    final direct = _extractInlineIcsFromText(raw);
    if (direct != null) {
      return direct;
    }
    // raw 包含 begin 但匹配失败 → 标记残缺，直接降级到附件提取
    return extractIcsFromMail(raw);
  }

  // B. 若 raw 未直接包含 begin，但正文可能经过 MIME 传输编码（如 base64）
  final headerEnd = raw.indexOf('\r\n\r\n');
  final sep = headerEnd >= 0 ? 4 : (raw.indexOf('\n\n') >= 0 ? 2 : -1);
  if (sep >= 0) {
    final headerBlock = raw.substring(0, sep == 4 ? headerEnd : raw.indexOf('\n\n'));
    final body = raw.substring(sep == 4 ? headerEnd + 4 : raw.indexOf('\n\n') + 2);
    final lowerHeader = headerBlock.toLowerCase();
    if (lowerHeader.contains('content-transfer-encoding: base64')) {
      try {
        final decoded = utf8.decode(
            base64Decode(body.replaceAll(RegExp(r'\s+'), '')),
            allowMalformed: true);
        final fromDecoded = _extractInlineIcsFromText(decoded);
        if (fromDecoded != null) {
          return fromDecoded;
        }
      } catch (_) {}
    }
  }

  // C. 降级走既有附件提取
  return extractIcsFromMail(raw);
}


/// ============================================================================
/// WO-69 · 日历自动同步编排（IDLE 主路径秒级推送 + 15 分钟兜底轮询）
/// ============================================================================
/// 时效设计（工单 ④ 硬指标）：
///  - 主路径 = IMAP IDLE 长连接：SMTP 投递 → EXISTS 约 1.2s（本机实测）→ 拉取+解析+写日历
///    目标 ≤5s；每 25 分钟 DONE+重发 IDLE（实测服务端 30.0 分钟强制断开，留 5 分钟裕度）；
///  - 兜底 = 连续失败 ≥3 次后退避到 15 分钟节奏（整连重拉，防 QQ 风控；**绝不退化到 1 分钟轮询**）；
///  - 水位线纪律（与 NAS 同口径）：QQ flag 落不上 → "已处理"语义自建；空扫也推进；
///    坏件（解析失败）越过不阻塞；**通道写失败不越过**（下次重拉重放，幂等保证无害）；
///  - 隔离纪律：本服务所有异常自吞并落状态，绝不影响遥测 30s 扫描主线。
/// 幂等版本台账决策（纯逻辑，单测覆盖）
enum LedgerDecision { apply, skip }

class CalendarEventLedger {
  final Map<String, Map<String, dynamic>> entries;

  CalendarEventLedger(Map<String, Map<String, dynamic>>? initial)
      : entries = initial ?? <String, Map<String, dynamic>>{};

  /// 新旧判定：
  /// - **CANCELLED 墓碑一律 apply**（契约补充 2026-09-27 · 冻结于 WO-68-SPEC §7：
  ///   NAS 墓碑不保留删前 sequence、取消通告恒为 SEQUENCE=0 → 不得判为过时丢弃，
  ///   UID 命中即物理删除；UID 升序处理 + 删除幂等保证不误删后到的新版本）；
  /// - 非取消事件：SEQUENCE 大者新；相等看 LAST-MODIFIED；两者皆等 → 重复投递跳过。
  LedgerDecision decideFor(IcsEvent e) {
    if (e.cancelled) return LedgerDecision.apply;
    final known = entries[e.uid];
    if (known == null) return LedgerDecision.apply;
    final knownSeq = (known['sequence'] as num?)?.toInt() ?? 0;
    final knownLm = (known['lastModifiedMs'] as num?)?.toInt() ?? 0;
    final inSeq = e.sequence;
    final inLm = e.lastModified?.millisecondsSinceEpoch ?? 0;
    if (inSeq > knownSeq) return LedgerDecision.apply;
    if (inSeq == knownSeq && inLm > knownLm) return LedgerDecision.apply;
    return LedgerDecision.skip;
  }

  void recordApplied(IcsEvent e) {
    entries[e.uid] = {
      'sequence': e.sequence,
      'lastModifiedMs': e.lastModified?.millisecondsSinceEpoch ?? 0,
      if (e.cancelled) 'cancelled': true,
    };
  }
}

/// WO-82-R3 追加（12:12 跳信定案）：候选集相对 (lastUid, maxCandidate] 的缺口
/// 检测——QQ UID SEARCH 会静默漏件（实证：UID 1263 被漏、34s 后入箱的 1264
/// 反而在列），「空扫推进 maxSeen」语义会把漏件永久焊死。本函数给出缺口 UID
/// 列表（升序）；候选为空或最大候选 ≤ 水位线时返回空（无更高件=无缺口）。
@visibleForTesting
List<int> uidHoles(int lastUid, List<int> candidates) {
  if (candidates.isEmpty) return const <int>[];
  var maxC = candidates.first;
  for (final c in candidates) {
    if (c > maxC) maxC = c;
  }
  if (maxC <= lastUid) return const <int>[];
  final have = candidates.toSet();
  final holes = <int>[];
  for (var u = lastUid + 1; u <= maxC; u++) {
    if (!have.contains(u)) holes.add(u);
  }
  return holes;
}

/// 原生日历写入通道抽象（生产 = 本机事件库；MethodChannel 为降级回滚面）
abstract class CalendarGateway {
  /// 批量 upsert；CANCELLED 事件由原生侧按 UID 删除。失败抛异常。
  Future<void> upsertEvents(List<Map<String, dynamic>> events);

  /// 库内事件总数（WO-70 整改①同步后自检用；未知 = -1）
  Future<int> storedCount();

  /// 通道健康探测（可选实现；默认成功）
  Future<void> ping() async {}
}

/// WO-70：默认日历写入通道 = 本机事件库（CalendarProvider 路径降级为回滚面）
class EventStoreCalendarGateway implements CalendarGateway {
  @override
  Future<void> upsertEvents(List<Map<String, dynamic>> events) async {
    await CalendarLocalService.instance.applyAndPersist(events);
  }

  @override
  Future<int> storedCount() async =>
      CalendarLocalService.instance.store.events.length;

  @override
  Future<void> ping() async {}
}

class MethodChannelCalendarGateway implements CalendarGateway {
  static const MethodChannel _channel =
      MethodChannel(AppConstants.calendarChannelName);

  /// 通道往返超时（驳回缺陷二：MissingPluginException 是【立即抛】，
  /// 通道挂起是【永不完成】；10s 显式超时把「写入过慢/无应答」变成可判读错误）
  static const Duration channelTimeout = Duration(seconds: 10);

  @override
  Future<void> upsertEvents(List<Map<String, dynamic>> events) async {
    final sw = Stopwatch()..start();
    debugPrint('[WO69] 通道请求 upsertEvents(${events.length} 条)…');
    try {
      await _channel
          .invokeMethod('upsertEvents', {'events': events})
          .timeout(channelTimeout);
      lastRoundTripMs = sw.elapsedMilliseconds;
      debugPrint('[WO69] 通道响应 ${sw.elapsedMilliseconds}ms (${events.length} 条)');
    } on TimeoutException {
      debugPrint('[WO69] 通道往返超时 ${channelTimeout.inSeconds}s '
          '(${events.length} 条)——无应答或原生写入过慢');
      rethrow;
    }
  }

  /// 最近一次通道往返耗时（状态页展示：驳回硬性条件①）
  static int? lastRoundTripMs;

  @override
  Future<int> storedCount() async => -1; // 降级面无法回读库内条数

  @override
  Future<void> ping() async {
    final sw = Stopwatch()..start();
    await _channel.invokeMethod('ping').timeout(channelTimeout);
    lastRoundTripMs = sw.elapsedMilliseconds;
    debugPrint('[WO69] ping 往返 ${sw.elapsedMilliseconds}ms');
  }
}

/// ============================================================================
/// WO-84 WebDAV 优先快路（坚果云 ctag 明文比对）
/// ============================================================================
/// HTTP 429/503：限频 → 立即进入熔断退避（60s/120s），严禁 8s 死磕
class WebdavRateLimitedException implements Exception {
  final int statusCode;
  WebdavRateLimitedException(this.statusCode);
  @override
  String toString() => 'WebDAV 限频（HTTP $statusCode）';
}

/// 其它非 2xx（404=文件夹未就绪/401=凭据错/5xx 等）：计入连续失败
class WebdavUnreachableException implements Exception {
  final int statusCode;
  WebdavUnreachableException(this.statusCode);
  @override
  String toString() => 'WebDAV 不可达（HTTP $statusCode）';
}

/// WO-84：由三字段解析 WebDAV base（🔒 三字段全非空才启用快路；空=禁用）。
/// folder 规则：完整 http(s) URL → 逐字使用（测试/迁移覆盖）；`dav/…` → 视为
/// 已含 dav 根；其余 → 拼到坚果云 dav 根下。返回值恒以 `/` 结尾。
@visibleForTesting
String? webdavBaseFromSettings(String user, String pass, String folder) {
  if (user.trim().isEmpty || pass.trim().isEmpty || folder.trim().isEmpty) {
    return null;
  }
  final f = folder.trim();
  if (f.startsWith('http://') || f.startsWith('https://')) {
    return f.endsWith('/') ? f : '$f/';
  }
  const host = 'https://dav.jianguoyun.com';
  final clean = f.replaceAll(RegExp(r'^/+|/+$'), '');
  if (clean.isEmpty) return null;
  if (clean == 'dav' || clean.startsWith('dav/')) return '$host/$clean/';
  return '$host/dav/$clean/';
}

/// 邮件源抽象（生产 = QQ IMAP；测试 = 假实现）
abstract class CalendarMailSource {
  /// 连接并 SELECT INBOX；返回 UIDVALIDITY（拿不到为 null）
  Future<int?> connect();

  Future<({List<CalendarMail> mails, int maxSeenUid, List<int> candidates})>
      fetchNewSince(int lastProcessedUid);

  Future<bool> startIdle();
  Future<int?> waitForEvent({required Duration beat});

  /// WO-78-R3 ①：IDLE 生命周期日志出口（每跳一行）
  void Function(String line)? get onLifecycleLog;
  set onLifecycleLog(void Function(String line)? v);

  /// WO-82-R3：最近一次唤醒原因（'IDLE推送'/'兜底查件'）——
  /// 拉取日志触发原因的归因源；null=未知。
  String? get lastWakeReason;

  /// WO-78-R3 返工③：当前 INBOX EXISTS（UID 序列重置防御用）；null=不可知
  Future<int?> inboxExists();
  Future<void> stopIdle();
  Future<void> close();
}

class QqImapSource implements CalendarMailSource {
  final ImapConfig config;
  ImapIdleClient? _client;

  /// WO-71 任务 A.4：命令级日志出口（设置页可见）
  void Function(String line)? onCommandLog;

  /// WO-78-R3 ①：IDLE 生命周期日志出口（挂载/重挂/NOOP/推送/断开 每跳一行）
  @override
  void Function(String line)? onLifecycleLog;

  @override
  String? get lastWakeReason => _client?.lastWakeReason;

  @override
  Future<int?> inboxExists() => _client?.selectInboxExists() ?? Future.value(null);

  QqImapSource(this.config);

  @override
  Future<int?> connect() async {
    final client = ImapIdleClient(config: config);
    client.onCommandLog = onCommandLog;
    client.onLifecycleLog = onLifecycleLog;
    _client = client;
    final units = await client.connect();
    return parseUidValidity(units);
  }

  @override
  Future<({List<CalendarMail> mails, int maxSeenUid, List<int> candidates})>
      fetchNewSince(int lastProcessedUid) async {
    return _client!.fetchNewSince(lastProcessedUid);
  }

  @override
  Future<bool> startIdle() => _client!.startIdle();

  @override
  Future<int?> waitForEvent({required Duration beat}) =>
      _client!.waitForEvent(beat: beat);

  @override
  Future<void> stopIdle() => _client!.stopIdle();

  @override
  Future<void> close() async {
    await _client?.close();
    _client = null;
  }
}

/// 同步状态快照（设置页展示）
class CalendarSyncStatus {
  final DateTime? lastSyncAt;
  final String lastResult;
  final String? lastError;
  final String mode; // idle / poll / backoff / off

  const CalendarSyncStatus({
    this.lastSyncAt,
    this.lastResult = '',
    this.lastError,
    this.mode = 'off',
  });
}

/// WO-69 日历自动同步服务（每个 isolate 一个实例；后台任务 isolate 持有运行态）
class CalendarSyncService {
  /// 生产单例（后台任务 isolate 内使用）
  static final CalendarSyncService instance = CalendarSyncService();

  /// 依赖注入点（单测替换；生产走默认实现）
  final CalendarGateway gateway;
  final CalendarMailSource Function(AppSettings settings) sourceFactory;
  final AppSettings Function() settingsProvider;
  final void Function(CalendarSyncStatus status)? onStatus;

  bool _running = false;
  bool _stopRequested = false;
  Future<void>? _loop;
  CalendarMailSource? _currentSource;
  int _consecutiveFailures = 0;
  int _rebuildCount = 0; // WO-78-R3：连续会话重建计数（防打爆护栏）
  int _emptySearchStreak = 0; // WO-82-R3：连续 SEARCH 空返回计数（连接失智守卫）

  /// WO-82 终裁（8s 拍配套）：回退验证冷却——带删信箱 boxExists<水位线是
  /// 常态，v2 验证若每拍都跑=每拍 10s 全段重扫（8s 拍下=持续自压）。
  /// 🔴 纯时间键（真机 21:30 实证修正：水位线做键会在每次消费后失效——
  /// 冷却退化成每 ~36s 一轮 11s 重验证）；「序列是否重置」与具体水位线无关，
  /// 10 分钟内一次「序列健在」结论全局有效。真重置最坏延迟一冷却窗发现。
  DateTime? _rollbackVerifiedAt;
  String _mode = 'off';

  /// 主 isolate / 测试用默认构造
  CalendarSyncService({
    CalendarGateway? gateway,
    CalendarMailSource Function(AppSettings)? sourceFactory,
    AppSettings Function()? settingsProvider,
    this.onStatus,
  // WO-70 整改①（检测员指认断路）：默认写入通道 = 本机事件库。
  // 此前默认仍是 MethodChannelCalendarGateway（从未被后台 isolate 激活），
  // 导致 CalendarLocalService.store 恒空、/calendar.ics 恒 0 条。
  })  : gateway = gateway ?? EventStoreCalendarGateway(),
        sourceFactory = sourceFactory ??
            ((s) => QqImapSource(ImapConfig(
                  account: s.mailAccount,
                  authCode: s.mailAuthCode,
                ))),
        settingsProvider = settingsProvider ?? StorageService.loadSettings;

  /// 单测构造（全部可注入）
  CalendarSyncService.test({
    required this.gateway,
    required this.sourceFactory,
    required this.settingsProvider,
    this.onStatus,
  });

  /// 节拍常量（WO-84 终架构：WebDAV 优先、邮件兜底）
  ///
  /// 沿革：WO-82-R3 退役 10s 高频拍（挂载态发命令的协议违规致推送死亡）→
  /// 管理员终裁 8s IMAP 拍 → **WO-84**：8s 拍让位给 WebDAV ctag 快路（坚果云
  /// 纯文本 GET，绕开 QQ 索引层；未变零全量 GET 的配额红线），IMAP 邮件轮询
  /// 降为 90s 兜底（QQ 推送死亡 + 索引滞后 25-35s 实证下，邮件通道只承担兜底）。
  /// 🔒 前后台分档：WebDAV 前台 8s / 后台 FGS 30s（主 isolate 生命周期写 pref，
  /// FGS isolate 每拍读——WO-70 跨 isolate 同款模式）。
  static const Duration webdavForegroundBeat = Duration(seconds: 8);
  static const Duration webdavBackgroundBeat = Duration(seconds: 30);
  /// 邮件兜底轮询节拍（WebDAV 优先架构下的 IMAP 感知节拍）
  static const Duration mailFallbackBeat = Duration(seconds: 90);
  /// 🔒 频控熔断阶梯：429/503 或连续 2 次失败 → 60s/120s 指数退避，严禁 8s 死磕
  static const List<Duration> webdavBackoffLadder = [
    Duration(seconds: 60),
    Duration(seconds: 120),
  ];
  static const Duration fallbackPollInterval = Duration(minutes: 15);

  /// WO-69 追补整改（急件解耦）：会话失败退避——**严禁秒级热重试**。
  /// 实证：通道写失败 → 水位线卡死 → 本服务 1s/3s/10s 重连风暴 → QQ 风控 →
  /// 连累遥测 SMTP 535。现改为 60s / 300s / 15min（封顶 15min）。
  static const List<Duration> sessionBackoff = [
    Duration(seconds: 60),
    Duration(minutes: 5),
    Duration(minutes: 15),
  ];

  bool get isRunning => _running;
  String get mode => _mode;

  // ------------------------------------------------------------------
  // 生命周期
  // ------------------------------------------------------------------

  /// 30s tick 入口：按开关状态起/停（天然自愈：isolate 重启后下一 tick 即恢复）
  Future<void> tick() async {
    // WO-70：跨 isolate 写入可见性——先刷新 prefs 缓存再读开关
    //（否则任务 isolate 永远看到启动时的旧值）
    await StorageService.reloadPrefs();
    final settings = settingsProvider();
    // WO-70 自验观测：开关值与分支走向（不含任何凭据）
    // ignore: avoid_print
    print('[WO70] tick: calEnabled=${settings.calendarSyncEnabled} '
        'accountSet=${settings.mailAccount.trim().isNotEmpty} '
        'authSet=${settings.mailAuthCode.trim().isNotEmpty} '
        'running=$_running server=${CalendarLocalService.instance.isRunning}');
    final webdavReady = webdavBaseFromSettings(
            settings.webdavUser, settings.webdavPass, settings.webdavFolder) !=
        null;
    final shouldRun = settings.calendarSyncEnabled &&
        ((settings.mailAccount.trim().isNotEmpty &&
                settings.mailAuthCode.trim().isNotEmpty) ||
            webdavReady);
    // 本机只读服务与 IMAP 解耦：开关开即服务（IMAP 凭据缺失只影响拉取，
    // 不影响对外提供已同步内容；服务常驻由 tick 自愈维持）
    try {
      if (settings.calendarSyncEnabled) {
        await CalendarLocalService.instance.ensureStarted();
        // ignore: avoid_print
        print('[WO70] local service ensured: '
            'running=${CalendarLocalService.instance.isRunning} '
            'port=${CalendarLocalService.instance.port}');
      } else {
        await CalendarLocalService.instance.ensureStopped();
      }
    } catch (e) {
      // ignore: avoid_print
      print('[WO70] ensureStarted failed: $e');
    }
    if (shouldRun && !_running) {
      start();
    } else if (!shouldRun && _running) {
      await stop();
    }
  }

  // ------------------------------------------------------------------
  // WO-84 WebDAV 优先快路轮询器（坚果云）
  // ------------------------------------------------------------------

  Timer? _webdavTimer;
  bool _webdavInFlight = false;
  String? _lastWebdavCtag;
  int _webdavFailStreak = 0;
  bool _webdavBackoffActive = false;
  int _webdavBackoffLevel = 0; // 退避档位：首次进入=60s，退避中再失败升 120s

  void _startWebdavPoller() {
    _lastWebdavCtag = null;
    _webdavFailStreak = 0;
    _webdavBackoffActive = false;
    _scheduleWebdavTick(Duration.zero); // 启动即刻首探
  }

  void _scheduleWebdavTick(Duration delay) {
    _webdavTimer?.cancel();
    _webdavTimer = Timer(delay, _webdavTick);
  }

  void _stopWebdavPoller() {
    _webdavTimer?.cancel();
    _webdavTimer = null;
    _webdavInFlight = false;
  }

  Duration get _webdavCurrentBackoff =>
      webdavBackoffLadder[_webdavBackoffLevel.clamp(0, webdavBackoffLadder.length - 1)];

  /// 🔒 失败记账：429/503 立即熔断；其它失败连续 ≥2 次熔断。
  /// 阶梯语义：首次进入=60s；退避中再失败升 120s（封顶）；成功清零。
  /// 熔断进入只打一行日志（静默回落邮件兜底的可见锚点），期间不刷屏。
  @visibleForTesting
  void noteWebdavFailure(String why, {bool rateLimited = false}) {
    _webdavFailStreak++;
    if (rateLimited || _webdavFailStreak >= 2) {
      if (!_webdavBackoffActive) {
        _webdavBackoffActive = true;
        _webdavBackoffLevel = 0;
        // ignore: avoid_print
        print('[WO84] WebDAV 熔断退避 ${_webdavCurrentBackoff.inSeconds}s（$why）'
            '→ 邮件兜底承接（${mailFallbackBeat.inSeconds}s）');
      } else {
        _webdavBackoffLevel =
            (_webdavBackoffLevel + 1).clamp(0, webdavBackoffLadder.length - 1);
      }
    }
  }

  /// 成功记账：清失败链 + 解除熔断（一行恢复日志）
  @visibleForTesting
  void noteWebdavSuccess() {
    _webdavFailStreak = 0;
    _webdavBackoffLevel = 0;
    if (_webdavBackoffActive) {
      _webdavBackoffActive = false;
      // ignore: avoid_print
      print('[WO84] WebDAV 熔断解除，恢复快路节拍');
    }
  }

  /// 测试观测：熔断中的下一拍间隔（Duration.zero = 正常分档节拍调度）
  @visibleForTesting
  Duration get webdavNextIntervalForTest =>
      _webdavBackoffActive ? _webdavCurrentBackoff : Duration.zero;

  Future<void> _webdavTick() async {
    if (_stopRequested) return;
    var tier = webdavForegroundBeat;
    try {
      await StorageService.reloadPrefs();
      // 🔒 前后台分档：主 isolate 生命周期写 pref → FGS 每拍读（跨 isolate 桥）
      final foreground = StorageService.prefs
              .getBool(AppConstants.keyCalSyncForeground) ??
          false;
      tier = foreground ? webdavForegroundBeat : webdavBackgroundBeat;
    } catch (_) {}
    try {
      final s = settingsProvider();
      final base =
          webdavBaseFromSettings(s.webdavUser, s.webdavPass, s.webdavFolder);
      if (base == null) {
        // 空=禁用快路：不发任何网络请求，低频自检等配置变化
        _scheduleWebdavTick(webdavBackgroundBeat);
        return;
      }
      if (_webdavInFlight) {
        _scheduleWebdavTick(tier);
        return;
      }
      _webdavInFlight = true;
      try {
        await webdavProbeAndSync(base);
        noteWebdavSuccess();
      } on WebdavRateLimitedException catch (e) {
        noteWebdavFailure(e.toString(), rateLimited: true);
      } catch (e) {
        noteWebdavFailure(_safeMessage(e));
      } finally {
        _webdavInFlight = false;
      }
    } catch (_) {
      // 🔴 WebDAV 异常绝不崩服务：邮件兜底无缝承接（90s 拍独立运转）
    }
    if (_stopRequested) return;
    _scheduleWebdavTick(_webdavBackoffActive ? _webdavCurrentBackoff : tier);
  }

  /// 单拍探测（供轮询器与单测调用）：GET ctag.txt（明文，与内存值比对）→
  /// 未变 = 本拍结束（零全量 GET，配额红线）；变化 = GET calendar.ics →
  /// 走既有解析/台账/应用管线。ctag 仅在应用成功后提交（失败不消费，下拍重拉）。
  @visibleForTesting
  Future<void> webdavProbeAndSync(String base,
      {HttpClient? customClient}) async {
    final settings = settingsProvider();
    final auth =
        'Basic ${base64.encode(utf8.encode('${settings.webdavUser}:${settings.webdavPass}'))}';
    final uri = Uri.parse(base);
    final client = customClient ??
        (HttpClient()..connectionTimeout = const Duration(seconds: 3));
    try {
      // 🔒 纯文本 GET ctag（禁 PROPFIND/XML——Flutter 无 XML 解析器，WO-74 同款雷）
      final ctag = (await _webdavGetText(client, uri, 'ctag.txt', auth)).trim();
      if (ctag == _lastWebdavCtag) return; // 未变：零全量 GET
      final icsText = await _webdavGetText(client, uri, 'calendar.ics', auth);
      final applied = await _applyIcsSnapshot(icsText);
      _lastWebdavCtag = ctag; // 应用成功才提交 ctag（失败不消费变更）
      if (applied > 0) {
        // ignore: avoid_print
        print('[WO84] WebDAV ctag 变化 → 拉取并应用 $applied 条');
      }
    } finally {
      if (customClient == null) {
        client.close(force: true);
      }
    }
  }

  Future<String> _webdavGetText(
      HttpClient client, Uri base, String file, String auth) async {
    final req = await client
        .openUrl('GET', base.resolve(file))
        .timeout(const Duration(seconds: 5));
    req.headers.set(HttpHeaders.authorizationHeader, auth);
    final resp = await req.close().timeout(const Duration(seconds: 5));
    try {
      if (resp.statusCode == 429 || resp.statusCode == 503) {
        throw WebdavRateLimitedException(resp.statusCode);
      }
      if (resp.statusCode != 200) {
        throw WebdavUnreachableException(resp.statusCode);
      }
      return await utf8.decodeStream(resp).timeout(const Duration(seconds: 5));
    } finally {
      try {
        await resp.drain<void>();
      } catch (_) {}
    }
  }

  /// 全量 ICS 快照 → 既有解析/台账判新/分批应用管线（幂等；返回应用条数）
  Future<int> _applyIcsSnapshot(String icsText) async {
    final parsed = parseIcs(icsText);
    if (parsed.events.isEmpty) return 0;
    final ledger =
        CalendarEventLedger(StorageService.loadCalendarEventLedger());
    final decided = <IcsEvent>[];
    for (final e in parsed.events) {
      if (ledger.decideFor(e) == LedgerDecision.apply) {
        decided.add(e);
        ledger.recordApplied(e);
      }
    }
    if (decided.isEmpty) return 0;
    const batchSize = 50;
    for (var i = 0; i < decided.length; i += batchSize) {
      final chunk = decided.sublist(i,
          (i + batchSize) < decided.length ? i + batchSize : decided.length);
      await gateway.upsertEvents(chunk.map(_eventToNativeMap).toList());
    }
    await StorageService.saveCalendarEventLedger(ledger.entries);
    return decided.length;
  }

  /// 启动同步循环（幂等）：IMAP 邮件会话（90s 兜底）+ WebDAV 快路轮询器（8s/30s 分档）
  void start() {
    if (_running) return;
    _running = true;
    _stopRequested = false;
    _loop = _runLoop();
    _startWebdavPoller();
  }

  /// 停止（关连接、唤醒等待）
  Future<void> stop() async {
    _stopRequested = true;
    _running = false;
    _stopWebdavPoller();
    _mode = 'off';
    _setStatus(mode: 'off');
    try {
      await _currentSource?.close();
    } catch (_) {}
    final loop = _loop;
    if (loop != null) {
      try {
        await loop.timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    _loop = null;
  }

  // ------------------------------------------------------------------
  // 主循环
  // ------------------------------------------------------------------

  Future<void> _runLoop() async {
    _lastKnownState = await StorageService.loadCalendarSyncStateAsync();
    while (!_stopRequested) {
      try {
        final settings = settingsProvider();
        final mailReady = settings.mailAccount.trim().isNotEmpty &&
            settings.mailAuthCode.trim().isNotEmpty;
        final webdavReady = webdavBaseFromSettings(
                settings.webdavUser, settings.webdavPass, settings.webdavFolder) !=
            null;
        if (!settings.calendarSyncEnabled) {
          _mode = 'off';
          _setStatus(mode: 'off');
          if (await _sleep(const Duration(seconds: 60))) return;
          continue;
        }
        if (!mailReady) {
          // WO-84：WebDAV-only 模式——IMAP 会话让位，快路轮询器独立承载（mode=webdav）
          if (webdavReady) {
            _mode = 'webdav';
            if (await _sleep(const Duration(seconds: 30))) return;
            continue;
          }
          _mode = 'off';
          _setStatus(mode: 'off');
          if (await _sleep(const Duration(seconds: 60))) return;
          continue;
        }
        await _runSession(settings);
        // 会话正常退出（stop）即返回
        if (_stopRequested) return;
      } on ImapClosedException catch (e) {
        // WO-78-R3 ②/WO-82-R3：连接断开（BYE/FIN/DONE 无响应暴露的死连）≠ 持久性失败——
        // 立即重建会话（连接即做一次增量同步），不吃 60s 退避（旧路径白等）。
        // 防打爆护栏：连续重建 >3 次（flapping 网络）→ 30s 冷却；
        // 成功同步会把 _consecutiveFailures 清零 → 顺带解除冷却。
        if (_stopRequested) return;
        _rebuildCount++;
        // ignore: avoid_print
        print('[WO78-R3] 连接断开 → 重建会话（第 $_rebuildCount 次）：${_safeMessage(e)}');
        if (_rebuildCount > 3) {
          // ignore: avoid_print
          print('[WO78-R3] 连续重建超限，冷却 30s（网络 flapping 防打爆）');
          if (await _sleep(const Duration(seconds: 30))) return;
        }
        continue;
      } catch (e) {
        if (_stopRequested) return;
        _consecutiveFailures++;
        debugPrint('[WO69] 会话失败（第 $_consecutiveFailures 次）：${_safeMessage(e)}');
        // 有界退避：60s / 5min / 15min（封顶 15min）。严禁秒级热重试（急件解耦）。
        final wait = _consecutiveFailures <= sessionBackoff.length
            ? sessionBackoff[_consecutiveFailures - 1]
            : fallbackPollInterval;
        _mode = 'backoff';
        await _setStatus(
          mode: 'backoff',
          result: 'error',
          error: 'IMAP 会话失败（第 $_consecutiveFailures 次，${_formatWait(wait)}后重试）：${_safeMessage(e)}',
        );
        if (await _sleep(wait)) return;
      }
    }
  }

  /// 单次会话：连接 → 增量同步 → IDLE 长连接循环
  Future<void> _runSession(AppSettings settings) async {
    final source = sourceFactory(settings);
    if (source is QqImapSource) {
      source.onCommandLog = (line) {
        // WO-71 A.4：命令级可观测——写入状态环（设置页渲染最近 6 条）
        try {
          final st = _lastKnownState;
          final log = (st['imapLog'] as List?) ?? <dynamic>[];
          log.insert(0, '$line');
          st['imapLog'] = log.take(6).toList();
        } catch (_) {}
      };
      // WO-78-R3 ①：生命周期每跳一行——客户端已 print（logcat），此处仅入设置页环
      source.onLifecycleLog = (line) {
        try {
          final st = _lastKnownState;
          final log = (st['imapLog'] as List?) ?? <dynamic>[];
          log.insert(0, line);
          st['imapLog'] = log.take(6).toList();
        } catch (_) {}
      };
    }
    _currentSource = source;
    _emptySearchStreak = 0; // 失智计数随新会话清零
    // 通道健康探测：未激活（如开机自启、App 尚未打开过）只记录不自断——
    // 打开 App 一次保存设置后服务热重启即挂载通道（自愈路径）
    try {
      await gateway.ping();
      debugPrint('[WO69] 日历通道 ping OK');
    } catch (e) {
      debugPrint('[WO69] 日历通道未激活：${_safeMessage(e)}（打开 App 一次保存设置后自愈）');
    }
    try {
      final uidValidity = await source.connect();
      debugPrint('[WO69] IMAP 连接成功 (uidValidity=$uidValidity)');
      _lastKnownState = await StorageService.loadCalendarSyncStateAsync();
      var wm = StorageService.loadCalendarWatermark();
      var lastUid = wm.lastProcessedUid;
      if (wm.uidValidity != null &&
          uidValidity != null &&
          wm.uidValidity != uidValidity) {
        // 邮箱被重建：历史 UID 全作废 → 全量重扫（幂等 upsert 保证无害）
        lastUid = 0;
      }
      if (uidValidity != null && wm.uidValidity != uidValidity) {
        await StorageService.saveCalendarWatermark(
            uidValidity: uidValidity, lastProcessedUid: lastUid);
      }

      lastUid = await _syncIncrement(source, lastUid,
          uidValidity: uidValidity, trigger: '启动');
      _consecutiveFailures = 0;
      _rebuildCount = 0;
      _mode = 'idle';
      await _setStatus(mode: 'idle', result: 'ok');

      // IDLE 长连接循环（WO-82-R3 纯长持：推送主路径 + 90s 兜底，全程 G3 时序）
      while (!_stopRequested) {
        final accepted = await source.startIdle();
        if (!accepted) {
          _mode = 'poll';
          await _setStatus(mode: 'poll', error: '服务器不接受 IDLE，退化为兜底轮询');
          // 兜底轮询：每 15 分钟整连重拉（服务循环外层 sleep 实现同节奏）
          if (await _sleep(fallbackPollInterval)) return;
          lastUid = await _syncIncrement(source, lastUid,
              uidValidity: uidValidity, trigger: '轮询');
          await _setStatus(mode: 'poll', result: 'ok');
          continue;
        }
        // 🔴 G3 时序铁律（WO-82-R3）：waitForEvent 的两种返回——EXISTS 推送
        // （n>0）与 90s 兜底节拍（null）——都【保持 IDLE 挂载态】。发任何命令
        // 前必须先 stopIdle（②DONE → ③等 tag OK IDLE completed），之后才允许
        // ④SELECT/UID SEARCH/FETCH，循环顶部 ⑤重发 IDLE。挂载态直接发命令 =
        // 协议违规 → BAD 断连（WO-82 实证「连接每拍被服务端关闭」的真因）。
        // WO-84：邮件通道降为 90s 兜底节拍（WebDAV 快路承载 8s/30s 感知）
        final event = await source.waitForEvent(beat: mailFallbackBeat);
        if (_stopRequested) return;
        final pushed = event != null && event > 0;
        // ②③ DONE → tag OK（死连在此暴露为 ImapClosedException → 即时重建）
        await source.stopIdle();
        if (pushed) {
          debugPrint('[WO69] 推送唤醒 EXISTS=$event → G3 序列拉取');
        }
        // ④ 查件（未挂载态，协议合法）：SELECT EXISTS 供 UID 序列重置防御 +
        // UID 水位线增量（QQ 的 EXISTS 与 UID 水位线不同轴，新件判据走水位线）。
        final boxExists = await source.inboxExists().catchError((_) => null);
        lastUid = await _syncIncrement(source, lastUid,
            uidValidity: uidValidity,
            trigger: source.lastWakeReason ?? (pushed ? 'IDLE推送' : '兜底查件'),
            lightIdle: !pushed, // 兜底空扫不写状态盘（防节拍写放大）
            boxExists: boxExists);
        await _setStatus(mode: 'idle', result: 'ok');
        // ⑤ 循环顶部 startIdle 重挂
      }
    } finally {
      try {
        await source.close();
      } catch (_) {}
      if (identical(_currentSource, source)) _currentSource = null;
    }
  }

  /// 测试桥：单测直接驱动增量同步路径（生产零调用）
  @visibleForTesting
  Future<int> debugSyncIncrement(CalendarMailSource source, int lastUid,
          {int? uidValidity, String trigger = '启动', int? boxExists}) =>
      _syncIncrement(source, lastUid,
          uidValidity: uidValidity, trigger: trigger, boxExists: boxExists);

  /// WO-82-R3 追加：缺口重扫间隔（测试可缩至毫秒级；生产 5s——QQ 索引滞后
  /// 为秒级瞬态，两轮重扫覆盖 ~10s 窗口）
  @visibleForTesting
  Duration skipRetryDelay = const Duration(seconds: 5);

  /// 增量同步：粗筛→精筛→拉全文→提取 ICS→解析→幂等 upsert→推进水位线。
  /// 返回推进后的水位线（调用方保存）。[trigger]=拉取原因（拉取日志可观测）。
  Future<int> _syncIncrement(CalendarMailSource source, int lastUid,
      {int? uidValidity, String trigger = '启动', bool lightIdle = false,
      int? boxExists}) async {
    final sw = Stopwatch()..start();
    var scan = await source.fetchNewSince(lastUid);
    var mails = scan.mails;
    var maxSeen = scan.maxSeenUid;
    var candidates = scan.candidates;
    // WO-78-R3 返工③：QQ UID 序列重置防御——实测 QQ 在某时刻【静默重置 UID 序列】
    //（UIDVALIDITY 不变：违反 RFC 3501）：旧水位线(1238) 高于新序列最大 UID，
    // SEARCH UID n:* 永远空返回 → 水位线机制对该账号失效。防御：粗筛空返回
    // 且 boxExists < 水位线 → 判定序列重置 → 水位线回退到 boxExists 全量重扫
    //（幂等 upsert + 台账判重保证无害；新序列 minUID=1/maxUID=EXISTS 实测一致）。
    // WO-78-R3 返工③ + WO-82-R3 v2（真机实证修正 19:46）：QQ UID 序列重置防御。
    // 🔴 v2 修正：信箱带历史删除/移出（真机实证 EXISTS=1018 << 最大UID≈1290），
    // 旧判据「boxExists < 水位线 ⇒ 序列重置」在带删信箱【恒真】→ 每拍误鸣且回退
    // 重扫遇 SEARCH 瞬断（同刻 NAS 侧同命令返回正常——连接级瞬断）时把会话打进
    // 降级循环。改为【验证后采纳】三态：
    //  a) 回退重扫非空且 maxSeen < 回退前水位线 → 真重置（新序列低位且活着）→ 采纳；
    //  b) 回退重扫非空且 maxSeen ≥ 回退前 → 序列健在 → 恢复原水位线（重扫件台账幂等）；
    //  c) 回退重扫空返回（EXISTS 明言有信）→ SEARCH 瞬断（非重置）→ 恢复原水位线，
    //     交下方缺口/空返回重扫自愈。
    if (mails.isEmpty && maxSeen == 0 && boxExists != null && boxExists < lastUid) {
      final preRollback = lastUid;
      final verifiedRecently = _rollbackVerifiedAt != null &&
          DateTime.now().difference(_rollbackVerifiedAt!) <
              const Duration(minutes: 10);
      if (!verifiedRecently) {
        // ignore: avoid_print
        print('[WO78-R3] boxExists($boxExists) < 水位线($lastUid) → 回退验证重扫'
            '（v2 三态：真重置/序列健在/SEARCH 瞬断）');
        final retry = await source.fetchNewSince(boxExists);
        _rollbackVerifiedAt = DateTime.now();
        if (retry.mails.isNotEmpty || retry.maxSeenUid > 0) {
          if (retry.maxSeenUid < preRollback) {
            // a) 真重置
            // ignore: avoid_print
            print('[WO78-R3] 重置验证成立（新基线 max=${retry.maxSeenUid} < '
                '$preRollback）→ 水位线回退至 $boxExists 全量重扫（幂等）');
            mails = retry.mails;
            maxSeen = retry.maxSeenUid;
            candidates = retry.candidates;
            lastUid = boxExists;
          } else {
            // b) 序列健在
            // ignore: avoid_print
            print('[WO78-R3] 序列健在（重扫 max=${retry.maxSeenUid} ≥ $preRollback）'
                '→ 恢复水位线 $preRollback（重扫件台账幂等去重）');
            mails = retry.mails;
            maxSeen = retry.maxSeenUid;
            candidates = retry.candidates;
          }
        } else {
          // c) SEARCH 瞬断
          // ignore: avoid_print
          print('[WO82] 回退重扫空返回（EXISTS=$boxExists 明言有信）→ 判 SEARCH '
              '瞬断，恢复水位线 $preRollback（交缺口重扫自愈）');
        }
      }
      // verifiedRecently=true → 静默跳过（8s 拍常态路径零开销零日志）
    }

    // WO-82-R3 追加（12:12 跳信定案）：缺口检测 + 有界重扫。
    // 机理实证：QQ UID SEARCH 静默漏件（1263 被漏，34s 后入箱的 1264 反而在列）
    // + 「空扫推进 maxSeen」语义 = 漏件被永久焊死（幽灵事件 5 天）。防御指纹：
    // 候选集相对 (水位线, 最大候选] 存在缺口（SEARCH 漏件），或推送触发却
    // 「零新件」（服务端刚说有新件而扫描一无所见）。
    // 🔴 WO-82 终裁（8s 拍配套）：candidates.isEmpty 不再是通用怀疑指纹——
    // 水位线==服务器 max 是常态空闲态，QQ 按怪癖回空，8s 拍下每拍空烧 2×5s
    // 重试不可接受；空扫怀疑保留给推送触发（有 EXISTS 证据才值得重扫）。
    // 命中 → 5s×2 重扫（QQ 索引滞后为秒级瞬态）；仍缺口 → 水位线照常推进
    // （防卡死、防重扫风暴）+ [WO82] 疑似跳信行 + 状态标记（即刻可见）。
    var holes = uidHoles(lastUid, candidates);
    bool suspicious() =>
        holes.isNotEmpty ||
        (trigger == 'IDLE推送' && mails.isEmpty && maxSeen <= lastUid);
    for (var attempt = 0; suspicious() && attempt < 2; attempt++) {
      await Future<void>.delayed(skipRetryDelay);
      scan = await source.fetchNewSince(lastUid);
      mails = scan.mails;
      maxSeen = scan.maxSeenUid;
      candidates = scan.candidates;
      holes = uidHoles(lastUid, candidates);
    }

    // WO-82-R3：空返回连击守卫（纯长持配套）。长持下连接不再周期重建——若某
    // 连接的 SEARCH 持续空返回将永久聋化。连续 3 次空返回且 EXISTS 明言有信
    // → 判连接失智，转断连语义强制重建会话。
    if (candidates.isEmpty) {
      _emptySearchStreak++;
      if (boxExists != null && boxExists > 0 && _emptySearchStreak >= 3) {
        final streak = _emptySearchStreak;
        _emptySearchStreak = 0;
        throw ImapClosedException('连续 $streak 次 SEARCH 空返回且 '
            'EXISTS=$boxExists 明言有信（连接失智）→ 重建会话');
      }
    } else {
      _emptySearchStreak = 0;
    }
    if (holes.isNotEmpty) {
      // ignore: avoid_print
      print('[WO82] 疑似跳信（缺口 UID=${holes.take(5).join(',')}'
          '${holes.length > 5 ? ' 等${holes.length}个' : ''}）→ 重扫后仍缺口，'
          '水位线照常推进至 $maxSeen（已记观测标记，请 NAS 侧对账）');
      await _recordSkipSuspect(holes, maxSeen);
    }
    // WO-78-R3：观测行必须进 logcat（debugPrint 有节流丢弃；print 为 WO-70 同款先例）
    // ignore: avoid_print
    print('[WO78] 拉取(触发=$trigger)：水位线=$lastUid，粗筛 maxSeen=$maxSeen，'
        '日历新件=${mails.length} 封（粗筛 ${sw.elapsedMilliseconds}ms）');
    try {
      final st = _lastKnownState;
      final log = (st['imapLog'] as List?) ?? <dynamic>[];
      log.insert(0,
          '[WO78] 拉取(触发=$trigger) ${DateTime.now().toIso8601String().substring(11, 19)} 新件=${mails.length}');
      st['imapLog'] = log.take(6).toList();
    } catch (_) {}

    if (mails.isEmpty) {
      // 空扫也推进（防重复扫），与 NAS 同口径
      final next = maxSeen > lastUid ? maxSeen : lastUid;
      if (next > lastUid) {
        await StorageService.saveCalendarWatermark(
            uidValidity: uidValidity, lastProcessedUid: next);
      }
      if (!lightIdle) await _touchState(result: 'ok');
      return next;
    }

    final ledger = CalendarEventLedger(StorageService.loadCalendarEventLedger());
    var handledUid = lastUid;
    var appliedCount = 0;
    var badCount = 0;
    int? stateInStore; // 库内条数自检结果（null = 通道不可回读）
    final errors = <String>[];

    for (final mail in mails) {
      // WO-78/WO-82-R3-G4：端到端推送延迟（邮件 Date 头=NAS 发出时刻 → 入库侧
      // 到达），验收「推送行 ≤5s」的回测硬证据行（logcat 时间戳可对表）
      final mailDate = parseRfc5322Date(mail.raw);
      if (mailDate != null) {
        final sec = DateTime.now().difference(mailDate).inSeconds;
        // ignore: avoid_print
        print('[WO78] 推送到达（延迟 ${sec}s）→ 拉取（触发=$trigger，UID=${mail.uid}）');
      }
      final icsText = extractIcsFromMailDual(mail.raw);
      if (icsText == null) {
        badCount++;
        errors.add('UID ${mail.uid}: 日历正文/附件提取失败（结构超契约）');
        handledUid = mail.uid; // 坏件越过：重试无益，记错不阻塞
        continue;
      }
      final parsed = parseIcs(icsText);
      if (parsed.events.isEmpty && parsed.errors.isNotEmpty) {
        badCount++;
        errors.add('UID ${mail.uid}: ICS 解析失败（${parsed.errors.first}）');
        handledUid = mail.uid;
        continue;
      }

      // 台账判新旧 → 分批下发（驳回缺陷二(b)：首次全量 411 条单发调用过重）
      final decided = <IcsEvent>[];
      for (final e in parsed.events) {
        if (ledger.decideFor(e) == LedgerDecision.apply) {
          decided.add(e);
        }
      }
      const batchSize = 50;
      for (var i = 0; i < decided.length; i += batchSize) {
        final chunk = decided.sublist(
            i, (i + batchSize) < decided.length ? i + batchSize : decided.length);
        final chunkMaps = chunk.map(_eventToNativeMap).toList();
        try {
          await gateway.upsertEvents(chunkMaps);
        } catch (e) {
          // **通道写失败不越过**：水位线停在已处理边界；已成功的批次台账已记，
          // 下次重拉时已写条目按台账跳过 → 幂等续传
          errors.add('UID ${mail.uid}: 日历写入失败（通道）(${_safeMessage(e)}；'
              '本批 ${chunkMaps.length} 条，已累计应用 $appliedCount 条)');
          await _touchState(result: 'error', error: errors.last);
          await StorageService.saveCalendarWatermark(
              uidValidity: uidValidity, lastProcessedUid: handledUid);
          rethrow;
        }
        for (final e in chunk) {
          ledger.recordApplied(e);
        }
        await StorageService.saveCalendarEventLedger(ledger.entries);
        appliedCount += chunk.length;
      }
      handledUid = mail.uid;
    }

    // 成功路径推进到本轮粗筛所见最大 UID（含尾部非日历件，NAS 同口径）；
    // 坏件已越过、全部应用完毕，越过 maxSeen 段安全。通道失败路径在上方已按
    // handledUid（已处理边界）落盘并抛出，绝不越过未应用邮件。
    final next = handledUid > maxSeen ? handledUid : maxSeen;
    if (next > lastUid) {
      await StorageService.saveCalendarWatermark(
          uidValidity: uidValidity, lastProcessedUid: next);
    }
    // WO-70 整改①：同步后库内自检——本次解析应应用 N 条，库内总数不得少于
    // 已应用累计；不符（写通道断路/静默丢弃）→ 记 failed 而非 ok。
    var finalResult = errors.isEmpty ? 'ok' : 'partial';
    try {
      final inStore = await gateway.storedCount();
      if (inStore >= 0 && inStore < appliedCount) {
        finalResult = 'failed';
        errors.add('库内自检不符：本次应用 $appliedCount 条但库内仅 $inStore 条');
      }
      if (inStore >= 0) stateInStore = inStore;
    } catch (_) {
      stateInStore = null; // 自检不可用（降级面）不阻断
    }
    await _touchState(
      result: finalResult,
      error: errors.isEmpty ? null : errors.join('；'),
      applied: appliedCount,
      bad: badCount,
      inStore: stateInStore,
    );
    debugPrint('[WO69] 同步完成：水位线推进至 $next（应用 $appliedCount 条，'
        '坏件 $badCount 封）');
    return next > lastUid ? next : lastUid;
  }

  // ------------------------------------------------------------------
  // 工具
  // ------------------------------------------------------------------

  /// WO-78：从邮件原文解析 RFC 5322 Date 头（QQ 形如
  /// `Date: Thu, 01 Oct 2026 08:00:12 +0800`）；解析失败返回 null（不猜）。
  @visibleForTesting
  static DateTime? parseRfc5322Date(String raw) {
    final m = RegExp(
            r'Date:\s*(?:\w{3},?\s+)?(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+([+-]\d{4})',
            caseSensitive: false)
        .firstMatch(raw);
    if (m == null) return null;
    const months = {
      'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
      'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
    };
    final month = months[m.group(2)!.toLowerCase()];
    if (month == null) return null;
    final offset = m.group(7)!;
    final sign = offset[0] == '-' ? -1 : 1;
    final oh = int.parse(offset.substring(1, 3));
    final om = int.parse(offset.substring(3, 5));
    final utc = DateTime.utc(
        int.parse(m.group(3)!),
        month,
        int.parse(m.group(1)!),
        int.parse(m.group(4)!) - sign * oh,
        int.parse(m.group(5)!) - sign * om,
        int.parse(m.group(6)!));
    return utc; // UTC 时刻（本地差值用 DateTime.now() 差分，天然无歧义）
  }

  Map<String, dynamic> _eventToNativeMap(IcsEvent e) {
    // 结束时间：DTEND 优先，其次 DURATION；全天缺省 1 天、定时缺省 1 小时（防御性）
    Duration effectiveDuration = e.duration ??
        (e.allDay ? const Duration(days: 1) : const Duration(hours: 1));
    DateTime? end = e.dtend;
    if (end == null && !e.cancelled) {
      end = e.dtstart.add(effectiveDuration);
    }
    return {
      'uid': e.uid,
      'sequence': e.sequence,
      'dtstampMs': e.dtstamp?.millisecondsSinceEpoch,
      'lastModifiedMs': e.lastModified?.millisecondsSinceEpoch,
      'dtstartMs': e.dtstart.millisecondsSinceEpoch,
      'allDay': e.allDay,
      'endMs': end?.millisecondsSinceEpoch,
      'rrule': e.rrule,
      'summary': e.summary,
      'description': e.description,
      'cancelled': e.cancelled,
    };
  }

  String _formatWait(Duration d) {
    if (d.inMinutes >= 1) return d.inMinutes >= 15 ? '15 分钟' : '${d.inMinutes} 分钟';
    return '${d.inSeconds} 秒';
  }

  /// 分片睡眠：可被 stop() 及时打断。返回 true = 已请求停止。
  Future<bool> _sleep(Duration duration) async {
    const slice = Duration(milliseconds: 500);
    var remain = duration;
    while (remain > Duration.zero && !_stopRequested) {
      final step = remain < slice ? remain : slice;
      await Future<void>.delayed(step);
      remain -= step;
    }
    return _stopRequested;
  }

  Future<void> _touchState({String? result, String? error, int? applied, int? bad, int? inStore}) async {
    // 同步读在 tick 异步链上不可用——用最近一次快照 + 本函数写入后由 Async 落盘。
    // 为保持 attemptLog 追加语义，这里读 Async 的最新副本（fire-and-forget 缓存）。
    final state = _lastKnownState;
    // 驳回硬性条件①：记录「上次尝试时间」（与成功时间区分）
    state['lastAttemptAt'] = DateTime.now().toIso8601String();
    state['lastChannelMs'] = MethodChannelCalendarGateway.lastRoundTripMs;
    if (state['attemptLog'] is List) {
      final log = state['attemptLog'] as List;
      log.insert(0, {
        'at': state['lastAttemptAt'],
        'result': result ?? state['lastResult'],
        'error': error,
      });
      state['attemptLog'] = log.take(5).toList();
    } else {
      state['attemptLog'] = [
        {'at': state['lastAttemptAt'], 'result': result ?? state['lastResult'], 'error': error}
      ];
    }
    // P1（检测员手术）：lastSyncAt 语义 = 上次【成功】同步时间——
    // 仅 ok/partial 时推进；失败也写会让「上次尝试 / 上次成功」分离落空，
    // 且首次配置失败即伪报成功时间。
    if (result == 'ok' || result == 'partial') {
      state['lastSyncAt'] = DateTime.now().toIso8601String();
    }
    if (result != null) state['lastResult'] = result;
    if (error != null) {
      state['lastError'] = error;
    } else if (result == 'ok') {
      state.remove('lastError');
    }
    if (applied != null) state['lastApplied'] = applied;
    if (bad != null) state['lastBad'] = bad;
    if (inStore != null && inStore >= 0) state['storeCount'] = inStore;
    state['mode'] = _mode;
    // WO-70：本机服务自证数据（设置页显示）
    final local = CalendarLocalService.instance;
    state['serverRunning'] = local.isRunning;
    state['serverPort'] = local.port;
    state['serverUser'] = local.username;
    state['serverPass'] = local.password;
    state['storeCount'] = local.store.events.length;
    _lastKnownState = Map<String, dynamic>.of(state);
    await StorageService.saveCalendarSyncState(state);
  }

  /// _touchState 的追加语义所需：最近一次状态副本（任务 isolate 内存）
  Map<String, dynamic> _lastKnownState = <String, dynamic>{};

  Future<void> _setStatus({String? mode, String? result, String? error}) async {
    if (mode != null) _mode = mode;
    await _touchState(result: result, error: error);
    onStatus?.call(CalendarSyncStatus(
      lastSyncAt: DateTime.now(),
      lastResult: result ?? '',
      lastError: error,
      mode: _mode,
    ));
  }

  /// WO-82-R3 追加：疑似跳信观测标记（缺口 UID + 推进位置）——写入同步状态
  /// 供设置页/对账即刻可见（12:12 事故的幽灵曾 5 天不可见）。失败静默（观测
  /// 面不阻断主流程；logcat 行已另行打出）。
  Future<void> _recordSkipSuspect(List<int> holes, int advancedTo) async {
    try {
      final st = _lastKnownState;
      st['lastSuspectedSkip'] = {
        'at': DateTime.now().toIso8601String(),
        'uids': holes.take(20).toList(),
        'advancedTo': advancedTo,
      };
      await StorageService.saveCalendarSyncState(st);
    } catch (_) {}
  }

  /// 错误消息消毒：剥离可能内嵌凭据的异常形态（红线：凭据零外泄）
  String _safeMessage(Object e) {
    var msg = e.toString();
    if (msg.length > 300) msg = '${msg.substring(0, 300)}…';
    return msg.replaceAll(RegExp(r'LOGIN\s+"[^"]*"\s+"[^"]*"'), 'LOGIN <redacted>');
  }
}
