import 'package:flutter_test/flutter_test.dart';

import 'package:bot_companion/services/calendar_event_store.dart';
import 'package:bot_companion/services/ics_min_parser.dart';

/// WO-78 缺陷① · 全天事件时区对称性（硬不变式）
///
/// 断言现状对照（grep -n 复核于改前 b05c418）：
/// - ics_min_parser.dart:121-128 `VALUE=DATE:YYYYMMDD` → **本地零点** DateTime(y,mo,d)；
/// - calendar_event_store.dart toIcs() 全天导出 `...fromMillisecondsSinceEpoch(ms).toUtc()`
///   → 取 **UTC** 日期。
/// UTC+8 宿主上：本地零点(10-01 00:00+08) == UTC(09-30 16:00Z) → 导出 DATE=20260930
/// = **错位一天**（全部全天事件，节假日首当其冲）。
///
/// 硬不变式（规格①）：NAS ICS → parse → store → toIcs() → 与 NAS 输入的
/// DTSTART/DTEND DATE 行【逐字节相等】。本文件日期特意跨年（01-01 本地零点
/// −8h = 前一年 12-31 → 年份也会错的经典形态）。
Map<String, dynamic> toNative(dynamic e) => {
      'uid': e.uid,
      'sequence': e.sequence,
      'dtstampMs': e.dtstamp?.millisecondsSinceEpoch,
      'lastModifiedMs': e.lastModified?.millisecondsSinceEpoch,
      'dtstartMs': e.dtstart.millisecondsSinceEpoch,
      'allDay': e.allDay,
      'endMs': (e.dtend ?? e.dtstart.add(e.duration ?? const Duration(days: 1)))
          .millisecondsSinceEpoch,
      'rrule': e.rrule,
      'summary': e.summary,
      'description': e.description,
      'cancelled': e.cancelled,
    };

void main() {
  // 宿主时区为 UTC+8（中国标准时间）——正是缺陷暴露的时区形态
  test('往返性质：全天事件 parse→store→toIcs 与 NAS 输入 DATE 行逐字节相等', () {
    final dates = <(String, String)>[
      ('20261001', '20261008'), // 国庆 10/1–10/7（DTEND 独占）
      ('20270101', '20270102'), // 跨年：本地零点−8h 落前一年
      ('20260228', '20260301'), // 平年月末
      ('20240229', '20240301'), // 闰日
      ('20261231', '20270101'), // 年末→元旦（DTEND 跨年）
    ];
    for (final (start, end) in dates) {
      final nasIcs = 'BEGIN:VCALENDAR\n'
          'VERSION:2.0\n'
          'BEGIN:VEVENT\n'
          'UID:wo78-$start\n'
          'DTSTAMP:20260929T000000Z\n'
          'DTSTART;VALUE=DATE:$start\n'
          'DTEND;VALUE=DATE:$end\n'
          'SUMMARY:假期测试\n'
          'END:VEVENT\n'
          'END:VCALENDAR';

      final parsed = parseIcs(nasIcs);
      expect(parsed.events, hasLength(1), reason: 'NAS ICS: $nasIcs');
      final ev = parsed.events.single;
      expect(ev.allDay, isTrue);

      final store = CalendarEventStore()..applyUpserts([toNative(ev)]);

      final exported = store.events['wo78-$start']!.toIcs();

      final startLine = exported
          .split('\n')
          .firstWhere((l) => l.startsWith('DTSTART;VALUE=DATE:'));
      final endLine = exported
          .split('\n')
          .firstWhere((l) => l.startsWith('DTEND;VALUE=DATE:'));

      expect(startLine, 'DTSTART;VALUE=DATE:$start',
          reason: 'DTSTART 必须与 NAS 输入逐字节相等（错位=缺陷）');
      expect(endLine, 'DTEND;VALUE=DATE:$end',
          reason: 'DTEND 必须与 NAS 输入逐字节相等（独占尾日不得丢/移）');
    }
  });

  test('往返性质：全天事件经 toIcsWithEnvelope 后 DATE 行同样对称', () {
    final nasIcs = 'BEGIN:VCALENDAR\n'
        'VERSION:2.0\n'
        'BEGIN:VEVENT\n'
        'UID:wo78-env\n'
        'DTSTAMP:20260929T000000Z\n'
        'DTSTART;VALUE=DATE:20261001\n'
        'DTEND;VALUE=DATE:20261008\n'
        'SUMMARY:国庆\n'
        'END:VEVENT\n'
        'END:VCALENDAR';
    final ev = parseIcs(nasIcs).events.single;
    final store = CalendarEventStore()..applyUpserts([toNative(ev)]);
    final exported = store.events['wo78-env']!.toIcsWithEnvelope();
    expect(exported, contains('DTSTART;VALUE=DATE:20261001'));
    expect(exported, contains('DTEND;VALUE=DATE:20261008'));
  });

  test('往返性质：DURATION 形态全天事件（无 DTEND）同样对称', () {
    final nasIcs = 'BEGIN:VCALENDAR\n'
        'VERSION:2.0\n'
        'BEGIN:VEVENT\n'
        'UID:wo78-dur\n'
        'DTSTAMP:20260929T000000Z\n'
        'DTSTART;VALUE=DATE:20261001\n'
        'DURATION:P1D\n'
        'SUMMARY:单日\n'
        'END:VEVENT\n'
        'END:VCALENDAR';
    final ev = parseIcs(nasIcs).events.single;
    final store = CalendarEventStore()..applyUpserts([toNative(ev)]);
    final exported = store.events['wo78-dur']!.toIcs();
    final startLine =
        exported.split('\n').firstWhere((l) => l.startsWith('DTSTART;VALUE=DATE:'));
    expect(startLine, 'DTSTART;VALUE=DATE:20261001');
  });

  test('ctag 自愈前提：修复后全天事件导出字节必与改前不同（触发 KashCal 重拉）', () {
    // 以国庆事件证明：改前（错位 20260930）与改后（20261001）字节不同
    // → 内容派生 ctag/etag 跃迁 → 客户端全量重拉自愈（规格②前提）
    final nasIcs = 'BEGIN:VCALENDAR\n'
        'VERSION:2.0\n'
        'BEGIN:VEVENT\n'
        'UID:wo78-ctag\n'
        'DTSTAMP:20260929T000000Z\n'
        'DTSTART;VALUE=DATE:20261001\n'
        'DTEND;VALUE=DATE:20261008\n'
        'SUMMARY:x\n'
        'END:VEVENT\n'
        'END:VCALENDAR';
    final ev = parseIcs(nasIcs).events.single;
    final store = CalendarEventStore()..applyUpserts([toNative(ev)]);
    final exported = store.events['wo78-ctag']!.toIcs();
    expect(exported, contains('DTSTART;VALUE=DATE:20261001'),
        reason: '错位修复后 ctag 必跃迁（改前为 20260930）');
    expect(exported, isNot(contains('20260930')));
  });
}
