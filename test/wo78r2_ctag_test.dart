import 'package:flutter_test/flutter_test.dart';

import 'package:bot_companion/services/calendar_event_store.dart';

/// WO-78-R2 · ctag/sync-token 反映「实际发送字节」
///
/// 断言现状对照（改前 9f4094f）：ctag = hash(json(库) + '|rv1')——渲染版本常量
/// 在 WO-78 改全天 DATE 渲染时未 bump → ctag 停在 -42734b97… → 客户端探针
/// 永不重拉 → 错日期滞留（NAS #54 手机版）。
/// 修复后（推荐实现①）：ctag = hash(json(库) + per-event 服务端 etag 聚合)——
/// etag 即实际发送 ICS 字节哈希，渲染任何变化自动传导。
Map<String, dynamic> nativeOf(String uid, {bool cancelled = false}) => {
      'uid': uid,
      'sequence': 0,
      'lastModifiedMs': 1727000000000,
      'dtstartMs': 1727100000000,
      'allDay': true,
      'endMs': 1727186400000,
      'summary': '事件 $uid',
      'cancelled': cancelled,
    };

/// 渲染变体：同字段数据、不同 ICS 字节（模拟「将来某次渲染修改」）
class RenderV2Event extends StoredEvent {
  const RenderV2Event({
    required super.uid,
    required super.sequence,
    required super.lastModifiedMs,
    required super.dtstartMs,
    required super.allDay,
    required super.endMs,
    required super.summary,
  });

  @override
  String toIcsWithEnvelope() =>
      'BEGIN:VCALENDAR\r\nX-RENDER:V2\r\n${super.toIcsWithEnvelope()}';
}

StoredEvent _base(String uid) => StoredEvent(
      uid: uid,
      sequence: 0,
      lastModifiedMs: 1727000000000,
      dtstartMs: 1727100000000,
      allDay: true,
      endMs: 1727186400000,
      summary: '事件 $uid',
    );

void main() {
  group('WO-78-R2 · ctag 聚合指纹', () {
    test('渲染耦合（决定性）：同数据、渲染字节不同 → ctag 必变', () {
      final v1 = CalendarEventStore(events: {'a': _base('a')});
      final v2 = CalendarEventStore(events: {'a': RenderV2Event(
        uid: 'a',
        sequence: 0,
        lastModifiedMs: 1727000000000,
        dtstartMs: 1727100000000,
        allDay: true,
        endMs: 1727186400000,
        summary: '事件 a',
      )});
      expect(v1.ctag, isNot(v2.ctag),
          reason: '渲染变化必须传导进 ctag（本单病灶的回归钉）');
      // sync-token 同步传导
      expect(v1.syncToken, isNot(v2.syncToken));
    });

    test('幂等：同库连算两次同值；同数据两实例同值（不许每算必变→重拉风暴）', () {
      final s = CalendarEventStore()
        ..applyUpserts([nativeOf('a'), nativeOf('b')]);
      expect(s.ctag, s.ctag, reason: '同一实例连算两次必须稳定');
      final s2 = CalendarEventStore()
        ..applyUpserts([nativeOf('a'), nativeOf('b')]);
      expect(s2.ctag, s.ctag, reason: '同数据两实例必须同指纹');
      expect(s2.syncToken, s.syncToken);
    });

    test('插入序无关：upsert [a,b] 与 [b,a] 同指纹（排序消除顺序噪声）', () {
      final s1 = CalendarEventStore()
        ..applyUpserts([nativeOf('a'), nativeOf('b')]);
      final s2 = CalendarEventStore()
        ..applyUpserts([nativeOf('b'), nativeOf('a')]);
      expect(s1.ctag, s2.ctag, reason: '插入序不得造成伪变化（防重启后全量重拉）');
    });

    test('库数据变化仍传导：新增/墓碑 → ctag 跃迁（原语义保留）', () {
      final s = CalendarEventStore()..applyUpserts([nativeOf('a')]);
      final c0 = s.ctag;
      s.applyUpserts([nativeOf('b')]);
      expect(s.ctag, isNot(c0), reason: '新增事件');

      final s2 = CalendarEventStore()..applyUpserts([nativeOf('a')]);
      final c1 = s2.ctag;
      s2.applyUpserts([
        {'uid': 'a', 'cancelled': true, 'lastModifiedMs': 1727999999999},
      ]);
      expect(s2.ctag, isNot(c1), reason: '墓碑删除（sync-collection 404 语义）');
    });

    test('形状：sync-token 对齐 NAS `data:,<hex>`（既有断言语义保留）', () {
      final s = CalendarEventStore()..applyUpserts([nativeOf('a')]);
      expect(s.syncToken, startsWith('data:,'));
      expect(s.ctag.length, greaterThanOrEqualTo(16));
    });
  });
}
