import 'dart:convert';

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:bot_companion/models/app_settings.dart';
import 'package:bot_companion/services/calendar_event_store.dart';
import 'package:bot_companion/services/calendar_local_service.dart';
import 'package:bot_companion/services/calendar_sync_service.dart';
import 'package:bot_companion/services/ics_min_parser.dart';
import 'package:bot_companion/services/imap_idle_client.dart';
import 'package:bot_companion/services/storage_service.dart';
import 'package:bot_companion/utils/constants.dart';

/// ============================================================================
/// WO-69 · 日历同步编排单测（台账幂等 / 水位线纪律 / 取消传播 / 契约节拍常量）
/// ============================================================================
/// 全部走注入的假邮件源与假通道（零真连、零真邮件、零平台通道），持久化走
/// SharedPreferences mock 初始值——不触生产数据（测试沙盒铁律）。
void main() {
  setUp(() async {
    // 静态缓存必须随每个用例重置（_prefs ??= 会跨用例泄漏上一用例的台账/水位线）
    StorageService.resetForTest();
    SharedPreferences.setMockInitialValues({});
    // 状态写端走 SharedPreferencesAsync（与 UI 读端同存储），测试须挂内存平台实现
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData(const {});
    await StorageService.init();
  });

  IcsEvent ev(
    String uid, {
    int sequence = 0,
    DateTime? lastModified,
    bool cancelled = false,
  }) =>
      IcsEvent(
        uid: uid,
        sequence: sequence,
        dtstart: DateTime.utc(2026, 9, 28, 9),
        allDay: false,
        lastModified: lastModified ?? DateTime.utc(2026, 9, 27, 1),
        cancelled: cancelled,
      );

  group('CalendarEventLedger 新旧判定（幂等核心）', () {
    test('新事件 apply；同版本重复投递 skip', () {
      final ledger = CalendarEventLedger(null);
      expect(ledger.decideFor(ev('u1', sequence: 2)), LedgerDecision.apply);
      ledger.recordApplied(ev('u1', sequence: 2));
      expect(ledger.decideFor(ev('u1', sequence: 2)), LedgerDecision.skip,
          reason: '同 SEQUENCE 同 LAST-MODIFIED = 重复投递');
    });

    test('SEQUENCE 大者新；相等看 LAST-MODIFIED', () {
      final t1 = DateTime.utc(2026, 9, 27, 1);
      final t2 = DateTime.utc(2026, 9, 27, 2);
      final ledger = CalendarEventLedger(null)..recordApplied(ev('u', sequence: 1, lastModified: t1));
      expect(ledger.decideFor(ev('u', sequence: 2, lastModified: t1)),
          LedgerDecision.apply, reason: 'SEQUENCE 更大 → 更新');
      expect(ledger.decideFor(ev('u', sequence: 1, lastModified: t2)),
          LedgerDecision.apply, reason: 'SEQUENCE 相等、LAST-MODIFIED 更新 → 更新');
      expect(ledger.decideFor(ev('u', sequence: 1, lastModified: t1)),
          LedgerDecision.skip);
      expect(ledger.decideFor(ev('u', sequence: 0, lastModified: t2)),
          LedgerDecision.skip, reason: 'SEQUENCE 更小 → 一律过时');
    });

    test('【契约补充 2026-09-27】CANCELLED 墓碑绕过新旧判定：UID 命中即删', () {
      final ledger = CalendarEventLedger(null)
        ..recordApplied(ev('gone', sequence: 3, lastModified: DateTime.utc(2026, 9, 27, 5)));
      // NAS 墓碑不保留删前 sequence（恒为 0）——若按台账比较会被误判过时丢弃
      expect(ledger.decideFor(ev('gone', sequence: 0, cancelled: true)),
          LedgerDecision.apply, reason: '取消通告必须传播，不得因 SEQUENCE=0 被丢');
      expect(ledger.decideFor(ev('gone', sequence: 0, cancelled: true)),
          LedgerDecision.apply, reason: '删除幂等：重复墓碑照常下发（原生侧跳过）');
    });
  });

  group('增量同步编排（假源 + 假通道 + mock prefs）', () {
    late List<List<Map<String, dynamic>>> gatewayBatches;
    late bool failGateway;

    setUp(() {
      gatewayBatches = <List<Map<String, dynamic>>>[];
      failGateway = false;
    });

    CalendarSyncService build(FakeSource source) {
      return CalendarSyncService.test(
        settingsProvider: () => AppSettings(
          calendarSyncEnabled: true,
          mailAccount: 'fixture@example.invalid',
          mailAuthCode: 'FIXTURE',
        ),
        sourceFactory: (_) => source,
        gateway: FakeGateway(
          onUpsert: (batch) {
            if (failGateway) throw StateError('通道未激活(模拟)');
            gatewayBatches.add(batch);
          },
        ),
      );
    }

    test('正常增量：新事件下发原生 + 水位线推进到 maxSeen', () async {
      final source = FakeSource(
        uidValidity: 1789989266,
        result: (
          mails: [
            _mail(869, _ics('cal_1', sequence: 0)),
          ],
          maxSeenUid: 871, // 中间夹了非日历件 870/871
        ),
      );
      final svc = build(source);
      final next = await svc.debugSyncIncrement(source, 0);

      expect(gatewayBatches, hasLength(1));
      expect(gatewayBatches.single.single['uid'], 'cal_1');
      expect(gatewayBatches.single.single['dtstartMs'], isNotNull);
      final wm = StorageService.loadCalendarWatermark();
      expect(wm.lastProcessedUid, 871, reason: '空扫段（非日历件）也推进水位线（NAS 同口径）');
      expect(next, 871);
    });

    test('幂等重放：同一批邮件再来一次 → 台账判 skip，不再下发', () async {
      final mails = (mails: [_mail(869, _ics('cal_1', sequence: 0))], maxSeenUid: 869);
      final source = FakeSource(uidValidity: 1, result: mails);
      final svc = build(source);
      await svc.debugSyncIncrement(source, 0);
      expect(gatewayBatches, hasLength(1));

      final source2 = FakeSource(uidValidity: 1, result: mails);
      await svc.debugSyncIncrement(source2, 869);
      expect(gatewayBatches, hasLength(1), reason: '重复投递不得重复写入日历');
    });

    test('变更重投：SEQUENCE/LAST-MODIFIED 更新 → 同 UID 更新不新增', () async {
      final source = FakeSource(
        uidValidity: 1,
        result: (mails: [_mail(869, _ics('cal_1', sequence: 1, lm: '20260927T020000Z'))], maxSeenUid: 869),
      );
      final svc = build(source);
      final ledgerBefore = StorageService.loadCalendarEventLedger()
        ..['cal_1'] = {'sequence': 0, 'lastModifiedMs': 0};
      await StorageService.saveCalendarEventLedger(ledgerBefore);

      await svc.debugSyncIncrement(source, 0);
      expect(gatewayBatches, hasLength(1), reason: '版本更新 → 下发（原生按 UID upsert）');
      expect(gatewayBatches.single.single['sequence'], 1);
    });

    test('【契约补充】取消传播：墓碑 SEQUENCE=0 也必须下发删除', () async {
      final source = FakeSource(
        uidValidity: 1,
        result: (mails: [_mail(869, _ics('cal_gone', sequence: 0, cancelled: true))], maxSeenUid: 869),
      );
      final svc = build(source);
      // 模拟此前已应用过更高版本：台账 sequence=3
      final ledger = StorageService.loadCalendarEventLedger()
        ..['cal_gone'] = {'sequence': 3, 'lastModifiedMs': 9999999999999};
      await StorageService.saveCalendarEventLedger(ledger);

      await svc.debugSyncIncrement(source, 0);
      expect(gatewayBatches, hasLength(1), reason: '取消通告不得因 SEQUENCE=0 判过时丢弃');
      expect(gatewayBatches.single.single['cancelled'], isTrue);
      final state = await StorageService.loadCalendarSyncStateAsync();
      expect(state['lastResult'], 'ok');
    });

    test('坏件越过：附件提取失败不阻塞，水位线仍推进且计数落状态', () async {
      final source = FakeSource(
        uidValidity: 1,
        result: (
          mails: [
            _badMail(869), // 无 ICS 附件（结构超契约 → 提取 null）
            _mail(870, _ics('cal_2', sequence: 0)),
          ],
          maxSeenUid: 870,
        ),
      );
      final svc = build(source);
      await svc.debugSyncIncrement(source, 0);

      expect(gatewayBatches, hasLength(1), reason: '坏件越过，好件照常应用');
      expect(gatewayBatches.single.single['uid'], 'cal_2');
      expect(StorageService.loadCalendarWatermark().lastProcessedUid, 870);
      final state = await StorageService.loadCalendarSyncStateAsync();
      expect(state['lastBad'], 1);
      expect(state['lastResult'], 'partial');
    });

    test('【不越过纪律】通道写失败：水位线停在已处理边界并抛出', () async {
      failGateway = true;
      final source = FakeSource(
        uidValidity: 1,
        result: (
          mails: [
            _mail(869, _ics('cal_ok', sequence: 0)),
            _mail(870, _ics('cal_late', sequence: 0)),
          ],
          maxSeenUid: 870,
        ),
      );
      final svc = build(source);
      await expectLater(
        svc.debugSyncIncrement(source, 0),
        throwsA(isA<StateError>()),
      );
      final wm = StorageService.loadCalendarWatermark();
      expect(wm.lastProcessedUid, 0, reason: '第一封就失败 → 水位线不得越过任何未应用邮件');
      final errState = await StorageService.loadCalendarSyncStateAsync();
      expect(errState['lastResult'], 'error',
          reason: '失败须落状态供设置页展示');
    });

    test('空扫推进：无新邮件也把水位线推到 maxSeen（防重复重扫）', () async {
      final source = FakeSource(uidValidity: 1, result: (mails: [], maxSeenUid: 900));
      final svc = build(source);
      final next = await svc.debugSyncIncrement(source, 800);
      expect(next, 900);
      expect(gatewayBatches, isEmpty);
    });
  });

  group('WO-70 整改①：gateway 断路回归守门', () {
    test('默认构造的 CalendarSyncService 必须注入 EventStoreCalendarGateway', () {
      final svc = CalendarSyncService();
      expect(svc.gateway, isA<EventStoreCalendarGateway>(),
          reason: '断路回归守门：默认 MethodChannelGateway 从未被后台 isolate 激活，'
              'store 恒空（检测员第二轮指认）');
    });

    test('写入后库内回读：store 事件数与 gateway.storedCount 一致且可渲染', () async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.init();
      // 重置单例库（防跨用例污染）
      CalendarLocalService.instance.store = CalendarEventStore();
      const crlf = '\r\n';
      final ics = 'BEGIN:VCALENDAR$crlf'
          'BEGIN:VEVENT$crlf'
          'UID:cal_gate$crlf'
          'DTSTART:20260928T090000Z$crlf'
          'DURATION:PT1H$crlf'
          'SUMMARY:断路守门事件$crlf'
          'END:VEVENT$crlf'
          'END:VCALENDAR$crlf';
      final encoded = base64.encode(utf8.encode(ics));
      final raw = 'Subject: X-2BOT-CAL-20260928-0100$crlf'
          'Content-Type: multipart/mixed; boundary=B$crlf$crlf'
          '--B$crlf'
          'Content-Type: text/calendar; name=calendar.ics$crlf'
          'Content-Transfer-Encoding: base64$crlf$crlf'
          '$encoded$crlf--B--$crlf';
      final source = FakeSource(
        uidValidity: 1,
        result: (
          mails: [CalendarMail(uid: 950, subject: 'cal', raw: raw)],
          maxSeenUid: 950,
        ),
      );
      final svc = CalendarSyncService.test(
        settingsProvider: () => AppSettings(
          calendarSyncEnabled: true,
          mailAccount: 'fixture@example.invalid',
          mailAuthCode: 'FIXTURE',
        ),
        sourceFactory: (_) => source,
        gateway: EventStoreCalendarGateway(),
      );
      await svc.debugSyncIncrement(source, 0);

      // 写后回读：库内恰 1 条 + storedCount 一致 + 可渲染出该事件
      expect(CalendarLocalService.instance.store.events.length, 1);
      expect(await svc.gateway.storedCount(), 1);
      final rendered = CalendarLocalService.instance.store.renderFullIcs();
      expect(rendered, contains('UID:cal_gate'));
      expect(rendered, contains('SUMMARY:断路守门事件'));
    });
  });

  group('WO-71 ③：首次同步顺序（水位线空 → 先扫描再 IDLE）', () {
    test('连接后第一个动作必须是扫描（fetchNewSince），绝不先 IDLE', () async {
      StorageService.resetForTest();
      SharedPreferences.setMockInitialValues({});
      await StorageService.init();
      final source = FakeSource(
        uidValidity: 1,
        result: (mails: [], maxSeenUid: 900),
      );
      final svc = CalendarSyncService.test(
        settingsProvider: () => AppSettings(
          calendarSyncEnabled: true,
          mailAccount: 'fixture@example.invalid',
          mailAuthCode: 'FIXTURE',
        ),
        sourceFactory: (_) => source,
        gateway: FakeGateway(onUpsert: (_) {}),
      );
      // 直接驱动一个短会话：start → 等 1 秒 → stop
      void dbg(String m) {
        File('C:/Users/NAS/AppData/Local/Temp/wo71_dbg.log').writeAsStringSync(
            '$m\r\n', mode: FileMode.append);
      }
      dbg('start begin, calls=${source.calls}');
      svc.start();
      dbg('start returned');
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      dbg('waited, calls=${source.calls}');
      await svc.stop();
      dbg('stopped, calls=${source.calls}');
      expect(source.calls.first, 'scan',
          reason: '水位线为空时必须先扫描再 IDLE——'
              '先 IDLE 则无历史推送、永不扫描、库内恒 0（WO-71 §1.2）');
      final idleIdx = source.calls.indexOf('idle');
      final scanIdx = source.calls.indexOf('scan');
      expect(idleIdx, greaterThan(scanIdx), reason: 'IDLE 必须在首轮扫描之后');
    });
  });

  group('时效契约常量（工单 ④ 硬指标的守门断言）', () {
    test('IDLE 节拍必须 < 30 分钟（实测服务端 30.0 分钟强断）', () {
      expect(CalendarSyncService.idleBeat, lessThan(const Duration(minutes: 30)));
      expect(CalendarSyncService.idleBeat, const Duration(minutes: 25));
    });

    test('兜底轮询必须是 15 分钟——严禁退化到 1 分钟轮询（QQ 风控 + 耗电）', () {
      expect(
        CalendarSyncService.fallbackPollInterval,
        const Duration(minutes: 15),
      );
    });
  });
}

// ---------------------------------------------------------------------------
// 测试夹具（example.invalid 域名纪律；无真实凭据、无真实邮件）
// ---------------------------------------------------------------------------

String _ics(String uid, {int sequence = 0, bool cancelled = false, String lm = '20260927T010000Z'}) {
  return 'BEGIN:VCALENDAR\r\n'
      'BEGIN:VEVENT\r\n'
      'UID:$uid\r\n'
      'SEQUENCE:$sequence\r\n'
      'LAST-MODIFIED:$lm\r\n'
      'DTSTART:20260928T090000Z\r\n'
      'DURATION:PT1H\r\n'
      'SUMMARY:夹具日程\r\n'
      '${cancelled ? 'STATUS:CANCELLED\r\n' : ''}'
      'END:VEVENT\r\n'
      'END:VCALENDAR\r\n';
}

/// base64 契约形态的日历邮件
CalendarMail _mail(int uid, String icsText) {
  final encoded = base64Of(utf8.encode(icsText));
  final raw = 'Subject: ${AppConstants.calSubjectPrefix}20260927-0930\r\n'
      'Content-Type: multipart/mixed; boundary=B\r\n'
      '\r\n'
      '--B\r\n'
      'Content-Type: text/calendar; name=calendar.ics\r\n'
      'Content-Transfer-Encoding: base64\r\n'
      '\r\n'
      '$encoded\r\n'
      '--B--\r\n';
  return CalendarMail(uid: uid, subject: 'cal', raw: raw);
}

/// 结构超契约的邮件（无任何 ICS 附件 → 提取必须返回 null）
CalendarMail _badMail(int uid) {
  final raw = 'Subject: ${AppConstants.calSubjectPrefix}20260927-0999\r\n'
      'Content-Type: text/plain; charset=utf-8\r\n'
      '\r\n'
      '这封邮件被人为弄坏了：没有日历附件。\r\n';
  return CalendarMail(uid: uid, subject: 'cal', raw: raw);
}

String base64Of(List<int> bytes) => base64Encode(bytes);

class FakeGateway implements CalendarGateway {
  final void Function(List<Map<String, dynamic>> batch) onUpsert;
  FakeGateway({required this.onUpsert});

  @override
  Future<void> upsertEvents(List<Map<String, dynamic>> events) async =>
      onUpsert(events);

  @override
  Future<int> storedCount() async => -1;

  @override
  Future<void> ping() async {}
}

class FakeSource implements CalendarMailSource {
  final int? uidValidity;
  final ({List<CalendarMail> mails, int maxSeenUid}) result;

  /// WO-71 ③：调用序列记录（断言「水位线空 → 先扫描再 IDLE」）
  final List<String> calls = <String>[];

  /// 真实 IDLE 语义：waitForEvent 阻塞直到 close()（模拟服务器长等待），
  /// 避免「立即 null」造成的紧密空转（那会饿死测试 Timer）
  final Completer<void> _idleWake = Completer<void>();

  FakeSource({required this.uidValidity, required this.result});

  @override
  Future<int?> connect() async => uidValidity;

  @override
  Future<({List<CalendarMail> mails, int maxSeenUid})> fetchNewSince(
          int lastProcessedUid) async {
    calls.add('scan');
    return result;
  }

  @override
  Future<bool> startIdle() async {
    calls.add('idle');
    return true;
  }

  @override
  Future<int?> waitForEvent({required Duration beat}) async {
    // 真实 IDLE 语义：长阻塞至 close() 唤醒（否则立即 null 会让会话循环
    // 微任务级紧密空转、饿死测试 Timer——此前用例挂死的根因）
    await _idleWake.future;
    return null;
  }

  @override
  Future<void> stopIdle() async {}

  @override
  Future<void> close() async {
    if (!_idleWake.isCompleted) _idleWake.complete();
  }
}
