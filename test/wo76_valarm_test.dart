import 'package:flutter_test/flutter_test.dart';

import 'package:bot_companion/services/calendar_event_store.dart';
import 'package:bot_companion/services/calendar_sync_service.dart';
import 'package:bot_companion/services/ics_min_parser.dart';

/// ============================================================================
/// WO-76 · VALARM 提醒全链路单测
/// ============================================================================
/// 覆盖：
///  1. 解析矩阵：相对时长各形态（-PT15M / -PT4H / -P1D / -P1DT2H / PT0S）、
///     ACTION 过滤（仅认 DISPLAY）、无 VALARM 缺省为 null；
///  2. ⑤ 绝对时间 TRIGGER：VALUE=DATE-TIME 或时间戳字符串 → reminderMinutes=null
///     且 ignoredAbsoluteTriggerCount 计数精确递增，不许静默；
///  3. 🔴 G1 严禁凭空造提醒：toIcs() 当且仅当 reminderMinutes != null 才输出 BEGIN:VALARM；
///     节日事件导出 VALARM 恒为 0（反向锁死）；
///  4. 🔴 G2 零迁移防御转换：fromJson / applyMap 宽容 String/num，负数→null，畸形不抛；
///  5. 🔴 G3 四点贯穿：IcsEvent → _eventToNativeMap → applyMap → StoredEvent → toIcs()。
void main() {
  group('WO-76 ① 解析矩阵：VALARM 相对时长各形态与 ACTION 过滤', () {
    test('标准提前 15 分钟（-PT15M）', () {
      const ics = 'BEGIN:VEVENT\r\n'
          'UID:valarm-15\r\n'
          'DTSTART:20261001T090000Z\r\n'
          'SUMMARY:15分钟提醒\r\n'
          'BEGIN:VALARM\r\n'
          'ACTION:DISPLAY\r\n'
          'DESCRIPTION:15分钟提醒\r\n'
          'TRIGGER:-PT15M\r\n'
          'END:VALARM\r\n'
          'END:VEVENT\r\n';
      final r = parseIcs(ics);
      expect(r.events, hasLength(1));
      expect(r.events.single.reminderMinutes, 15);
      expect(r.ignoredAbsoluteTriggerCount, 0);
    });

    test('全天事件提前 4 小时（-PT4H = 240 分钟，NAS 契约）', () {
      const ics = 'BEGIN:VEVENT\r\n'
          'UID:valarm-4h\r\n'
          'DTSTART;VALUE=DATE:20261001\r\n'
          'SUMMARY:全天日程\r\n'
          'BEGIN:VALARM\r\n'
          'ACTION:DISPLAY\r\n'
          'DESCRIPTION:全天日程\r\n'
          'TRIGGER:-PT4H\r\n'
          'END:VALARM\r\n'
          'END:VEVENT\r\n';
      final r = parseIcs(ics);
      expect(r.events, hasLength(1));
      expect(r.events.single.reminderMinutes, 240);
      expect(r.events.single.allDay, isTrue);
    });

    test('提前 1 天（-P1D = 1440 分钟）与 1 天 2 小时（-P1DT2H = 1560 分钟）', () {
      const ics1 = 'BEGIN:VEVENT\r\n'
          'UID:valarm-1d\r\n'
          'DTSTART:20261001T090000Z\r\n'
          'SUMMARY:提前1天\r\n'
          'BEGIN:VALARM\r\n'
          'ACTION:DISPLAY\r\n'
          'TRIGGER:-P1D\r\n'
          'END:VALARM\r\n'
          'END:VEVENT\r\n';
      expect(parseIcs(ics1).events.single.reminderMinutes, 1440);

      const ics2 = 'BEGIN:VEVENT\r\n'
          'UID:valarm-1d2h\r\n'
          'DTSTART:20261001T090000Z\r\n'
          'SUMMARY:提前1天2小时\r\n'
          'BEGIN:VALARM\r\n'
          'ACTION:DISPLAY\r\n'
          'TRIGGER:-P1DT2H\r\n'
          'END:VALARM\r\n'
          'END:VEVENT\r\n';
      expect(parseIcs(ics2).events.single.reminderMinutes, 1560);
    });

    test('准时提醒（PT0S = 0 分钟）', () {
      const ics = 'BEGIN:VEVENT\r\n'
          'UID:valarm-0\r\n'
          'DTSTART:20261001T090000Z\r\n'
          'SUMMARY:准时提醒\r\n'
          'BEGIN:VALARM\r\n'
          'ACTION:DISPLAY\r\n'
          'TRIGGER:PT0S\r\n'
          'END:VALARM\r\n'
          'END:VEVENT\r\n';
      final r = parseIcs(ics);
      expect(r.events.single.reminderMinutes, 0);
    });

    test('ACTION 非 DISPLAY（如 AUDIO / EMAIL）→ 忽略，reminderMinutes 为 null', () {
      const ics = 'BEGIN:VEVENT\r\n'
          'UID:valarm-audio\r\n'
          'DTSTART:20261001T090000Z\r\n'
          'SUMMARY:音频闹钟\r\n'
          'BEGIN:VALARM\r\n'
          'ACTION:AUDIO\r\n'
          'TRIGGER:-PT15M\r\n'
          'END:VALARM\r\n'
          'END:VEVENT\r\n';
      final r = parseIcs(ics);
      expect(r.events.single.reminderMinutes, isNull);
    });

    test('无 VALARM 组件的普通事件 → reminderMinutes 为 null', () {
      const ics = 'BEGIN:VEVENT\r\n'
          'UID:valarm-none\r\n'
          'DTSTART:20261001T090000Z\r\n'
          'SUMMARY:无闹钟\r\n'
          'END:VEVENT\r\n';
      final r = parseIcs(ics);
      expect(r.events.single.reminderMinutes, isNull);
    });
  });

  group('WO-76 ⑤ 绝对时间 TRIGGER 显式忽略与计数不静默', () {
    test('TRIGGER;VALUE=DATE-TIME 绝对时间戳 → reminderMinutes=null 且计数递增', () {
      const ics = 'BEGIN:VEVENT\r\n'
          'UID:valarm-abs-1\r\n'
          'DTSTART:20261001T090000Z\r\n'
          'SUMMARY:绝对时间1\r\n'
          'BEGIN:VALARM\r\n'
          'ACTION:DISPLAY\r\n'
          'TRIGGER;VALUE=DATE-TIME:20261001T084500Z\r\n'
          'END:VALARM\r\n'
          'END:VEVENT\r\n';
      final r = parseIcs(ics);
      expect(r.events.single.reminderMinutes, isNull);
      expect(r.ignoredAbsoluteTriggerCount, 1);
    });

    test('裸绝对时间戳字符串（如 20261001T084500Z）→ reminderMinutes=null 且计数递增', () {
      const ics = 'BEGIN:VEVENT\r\n'
          'UID:valarm-abs-2\r\n'
          'DTSTART:20261001T090000Z\r\n'
          'SUMMARY:绝对时间2\r\n'
          'BEGIN:VALARM\r\n'
          'ACTION:DISPLAY\r\n'
          'TRIGGER:20261001T084500Z\r\n'
          'END:VALARM\r\n'
          'END:VEVENT\r\n';
      final r = parseIcs(ics);
      expect(r.events.single.reminderMinutes, isNull);
      expect(r.ignoredAbsoluteTriggerCount, 1);
    });

    test('多事件混排：绝对时间精确计数、相对时间正常解析', () {
      const ics = 'BEGIN:VEVENT\r\n'
          'UID:e1\r\n'
          'DTSTART:20261001T090000Z\r\n'
          'BEGIN:VALARM\r\n'
          'ACTION:DISPLAY\r\n'
          'TRIGGER:-PT15M\r\n'
          'END:VALARM\r\n'
          'END:VEVENT\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:e2\r\n'
          'DTSTART:20261001T100000Z\r\n'
          'BEGIN:VALARM\r\n'
          'ACTION:DISPLAY\r\n'
          'TRIGGER;VALUE=DATE-TIME:20261001T093000Z\r\n'
          'END:VALARM\r\n'
          'END:VEVENT\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:e3\r\n'
          'DTSTART:20261001T110000Z\r\n'
          'BEGIN:VALARM\r\n'
          'ACTION:DISPLAY\r\n'
          'TRIGGER:20261001T100000Z\r\n'
          'END:VALARM\r\n'
          'END:VEVENT\r\n';
      final r = parseIcs(ics);
      expect(r.events, hasLength(3));
      expect(r.events[0].reminderMinutes, 15);
      expect(r.events[1].reminderMinutes, isNull);
      expect(r.events[2].reminderMinutes, isNull);
      expect(r.ignoredAbsoluteTriggerCount, 2);
    });
  });

  group('WO-76 🔴 护栏 G1：严禁凭空造提醒（toIcs 导出当且仅当 != null，节日 VALARM=0）', () {
    test('节日事件（reminderMinutes=null）导出 VALARM 严格为 0（反向锁死）', () {
      const holidayEvent = StoredEvent(
        uid: 'holiday_national_day_2026',
        sequence: 0,
        lastModifiedMs: 1727740800000,
        dtstartMs: 1727740800000,
        allDay: true,
        endMs: 1728345600000,
        summary: '国庆节',
        reminderMinutes: null, // NAS WO-67 契约：节日豁免无提醒
      );
      final ics = holidayEvent.toIcs();
      expect(ics.contains('BEGIN:VALARM'), isFalse,
          reason: 'G1 核心底线：节日事件严禁逆向补齐 VALARM 提醒');
      expect(ics.contains('TRIGGER'), isFalse);
      expect(ics.contains('END:VALARM'), isFalse);
      expect(holidayEvent.toIcsWithEnvelope().contains('BEGIN:VALARM'), isFalse);
    });

    test('普通无提醒事件（reminderMinutes=null）导出无 VALARM', () {
      const event = StoredEvent(
        uid: 'no_rem',
        sequence: 1,
        lastModifiedMs: null,
        dtstartMs: 1727740800000,
        allDay: false,
        endMs: 1727744400000,
        summary: '无提醒事件',
        reminderMinutes: null,
      );
      expect(event.toIcs().contains('BEGIN:VALARM'), isFalse);
    });

    test('各档 reminderMinutes 导出 TRIGGER 形态逐字节断言', () {
      // 0 分钟 -> PT0S
      const e0 = StoredEvent(
        uid: 'rem0',
        sequence: 0,
        lastModifiedMs: null,
        dtstartMs: 1727740800000,
        allDay: false,
        endMs: null,
        summary: '准时',
        reminderMinutes: 0,
      );
      expect(e0.toIcs(), contains('TRIGGER:PT0S'));

      // 15 分钟 -> -PT15M
      const e15 = StoredEvent(
        uid: 'rem15',
        sequence: 0,
        lastModifiedMs: null,
        dtstartMs: 1727740800000,
        allDay: false,
        endMs: null,
        summary: '15分',
        reminderMinutes: 15,
      );
      expect(e15.toIcs(), contains('TRIGGER:-PT15M'));

      // 4 小时 (240 分) -> -PT4H
      const e240 = StoredEvent(
        uid: 'rem240',
        sequence: 0,
        lastModifiedMs: null,
        dtstartMs: 1727740800000,
        allDay: true,
        endMs: null,
        summary: '4小时',
        reminderMinutes: 240,
      );
      expect(e240.toIcs(), contains('TRIGGER:-PT4H'));

      // 1 天 (1440 分) -> -P1D
      const e1440 = StoredEvent(
        uid: 'rem1440',
        sequence: 0,
        lastModifiedMs: null,
        dtstartMs: 1727740800000,
        allDay: false,
        endMs: null,
        summary: '1天',
        reminderMinutes: 1440,
      );
      expect(e1440.toIcs(), contains('TRIGGER:-P1D'));

      // 2 天 (2880 分) -> -P2D
      const e2880 = StoredEvent(
        uid: 'rem2880',
        sequence: 0,
        lastModifiedMs: null,
        dtstartMs: 1727740800000,
        allDay: false,
        endMs: null,
        summary: '2天',
        reminderMinutes: 2880,
      );
      expect(e2880.toIcs(), contains('TRIGGER:-P2D'));
    });
  });

  group('WO-76 🔴 护栏 G2：零迁移防御性转换（fromJson / applyMap 宽容容错）', () {
    test('旧 JSON 记录无 reminderMinutes 字段 → 零迁移自然反序列化为 null', () {
      final oldJson = {
        'uid': 'legacy_event',
        'sequence': 1,
        'dtstartMs': 1727740800000,
        'allDay': false,
        'summary': '旧版本日程',
      };
      final event = StoredEvent.fromJson(oldJson);
      expect(event.reminderMinutes, isNull);
      expect(event.toIcs().contains('BEGIN:VALARM'), isFalse);
    });

    test('字符串数值（如 "15" / "240"）宽容转换，不崩 TypeError', () {
      final strJson = {
        'uid': 'str_event',
        'sequence': 1,
        'dtstartMs': 1727740800000,
        'allDay': false,
        'summary': '字符串数值',
        'reminderMinutes': '15',
      };
      final event = StoredEvent.fromJson(strJson);
      expect(event.reminderMinutes, 15);
    });

    test('负数归一化为 null（NAS 语义：负数无需提醒）', () {
      final negJson = {
        'uid': 'neg_event',
        'sequence': 1,
        'dtstartMs': 1727740800000,
        'allDay': false,
        'summary': '负数提醒',
        'reminderMinutes': -15,
      };
      final event = StoredEvent.fromJson(negJson);
      expect(event.reminderMinutes, isNull);

      final negStrJson = {
        'uid': 'neg_str_event',
        'sequence': 1,
        'dtstartMs': 1727740800000,
        'allDay': false,
        'summary': '负数字符串',
        'reminderMinutes': '-30',
      };
      expect(StoredEvent.fromJson(negStrJson).reminderMinutes, isNull);
    });

    test('畸形输入（非数字字符串、布尔、非法类型）不抛异常且安全归一为 null', () {
      final badInputs = [
        'invalid_string',
        true,
        false,
        [15],
        {'rem': 15},
      ];
      for (final bad in badInputs) {
        final j = {
          'uid': 'bad_event',
          'sequence': 1,
          'dtstartMs': 1727740800000,
          'allDay': false,
          'summary': '畸形输入',
          'reminderMinutes': bad,
        };
        expect(() => StoredEvent.fromJson(j), returnsNormally);
        expect(StoredEvent.fromJson(j).reminderMinutes, isNull);
      }
    });

    test('applyUpserts 同样具备完整的宽容转换与负数归一化', () {
      final store = CalendarEventStore();
      store.applyUpserts([
        {
          'uid': 'up_1',
          'dtstartMs': 1727740800000,
          'summary': '条目1',
          'reminderMinutes': '60',
        },
        {
          'uid': 'up_2',
          'dtstartMs': 1727740800000,
          'summary': '条目2',
          'reminderMinutes': -1,
        },
        {
          'uid': 'up_3',
          'dtstartMs': 1727740800000,
          'summary': '条目3',
          'reminderMinutes': 'garbage',
        },
      ]);
      expect(store.events['up_1']?.reminderMinutes, 60);
      expect(store.events['up_2']?.reminderMinutes, isNull);
      expect(store.events['up_3']?.reminderMinutes, isNull);
    });
  });

  group('WO-76 🔴 护栏 G3：数据链四点贯穿验证', () {
    test('完整数据链贯穿：ICS → IcsEvent → _eventToNativeMap → applyMap → StoredEvent → toIcs()', () {
      const ics = 'BEGIN:VCALENDAR\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:wo76-pipeline-1\r\n'
          'SEQUENCE:1\r\n'
          'DTSTART:20261001T090000Z\r\n'
          'DURATION:PT1H\r\n'
          'SUMMARY:全链路测试事件\r\n'
          'BEGIN:VALARM\r\n'
          'ACTION:DISPLAY\r\n'
          'DESCRIPTION:全链路测试事件\r\n'
          'TRIGGER:-PT15M\r\n'
          'END:VALARM\r\n'
          'END:VEVENT\r\n'
          'END:VCALENDAR\r\n';

      // 点 1：IcsEvent
      final parseResult = parseIcs(ics);
      expect(parseResult.events, hasLength(1));
      final icsEvent = parseResult.events.single;
      expect(icsEvent.reminderMinutes, 15, reason: '点 1：IcsEvent 必须持有 reminderMinutes');

      // 点 2：_eventToNativeMap
      final nativeMap = CalendarSyncService.eventToNativeMap(icsEvent);
      expect(nativeMap['reminderMinutes'], 15,
          reason: '点 2：_eventToNativeMap 必须转发 reminderMinutes');

      // 点 3：CalendarEventStore.applyUpserts
      final store = CalendarEventStore();
      store.applyUpserts([nativeMap]);
      expect(store.events.containsKey('wo76-pipeline-1'), isTrue);

      // 点 4：StoredEvent
      final stored = store.events['wo76-pipeline-1']!;
      expect(stored.reminderMinutes, 15, reason: '点 4：StoredEvent 必须存储 reminderMinutes');

      // 回吐：toIcs()
      final exportedIcs = stored.toIcs();
      expect(exportedIcs, contains('BEGIN:VALARM'));
      expect(exportedIcs, contains('ACTION:DISPLAY'));
      expect(exportedIcs, contains('TRIGGER:-PT15M'));
      expect(exportedIcs, contains('END:VALARM'));

      // 往返序列化
      final jsonRoundtrip = StoredEvent.fromJson(stored.toJson());
      expect(jsonRoundtrip.reminderMinutes, 15);
    });
  });
}
