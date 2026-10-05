import 'dart:convert';

import '../../lib/services/calendar_event_store.dart';
import '../../lib/services/ics_min_parser.dart';

const expectedDates = [
  ['DTSTART;VALUE=DATE:20261231', 'DTEND;VALUE=DATE:20270101'],
  ['DTSTART;VALUE=DATE:20240229', 'DTEND;VALUE=DATE:20240301'],
  ['DTSTART;VALUE=DATE:20260228', 'DTEND;VALUE=DATE:20260301'],
];

Map<String, Object> probe() {
  final dates = <List<String>>[];
  for (var i = 0; i < expectedDates.length; i++) {
    final pair = expectedDates[i];
    final input = 'BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\n'
        'UID:wo105-$i\n${pair.join('\n')}\n'
        'SUMMARY:fixture\nEND:VEVENT\nEND:VCALENDAR';
    final parsed = parseIcs(input).events.single;
    final store = CalendarEventStore()
      ..applyUpserts([
        {
          'uid': parsed.uid,
          'sequence': parsed.sequence,
          'allDay': parsed.allDay,
          'dtstartMs': parsed.dtstart.millisecondsSinceEpoch,
          'endMs': parsed.dtend!.millisecondsSinceEpoch,
        }
      ]);
    dates.add(store.events[parsed.uid]!
        .toIcs()
        .split('\n')
        .where((line) =>
            line.startsWith('DTSTART;VALUE=DATE:') ||
            line.startsWith('DTEND;VALUE=DATE:'))
        .toList());
  }
  return {
    'offsetMinutes': DateTime(2024, 9, 25).timeZoneOffset.inMinutes,
    'dates': dates,
  };
}

void main() => print(jsonEncode(probe()));
