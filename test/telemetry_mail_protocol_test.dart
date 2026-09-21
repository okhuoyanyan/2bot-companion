import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bot_companion/services/telemetry_mail_protocol.dart';

/// ============================================================================
/// WO-36 · 协议层单测（ENC1 跨语言 KAT / 信封往返 / dot-stuffing / 报文组装）
/// ============================================================================
/// **KAT 向量来源**：由 NAS 侧 Node 实现（plugins/core/telemetry-mail/payload.mjs，
/// 已在 WO-36 第 23 套件断言 1/2 覆盖）以固定 key+iv 生成并经本地回解验证。
/// 本测试断言 Dart 端产出**逐字节相同**的信封 —— 这是双端互操作的唯一硬保证：
/// 任一端的 iv/tag 布局、字段序、base64 口径偏移，都会在此直接爆红。
void main() {
  // ---- 跨语言 KAT 固定向量 ----------------------------------------------
  const katKeyHex = '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
  const katIvB64 = 'Dw4NDAsKCQgHBgUE';
  const katPlain =
      '{"timestamp":1789989045827,"foregroundApp":"2bot-companion","battery":{"level":44}}';
  const katEnvelope =
      'ENC1:Dw4NDAsKCQgHBgUE:tQW09kTrlwGasKsDqZkhPw==:3xLFNTay3NqKssF9Aqu+OVBfJ1n/bcRcZH6C3VRlwk9j+Kw1RS06/lCXFs+hbkdxOmOaPBjcMIKbMmTaURUk/sZSNXBDY9GVOX5O0DwKToXnTzA=';

  group('ENC1 加密信封', () {
    test('跨语言 KAT：固定 key+iv 下与 NAS 端产出逐字节一致', () {
      final envelope = MailProtocol.encryptEnc1(
        katPlain,
        katKeyHex,
        ivOverride: base64.decode(katIvB64),
      );
      expect(envelope, isNotNull);
      expect(envelope, equals(katEnvelope));
    });

    test('解密 NAS 端产出的信封（反向互操作）', () {
      expect(MailProtocol.decryptEnc1(katEnvelope, katKeyHex), equals(katPlain));
    });

    test('信封结构符合 §1 冻结格式：4 段 / iv 12B / tag 16B / 无空格分隔', () {
      final envelope = MailProtocol.encryptEnc1(katPlain, katKeyHex)!;
      final parts = envelope.split(':');
      expect(parts.length, equals(4));
      expect(parts[0], equals('ENC1'));
      expect(base64.decode(parts[1]).length, equals(12));
      expect(base64.decode(parts[2]).length, equals(16));
      expect(envelope.contains(': '), isFalse);
    });

    test('往返无损（含中文与 emoji 的 UTF-8 载荷）', () {
      const plain = '{"wifi":{"ssid":"RainLain_5G"},"foregroundApp":"哔哩哔哩 🎬"}';
      final envelope = MailProtocol.encryptEnc1(plain, katKeyHex)!;
      expect(MailProtocol.decryptEnc1(envelope, katKeyHex), equals(plain));
    });

    test('每封 iv 随机（GCM 下 iv 复用即密钥流复用）', () {
      final a = MailProtocol.encryptEnc1(katPlain, katKeyHex);
      final b = MailProtocol.encryptEnc1(katPlain, katKeyHex);
      expect(a, isNot(equals(b)));
    });
  });

  group('坏件拒绝（§1 禁明文降级）', () {
    test('非法密钥一律返回 null，绝不产出密文', () {
      expect(MailProtocol.encryptEnc1('x', 'tooshort'), isNull);
      expect(MailProtocol.encryptEnc1('x', 'z' * 64), isNull, reason: '非 hex 字符必须拒绝');
      expect(MailProtocol.encryptEnc1('x', ''), isNull);
      expect(MailProtocol.normalizeKeyHex(katKeyHex)!.length, equals(32));
    });

    test('错钥 / 结构异常 / 非 ENC1 一律解密失败', () {
      final wrongKey = 'f' * 64;
      expect(MailProtocol.decryptEnc1(katEnvelope, wrongKey), isNull, reason: 'GCM 认证必须失败');
      expect(MailProtocol.decryptEnc1('ENC1:AAAA:BBBB', katKeyHex), isNull, reason: '段数不足');
      expect(MailProtocol.decryptEnc1('明文不是信封', katKeyHex), isNull);
      expect(MailProtocol.decryptEnc1(katEnvelope, 'badkey'), isNull);
    });
  });

  group('SMTP dot-stuffing（RFC 5321 §4.5.2）', () {
    test('行首句点必须转义为双点', () {
      expect(MailProtocol.dotStuff('.hidden'), equals('..hidden'));
      expect(MailProtocol.dotStuff('..already'), equals('...already'));
      expect(MailProtocol.dotStuff('a\n.b\nc'), equals('a\r\n..b\r\nc'));
    });

    test('单独一行的句点（正文结束标记）必须被转义，否则正文被截断', () {
      expect(MailProtocol.dotStuff('line1\n.\nline2'), equals('line1\r\n..\r\nline2'));
    });

    test('换行统一为 CRLF 且不动行内句点', () {
      expect(MailProtocol.dotStuff('a\r\nb\nc\rd'), equals('a\r\nb\r\nc\r\nd'));
      expect(MailProtocol.dotStuff('a.b.c'), equals('a.b.c'));
      expect(MailProtocol.dotStuff(''), equals(''));
    });
  });

  group('主题与报文组装', () {
    test('主题形如 {prefix}-{毫秒时间戳}', () {
      expect(MailProtocol.buildSubject(1789989045827), equals('X-2BOT-TEL-1789989045827'));
      expect(MailProtocol.buildSubject(1, prefix: 'CUSTOM'), equals('CUSTOM-1'));
      expect(MailProtocol.defaultSubjectPrefix, equals('X-2BOT-TEL'));
    });

    test('RFC 5322 日期格式正确', () {
      final d = DateTime.utc(2026, 9, 21, 11, 45, 0);
      expect(
        MailProtocol.formatRfc5322Date(d),
        equals('Mon, 21 Sep 2026 19:45:00 +0800'),
      );
    });

    test('报文含必需报头、空行分隔，正文已 dot-stuffing', () {
      final msg = MailProtocol.buildMessage(
        from: 'a@example.invalid',
        to: 'a@example.invalid',
        subject: 'X-2BOT-TEL-1',
        body: '.start',
        date: DateTime.utc(2026, 9, 21, 11, 45, 0),
      );
      expect(msg, contains('Subject: X-2BOT-TEL-1\r\n'));
      expect(msg, contains('Content-Type: text/plain; charset="UTF-8"\r\n'));
      expect(msg, contains('Content-Transfer-Encoding: 8bit\r\n'));
      expect(msg, contains('\r\n\r\n..start'), reason: '正文行首句点必须已转义');
    });
  });
}
