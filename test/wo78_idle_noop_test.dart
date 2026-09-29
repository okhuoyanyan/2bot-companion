import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:bot_companion/services/imap_idle_client.dart';

/// WO-78-R3 返工 · IDLE 保活节拍终版（DONE→重发 IDLE→哨兵 -1，零 NOOP）
///
/// 真机归因实证（架构师实测 + 本机 logcat）：
/// ① QQ 对本连接的 IDLE 不推 EXISTS（出站后静默期零推送行）；
/// ② QQ 对「IDLE 后发 NOOP」一律立即断连（每次 NOOP 后 服务端关闭连接）；
/// 故终版节拍 = DONE → 直接重发 IDLE（RFC 2177 标准循环）→ 哨兵 -1，
/// 新件判定由上层走 UID 水位线（fetchNewSince）；重发失败/超时 = 死连，
/// 转 ImapClosedException 由上层即时重建（连接即查件）。

class _ScriptedImapServer {
  final ServerSocket socket;
  final StringBuffer received = StringBuffer();
  bool rejectIdleReissue = false; // 重发 IDLE 回 tagged NO
  bool swallowIdleReissue = false; // 死连：吞重发 IDLE 的 continuation
  bool _reissueSeen = false;
  String? _idleTag;

  _ScriptedImapServer._(this.socket);

  static Future<_ScriptedImapServer> bind() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final server = _ScriptedImapServer._(s);
    s.listen(server._onClient, onError: (_) {});
    return server;
  }

  void _onClient(Socket client) {
    client.write('* OK IMAP4rev1 Ready\r\n'); // IMAP 问候语（连接即发）
    final buf = <int>[];
    client.listen((data) {
      buf.addAll(data);
      while (true) {
        final idx = _crlfIndex(buf);
        if (idx < 0) break;
        final line = utf8.decode(buf.sublist(0, idx));
        buf.removeRange(0, idx + 2);
        received.writeln(line);
        _respond(client, line);
      }
    }, onDone: () => client.close(), onError: (_) {});
  }

  int _crlfIndex(List<int> b) {
    for (var i = 0; i + 1 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10) return i;
    }
    return -1;
  }

  void _respond(Socket client, String line) {
    if (line.contains(' LOGIN "')) {
      client.write('${line.split(' ').first} OK\r\n');
    } else if (line.contains(' SELECT INBOX')) {
      client.write('${line.split(' ').first} OK [READ-WRITE] done\r\n');
    } else if (line.endsWith(' IDLE')) {
      if (_reissueSeen) {
        // 重发轮
        if (swallowIdleReissue) return; // 死连：吞 continuation
        if (rejectIdleReissue) {
          client.write('${line.split(' ').first} NO\r\n');
          return;
        }
      }
      _reissueSeen = true;
      _idleTag = line.split(' ').first;
      client.write('+ idling\r\n');
    } else if (line == 'DONE') {
      client.write('${_idleTag ?? 'P0001'} OK\r\n');
    } else {
      client.write('${line.split(' ').first} OK\r\n');
    }
  }

  Future<void> close() => socket.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WO-78-R3 返工 · 保活节拍终版（零 NOOP）', () {
    test('哨兵：节拍到点 → DONE+重发 IDLE → 返回 -1 + 归因 NOOP查件', () async {
      final server = await _ScriptedImapServer.bind();
      ImapIdleClient.socketFactory =
          (host, port, timeout) => Socket.connect(host, port, timeout: timeout);
      try {
        final client = ImapIdleClient(
          config: ImapConfig(
              account: 'acct',
              authCode: 'code',
              host: '127.0.0.1',
              port: server.socket.port),
        );
        final hops = <String>[];
        client.onLifecycleLog = hops.add;
        await client.connect();
        expect(await client.startIdle(), isTrue);
        final n = await client.waitForEvent(
            beat: const Duration(seconds: 10),
            noopBeat: const Duration(milliseconds: 300));
        expect(n, -1, reason: '哨兵 -1：上层做 UID 水位线查件');
        expect(client.lastWakeReason, 'NOOP查件', reason: '归因可见');
        expect(hops.join('|'), contains('IDLE 挂载'), reason: '①建立可观测');
        expect(hops.join('|'), contains('保活节拍到点'), reason: '①节拍跳可观测');
        expect(hops.join('|'), contains('IDLE 重挂（NOOP 节拍循环）'),
            reason: '①重挂可观测');
        expect(server.received.toString(), isNot(contains(' NOOP')),
            reason: '实测 QQ 对 IDLE 后 NOOP 一律断连——节拍不得发 NOOP');
        expect(server.received.toString(), contains('DONE'));
        await client.close();
      } finally {
        ImapIdleClient.socketFactory = null;
        await server.close();
      }
    });

    test('重发被拒 → ImapClosedException（上层即时重建语义）', () async {
      final server = await _ScriptedImapServer.bind();
      server.rejectIdleReissue = true; // 重发 IDLE 回 tagged NO
      ImapIdleClient.socketFactory =
          (host, port, timeout) => Socket.connect(host, port, timeout: timeout);
      try {
        final client = ImapIdleClient(
          config: ImapConfig(
              account: 'acct',
              authCode: 'code',
              host: '127.0.0.1',
              port: server.socket.port),
        );
        final hops = <String>[];
        client.onLifecycleLog = hops.add;
        await client.connect();
        expect(await client.startIdle(), isTrue);
        Object? caught;
        try {
          await client.waitForEvent(
              beat: const Duration(seconds: 10),
              noopBeat: const Duration(milliseconds: 300));
        } catch (e) {
          caught = e;
        }
        expect(caught, isA<ImapClosedException>(),
            reason: '重发被拒=连接不可用语义 → 上层即时重建');
        expect(hops.join('|'), contains('重发 IDLE 被拒 → 重建会话'));
        await client.close();
      } finally {
        ImapIdleClient.socketFactory = null;
        await server.close();
      }
    });

    test('死连：重发 IDLE 无响应 → 10s 超时转断连语义（聋态从 25 分钟压到 ≤节拍+10s）',
        () async {
      final server = await _ScriptedImapServer.bind();
      server.swallowIdleReissue = true; // 吞重发 IDLE 的 continuation
      ImapIdleClient.socketFactory =
          (host, port, timeout) => Socket.connect(host, port, timeout: timeout);
      try {
        final client = ImapIdleClient(
          config: ImapConfig(
              account: 'acct',
              authCode: 'code',
              host: '127.0.0.1',
              port: server.socket.port),
        );
        final hops = <String>[];
        client.onLifecycleLog = hops.add;
        await client.connect();
        expect(await client.startIdle(), isTrue);
        final sw = Stopwatch()..start();
        Object? caught;
        try {
          await client.waitForEvent(
              beat: const Duration(minutes: 25),
              noopBeat: const Duration(milliseconds: 300));
        } catch (e) {
          caught = e;
        }
        sw.stop();
        expect(caught, isA<ImapClosedException>(),
            reason: '死连（重发 IDLE 超时）必须转断连语义即时暴露，而非聋等 25 分钟');
        expect(sw.elapsed.inSeconds, lessThan(15),
            reason: '重挂超时 10s → 抛出点 ≤15s（对比改前最坏 25 分钟）');
        expect(hops.join('|'), contains('保活节拍到点'));
        await client.close();
      } finally {
        ImapIdleClient.socketFactory = null;
        await server.close();
      }
    }, timeout: const Timeout(Duration(seconds: 40)));
  });
}
