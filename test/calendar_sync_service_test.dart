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
        result: scan([
          _mail(869, _ics('cal_1', sequence: 0)),
        ], 871), // 中间夹了非日历件 870/871
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
      final mails = scan([_mail(869, _ics('cal_1', sequence: 0))], 869);
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
        result: scan([_mail(869, _ics('cal_1', sequence: 1, lm: '20260927T020000Z'))], 869),
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
        result: scan([_mail(869, _ics('cal_gone', sequence: 0, cancelled: true))], 869),
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
        result: scan([
          _badMail(869), // 无 ICS 附件（结构超契约 → 提取 null）
          _mail(870, _ics('cal_2', sequence: 0)),
        ], 870),
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
        result: scan([
          _mail(869, _ics('cal_ok', sequence: 0)),
          _mail(870, _ics('cal_late', sequence: 0)),
        ], 870),
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
      final source = FakeSource(uidValidity: 1, result: scan([], 900));
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
        result: scan([CalendarMail(uid: 950, subject: 'cal', raw: raw)], 950),
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
        result: scan([], 900),
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
    test('WO-84 终架构：WebDAV 前台 8s / 后台 FGS 30s / 邮件兜底 90s + 熔断 60/120s', () {
      expect(
        CalendarSyncService.webdavForegroundBeat,
        const Duration(seconds: 8),
      );
      expect(
        CalendarSyncService.webdavBackgroundBeat,
        const Duration(seconds: 30),
      );
      expect(
        CalendarSyncService.mailFallbackBeat,
        const Duration(seconds: 90),
      );
      expect(CalendarSyncService.webdavBackoffLadder, [
        const Duration(seconds: 60),
        const Duration(seconds: 120),
      ]);
    });

    test('兜底轮询必须是 15 分钟——严禁退化到 1 分钟轮询（QQ 风控 + 耗电）', () {
      expect(
        CalendarSyncService.fallbackPollInterval,
        const Duration(minutes: 15),
      );
    });
  });

  group('WO-82-R1 解析器双形态（附件 / 内联 / 并存 / 标记残缺降级）', () {
    final icsAtt = _ics('att-uid-001');
    final icsInline = _ics('inline-uid-002');

    test('例 1【纯附件】：无正文标记，标准 calendar.ics base64 附件正常解析', () {
      final mail = _mail(101, icsAtt);
      final extracted = extractIcsFromMailDual(mail.raw);
      expect(extracted, isNotNull);
      expect(extracted, contains('UID:att-uid-001'));
    });

    test('例 2【纯内联】：正文标记包裹 ICS，无附件，直接提取内联内容', () {
      final raw = 'Subject: ${AppConstants.calSubjectPrefix}20260930-1000\r\n'
          'Content-Type: text/plain; charset=utf-8\r\n'
          '\r\n'
          '2BOT 日历投递 (内联格式)\r\n\r\n'
          '$calInlineBegin\r\n'
          '$icsInline\r\n'
          '$calInlineEnd\r\n';
      final extracted = extractIcsFromMailDual(raw);
      expect(extracted, isNotNull);
      expect(extracted, contains('UID:inline-uid-002'));
    });

    test('例 3【并存优先】：正文内联标记与附件并存，标记段优先生效', () {
      final encodedAtt = base64Of(utf8.encode(icsAtt));
      final raw = 'Subject: ${AppConstants.calSubjectPrefix}20260930-1001\r\n'
          'Content-Type: multipart/mixed; boundary=B_DUAL\r\n'
          '\r\n'
          '--B_DUAL\r\n'
          'Content-Type: text/plain; charset=utf-8\r\n'
          '\r\n'
          '2BOT 日历投递 (双形态并存)\r\n'
          '$calInlineBegin\r\n'
          '$icsInline\r\n'
          '$calInlineEnd\r\n'
          '--B_DUAL\r\n'
          'Content-Type: text/calendar; name=calendar.ics\r\n'
          'Content-Transfer-Encoding: base64\r\n'
          '\r\n'
          '$encodedAtt\r\n'
          '--B_DUAL--\r\n';
      final extracted = extractIcsFromMailDual(raw);
      expect(extracted, isNotNull);
      expect(extracted, contains('UID:inline-uid-002'),
          reason: '并存时必须标记段优先，不得取附件');
      expect(extracted, isNot(contains('UID:att-uid-001')));
    });

    test('例 4【标记残缺降级】：正文有 BEGIN 但缺少 END，降级并成功提取附件', () {
      final encodedAtt = base64Of(utf8.encode(icsAtt));
      final raw = 'Subject: ${AppConstants.calSubjectPrefix}20260930-1002\r\n'
          'Content-Type: multipart/mixed; boundary=B_BROKEN\r\n'
          '\r\n'
          '--B_BROKEN\r\n'
          'Content-Type: text/plain; charset=utf-8\r\n'
          '\r\n'
          '2BOT 日历投递 (标记残缺)\r\n'
          '$calInlineBegin\r\n'
          'BEGIN:VCALENDAR\r\n'
          'UID:broken-inline\r\n'
          '（注意：此处人为省略 calInlineEnd）\r\n'
          '--B_BROKEN\r\n'
          'Content-Type: text/calendar; name=calendar.ics\r\n'
          'Content-Transfer-Encoding: base64\r\n'
          '\r\n'
          '$encodedAtt\r\n'
          '--B_BROKEN--\r\n';
      final extracted = extractIcsFromMailDual(raw);
      expect(extracted, isNotNull, reason: '标记残缺必须平滑降级，不得直接报错');
      expect(extracted, contains('UID:att-uid-001'),
          reason: '降级后应成功提取附件中的 ICS');
      expect(extracted, isNot(contains('broken-inline')));
    });
  });

  group('WO-82-R3 追加 · 跳信防御（12:12 定案：QQ SEARCH 漏件 + 缺口重扫）', () {
    late List<List<Map<String, dynamic>>> gatewayBatches;

    setUp(() {
      gatewayBatches = <List<Map<String, dynamic>>>[];
    });

    CalendarSyncService build(FakeSource source, {bool failGateway = false}) {
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

    test('uidHoles 纯函数：漏件缺口/连续候选/无更高件 三态', () {
      // 12:12 实证形态：水位线 1262，SEARCH 只回了 1264（1263 被漏）
      expect(uidHoles(1262, [1264]), [1263]);
      // 连续候选 → 无缺口
      expect(uidHoles(1262, [1263, 1264, 1265]), isEmpty);
      // 候选为空 / 最大候选 ≤ 水位线（RFC n:* 怪癖回显）→ 无缺口
      expect(uidHoles(1264, <int>[]), isEmpty);
      expect(uidHoles(1264, [1264]), isEmpty);
      // 首尾双缺口
      expect(uidHoles(1260, [1262, 1264]), [1261, 1263]);
    });

    test('缺口重扫补齐：第一轮 SEARCH 漏 1263 → 重扫后补齐并消费（12:12 情景重放）',
        () async {
      // 1263=日历取消件（12:12 实物形态）、1264=遥测件（晚 34s 入箱）
      final calMail = _mail(1263, _ics('cal_1790727728690', cancelled: true));
      final source = FakeSource(
        uidValidity: 1,
        result: scan([], 0),
        scanScript: [
          // 第一轮：QQ SEARCH 漏件——只回 1264（TEL 非日历件，不出现在 mails）
          scan(const <CalendarMail>[], 1264, candidates: [1264]),
          // 重扫第 1 轮：索引已热 → 1263/1264 齐全
          scan([calMail], 1264, candidates: [1263, 1264]),
        ],
      );
      final svc = build(source);
      svc.skipRetryDelay = const Duration(milliseconds: 10);

      final next = await svc.debugSyncIncrement(source, 1262);

      expect(source.scanCalls, 2, reason: '缺口触发 1 次重扫');
      expect(gatewayBatches, hasLength(1), reason: '1263 取消件必须被消费');
      expect(gatewayBatches.single.single['uid'], 'cal_1790727728690');
      expect(gatewayBatches.single.single['cancelled'], isTrue);
      expect(next, 1264, reason: '消费后水位线照常推进');
      final state = await StorageService.loadCalendarSyncStateAsync();
      expect(state['lastSuspectedSkip'], isNull,
          reason: '缺口已补齐，不得留下跳信标记');
    });

    test('缺口持续：两轮重扫后仍缺口 → 水位线照常推进（防卡死）+ 跳信标记落状态',
        () async {
      final source = FakeSource(
        uidValidity: 1,
        result: scan([], 0),
        scanScript: [
          scan(const <CalendarMail>[], 1264, candidates: [1264]),
          scan(const <CalendarMail>[], 1264, candidates: [1264]),
          scan(const <CalendarMail>[], 1264, candidates: [1264]),
        ],
      );
      final svc = build(source);
      svc.skipRetryDelay = const Duration(milliseconds: 10);

      final next = await svc.debugSyncIncrement(source, 1262);

      expect(source.scanCalls, 3, reason: '首轮 + 2 次有界重扫（5s×2 语义）');
      expect(next, 1264, reason: '缺口不得卡死水位线（防重扫风暴）');
      final state = await StorageService.loadCalendarSyncStateAsync();
      final marker = state['lastSuspectedSkip'] as Map<dynamic, dynamic>?;
      expect(marker, isNotNull, reason: '疑似跳信必须即刻可见（12:12 反例：5 天幽灵）');
      expect(marker!['uids'], [1263]);
      expect(marker['advancedTo'], 1264);
    });

    test('连续候选 + 非日历新件：零重扫零标记（TEL 件高频到达不得放大扫描）', () async {
      final source = FakeSource(
        uidValidity: 1,
        result: scan(const <CalendarMail>[], 1266, candidates: [1266]),
      );
      final svc = build(source);
      svc.skipRetryDelay = const Duration(milliseconds: 10);

      final next = await svc.debugSyncIncrement(source, 1265);

      expect(source.scanCalls, 1, reason: '候选连续=无缺口，不重扫');
      expect(next, 1266);
      final state = await StorageService.loadCalendarSyncStateAsync();
      expect(state['lastSuspectedSkip'], isNull);
    });

    test('推送触发零新件（SEARCH 连回显都没给）：有界重扫后放行', () async {
      final source = FakeSource(
        uidValidity: 1,
        result: scan([], 0),
        scanScript: [
          // 推送刚到却一无所见（同族漏件形态：候选空回）
          scan(const <CalendarMail>[], 0, candidates: const <int>[]),
          scan(const <CalendarMail>[], 0, candidates: const <int>[]),
          scan(const <CalendarMail>[], 0, candidates: const <int>[]),
        ],
      );
      final svc = build(source);
      svc.skipRetryDelay = const Duration(milliseconds: 10);

      final next = await svc.debugSyncIncrement(source, 1262,
          trigger: 'IDLE推送');

      expect(source.scanCalls, 3, reason: '推送空扫必须重扫（服务端刚说有新件）');
      expect(next, 1262, reason: '无新件不得越位推进');
      final state = await StorageService.loadCalendarSyncStateAsync();
      expect(state['lastSuspectedSkip'], isNull,
          reason: '无缺口证据不落跳信标记');
    });

    test('兜底空扫（非推送触发）：候选只回显水位线本身 → 不重扫（90s 节拍常态）',
        () async {
      final source = FakeSource(
        uidValidity: 1,
        result: scan(const <CalendarMail>[], 1262, candidates: [1262]),
      );
      final svc = build(source);
      svc.skipRetryDelay = const Duration(milliseconds: 10);

      final next = await svc.debugSyncIncrement(source, 1262,
          trigger: '兜底查件');

      expect(source.scanCalls, 1, reason: 'RFC n:* 回显形态 ≠ 缺口，兜底常态不重扫');
      expect(next, 1262);
    });

    test('v2-a 真重置：回退重扫低位非空 → 采纳低位基线（序列重置防御保留）', () async {
      final mail6 = _mail(6, _ics('cal_reset_a', sequence: 0));
      final source = FakeSource(
        uidValidity: 1,
        result: scan([], 0),
        scanScript: [
          // 初始扫（水位线 1290）：SEARCH 空返回 → boxExists=5 < 1290 触发回退验证
          scan(const <CalendarMail>[], 0, candidates: const <int>[]),
          // 回退重扫（从 5 起）：新序列低位且活着
          scan([mail6], 6, candidates: [6]),
        ],
      );
      final svc = build(source);
      svc.skipRetryDelay = const Duration(milliseconds: 10);

      final next = await svc.debugSyncIncrement(source, 1290, boxExists: 5);

      expect(source.scanCalls, 2);
      expect(next, 6, reason: '真重置 → 低位基线照常推进');
      expect(gatewayBatches.single.single['uid'], 'cal_reset_a');
    });

    test('v2-c 回退重扫空返回 → 判 SEARCH 瞬断，恢复原水位线（带删信箱误鸣修正）',
        () async {
      final source = FakeSource(
        uidValidity: 1,
        result: scan(const <CalendarMail>[], 0, candidates: const <int>[]),
      );
      final svc = build(source);
      svc.skipRetryDelay = const Duration(milliseconds: 10);

      final next = await svc.debugSyncIncrement(source, 1290, boxExists: 1018);

      expect(next, 1290,
          reason: 'EXISTS=1018 明言有信而扫描空返回 = SEARCH 瞬断，不得把水位线拖到 1018');
      expect(source.scanCalls, 2,
          reason: '初始 1 + 回退验证 1（空返回已不作通用怀疑指纹——8s 拍防自压）');
      final state = await StorageService.loadCalendarSyncStateAsync();
      expect(state['lastSuspectedSkip'], isNull,
          reason: '空返回非缺口，不落跳信标记');
    });

    test('终裁配套：回退验证 10 分钟纯时间冷却——跨水位线仍有效（防 8s 拍自压）',
        () async {
      // 剧本：拍1初始空 + 拍1回退验证空（瞬断）→ 拍2/拍3 初始回显健康候选
      //（真机 21:30 实证：水位线做键会在每次消费后失效，冷却退化成每 ~36s
      // 一轮 11s 重验证；「序列是否重置」与水位线无关 → 纯时间键）
      final echo = scan(const <CalendarMail>[], 1304, candidates: [1304]);
      final source = FakeSource(
        uidValidity: 1,
        result: echo,
        scanScript: [
          scan(const <CalendarMail>[], 0, candidates: const <int>[]),
          scan(const <CalendarMail>[], 0, candidates: const <int>[]),
          echo,
          echo,
        ],
      );
      final svc = build(source);
      svc.skipRetryDelay = const Duration(milliseconds: 10);

      await svc.debugSyncIncrement(source, 1304, boxExists: 1032);
      expect(source.scanCalls, 2, reason: '拍1：初始 + 回退验证');

      // 拍2：水位线已因消费推进到 1306——纯时间冷却仍须跳过回退验证
      final next2 = await svc.debugSyncIncrement(source, 1306, boxExists: 1032);
      expect(source.scanCalls, 3,
          reason: '10min 内不同水位线也不得再跑回退验证重扫——'
              '8s 拍下每拍 10s 全段重扫 = 持续自压（真机 21:30 实证）');
      expect(next2, 1306);

      final next3 = await svc.debugSyncIncrement(source, 1306, boxExists: 1032);
      expect(next3, 1306, reason: '冷却期水位线稳定不漂移');
      expect(source.scanCalls, 4);
    });

    test('空返回连击守卫：连续 3 次扫描空返回且 EXISTS 明言有信 → 强制重建（断连语义）',
        () async {
      final source = FakeSource(
        uidValidity: 1,
        result: scan(const <CalendarMail>[], 0, candidates: const <int>[]),
      );
      final svc = build(source);
      svc.skipRetryDelay = const Duration(milliseconds: 10);

      // 第 1、2 次调用：连击累积（长持连接不重建则聋化）
      await svc.debugSyncIncrement(source, 1290, boxExists: 1018);
      await svc.debugSyncIncrement(source, 1290, boxExists: 1018);
      await expectLater(
        svc.debugSyncIncrement(source, 1290, boxExists: 1018),
        throwsA(isA<ImapClosedException>()),
        reason: '连续 3 次空返回 + EXISTS 明言有信 = 连接失智 → 重建',
      );
    });
  });

  group('WO-84 WebDAV 优先快路（坚果云 ctag 明文比对 + 熔断 + 配额红线）', () {
    test('base 解析器：三字段全非空才启用；空=禁用；文件夹归一化；完整 URL 覆盖', () {
      // 任一字段空 = 禁用
      expect(webdavBaseFromSettings('', 'pass', '2bot-cal'), isNull);
      expect(webdavBaseFromSettings('a@b.c', '', '2bot-cal'), isNull);
      expect(webdavBaseFromSettings('a@b.c', 'pass', '  '), isNull);
      // 坚果云默认主机拼接
      expect(webdavBaseFromSettings('a@b.c', 'pass', '2bot-cal'),
          'https://dav.jianguoyun.com/dav/2bot-cal/');
      // 斜杠归一化（防 /dav 双拼）
      expect(webdavBaseFromSettings('a@b.c', 'pass', '/dav/2bot-cal/'),
          'https://dav.jianguoyun.com/dav/2bot-cal/');
      // 完整 URL 覆盖（测试/迁移两用）
      expect(
          webdavBaseFromSettings(
              'a@b.c', 'pass', 'http://10.0.0.2:8080/dav/x/'),
          'http://10.0.0.2:8080/dav/x/');
      expect(
          webdavBaseFromSettings('a@b.c', 'pass', 'http://10.0.0.2:8080/dav/x'),
          'http://10.0.0.2:8080/dav/x/');
    });

    test('熔断状态机：429 立即熔断 60s→120s；单次失败不熔断；成功解除', () {
      final svc = CalendarSyncService.test(
        settingsProvider: () => AppSettings(calendarSyncEnabled: true),
        sourceFactory: (_) =>
            FakeSource(uidValidity: 1, result: scan([], 0)),
        gateway: FakeGateway(onUpsert: (_) {}),
      );
      // 单次普通失败：不熔断（连续 2 次才熔断）
      svc.noteWebdavFailure('超时');
      // 429：立即熔断 60s
      svc.noteWebdavFailure('WebDAV 限频（HTTP 429）', rateLimited: true);
      expect(svc.webdavNextIntervalForTest, const Duration(seconds: 60));
      // 退避中继续失败：阶梯升到 120s
      svc.noteWebdavFailure('WebDAV 限频（HTTP 503）', rateLimited: true);
      expect(svc.webdavNextIntervalForTest, const Duration(seconds: 120));
      // 成功：解除熔断、清失败链
      svc.noteWebdavSuccess();
      expect(svc.webdavNextIntervalForTest, Duration.zero,
          reason: '零=按正常分档节拍（8s/30s）调度');
      // 普通失败连续 2 次：熔断 60s
      svc.noteWebdavFailure('超时1');
      expect(svc.webdavNextIntervalForTest, Duration.zero, reason: '第 1 次不熔断');
      svc.noteWebdavFailure('超时2');
      expect(svc.webdavNextIntervalForTest, const Duration(seconds: 60));
    });

    test('配额红线 + 快路管线：ctag 未变零全量 GET；变化才拉取并应用（台账幂等）',
        () async {
      final icsBody = _ics('wo84-event-1');
      late HttpServer dav;
      int ctagGets = 0, icsGets = 0;
      String ctag = 'w84-1';
      dav = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      dav.listen((req) async {
        if (req.headers.value('authorization') !=
            'Basic ${base64.encode(utf8.encode('user@example.invalid:apppass'))}') {
          req.response.statusCode = 401;
          await req.response.close();
          return;
        }
        if (req.uri.path.endsWith('ctag.txt')) {
          ctagGets++;
          req.response.write(ctag);
          await req.response.close();
        } else if (req.uri.path.endsWith('calendar.ics')) {
          icsGets++;
          req.response.headers.contentType =
              ContentType('text', 'calendar', charset: 'utf-8');
          req.response.write(icsBody);
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });
      try {
        final batches = <List<Map<String, dynamic>>>[];
        final svc = CalendarSyncService.test(
          settingsProvider: () => AppSettings(
            calendarSyncEnabled: true,
            webdavUser: 'user@example.invalid',
            webdavPass: 'apppass',
            webdavFolder: 'http://127.0.0.1:${dav.port}/dav/2bot-cal/',
          ),
          sourceFactory: (_) => FakeSource(uidValidity: 1, result: scan([], 0)),
          gateway: FakeGateway(onUpsert: (b) => batches.add(b)),
        );
        final base = 'http://127.0.0.1:${dav.port}/dav/2bot-cal/';

        // 拍 1：首次 ctag → 拉 ics → 应用 1 条
        await svc.webdavProbeAndSync(base);
        expect(ctagGets, 1);
        expect(icsGets, 1);
        expect(batches.single.single['uid'], 'wo84-event-1');

        // 拍 2/3：ctag 未变 → 只做 ctag GET，零全量 GET（配额红线）
        await svc.webdavProbeAndSync(base);
        await svc.webdavProbeAndSync(base);
        expect(ctagGets, 3);
        expect(icsGets, 1, reason: 'ctag 未变严禁重复全量 GET');

        // ctag 变化 → 重拉；台账判 skip（同版本重复投递）→ 应用 0 但仍提交 ctag
        ctag = 'w84-2';
        await svc.webdavProbeAndSync(base);
        expect(ctagGets, 4);
        expect(icsGets, 2);
        expect(batches.length, 1, reason: '同版本事件台账判 skip 不重复下发');
      } finally {
        await dav.close(force: true);
      }
    });

    test('不可达静默回落：探测抛出不崩服务；熔断记账进入 60s 退避（邮件兜底承接）',
        () async {
      final svc = CalendarSyncService.test(
        settingsProvider: () => AppSettings(
          calendarSyncEnabled: true,
          webdavUser: 'u',
          webdavPass: 'p',
          webdavFolder: 'http://127.0.0.1:59999/dav/x/',
        ),
        sourceFactory: (_) => FakeSource(uidValidity: 1, result: scan([], 0)),
        gateway: FakeGateway(onUpsert: (_) {}),
      );
      // 探测直接调用会抛（_webdavTick 才是承接面）——异常类型不限定（socket/DNS 等）
      await expectLater(
        svc.webdavProbeAndSync('http://127.0.0.1:59999/dav/x/'),
        throwsA(anything),
      );
      // 模拟 tick 的记账路径：连续 2 次失败 → 熔断 60s（一行回落日志），服务不崩
      svc.noteWebdavFailure('SocketException');
      expect(svc.webdavNextIntervalForTest, Duration.zero);
      svc.noteWebdavFailure('SocketException');
      expect(svc.webdavNextIntervalForTest, const Duration(seconds: 60),
          reason: 'WebDAV 不可达 → 静默回落邮件兜底（90s 独立运转）');
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

/// WO-82-R3 追加：三字段扫描结果构造助手。candidates 缺省 = 连续候选
/// 1..maxSeenUid（QQ 星搜索常态回显形态：无缺口、非空返回 → 不触发缺口
/// 重扫与空返回守卫，既有用例语义零漂移）。显式传 candidates 以模拟
/// 漏件/空返回剧本。
({List<CalendarMail> mails, int maxSeenUid, List<int> candidates}) scan(
        List<CalendarMail> mails, int maxSeenUid,
        {List<int>? candidates}) =>
    (
      mails: mails,
      maxSeenUid: maxSeenUid,
      candidates: candidates ??
          (maxSeenUid > 0
              ? List<int>.generate(maxSeenUid, (i) => i + 1)
              : const <int>[]),
    );

class FakeSource implements CalendarMailSource {
  final int? uidValidity;
  final ({List<CalendarMail> mails, int maxSeenUid, List<int> candidates}) result;

  /// WO-82-R3 追加：多轮扫描剧本（非空时按调用序弹出，用尽后停在最后一轮——
  /// 缺口重扫「第一轮漏件、第二轮补齐」的假源剧本）
  final List<({List<CalendarMail> mails, int maxSeenUid, List<int> candidates})>?
      scanScript;

  /// fetchNewSince 实际调用次数（缺口重扫次数断言用）
  int scanCalls = 0;

  /// WO-71 ③：调用序列记录（断言「水位线空 → 先扫描再 IDLE」）
  final List<String> calls = <String>[];

  /// 真实 IDLE 语义：waitForEvent 阻塞直到 close()（模拟服务器长等待），
  /// 避免「立即 null」造成的紧密空转（那会饿死测试 Timer）
  final Completer<void> _idleWake = Completer<void>();

  FakeSource({required this.uidValidity, required this.result, this.scanScript});

  @override
  Future<int?> connect() async => uidValidity;

  @override
  Future<({List<CalendarMail> mails, int maxSeenUid, List<int> candidates})>
      fetchNewSince(int lastProcessedUid) async {
    scanCalls++;
    calls.add('scan');
    if (scanScript != null && scanScript!.isNotEmpty) {
      final idx = scanCalls - 1;
      return scanScript![idx >= scanScript!.length
          ? scanScript!.length - 1
          : idx];
    }
    return result;
  }

  @override
  void Function(String line)? onLifecycleLog;

  @override
  String? lastWakeReason;

  @override
  Future<int?> inboxExists() async => null;

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
