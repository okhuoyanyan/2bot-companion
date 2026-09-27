import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:meta/meta.dart';

import '../models/app_settings.dart';
import '../utils/constants.dart';
import 'calendar_mail_extract.dart';
import 'ics_min_parser.dart';
import 'imap_idle_client.dart';
import 'storage_service.dart';

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

/// 原生日历写入通道抽象（生产 = MethodChannel；测试 = 假实现）
abstract class CalendarGateway {
  /// 批量 upsert；CANCELLED 事件由原生侧按 UID 删除。失败抛异常。
  Future<void> upsertEvents(List<Map<String, dynamic>> events);

  /// 通道健康探测（可选实现；默认成功）
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
  Future<void> ping() async {
    final sw = Stopwatch()..start();
    await _channel.invokeMethod('ping').timeout(channelTimeout);
    lastRoundTripMs = sw.elapsedMilliseconds;
    debugPrint('[WO69] ping 往返 ${sw.elapsedMilliseconds}ms');
  }
}

/// 邮件源抽象（生产 = QQ IMAP；测试 = 假实现）
abstract class CalendarMailSource {
  /// 连接并 SELECT INBOX；返回 UIDVALIDITY（拿不到为 null）
  Future<int?> connect();

  Future<({List<CalendarMail> mails, int maxSeenUid})> fetchNewSince(
      int lastProcessedUid);

  Future<bool> startIdle();
  Future<int?> waitForEvent({required Duration beat});
  Future<void> stopIdle();
  Future<void> close();
}

class QqImapSource implements CalendarMailSource {
  final ImapConfig config;
  ImapIdleClient? _client;

  QqImapSource(this.config);

  @override
  Future<int?> connect() async {
    final client = ImapIdleClient(config: config);
    _client = client;
    final units = await client.connect();
    return parseUidValidity(units);
  }

  @override
  Future<({List<CalendarMail> mails, int maxSeenUid})> fetchNewSince(
      int lastProcessedUid) async {
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
  String _mode = 'off';

  /// 主 isolate / 测试用默认构造
  CalendarSyncService({
    CalendarGateway? gateway,
    CalendarMailSource Function(AppSettings)? sourceFactory,
    AppSettings Function()? settingsProvider,
    this.onStatus,
  })  : gateway = gateway ?? MethodChannelCalendarGateway(),
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

  /// 单次拉取节拍常量（暴露给测试与上层观测）
  static const Duration idleBeat = Duration(minutes: 25);
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
    final settings = settingsProvider();
    final shouldRun = settings.calendarSyncEnabled &&
        settings.mailAccount.trim().isNotEmpty &&
        settings.mailAuthCode.trim().isNotEmpty;
    if (shouldRun && !_running) {
      start();
    } else if (!shouldRun && _running) {
      await stop();
    }
  }

  /// 启动同步循环（幂等）
  void start() {
    if (_running) return;
    _running = true;
    _stopRequested = false;
    _loop = _runLoop();
  }

  /// 停止（关连接、唤醒等待）
  Future<void> stop() async {
    _stopRequested = true;
    _running = false;
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
    while (!_stopRequested) {
      try {
        final settings = settingsProvider();
        if (!settings.calendarSyncEnabled ||
            settings.mailAccount.trim().isEmpty ||
            settings.mailAuthCode.trim().isEmpty) {
          _mode = 'off';
          _setStatus(mode: 'off');
          if (await _sleep(const Duration(seconds: 60))) return;
          continue;
        }
        await _runSession(settings);
        // 会话正常退出（stop）即返回
        if (_stopRequested) return;
      } catch (e) {
        if (_stopRequested) return;
        _consecutiveFailures++;
        debugPrint('[WO69] 会话失败（第 $_consecutiveFailures 次）：${_safeMessage(e)}');
        // 有界退避：60s / 5min / 15min（封顶 15min）。严禁秒级热重试（急件解耦）。
        final wait = _consecutiveFailures <= sessionBackoff.length
            ? sessionBackoff[_consecutiveFailures - 1]
            : fallbackPollInterval;
        _mode = 'backoff';
        _setStatus(
          mode: 'backoff',
          result: 'error',
          error: 'IMAP 会话失败（第 $_consecutiveFailures 次，$_formatWait(wait)后重试）：${_safeMessage(e)}',
        );
        if (await _sleep(wait)) return;
      }
    }
  }

  /// 单次会话：连接 → 增量同步 → IDLE 长连接循环
  Future<void> _runSession(AppSettings settings) async {
    final source = sourceFactory(settings);
    _currentSource = source;
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

      // 首轮增量同步（建立基线）
      lastUid = await _syncIncrement(source, lastUid, uidValidity: uidValidity);
      _consecutiveFailures = 0;
      _mode = 'idle';
      _setStatus(mode: 'idle', result: 'ok');

      // IDLE 长连接循环
      while (!_stopRequested) {
        final accepted = await source.startIdle();
        if (!accepted) {
          _mode = 'poll';
          _setStatus(mode: 'poll', error: '服务器不接受 IDLE，退化为兜底轮询');
          // 兜底轮询：每 15 分钟整连重拉（服务循环外层 sleep 实现同节奏）
          if (await _sleep(fallbackPollInterval)) return;
          lastUid = await _syncIncrement(source, lastUid, uidValidity: uidValidity);
          _setStatus(mode: 'poll', result: 'ok');
          continue;
        }
        final event = await source.waitForEvent(beat: idleBeat);
        if (_stopRequested) return;
        if (event == null) {
          // 25 分钟节拍到点：DONE + 重发 IDLE（防 30 分钟服务端强断）
          debugPrint('[WO69] IDLE 节拍到点，重发 IDLE（防 30 分钟强断）');
          await source.stopIdle();
          continue;
        }
        // 收到 EXISTS：秒级增量
        debugPrint('[WO69] IDLE 推送 EXISTS=$event，开始秒级增量');
        await source.stopIdle();
        lastUid = await _syncIncrement(source, lastUid, uidValidity: uidValidity);
        _setStatus(mode: 'idle', result: 'ok');
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
          {int? uidValidity}) =>
      _syncIncrement(source, lastUid, uidValidity: uidValidity);

  /// 增量同步：粗筛→精筛→拉全文→提取 ICS→解析→幂等 upsert→推进水位线。
  /// 返回推进后的水位线（调用方保存）。
  Future<int> _syncIncrement(CalendarMailSource source, int lastUid,
      {int? uidValidity}) async {
    final (:mails, maxSeenUid: maxSeen) = await source.fetchNewSince(lastUid);
    debugPrint('[WO69] 增量扫描：水位线=$lastUid，粗筛 maxSeen=$maxSeen，'
        '日历新件=${mails.length} 封');

    if (mails.isEmpty) {
      // 空扫也推进（防重复扫），与 NAS 同口径
      final next = maxSeen > lastUid ? maxSeen : lastUid;
      if (next > lastUid) {
        await StorageService.saveCalendarWatermark(
            uidValidity: uidValidity, lastProcessedUid: next);
      }
      _touchState(result: 'ok');
      return next;
    }

    final ledger = CalendarEventLedger(StorageService.loadCalendarEventLedger());
    var handledUid = lastUid;
    var appliedCount = 0;
    var badCount = 0;
    final errors = <String>[];

    for (final mail in mails) {
      final icsText = extractIcsFromMail(mail.raw);
      if (icsText == null) {
        badCount++;
        errors.add('UID ${mail.uid}: 附件提取失败（结构超契约）');
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
          _touchState(result: 'error', error: errors.last);
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
    _touchState(
      result: errors.isEmpty ? 'ok' : 'partial',
      error: errors.isEmpty ? null : errors.join('；'),
      applied: appliedCount,
      bad: badCount,
    );
    debugPrint('[WO69] 同步完成：水位线推进至 $next（应用 $appliedCount 条，'
        '坏件 $badCount 封）');
    return next > lastUid ? next : lastUid;
  }

  // ------------------------------------------------------------------
  // 工具
  // ------------------------------------------------------------------

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

  void _touchState({String? result, String? error, int? applied, int? bad}) {
    final state = StorageService.loadCalendarSyncState();
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
    state['lastSyncAt'] = DateTime.now().toIso8601String();
    if (result != null) state['lastResult'] = result;
    if (error != null) {
      state['lastError'] = error;
    } else if (result == 'ok') {
      state.remove('lastError');
    }
    if (applied != null) state['lastApplied'] = applied;
    if (bad != null) state['lastBad'] = bad;
    state['mode'] = _mode;
    StorageService.saveCalendarSyncState(state);
  }

  void _setStatus({String? mode, String? result, String? error}) {
    if (mode != null) _mode = mode;
    _touchState(result: result, error: error);
    onStatus?.call(CalendarSyncStatus(
      lastSyncAt: DateTime.now(),
      lastResult: result ?? '',
      lastError: error,
      mode: _mode,
    ));
  }

  /// 错误消息消毒：剥离可能内嵌凭据的异常形态（红线：凭据零外泄）
  String _safeMessage(Object e) {
    var msg = e.toString();
    if (msg.length > 300) msg = '${msg.substring(0, 300)}…';
    return msg.replaceAll(RegExp(r'LOGIN\s+"[^"]*"\s+"[^"]*"'), 'LOGIN <redacted>');
  }
}
