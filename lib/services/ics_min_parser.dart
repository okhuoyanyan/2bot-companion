/// ============================================================================
/// WO-69 · 最小 ICS 解析器（仅覆盖 WO-68-SPEC §7 冻结契约产出的子集）
/// ============================================================================
/// 设计要点：
///  1. **不追求通用 ICS**：未知属性一律忽略（不抛错）；解析不出的事件进 [IcsParseResult.errors]
///     并继续处理其余事件——坏数据绝不破坏既有日历内容（规格 T2）；
///  2. 主路径对齐 NAS 渲染器实测形态（caldav-server.js getEventIcs）：
///     全天 = `DTSTART;VALUE=DATE:YYYYMMDD` + `DURATION:P1D`；定时 = `DTSTART:YYYYMMDDTHHMMSSZ`（UTC）；
///     通用形态（TZID/浮动/DTEND）一并支持，但以契约形态优先；
///  3. 零 IO 纯函数，单测可逐字节喂入（与 SmtpSession 同款纪律）。
library;

/// 解析出的单个日程事件（字段名与 ICS 属性一一对应，全部为可空 = 契约字段可能缺席）
class IcsEvent {
  final String uid;
  final int sequence;
  final DateTime? dtstamp;
  final DateTime? lastModified;
  final DateTime dtstart;
  final bool allDay;
  final DateTime? dtend;
  final Duration? duration;
  final String? summary;
  final String? description;
  final String? rrule;
  final bool cancelled;

  const IcsEvent({
    required this.uid,
    required this.sequence,
    required this.dtstart,
    required this.allDay,
    this.dtstamp,
    this.lastModified,
    this.dtend,
    this.duration,
    this.summary,
    this.description,
    this.rrule,
    this.cancelled = false,
  });
}

/// 解析结果：[events] 为成功解析的事件；[errors] 为跳过原因（不中断整体解析）
class IcsParseResult {
  final List<IcsEvent> events;
  final List<String> errors;

  const IcsParseResult({required this.events, required this.errors});
}

/// RFC 5545 文本转义还原（TEXT 值：\\n / \\, / \\; / \\\\）
String _unescapeText(String raw) {
  final sb = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];
    if (ch == r'\' && i + 1 < raw.length) {
      final next = raw[i + 1];
      if (next == 'n' || next == 'N') {
        sb.write('\n');
      } else {
        sb.write(next); // \, \; \\ 原样还原
      }
      i++;
    } else {
      sb.write(ch);
    }
  }
  return sb.toString();
}

/// 行折叠还原（RFC 5545 §3.1：续行以空格或制表符开头）
List<String> unfoldIcsLines(String raw) {
  final normalized = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final physical = normalized.split('\n');
  final logical = <String>[];
  for (final line in physical) {
    if (line.isEmpty) continue;
    if ((line.startsWith(' ') || line.startsWith('\t')) && logical.isNotEmpty) {
      logical[logical.length - 1] += line.substring(1);
    } else {
      logical.add(line);
    }
  }
  return logical;
}

/// 把一行拆成 (NAME, params, value)：只在引号外的第一个冒号处切分
({String name, Map<String, String> params, String value})? _splitProperty(
    String line) {
  var inQuote = false;
  var colon = -1;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      inQuote = !inQuote;
    } else if (ch == ':' && !inQuote) {
      colon = i;
      break;
    }
  }
  if (colon <= 0) return null;
  final head = line.substring(0, colon);
  final value = line.substring(colon + 1);
  final parts = head.split(';');
  final name = parts[0].trim().toUpperCase();
  final params = <String, String>{};
  for (var i = 1; i < parts.length; i++) {
    final seg = parts[i];
    final eq = seg.indexOf('=');
    if (eq <= 0) continue;
    params[seg.substring(0, eq).trim().toUpperCase()] =
        seg.substring(eq + 1).trim();
  }
  return (name: name, params: params, value: value);
}

/// 解析 iCalendar 日期时间值。返回 null 表示无法识别（调用方记错误）。
/// - `YYYYMMDDTHHMMSSZ` → UTC（直接按 UTC 构造，与机器时区无关）
/// - `YYYYMMDDTHHMMSS`（含 TZID=…）→ 无 tzdata 支持，按本地墙钟处理（契约主路径为 UTC，不依赖此分支）
/// - `VALUE=DATE:YYYYMMDD` → 本地零点（allDay 由调用方依参数标记）
DateTime? _parseIcsDateTime(String value, bool valueIsDate) {
  final v = value.trim();
  if (valueIsDate || RegExp(r'^\d{8}$').hasMatch(v)) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})$').firstMatch(v);
    if (m == null) return null;
    return DateTime(
        int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
  }
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$')
      .firstMatch(v);
  if (m == null) return null;
  final isUtc = m.group(7) == 'Z';
  final y = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  final d = int.parse(m.group(3)!);
  final hh = int.parse(m.group(4)!);
  final mi = int.parse(m.group(5)!);
  final ss = int.parse(m.group(6)!);
  if (isUtc) return DateTime.utc(y, mo, d, hh, mi, ss);
  return DateTime(y, mo, d, hh, mi, ss);
}

/// 解析 ISO 8601 DURATION（PnW / PnD / PnDTnHnMnS，支持负号；契约产出 P1D 形态）
Duration? _parseIcsDuration(String value) {
  final m = RegExp(r'^([+-]?)P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$')
      .firstMatch(value.trim());
  if (m == null) return null;
  if (m.group(2) == null &&
      m.group(3) == null &&
      m.group(4) == null &&
      m.group(5) == null &&
      m.group(6) == null) {
    return null; // "P" 空段无效
  }
  var seconds = 0;
  seconds += (int.tryParse(m.group(2) ?? '0') ?? 0) * 7 * 86400;
  seconds += (int.tryParse(m.group(3) ?? '0') ?? 0) * 86400;
  seconds += (int.tryParse(m.group(4) ?? '0') ?? 0) * 3600;
  seconds += (int.tryParse(m.group(5) ?? '0') ?? 0) * 60;
  seconds += (int.tryParse(m.group(6) ?? '0') ?? 0);
  final negative = m.group(1) == '-';
  final d = Duration(seconds: seconds);
  return negative ? -d : d;
}

int? _parseInt(String? v) {
  if (v == null) return null;
  return int.tryParse(v.trim());
}

/// 解析 ICS 全文 → [IcsParseResult]。永不抛出：坏行忽略，坏事件记入 errors。
IcsParseResult parseIcs(String raw) {
  final events = <IcsEvent>[];
  final errors = <String>[];

  String? uid;
  int? sequence;
  DateTime? dtstamp;
  DateTime? lastModified;
  DateTime? dtstart;
  bool dtstartIsDate = false;
  DateTime? dtend;
  Duration? duration;
  String? summary;
  String? description;
  String? rrule;
  bool cancelled = false;
  var inEvent = false;
  final List<String> skipStack = <String>[]; // 未识别组件（VTIMEZONE/VALARM/自定义）栈

  void resetEvent() {
    uid = null;
    sequence = null;
    dtstamp = null;
    lastModified = null;
    dtstart = null;
    dtstartIsDate = false;
    dtend = null;
    duration = null;
    summary = null;
    description = null;
    rrule = null;
    cancelled = false;
  }

  for (final line in unfoldIcsLines(raw)) {
    if (line.startsWith('#')) continue;
    final prop = _splitProperty(line);
    if (prop == null) continue;
    final name = prop.name;
    final value = prop.value;

    if (skipStack.isNotEmpty) {
      // 未识别组件内部：按栈跟踪嵌套（VTIMEZONE 内 STANDARD 等），弹到顶层为止
      if (name == 'BEGIN') {
        skipStack.add(value.trim().toUpperCase());
      } else if (name == 'END' && skipStack.last == value.trim().toUpperCase()) {
        skipStack.removeLast();
      }
      continue;
    }

    switch (name) {
      case 'BEGIN':
        final comp = value.trim().toUpperCase();
        if (comp == 'VEVENT') {
          if (inEvent) {
            // 嵌套 VEVENT（异常形态）：上一个未闭合事件按坏件记账
            errors.add('VEVENT 未闭合（UID: ${uid ?? '<缺>'}），已跳过');
          }
          resetEvent();
          inEvent = true;
        } else if (comp == 'VCALENDAR') {
          // 根容器（可多层包裹）透明处理：绝不跳过内部 VEVENT
        } else {
          skipStack.add(comp);
        }
        break;
      case 'END':
        final comp = value.trim().toUpperCase();
        if (comp == 'VEVENT' && inEvent) {
          if (uid == null || uid!.isEmpty) {
            errors.add('VEVENT 缺少 UID，已跳过');
          } else if (dtstart == null) {
            errors.add('VEVENT (UID: $uid) 缺少 DTSTART，已跳过');
          } else {
            events.add(IcsEvent(
              uid: uid!,
              sequence: sequence ?? 0,
              dtstamp: dtstamp,
              lastModified: lastModified,
              dtstart: dtstart!,
              allDay: dtstartIsDate,
              dtend: dtend,
              duration: duration,
              summary: summary,
              description: description,
              rrule: rrule,
              cancelled: cancelled,
            ));
          }
          resetEvent();
          inEvent = false;
        }
        break;
      case 'UID':
        if (inEvent) uid = value.trim();
        break;
      case 'SEQUENCE':
        if (inEvent) sequence = _parseInt(value) ?? 0;
        break;
      case 'DTSTAMP':
        if (inEvent) dtstamp = _parseIcsDateTime(value, false);
        break;
      case 'LAST-MODIFIED':
        if (inEvent) lastModified = _parseIcsDateTime(value, false);
        break;
      case 'DTSTART':
        if (inEvent) {
          dtstartIsDate =
              prop.params['VALUE']?.toUpperCase() == 'DATE' ||
                  RegExp(r'^\d{8}$').hasMatch(value.trim());
          dtstart = _parseIcsDateTime(value, dtstartIsDate);
        }
        break;
      case 'DTEND':
        if (inEvent) dtend = _parseIcsDateTime(value, false);
        break;
      case 'DURATION':
        if (inEvent) duration = _parseIcsDuration(value);
        break;
      case 'SUMMARY':
        if (inEvent) summary = _unescapeText(value);
        break;
      case 'DESCRIPTION':
        if (inEvent) description = _unescapeText(value);
        break;
      case 'RRULE':
        if (inEvent) rrule = value.trim();
        break;
      case 'STATUS':
        if (inEvent) cancelled = value.trim().toUpperCase() == 'CANCELLED';
        break;
      default:
        // 未知属性一律忽略（不得抛错）
        break;
    }
  }

  if (inEvent) {
    errors.add('ICS 末尾存在未闭合 VEVENT（UID: ${uid ?? '<缺>'}），已跳过');
  }
  return IcsParseResult(events: events, errors: errors);
}
