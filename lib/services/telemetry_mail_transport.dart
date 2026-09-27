import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'cross_isolate_lock.dart';
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

  /// WO-69 追补：服务端明确限流（QQ 535 等）——调度层据此进入有界冷却
  final bool rateLimited;

  MailSendResult({
    required this.success,
    required this.message,
    required this.attempts,
    this.rateLimited = false,
  });
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

  /// WO-69 追补整改：正文（DATA 载荷）是否已送出。
  /// 一旦送出，投递结果即「不确定但不可重试」——服务端可能已入队；
  /// 重试同一 payload = 重复投递（触发 QQ 535 限流的直接来源，架构师 2026-09-27 急件）。
  bool messageTransmitted = false;

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
        messageTransmitted = true; // 正文出网即不可重试（WO-69 追补：防同 payload 重复投递）
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

  /// WO-69 追补：两次 SMTP 会话的最小间隔（同秒连发是 535 的直接触发器）。
  /// 仅约束**本 isolate**；跨 isolate 由调度层载荷去重兜底。
  static const Duration minSessionGap = Duration(seconds: 3);

  /// 限流特征（QQ 535 文案多变，按码与关键词双判）
  static final RegExp _rateLimitPattern =
      RegExp(r'\b535\b|too many|frequently|frequency|limit', caseSensitive: false);

  // 测试注入钩子（生产零改动）
  static DateTime Function() nowProvider = DateTime.now;
  static Future<void> Function(Duration) delayProvider = Future<void>.delayed;
  @visibleForTesting
  static Future<Socket> Function(String host, int port, Duration timeout)?
      socketFactoryForTest;

  static DateTime? _lastAttemptAt;

  /// 测试辅助：清空发送节流状态（仅测试使用）
  @visibleForTesting
  static void resetForTest() {
    _lastAttemptAt = null;
  }

  /// 发送一封邮件。
  ///
  /// WO-69 追补整改（架构师急件 2026-09-27）重试纪律：
  ///  1. 正文送出后（[SmtpSession.messageTransmitted]）任何失败一律**不重试**——
  ///     服务端可能已入队，重试同一 payload = 重复投递；按成功返回（宁可少确认不可重发）；
  ///  2. 服务端限流（535 等）→ 标记 [MailSendResult.rateLimited]，调度层冷却；
  ///  3. 两次会话强制 ≥ [minSessionGap]（有界），杜绝同秒并发会话。
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

    // 最小会话间隔（有界等待，防同秒连发）
    final last = _lastAttemptAt;
    if (last != null) {
      final since = nowProvider().difference(last);
      if (since < minSessionGap) {
        await delayProvider(minSessionGap - since);
      }
    }
    // 跨 isolate 同秒闸（第三轮 P2，架构师裁定）：原 SharedPreferencesAsync
    // 「读-判断-写」非原子（TOCTOU）——双 isolate 同读旧值 → 同秒双会话。
    // 现改 OS 级文件锁：持锁者完成「读戳-等待-盖新戳」全程，后到者在锁上
    // 排队 → 会话严格串行，事件不丢。时间戳存锁旁的 .stamp 文件
    // （纯文件 IO，任何 isolate 可用，不依赖平台通道）。
    await crossIsolateSynchronized('smtp-gate', () async {
      try {
        final stamp = _smtpGateStampFile();
        int? lastMs;
        try {
          lastMs = int.tryParse(await stamp.readAsString());
        } catch (_) {}
        if (lastMs != null) {
          final since = nowProvider()
              .difference(DateTime.fromMillisecondsSinceEpoch(lastMs));
          if (!since.isNegative && since < minSessionGap) {
            // 持锁等待：其它 isolate 在锁上排队，串行语义由此保证
            await delayProvider(minSessionGap - since);
          }
        }
        await stamp.writeAsString(
            '${nowProvider().millisecondsSinceEpoch}', flush: true);
      } catch (_) {
        // 锁/文件不可用 → 退化为本 isolate 静态闸
      }
    });

    final totalAttempts = backoff.length + 1;
    String lastError = '未知错误';
    bool lastRateLimited = false;

    for (var attempt = 1; attempt <= totalAttempts; attempt++) {
      final session = SmtpSession(
        clientName: '2bot-companion',
        account: config.account,
        authCode: config.authCode,
        from: config.account,
        to: config.effectiveRecipient,
        message: message,
      );
      try {
        await _sendOnce(config: config, session: session, timeout: connectTimeout);
        return MailSendResult(
          success: true,
          message: '邮箱上报成功 (SMTP ${config.smtpHost}:${config.smtpPort})',
          attempts: attempt,
        );
      } catch (e) {
        lastError = e.toString();
        lastRateLimited = _rateLimitPattern.hasMatch(lastError);
        // 正文已出网：结果不可判定 → 严禁重试（重发同 payload 触发 535）。
        // 按成功返回让调度层推进水位（NAS 以最新快照为准，确认丢失无害）。
        final resolved = resolveSendFailure(session, lastError, attempt, lastRateLimited);
        if (resolved != null) return resolved;
        if (attempt <= backoff.length) {
          await delayProvider(backoff[attempt - 1]);
          await _touchLastSmtpAttempt();
        }
      }
    }

    return MailSendResult(
      success: false,
      message: '邮箱上报失败（已重试 ${totalAttempts - 1} 次）: $lastError',
      attempts: totalAttempts,
      rateLimited: lastRateLimited,
    );
  }

  /// WO-69 追补②：失败处置决策（纯函数，单测覆盖）。
  /// 返回 null = 允许重试；非 null = 终止重试并按该结果返回。
  @visibleForTesting
  static MailSendResult? resolveSendFailure(
      SmtpSession session, String error, int attempt, bool rateLimited) {
    if (session.messageTransmitted) {
      return MailSendResult(
        success: true,
        message: '邮箱上报已投递（DATA 后响应未确认，防重复投递不重试）：$error',
        attempts: attempt,
        rateLimited: rateLimited,
      );
    }
    return null;
  }

  /// 统一刷新「最近 SMTP 会话时刻」（本 isolate 静态 + 跨 isolate 盖章文件）
  static Future<void> _touchLastSmtpAttempt() async {
    _lastAttemptAt = nowProvider();
    try {
      await _smtpGateStampFile()
          .writeAsString('${_lastAttemptAt!.millisecondsSinceEpoch}', flush: true);
    } catch (_) {}
  }

  static File _smtpGateStampFile() {
    final dir = lockDirOverride ?? Directory.systemTemp.path;
    return File('$dir/wo69_smtp-gate.stamp');
  }

  static Future<void> _sendOnce({
    required MailAccountConfig config,
    required SmtpSession session,
    required Duration timeout,
  }) async {
    final socket = await (socketFactoryForTest != null
        ? socketFactoryForTest!(config.smtpHost, config.smtpPort, timeout)
        : SecureSocket.connect(config.smtpHost, config.smtpPort, timeout: timeout)
            .timeout(timeout));

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
