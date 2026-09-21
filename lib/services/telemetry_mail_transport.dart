import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'telemetry_mail_protocol.dart';

/// ============================================================================
/// WO-36 · SMTP over SSL 发信通道（QQ 邮箱 smtp.qq.com:465 隐式 TLS）
/// ============================================================================
/// 设计要点：
///  1. 协议对话抽成**纯状态机** [SmtpSession]（零 IO），单测可逐行喂响应验证命令序列与
///     dot-stuffing，无需真连邮箱；
///  2. 重试修复（顺修今晚「8s 一把过」缺陷）：单次 5s 超时，失败退避重试 2 次（1s / 3s），
///     三次皆败才记失败；成功即返回；
///  3. 加密失败 = 本封放弃（禁明文降级），由 [MailProtocol.encryptEnc1] 返回 null 表达。
class MailSendResult {
  final bool success;
  final String message;
  final int attempts;

  MailSendResult({required this.success, required this.message, required this.attempts});
}

/// 邮箱模式的连接与凭据参数（凭据来自 flutter_secure_storage，绝不落明文 SharedPreferences）
class MailAccountConfig {
  final String account;
  final String authCode;
  final String recipient;
  final String smtpHost;
  final int smtpPort;

  const MailAccountConfig({
    required this.account,
    required this.authCode,
    String? recipient,
    this.smtpHost = 'smtp.qq.com',
    this.smtpPort = 465,
  }) : recipient = recipient ?? '';

  String get effectiveRecipient => recipient.trim().isEmpty ? account : recipient.trim();
}

/// ---------------------------------------------------------------------------
/// SMTP 会话状态机（零 IO，纯函数式推进）
/// ---------------------------------------------------------------------------
/// 用法：构造 → 每收到一行服务端响应调用 [onResponseLine] → 返回下一条要发送的命令
/// （null 表示「继续等下一行」或「已结束」）。响应码不符即置 [failed]。
class SmtpSession {
  SmtpSession({
    required this.clientName,
    required this.account,
    required this.authCode,
    required this.from,
    required this.to,
    required this.message,
  });

  final String clientName;
  final String account;
  final String authCode;
  final String from;
  final String to;
  final String message;

  /// 已发出的完整命令流水（测试与排障审计用；**绝不包含 AUTH 之后的明文口令**）
  final List<String> transcript = <String>[];

  bool done = false;
  String? failure;

  int _step = 0;
  int _expected = 220;

  /// 喂入一行服务端响应，返回应发送的下一条命令；null = 继续等待 / 已终止
  String? onResponseLine(String line) {
    if (done) return null;
    if (line.length < 4) return null;

    final code = int.tryParse(line.substring(0, 3));
    if (code == null) return null;
    // `NNN-` 为多行响应续行（EHLO 的 250- 列表），必须等到 `NNN ` 终行才推进
    if (line[3] == '-') return null;

    if (code != _expected) {
      failure = 'SMTP 阶段 ${_step + 1} 期望响应码 $_expected，实际收到 $code';
      done = true;
      return null;
    }

    return _advance();
  }

  String? _advance() {
    switch (_step) {
      case 0: // 220 问候语 → EHLO
        _step = 1;
        _expected = 250;
        return _emit('EHLO $clientName');
      case 1: // 250 EHLO → AUTH LOGIN
        _step = 2;
        _expected = 334;
        return _emit('AUTH LOGIN');
      case 2: // 334 → base64(账号)
        _step = 3;
        _expected = 334;
        return _emit(base64.encode(utf8.encode(account)));
      case 3: // 334 → base64(授权码)
        _step = 4;
        _expected = 235;
        // 口令行同样进入流水，但落盘/上报前由调用方经 redactAuthCode 处理；此处仅记录占位
        transcript.add('AUTH <redacted>');
        return base64.encode(utf8.encode(authCode));
      case 4: // 235 认证成功 → MAIL FROM
        _step = 5;
        _expected = 250;
        return _emit('MAIL FROM:<$from>');
      case 5: // 250 → RCPT TO
        _step = 6;
        _expected = 250;
        return _emit('RCPT TO:<$to>');
      case 6: // 250 → DATA
        _step = 7;
        _expected = 354;
        return _emit('DATA');
      case 7: // 354 → 正文 + 结束标记
        _step = 8;
        _expected = 250;
        transcript.add('<message body ${message.length} chars>');
        return '$message\r\n.\r\n';
      case 8: // 250 → QUIT
        _step = 9;
        _expected = 221;
        return _emit('QUIT');
      default: // 221 → 会话结束
        done = true;
        return null;
    }
  }

  String _emit(String command) {
    transcript.add(command);
    return command;
  }

  /// 把流水中的凭据痕迹擦除（用于任何对外输出）
  String get redactedTranscript =>
      transcript.map((l) => l == 'AUTH <redacted>' ? l : l.replaceAll(authCode, '<redacted>')).join('\n');
}

/// ---------------------------------------------------------------------------
/// SMTP 发信器：把状态机驱动到 SecureSocket 上，含重试
/// ---------------------------------------------------------------------------
class SmtpMailer {
  /// 单次尝试超时（§3.1：单次 5s 超时）
  static const Duration perAttemptTimeout = Duration(seconds: 5);
  /// 退避节奏（§3.1：失败退避重试 2 次，1s / 3s，三次皆败才记失败）
  static const List<Duration> retryBackoff = <Duration>[Duration(seconds: 1), Duration(seconds: 3)];

  /// 发送一封邮件；任何一次尝试成功即返回。
  static Future<MailSendResult> send({
    required MailAccountConfig config,
    required String subject,
    required String body,
    Duration connectTimeout = perAttemptTimeout,
    List<Duration> backoff = retryBackoff,
  }) async {
    final message = MailProtocol.buildMessage(
      from: config.account,
      to: config.effectiveRecipient,
      subject: subject,
      body: body,
    );

    final totalAttempts = backoff.length + 1;
    String lastError = '未知错误';

    for (var attempt = 1; attempt <= totalAttempts; attempt++) {
      try {
        await _sendOnce(config: config, message: message, timeout: connectTimeout);
        return MailSendResult(
          success: true,
          message: '邮箱上报成功 (SMTP ${config.smtpHost}:${config.smtpPort})',
          attempts: attempt,
        );
      } catch (e) {
        lastError = e.toString();
        if (attempt <= backoff.length) {
          await Future<void>.delayed(backoff[attempt - 1]);
        }
      }
    }

    return MailSendResult(
      success: false,
      message: '邮箱上报失败（已重试 ${totalAttempts - 1} 次）: $lastError',
      attempts: totalAttempts,
    );
  }

  static Future<void> _sendOnce({
    required MailAccountConfig config,
    required String message,
    required Duration timeout,
  }) async {
    final session = SmtpSession(
      clientName: '2bot-companion',
      account: config.account,
      authCode: config.authCode,
      from: config.account,
      to: config.effectiveRecipient,
      message: message,
    );

    final socket = await SecureSocket.connect(
      config.smtpHost,
      config.smtpPort,
      timeout: timeout,
    ).timeout(timeout);

    final iterator = StreamIterator<String>(
      // cast 必要：SecureSocket 是 Stream<Uint8List>，而 utf8.decoder 是
      // StreamTransformer<List<int>, String>，因逆变不可直接赋给 StreamTransformer<Uint8List, _>。
      socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()),
    );

    try {
      while (!session.done) {
        if (!await iterator.moveNext().timeout(timeout)) {
          throw StateError('SMTP 连接被服务端提前关闭');
        }
        final command = session.onResponseLine(iterator.current);
        if (session.failure != null) {
          throw StateError(session.failure!);
        }
        if (command != null) {
          socket.write('$command\r\n');
          await socket.flush().timeout(timeout);
        }
      }
      if (session.failure != null) throw StateError(session.failure!);
    } finally {
      await iterator.cancel();
      try {
        await socket.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
      socket.destroy();
    }
  }
}
