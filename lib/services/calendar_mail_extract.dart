/// ============================================================================
/// WO-69 · 日历邮件 → ICS 正文提取（仅覆盖 WO-68-SPEC §7 冻结契约的 MIME 形态）
/// ============================================================================
/// 契约：单个 `calendar.ics` 附件（`text/calendar; charset=utf-8`，UTF-8 无 BOM、CRLF）。
/// 主路径 = base64 传输编码；quoted-printable / 7bit-8bit 为兼容加分。
/// 提取不到（结构超契约）→ 返回 null 由调用方记错误并停手上报（不得静默造数据）。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 提取邮件原始全文中的 ICS 正文。找不到 → null。
String? extractIcsFromMail(String raw) {
  // 1. 切头部/正文
  final headerEnd = raw.indexOf('\r\n\r\n');
  final sep = headerEnd >= 0 ? 4 : (raw.indexOf('\n\n') >= 0 ? 2 : -1);
  if (sep < 0) return null;
  final headerBlock = raw.substring(0, sep == 4 ? headerEnd : raw.indexOf('\n\n'));
  final body = raw.substring(sep == 4 ? headerEnd + 4 : raw.indexOf('\n\n') + 2);

  final contentType = _unfoldedHeader(headerBlock, 'Content-Type') ?? '';

  // 2. multipart：按 boundary 找 text/calendar 附件
  final boundaryMatch =
      RegExp(r'boundary\s*=\s*(?:"([^"]+)"|([^\s;]+))', caseSensitive: false)
          .firstMatch(contentType);
  if (boundaryMatch != null) {
    final boundary = boundaryMatch.group(1) ?? boundaryMatch.group(2)!;
    return _findIcsInMultipart(body, boundary);
  }

  // 3. 非 multipart：正文本身就是 ICS（仅当 Content-Type 声明 text/calendar）
  if (contentType.toLowerCase().contains('text/calendar')) {
    final cte = (_unfoldedHeader(headerBlock, 'Content-Transfer-Encoding') ?? '')
        .trim()
        .toLowerCase();
    return _decodeBody(body, cte);
  }
  return null;
}

/// 折叠还原后的单个头值（按头名取，忽略大小写）
String? _unfoldedHeader(String headerBlock, String name) {
  final lines = headerBlock.split(RegExp(r'\r?\n'));
  String? acc;
  for (final line in lines) {
    if (line.startsWith(' ') || line.startsWith('\t')) {
      acc = acc == null ? null : '$acc ${line.trim()}';
      continue;
    }
    if (acc != null) return acc; // 已进入下一个头
    final colon = line.indexOf(':');
    if (colon > 0 &&
        line.substring(0, colon).trim().toLowerCase() == name.toLowerCase()) {
      acc = line.substring(colon + 1).trim();
    }
  }
  return acc;
}

/// 在 multipart 正文里定位 ICS 附件并解码
String? _findIcsInMultipart(String body, String boundary) {
  final delimiter = '--$boundary';
  final parts = body.split(RegExp('^$delimiter',
          multiLine: true, caseSensitive: false));
  for (final part in parts) {
    var p = part;
    if (p.startsWith('\r\n')) p = p.substring(2);
    if (p.startsWith('\n')) p = p.substring(1);
    if (p.startsWith('--')) continue; // 结束标记
    final partHeaderEnd = p.indexOf('\r\n\r\n');
    var partSep = 4;
    if (partHeaderEnd < 0) {
      final lf = p.indexOf('\n\n');
      if (lf < 0) continue;
      partSep = 2;
    }
    final partHeader = p.substring(
        0, partSep == 4 ? partHeaderEnd : p.indexOf('\n\n'));
    var partBody = p.substring(
        partSep == 4 ? partHeaderEnd + 4 : p.indexOf('\n\n') + 2);
    // 去掉属于下一边界的尾部（split 残留）
    final tail = partBody.lastIndexOf('--$boundary');
    if (tail >= 0) partBody = partBody.substring(0, tail);
    partBody = partBody.trimRight();

    final ct = (_unfoldedHeader(partHeader, 'Content-Type') ?? '').toLowerCase();
    final cd = (_unfoldedHeader(partHeader, 'Content-Disposition') ?? '');
    final isIcs = ct.contains('text/calendar') ||
        RegExp(r'filename\s*=\s*"?calendar\.ics', caseSensitive: false)
            .hasMatch(cd);
    if (!isIcs) continue;

    final cte =
        (_unfoldedHeader(partHeader, 'Content-Transfer-Encoding') ?? '')
            .trim()
            .toLowerCase();
    return _decodeBody(partBody, cte);
  }
  return null;
}

/// 按传输编码解码正文（base64 契约主路径；QP/7bit 兼容加分）
String? _decodeBody(String body, String cte) {
  try {
    switch (cte) {
      case 'base64':
        final compact = body.replaceAll(RegExp(r'\s+'), '');
        return utf8.decode(base64Decode(compact), allowMalformed: true);
      case 'quoted-printable':
        return utf8.decode(_decodeQuotedPrintable(body), allowMalformed: true);
      case '':
      case '7bit':
      case '8bit':
        return body;
      default:
        return null; // 未知编码不猜（宁报错不造数据）
    }
  } catch (_) {
    return null;
  }
}

Uint8List _decodeQuotedPrintable(String input) {
  // 先去掉软换行 =\r\n / =\n
  final noSoft = input.replaceAll(RegExp('=\r?\n'), '');
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < noSoft.length; i++) {
    final ch = noSoft[i];
    if (ch == '=' && i + 2 < noSoft.length) {
      final hex = noSoft.substring(i + 1, i + 3);
      final byte = int.tryParse(hex, radix: 16);
      if (byte != null) {
        out.addByte(byte);
        i += 2;
        continue;
      }
    }
    out.addByte(ch.codeUnitAt(0)); // QP 正文为 ASCII 字节流
  }
  return out.takeBytes();
}
