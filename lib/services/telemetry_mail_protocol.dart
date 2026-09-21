import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;

/// ============================================================================
/// WO-36 遥测邮箱信道 · 协议层（协议常量 + ENC1 加解密 + dot-stuffing + 报文组装）
/// ============================================================================
/// 与 NAS 侧 `plugins/core/telemetry-mail/protocol.mjs` / `payload.mjs` **逐字节对齐**：
///   主题: X-2BOT-TEL-{毫秒时间戳}
///   正文: 明文 → 遥测 JSON 单行 UTF-8
///         加密 → ENC1:{iv_b64}:{tag_b64}:{ct_b64}（AES-256-GCM, key 32B hex, iv 12B, tag 16B, 无 AAD）
/// 本文件为纯函数集合，不触碰网络与存储，便于单测直接覆盖。
class MailProtocol {
  MailProtocol._();

  static const String defaultSubjectPrefix = 'X-2BOT-TEL';
  static const String enc1Tag = 'ENC1';
  static const String enc1Sep = ':';
  static const int keyByteLength = 32;
  static const int ivByteLength = 12;
  static const int tagByteLength = 16;

  /// 构造邮件主题：`{prefix}-{毫秒时间戳}`
  static String buildSubject(int timestampMs, {String prefix = defaultSubjectPrefix}) {
    return '$prefix-$timestampMs';
  }

  /// 校验并归一化 32 字节 hex 密钥；非法返回 null（调用方据此放弃本封，**严禁明文降级**）
  ///
  /// 返回 `Uint8List?`：`encrypt` 5.0.3 的 `Key`/`IV`/`Encrypted` 构造签名均要求 `Uint8List`，
  /// 转换点集中在本函数，避免散落的类型强转。
  static Uint8List? normalizeKeyHex(String keyHex) {
    final trimmed = keyHex.trim();
    if (trimmed.length != keyByteLength * 2) return null;
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(trimmed)) return null;
    final out = Uint8List(keyByteLength);
    for (var i = 0; i < keyByteLength; i++) {
      out[i] = int.parse(trimmed.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// AES-256-GCM 加密 → ENC1 信封；任何失败返回 null（§1：加密失败 = 本封放弃）
  ///
  /// [ivOverride] 仅供单测注入固定 IV（跨语言 KAT 向量）；生产恒为 null = 每次随机 12 字节。
  static String? encryptEnc1(String plaintext, String keyHex, {List<int>? ivOverride}) {
    final keyBytes = normalizeKeyHex(keyHex);
    if (keyBytes == null) return null;

    final ivBytes = Uint8List.fromList(
      ivOverride ?? List<int>.generate(ivByteLength, (_) => _secureRandomByte()),
    );
    if (ivBytes.length != ivByteLength) return null;

    try {
      final encrypter = enc.Encrypter(enc.AES(enc.Key(keyBytes), mode: enc.AESMode.gcm));
      final combined = encrypter
          .encryptBytes(utf8.encode(plaintext), iv: enc.IV(ivBytes))
          .bytes;
      // GCM 输出 = 密文 || 认证标签(16B)，按 §1 拆成两个字段
      if (combined.length < tagByteLength) return null;
      final ct = combined.sublist(0, combined.length - tagByteLength);
      final tag = combined.sublist(combined.length - tagByteLength);
      return [
        enc1Tag,
        base64.encode(ivBytes),
        base64.encode(tag),
        base64.encode(ct),
      ].join(enc1Sep);
    } catch (_) {
      return null;
    }
  }

  /// ENC1 信封 → 明文；结构/密钥/认证任一失败返回 null（GCM 认证失败即丢弃，不产出半截明文）
  static String? decryptEnc1(String envelope, String keyHex) {
    final keyBytes = normalizeKeyHex(keyHex);
    if (keyBytes == null) return null;
    if (!envelope.startsWith('$enc1Tag$enc1Sep')) return null;

    try {
      final parts = envelope.split(enc1Sep);
      if (parts.length != 4) return null;
      final ivBytes = base64.decode(parts[1]);
      final tag = base64.decode(parts[2]);
      final ct = base64.decode(parts[3]);
      if (ivBytes.length != ivByteLength || tag.length != tagByteLength) return null;

      final encrypter = enc.Encrypter(enc.AES(enc.Key(keyBytes), mode: enc.AESMode.gcm));
      final plain = encrypter.decryptBytes(
        enc.Encrypted(Uint8List.fromList(<int>[...ct, ...tag])),
        iv: enc.IV(ivBytes),
      );
      return utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }

  /// SMTP DATA 的 dot-stuffing（RFC 5321 §4.5.2）：**行首** `.` 必须转义为 `..`，漏掉即正文被截断。
  /// 同时把任意换行统一为 CRLF，避免服务端按行处理时错位。
  static String dotStuff(String body) {
    final normalized = body.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    return normalized
        .split('\n')
        .map((line) => line.startsWith('.') ? '.$line' : line)
        .join('\r\n');
  }

  /// RFC 5322 日期（形如 `Tue, 21 Sep 2026 19:45:00 +0800`）
  static String formatRfc5322Date(DateTime dt, {Duration offset = const Duration(hours: 8)}) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final local = dt.toUtc().add(offset);
    final sign = offset.isNegative ? '-' : '+';
    final abs = offset.abs();
    final hh = abs.inHours.toString().padLeft(2, '0');
    final mm = (abs.inMinutes % 60).toString().padLeft(2, '0');
    return '${weekdays[local.weekday - 1]}, ${local.day.toString().padLeft(2, '0')} '
        '${months[local.month - 1]} ${local.year} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')} $sign$hh$mm';
  }

  /// 组装完整 RFC822 报文（含报头与已 dot-stuffing 的正文）
  static String buildMessage({
    required String from,
    required String to,
    required String subject,
    required String body,
    DateTime? date,
  }) {
    final when = date ?? DateTime.now();
    return 'From: $from\r\n'
        'To: $to\r\n'
        'Subject: $subject\r\n'
        'Date: ${formatRfc5322Date(when)}\r\n'
        'MIME-Version: 1.0\r\n'
        'Content-Type: text/plain; charset="UTF-8"\r\n'
        'Content-Transfer-Encoding: 8bit\r\n'
        '\r\n'
        '${dotStuff(body)}';
  }

  static final Random _csprng = Random.secure();

  /// 加密学安全随机字节源（dart:math 的 Random.secure()，底层为平台 CSPRNG）。
  /// GCM 的 IV 绝不可用普通伪随机源——IV 复用会直接导致密钥流复用。
  static int _secureRandomByte() => _csprng.nextInt(256);
}
