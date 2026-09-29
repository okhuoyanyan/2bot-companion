import 'package:flutter_test/flutter_test.dart';

import 'package:bot_companion/services/calendar_sync_service.dart';

/// WO-78 缺陷② · 推送延迟度量（验收口径「推送 X 秒到达」的解析底座）
void main() {
  group('parseRfc5322Date（邮件 Date 头 → UTC 时刻）', () {
    test('QQ 形态 +0800', () {
      final d = CalendarSyncService.parseRfc5322Date(
          'Date: Thu, 01 Oct 2026 08:00:12 +0800\r\n');
      expect(d, DateTime.utc(2026, 10, 1, 0, 0, 12),
          reason: '08:00:12+08:00 == 00:00:12Z');
    });

    test('西方形态 -0500', () {
      final d = CalendarSyncService.parseRfc5322Date(
          'Date: Wed, 30 Sep 2026 20:15:00 -0500\r\n');
      expect(d, DateTime.utc(2026, 10, 1, 1, 15, 0));
    });

    test('无逗号形态 / 小写月 / 缺失 → null（不猜）', () {
      expect(
          CalendarSyncService.parseRfc5322Date(
              'Date: 1 Oct 2026 08:00:12 +0800'),
          DateTime.utc(2026, 10, 1, 0, 0, 12));
      expect(
          CalendarSyncService.parseRfc5322Date(
              'Date: Thu, 01 oct 2026 08:00:12 +0800'),
          DateTime.utc(2026, 10, 1, 0, 0, 12));
      expect(CalendarSyncService.parseRfc5322Date('Date: (none)\r\n'), isNull);
      expect(CalendarSyncService.parseRfc5322Date(''), isNull);
    });

    test('端到端延迟口径：Date 头早于 now → 差值即「推送 X 秒到达」的 X', () {
      final d = CalendarSyncService.parseRfc5322Date(
          'Date: Tue, 29 Sep 2026 02:00:00 +0800');
      expect(d, isNotNull);
      // 2026-10-01 08:00+08 = 00:00Z；真实设备时钟晚于此 → 差为正秒
      expect(
          DateTime.now().difference(d!).inSeconds, greaterThanOrEqualTo(0));
    });
  });
}
