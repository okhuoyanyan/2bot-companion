/// ============================================================================
/// WO-70 · 本机只读服务之事件模型（唯一事实源）
/// ============================================================================
/// 职责：接收 IMAP 同步管线解析出的事件 → 增量合并 / 墓碑删除 → 对外渲染
/// 完整 VCALENDAR、单事件 ICS、ETag、getctag / sync-token。
/// 存储：SharedPreferences 单键 JSON（写者唯一 = 后台任务 isolate；UI 走
/// SharedPreferencesAsync 直读平台层——与 WO-69 缓存隔离教训同源）。

import 'dart:convert';

import '../utils/constants.dart';

/// FNV-1a 64 位（ETag / ctag / sync-token 派生；随内容必变，与 WO-68 #54 同教训）
String wo70HashHex(String s) {
  var h = 0xcbf29ce484222325;
  for (final cu in s.codeUnits) {
    h ^= cu & 0xff;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    h ^= (cu >> 8) & 0xff;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(16, '0');
}

String _fmtIcsUtc(DateTime utc) {
  final u = utc.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}${two(u.month)}${two(u.day)}'
      'T${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
}

/// WO-76 护栏 G2：防御性转换 reminderMinutes（可空、非负整数、宽容 String/num；
/// 负数归一化为 null；畸形记录日志不抛异常，防 TypeError 崩溃）
int? _parseReminderMinutes(dynamic v) {
  if (v == null) return null;
  if (v is num) {
    final n = v.toInt();
    return n >= 0 ? n : null;
  }
  if (v is String) {
    final n = int.tryParse(v.trim());
    if (n != null) {
      return n >= 0 ? n : null;
    }
    // ignore: avoid_print
    print('[WO76] 畸形 reminderMinutes: "$v"，已归一为 null');
    return null;
  }
  // ignore: avoid_print
  print('[WO76] 畸形 reminderMinutes 类型: ${v.runtimeType} ($v)，已归一为 null');
  return null;
}

/// WO-76：导出 TRIGGER 形态（RFC 5545 Duration，严禁绝对时间戳）
String _formatReminderTrigger(int remMin) {
  if (remMin == 0) return 'PT0S';
  if (remMin % 1440 == 0) return '-P${remMin ~/ 1440}D';
  if (remMin % 60 == 0) return '-PT${remMin ~/ 60}H';
  return '-PT${remMin}M';
}

/// 库内单个事件（字段即渲染所需全部；时间均为 epoch ms）
class StoredEvent {
  final String uid;
  final int sequence;
  final int? lastModifiedMs;
  final int dtstartMs;
  final bool allDay;
  final int? endMs;
  final String? rrule;
  final String summary;
  final String? description;
  final int? reminderMinutes;

  const StoredEvent({
    required this.uid,
    required this.sequence,
    required this.lastModifiedMs,
    required this.dtstartMs,
    required this.allDay,
    required this.endMs,
    required this.summary,
    this.rrule,
    this.description,
    this.reminderMinutes,
  });

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'sequence': sequence,
        if (lastModifiedMs != null) 'lastModifiedMs': lastModifiedMs,
        'dtstartMs': dtstartMs,
        'allDay': allDay,
        if (endMs != null) 'endMs': endMs,
        'summary': summary,
        if (rrule != null) 'rrule': rrule,
        if (description != null) 'description': description,
        if (reminderMinutes != null) 'reminderMinutes': reminderMinutes,
      };

  static StoredEvent fromJson(Map<String, dynamic> j) => StoredEvent(
        uid: j['uid'] as String,
        sequence: (j['sequence'] as num?)?.toInt() ?? 0,
        lastModifiedMs: (j['lastModifiedMs'] as num?)?.toInt(),
        dtstartMs: (j['dtstartMs'] as num?)?.toInt() ?? 0,
        allDay: j['allDay'] as bool? ?? false,
        endMs: (j['endMs'] as num?)?.toInt(),
        summary: (j['summary'] as String?) ?? '(无标题)',
        rrule: j['rrule'] as String?,
        description: j['description'] as String?,
        reminderMinutes: _parseReminderMinutes(j['reminderMinutes']),
      );

  /// 单事件 VEVENT 文本（WO-69 通道事件 → CalDAV 资源；对齐 NAS 渲染语义）
  String toIcs() {
    final buf = StringBuffer()
      ..writeln('BEGIN:VEVENT')
      ..writeln('UID:$uid')
      ..writeln('SEQUENCE:$sequence');
    if (lastModifiedMs != null) {
      buf.writeln('DTSTAMP:${_fmtIcsUtc(
          DateTime.fromMillisecondsSinceEpoch(lastModifiedMs!, isUtc: true))}');
      buf.writeln('LAST-MODIFIED:${_fmtIcsUtc(
          DateTime.fromMillisecondsSinceEpoch(lastModifiedMs!, isUtc: true))}');
    }
    if (allDay) {
      // WO-78 缺陷①修复（时区对称硬不变式）：全天 DATE 的毫秒来自
      // ics_min_parser 的【本地零点】解析（VALUE=DATE → DateTime(y,mo,d) 本地），
      // 导出必须取【同一时区】的墙钟日期。原 `.toUtc()` 在 UTC+8 上把
      // 本地零点折成前一日 16:00Z → 全部全天事件错位一天（节假日首当其冲）。
      // 对称后与 NAS 输入 DATE 行逐字节相等（wo78_all_day_roundtrip_test 钉死）。
      final d = DateTime.fromMillisecondsSinceEpoch(dtstartMs);
      buf.writeln('DTSTART;VALUE=DATE:'
          '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}');
      if (endMs != null) {
        final e = DateTime.fromMillisecondsSinceEpoch(endMs!);
        buf.writeln('DTEND;VALUE=DATE:'
            '${e.year.toString().padLeft(4, '0')}${e.month.toString().padLeft(2, '0')}${e.day.toString().padLeft(2, '0')}');
      } else {
        buf.writeln('DURATION:P1D');
      }
    } else {
      buf.writeln('DTSTART:${_fmtIcsUtc(
          DateTime.fromMillisecondsSinceEpoch(dtstartMs, isUtc: true))}');
      if (endMs != null) {
        buf.writeln('DTEND:${_fmtIcsUtc(
            DateTime.fromMillisecondsSinceEpoch(endMs!, isUtc: true))}');
      } else {
        buf.writeln('DURATION:PT1H');
      }
    }
    if (rrule != null && rrule!.isNotEmpty) buf.writeln('RRULE:$rrule');
    buf.writeln('SUMMARY:${_escapeIcsText(summary)}');
    if (description != null && description!.isNotEmpty) {
      buf.writeln('DESCRIPTION:${_escapeIcsText(description!)}');
    }
    // WO-76 护栏 G1：严禁凭空造提醒——当且仅当 reminderMinutes != null 才输出 BEGIN:VALARM
    // 字段为 null（含 NAS 节日事件已定点豁免）恒不输出 VALARM，严禁擅自补齐默认提醒
    if (reminderMinutes != null) {
      buf.writeln('BEGIN:VALARM');
      buf.writeln('ACTION:DISPLAY');
      buf.writeln('DESCRIPTION:${_escapeIcsText(summary)}');
      buf.writeln('TRIGGER:${_formatReminderTrigger(reminderMinutes!)}');
      buf.writeln('END:VALARM');
    }
    buf.write('END:VEVENT');
    return buf.toString();
  }

  /// WO-74-R2 Phase 2 · 单事件 ICS 的 VCALENDAR 信封版（per-event 出口专用）。
  /// 病灶：per-event calendar-data 发裸 BEGIN:VEVENT，ical4j 严格解析拒收
  ///（RFC 4791 §5.1/5545 要求 text/calendar 必含 VCALENDAR 包裹）。
  /// 聚合 renderFullIcs() 自带信封，两勿混用。行尾统一 CRLF（与服务端
  /// _crlf 幂等）→ etag 按本字节计算，PROPFIND 列表/REPORT/GET 全链一致。
  /// PRODID 对齐 NAS 侧 caldav-server.js。
  String toIcsWithEnvelope() {
    return 'BEGIN:VCALENDAR\r\n'
        'VERSION:2.0\r\n'
        'PRODID:-//QQ-2BOT-NEW//CalDAV Server//CN\r\n'
        'CALSCALE:GREGORIAN\r\n'
        '${toIcs().replaceAll('\n', '\r\n')}'
        '\r\nEND:VCALENDAR';
  }

  static String _escapeIcsText(String raw) => raw
      .replaceAll('\\', '\\\\')
      .replaceAll(';', '\\;')
      .replaceAll(',', '\\,')
      .replaceAll('\n', '\\n');
}

/// 事件库：事件表 + 墓碑表 + 内容派生版本
class CalendarEventStore {
  final Map<String, StoredEvent> events;
  /// 墓碑：uid → 删除时刻 ms（sync-collection 以 404 通报，防旧数据复活）
  final Map<String, int> tombstones;

  CalendarEventStore({
    Map<String, StoredEvent>? events,
    Map<String, int>? tombstones,
  })  : events = events ?? <String, StoredEvent>{},
        tombstones = tombstones ?? <String, int>{};

  static CalendarEventStore fromJson(Map<String, dynamic> j) {
    final ev = <String, StoredEvent>{};
    final rawEvents = j['events'];
    if (rawEvents is Map) {
      rawEvents.forEach((k, v) {
        if (v is Map) {
          ev[k.toString()] = StoredEvent.fromJson(v.cast<String, dynamic>());
        }
      });
    }
    final tb = <String, int>{};
    final rawTb = j['tombstones'];
    if (rawTb is Map) {
      rawTb.forEach((k, v) => tb[k.toString()] = (v as num).toInt());
    }
    return CalendarEventStore(events: ev, tombstones: tb);
  }

  Map<String, dynamic> toJson() => {
        'events': events.map((k, v) => MapEntry(k, v.toJson())),
        'tombstones': tombstones,
      };

  /// ctag：内容指纹（事件表 + 墓碑表 + 渲染版本）——内容一变必跃迁（#54 教训）
  /// WO-78-R2：ctag = 库数据指纹（事件表+墓碑表）+【全部 per-event 服务端 etag】
  /// （etag 即实际发送 ICS 字节的哈希——渲染任何变化自动传导，根治「忘了 bump
  /// 渲染版本」失败模式；NAS #54 手机版终修。WO-78 全天 DATE 对称化即首例：
  /// 渲染变 → 本指纹必变 → 客户端全量重拉自愈）。
  /// etags 排序后拼接：同数据同渲染 → 指纹稳定（幂等，防每周期全量重拉风暴），
  /// 与事件插入序无关。
  String get ctag {
    // 规范化组合：事件/墓碑按 uid 排序、etags 排序——插入序不进指纹
    final uids = events.keys.toList()..sort();
    final dataParts = <String>[];
    for (final uid in uids) {
      dataParts.add('$uid:${json.encode(events[uid]!.toJson())}');
    }
    final tombUids = tombstones.keys.toList()..sort();
    final tombParts = <String>[];
    for (final k in tombUids) {
      tombParts.add('$k:${tombstones[k]}');
    }
    final etags = events.values
        .map((e) => etagOf(e.toIcsWithEnvelope()))
        .toList()
      ..sort();
    return wo70HashHex('events=[${dataParts.join(',')}]'
        '|tombs=[${tombParts.join(',')}]'
        '|ics:${etags.join(',')}');
  }

  /// sync-token：对齐 NAS 形态 `data:,<version>`（version=同上聚合指纹）
  String get syncToken => 'data:,$ctag';

  /// 应用同步管线下发的一批事件（CANCELLED → 物理移除 + 墓碑）。
  /// 返回 (applied, removed)。幂等：同版本事件重复应用无害。
  ({int applied, int removed}) applyUpserts(
      List<Map<String, dynamic>> incoming) {
    var applied = 0;
    var removed = 0;
    for (final e in incoming) {
      final uid = e['uid'] as String?;
      if (uid == null || uid.isEmpty) continue;
      if (e['cancelled'] == true) {
        if (events.containsKey(uid)) {
          events.remove(uid);
          removed++;
        }
        tombstones[uid] = (e['lastModifiedMs'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch;
        continue;
      }
      events[uid] = StoredEvent(
        uid: uid,
        sequence: (e['sequence'] as num?)?.toInt() ?? 0,
        lastModifiedMs: (e['lastModifiedMs'] as num?)?.toInt(),
        dtstartMs: (e['dtstartMs'] as num?)?.toInt() ?? 0,
        allDay: e['allDay'] as bool? ?? false,
        endMs: (e['endMs'] as num?)?.toInt(),
        summary: (e['summary'] as String?) ?? '(无标题)',
        rrule: e['rrule'] as String?,
        description: e['description'] as String?,
        reminderMinutes: _parseReminderMinutes(e['reminderMinutes']),
      );
      tombstones.remove(uid); // 复活语义：同 UID 重新出现即移除墓碑
      applied++;
    }
    return (applied: applied, removed: removed);
  }

  /// 完整 VCALENDAR（GET /calendar.ics 用；只渲染存活事件）
  String renderFullIcs() {
    final buf = StringBuffer()
      ..writeln('BEGIN:VCALENDAR')
      ..writeln('VERSION:2.0')
      ..writeln('PRODID:-//2BOT//Companion Local Calendar//CN')
      ..writeln('X-WR-CALNAME:${AppConstants.calendarDisplayName}')
      ..writeln('CALSCALE:GREGORIAN');
    final sorted = events.values.toList()
      ..sort((a, b) => a.dtstartMs.compareTo(b.dtstartMs));
    for (final e in sorted) {
      buf.writeln(e.toIcs().replaceAll('\n', '\r\n'));
    }
    buf.write('END:VCALENDAR');
    return buf.toString();
  }

  String etagOf(String body) => '"${wo70HashHex(body)}"';

  static const String prefsKey = 'pref_calendar_event_store';
}
