import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:bot_companion/services/imap_idle_client.dart';

/// WO-78 缺陷② · IDLE NOOP 保活节拍（死连检测 + 积压 EXISTS 顺路带回）
///
/// 断言现状对照（改前 b05c418）：waitForEvent 只有 25 分钟节拍——静默死连
/// （NAT 掉线/无线休眠，无 FIN）期间客户端最坏聋 25 分钟（管理员实测
/// 「3 分钟不合格」即此形态家族）。本组用本地 TCP 脚本服务器驱动全链：
/// NOOP 节拍到点 → DONE → NOOP（响应夹带积压 EXISTS → 立即返回）→ 重发 IDLE；
/// 死连形态：服务器吞掉 NOOP 不回 → 客户端 10s 超时抛出（不再聋等 25 分钟）。

class _ScriptedImapServer {
  final ServerSocket socket;
  final StringBuffer received = StringBuffer();
  bool swallowNoop = false;
  int _existsDuringNoop = 0;
  String? _idleTag;

  _ScriptedImapServer._(this.socket);

  static Future<_ScriptedImapServer> bind() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final server = _ScriptedImapServer._(s);
    s.listen(server._onClient, onError: (_) {});
    return server;
  }

  void setExistsDuringNoop(int n) => _existsDuringNoop = n;

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
      _idleTag = line.split(' ').first;
      client.write('+ idling\r\n');
    } else if (line == 'DONE') {
      client.write('${_idleTag ?? 'P0001'} OK\r\n');
    } else if (line.endsWith(' NOOP')) {
      if (swallowNoop) return; // 死连形态：吞掉不回
      if (_existsDuringNoop > 0) {
        client.write('* $_existsDuringNoop EXISTS\r\n');
      }
      client.write('${line.split(' ').first} OK\r\n');
    } else {
      client.write('${line.split(' ').first} OK\r\n');
    }
  }

  Future<void> close() => socket.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WO-78 缺陷② · IDLE NOOP 保活节拍（本地 TCP 全链）', () {
    test('NOOP 节拍到点：DONE→NOOP 带回积压 EXISTS→重发 IDLE，推送不漏', () async {
      final server = await _ScriptedImapServer.bind();
      server.setExistsDuringNoop(7); // 积压 EXISTS 只在 NOOP 响应里出现
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
        await client.connect();
        expect(await client.startIdle(), isTrue);

        final sw = Stopwatch()..start();
        // beat 给足 10s（不应触发）；noopBeat 300ms——积压 EXISTS 必须经 NOOP 带回
        final n = await client.waitForEvent(
            beat: const Duration(seconds: 10),
            noopBeat: const Duration(milliseconds: 300));
        sw.stop();

        expect(n, 7, reason: 'NOOP 响应夹带的积压 EXISTS 必须立即返回（不漏推送）');
        expect(sw.elapsed.inSeconds, lessThan(8), reason: '不应等到 25 分钟/beat 节拍');
        expect(server.received.toString(), contains('NOOP'));
        expect(server.received.toString(), contains('DONE'));
        await client.close();
      } finally {
        ImapIdleClient.socketFactory = null;
        await server.close();
      }
    });

    test('死连形态：NOOP 被吞 → 10s 超时抛出（聋态从 25 分钟压到 ≤noopBeat+10s）',
        () async {
      final server = await _ScriptedImapServer.bind();
      server.swallowNoop = true; // 吞 NOOP：模拟静默死连
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
        expect(caught, isNotNull, reason: '死连必须在 NOOP 超时处暴露，而非聋等 25 分钟');
        expect(sw.elapsed.inSeconds, lessThan(15),
            reason: 'noop 超时 10s → 抛出点 ≤15s（对比改前最坏 25 分钟）');
        await client.close();
      } finally {
        ImapIdleClient.socketFactory = null;
        await server.close();
      }
    }, timeout: const Timeout(Duration(seconds: 40)));
  });
}
