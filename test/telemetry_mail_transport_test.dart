import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bot_companion/services/telemetry_mail_transport.dart';

/// ============================================================================
/// WO-36 · SMTP 传输层单测（协议帧序列 / 多行响应 / 错误码 / 重试策略）
/// ============================================================================
/// 全部走零 IO 的 [SmtpSession] 状态机，**不连接任何真实邮箱、不发送任何真实邮件**（§5 红线）。
/// 唯一涉及 socket 的用例指向本机不可达端口（连接必然被拒），用于验证重试次数与退避策略。
void main() {
  SmtpSession buildSession() => SmtpSession(
        clientName: '2bot-companion',
        account: 'fixture@example.invalid',
        authCode: 'FIXTURE-CODE',
        from: 'fixture@example.invalid',
        to: 'fixture@example.invalid',
        message: 'HEADER\r\n\r\nBODY',
      );

  group('SMTP 协议帧序列', () {
    test('完整会话按 EHLO→AUTH LOGIN→MAIL FROM→RCPT TO→DATA→正文→QUIT 推进', () {
      final s = buildSession();
      final sent = <String>[];

      // 220 问候语
      sent.add(s.onResponseLine('220 smtp.qq.com ESMTP ready')!);
      // 250 多行 EHLO 响应（续行 `250-` 期间不得推进）
      expect(s.onResponseLine('250-smtp.qq.com'), isNull, reason: '多行续行不得推进状态机');
      expect(s.onResponseLine('250-AUTH LOGIN PLAIN'), isNull);
      sent.add(s.onResponseLine('250 SIZE 71680000')!);
      // AUTH LOGIN 交换
      sent.add(s.onResponseLine('334 VXNlcm5hbWU6')!);
      sent.add(s.onResponseLine('334 UGFzc3dvcmQ6')!);
      sent.add(s.onResponseLine('235 Authentication successful')!);
      sent.add(s.onResponseLine('250 OK')!);
      sent.add(s.onResponseLine('250 OK')!);
      sent.add(s.onResponseLine('354 End data with <CR><LF>.<CR><LF>')!);
      sent.add(s.onResponseLine('250 OK queued')!);
      // 221 终态：会话结束，状态机正确地返回 null（无后续命令）——不得用 `!`
      expect(s.onResponseLine('221 Bye'), isNull, reason: '221 终态后不应再产出命令');
      expect(s.done, isTrue);

      expect(sent[0], equals('EHLO 2bot-companion'));
      expect(sent[1], equals('AUTH LOGIN'));
      expect(sent[2], equals('Zml4dHVyZUBleGFtcGxlLmludmFsaWQ='), reason: '应为 base64 账号');
      // 授权码行：硬编码字面量易手打错（CI #29 即栽在 RUtD/RS1D 一个字符上），
      // 故既锁定字面量，又反向解码自校验 —— 双保险，任一侧错都爆红。
      expect(sent[3], equals('RklYVFVSRS1DT0RF'), reason: '应为 base64 授权码');
      expect(utf8.decode(base64.decode(sent[3])), equals('FIXTURE-CODE'), reason: 'base64 必须可还原回授权码原文');
      expect(sent[4], equals('MAIL FROM:<fixture@example.invalid>'));
      expect(sent[5], equals('RCPT TO:<fixture@example.invalid>'));
      expect(sent[6], equals('DATA'));
      expect(sent[7], equals('HEADER\r\n\r\nBODY\r\n.\r\n'), reason: '正文后必须追加 CRLF.CRLF 结束标记');
      expect(sent[8], equals('QUIT'));

      expect(s.done, isTrue);
      expect(s.failure, isNull);
    });

    test('响应码不符即判失败并终止', () {
      final s = buildSession();
      s.onResponseLine('220 ready');
      s.onResponseLine('250 ok');
      s.onResponseLine('334 VXNlcm5hbWU6');
      s.onResponseLine('334 UGFzc3dvcmQ6');
      final cmd = s.onResponseLine('535 Authentication failed');

      expect(cmd, isNull);
      expect(s.done, isTrue);
      expect(s.failure, contains('535'));
    });

    test('流水对待授权码做脱敏，绝不外泄明文口令', () {
      final s = buildSession();
      s.onResponseLine('220 ready');
      s.onResponseLine('250 ok');
      s.onResponseLine('334 VXNlcm5hbWU6');
      s.onResponseLine('334 UGFzc3dvcmQ6');

      expect(s.redactedTranscript.contains('FIXTURE-CODE'), isFalse);
      expect(s.transcript.contains('AUTH <redacted>'), isTrue);
    });
  });

  group('重试策略（§3.1 顺修「8s 一把过」缺陷）', () {
    test('单次 5s 超时、退避 1s/3s、三次皆败才记失败', () {
      expect(SmtpMailer.perAttemptTimeout, equals(const Duration(seconds: 5)));
      expect(
        SmtpMailer.retryBackoff,
        equals(const [Duration(seconds: 1), Duration(seconds: 3)]),
      );
    });

    test('不可达主机：重试耗尽后返回失败并给出尝试次数', () async {
      final result = await SmtpMailer.send(
        config: const MailAccountConfig(
          account: 'fixture@example.invalid',
          authCode: 'FIXTURE-CODE',
          smtpHost: '127.0.0.1',
          smtpPort: 1, // 本机保留端口，连接必被拒（非真实邮箱）
        ),
        subject: 'X-2BOT-TEL-1',
        body: 'ENC1:aa:bb:cc',
        connectTimeout: const Duration(milliseconds: 800),
        backoff: const [Duration.zero, Duration.zero], // 测试用零退避，仅验证次数
      );

      expect(result.success, isFalse);
      expect(result.attempts, equals(3), reason: '首次 + 重试 2 次 = 3 次尝试');
      expect(result.message, contains('已重试 2 次'));
    });
  });

  group('邮箱配置', () {
    test('收件地址留空时回落为发信账号（单邮箱自发自收）', () {
      const cfg = MailAccountConfig(account: 'a@example.invalid', authCode: 'x');
      expect(cfg.effectiveRecipient, equals('a@example.invalid'));
      const cfg2 = MailAccountConfig(account: 'a@example.invalid', authCode: 'x', recipient: '  ');
      expect(cfg2.effectiveRecipient, equals('a@example.invalid'));
      const cfg3 = MailAccountConfig(account: 'a@example.invalid', authCode: 'x', recipient: 'b@example.invalid');
      expect(cfg3.effectiveRecipient, equals('b@example.invalid'));
    });

    test('默认端点为中国区 QQ 邮箱隐式 TLS 465', () {
      const cfg = MailAccountConfig(account: 'a@example.invalid', authCode: 'x');
      expect(cfg.smtpHost, equals('smtp.qq.com'));
      expect(cfg.smtpPort, equals(465));
    });
  });
}
