import 'package:flutter_test/flutter_test.dart';

import 'package:bot_companion/services/ics_min_parser.dart';

/// ============================================================================
/// WO-69 · ICS 最小解析器单测（契约子集 / 全天 / 取消 / 未知字段 / 坏数据不抛错）
/// ============================================================================
/// 零 IO 纯函数；夹具形态对齐 NAS 渲染器（caldav-server.js getEventIcs）实测产出：
/// 全天 = VALUE=DATE + DURATION:P1D；定时 = DTSTART:...Z（UTC）。
void main() {
  group('契约主路径形态', () {
    test('定时事件：UTC DTSTART + DURATION + 全字段解析', () {
      const ics = 'BEGIN:VCALENDAR\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:cal_123\r\n'
          'SEQUENCE:2\r\n'
          'DTSTAMP:20260927T010000Z\r\n'
          'LAST-MODIFIED:20260927T003000Z\r\n'
          'DTSTART:20260927T090000Z\r\n'
          'DURATION:PT1H30M\r\n'
          'SUMMARY:体检\\, 复诊\r\n'
          'DESCRIPTION:带好报告\\n记得空腹\r\n'
          'END:VEVENT\r\n'
          'END:VCALENDAR\r\n';
      final r = parseIcs(ics);
      expect(r.errors, isEmpty);
      expect(r.events, hasLength(1));
      final e = r.events.single;
      expect(e.uid, 'cal_123');
      expect(e.sequence, 2);
      expect(e.dtstart, DateTime.utc(2026, 9, 27, 9, 0, 0));
      expect(e.duration, const Duration(hours: 1, minutes: 30));
      expect(e.summary, '体检, 复诊');
      expect(e.description, '带好报告\n记得空腹');
      expect(e.allDay, isFalse);
      expect(e.cancelled, isFalse);
    });

    test('全天事件：VALUE=DATE + DURATION:P1D（NAS 渲染器实测形态）', () {
      const ics = 'BEGIN:VEVENT\r\n'
          'UID:cal_day\r\n'
          'DTSTART;VALUE=DATE:20261001\r\n'
          'DURATION:P1D\r\n'
          'SUMMARY:国庆\r\n'
          'END:VEVENT\r\n';
      final e = parseIcs(ics).events.single;
      expect(e.allDay, isTrue);
      expect(e.dtstart, DateTime(2026, 10, 1));
      expect(e.duration, const Duration(days: 1));
    });

    test('DTEND 形态与 RRULE 原样透传', () {
      const ics = 'BEGIN:VEVENT\r\n'
          'UID:cal_rr\r\n'
          'DTSTART:20260928T020000Z\r\n'
          'DTEND:20260928T030000Z\r\n'
          'RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=8\r\n'
          'SUMMARY:周会\r\n'
          'END:VEVENT\r\n';
      final e = parseIcs(ics).events.single;
      expect(e.dtend, DateTime.utc(2026, 9, 28, 3, 0, 0));
      expect(e.rrule, 'FREQ=WEEKLY;BYDAY=MO;COUNT=8');
    });

    test('STATUS:CANCELLED → cancelled=true（墓碑，SEQUENCE=0 属契约常态）', () {
      const ics = 'BEGIN:VEVENT\r\n'
          'UID:cal_gone\r\n'
          'SEQUENCE:0\r\n'
          'DTSTAMP:20260927T020000Z\r\n'
          'DTSTART:20260928T020000Z\r\n'
          'STATUS:CANCELLED\r\n'
          'SUMMARY:已删除的日程\r\n'
          'END:VEVENT\r\n';
      final e = parseIcs(ics).events.single;
      expect(e.cancelled, isTrue);
      expect(e.sequence, 0);
    });
  });

  group('宽容性与坏数据（不抛错纪律）', () {
    test('未知属性与未知组件（VTIMEZONE/VALARM/X-XXX）一律忽略', () {
      const ics = 'BEGIN:VCALENDAR\r\n'
          'VERSION:2.0\r\n'
          'PRODID:-//2BOT//CN\r\n'
          'BEGIN:VTIMEZONE\r\n'
          'TZID:Asia/Shanghai\r\n'
          'BEGIN:STANDARD\r\n'
          'DTSTART:19700101T000000\r\n'
          'TZOFFSETFROM:+0800\r\n'
          'END:STANDARD\r\n'
          'END:VTIMEZONE\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:cal_x\r\n'
          'X-CUSTOM-PROP:whatever\r\n'
          'DTSTART:20260927T090000Z\r\n'
          'BEGIN:VALARM\r\n'
          'TRIGGER:-PT4H\r\n'
          'ACTION:DISPLAY\r\n'
          'END:VALARM\r\n'
          'SUMMARY:含闹钟事件\r\n'
          'END:VEVENT\r\n'
          'END:VCALENDAR\r\n';
      final r = parseIcs(ics);
      expect(r.errors, isEmpty, reason: '未知组件忽略后事件应完整解析');
      expect(r.events.single.summary, '含闹钟事件');
      expect(r.events.single.rrule, isNull);
    });

    test('行折叠还原与 LF-only 行尾容忍', () {
      const ics = 'BEGIN:VEVENT\n'
          'UID:cal_fold\n'
          'DTSTART:20260927T090000Z\n'
          'SUMMARY:这是一条被折行\n'
          ' 的长标题\n'
          'END:VEVENT\n';
      final e = parseIcs(ics).events.single;
      expect(e.summary, '这是一条被折行的长标题');
    });

    test('缺 UID / 缺 DTSTART → 记错误并跳过，不抛错；其余事件照常解析', () {
      const ics = 'BEGIN:VEVENT\r\n'
          'SUMMARY:没有UID\r\n'
          'DTSTART:20260927T090000Z\r\n'
          'END:VEVENT\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:cal_nostart\r\n'
          'SUMMARY:没有开始时间\r\n'
          'END:VEVENT\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:cal_ok\r\n'
          'DTSTART:20260927T090000Z\r\n'
          'SUMMARY:正常事件\r\n'
          'END:VEVENT\r\n';
      final r = parseIcs(ics);
      expect(r.events, hasLength(1), reason: '只有正常事件入库');
      expect(r.events.single.uid, 'cal_ok');
      expect(r.errors, hasLength(2));
    });

    test('完全坏的数据：空串 / 非ICS文本 / 截断 → 不抛错', () {
      expect(parseIcs('').events, isEmpty);
      expect(parseIcs('这不是 ICS 数据').events, isEmpty);
      final truncated = parseIcs('BEGIN:VEVENT\r\nUID:cal_cut\r\nDTSTART:2026');
      expect(truncated.events, isEmpty, reason: '未闭合事件跳过');
    });

    test('一条邮件多个 VEVENT 全部解析且保序', () {
      const ics = 'BEGIN:VEVENT\r\nUID:a\r\nDTSTART:20260927T090000Z\r\nEND:VEVENT\r\n'
          'BEGIN:VEVENT\r\nUID:b\r\nDTSTART:20260927T100000Z\r\nEND:VEVENT\r\n';
      expect(parseIcs(ics).events.map((e) => e.uid), ['a', 'b']);
    });
  });
}
