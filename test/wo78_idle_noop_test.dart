import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:bot_companion/services/imap_idle_client.dart';

/// WO-82-R3 · 纯长持 IDLE（G3 时序铁律）· 10s NOOP 高频拍退役
///
/// 管理员裁决 2026-09-30：10s 拍退役、90s 兜底地板；主路径 = 长持 IDLE 推送。
/// 历史归因改判：「连接每拍被服务端关闭」的真因是旧循环在【挂载态】发
/// SELECT/SEARCH（协议违规 → BAD 断连），非 DONE 本身。
/// G3 铁律：收到 `* n EXISTS` 后 —— ①读信号 → ②发 DONE → ③等
/// `tag OK IDLE completed` → ④UID SEARCH/FETCH → ⑤重发 IDLE。
/// 本套件钉死：waitForEvent 两种返回都【保持挂载态】（挂载期零命令写出），
/// UID SEARCH 必须出现在 DONE 之后；死连由 stopIdle 超时暴露为断连语义。

class _ScriptedImapServer {
  final ServerSocket socket;
  final StringBuffer received = StringBuffer();
  bool pushExistsAfterIdle = false; // 挂载后 ~100ms 推送 `* 5 EXISTS`
  bool swallowDone = false; // 死连：吞 DONE 的 tagged OK
  final List<Socket> _clients = <Socket>[];
  Timer? _pushTimer;
  String? _idleTag;

  _ScriptedImapServer._(this.socket);

  static Future<_ScriptedImapServer> bind() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final server = _ScriptedImapServer._(s);
    s.listen(server._onClient, onError: (_) {});
    return server;
  }

  void _onClient(Socket client) {
    _clients.add(client);
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
      if (pushExistsAfterIdle) {
        _pushTimer = Timer(const Duration(milliseconds: 100), () {
          for (final c in _clients) {
            c.write('* 5 EXISTS\r\n');
          }
        });
      }
    } else if (line == 'DONE') {
      if (swallowDone) return; // 死连：吞响应
      client.write('${_idleTag ?? 'P0001'} OK\r\n');
    } else {
      client.write('${line.split(' ').first} OK\r\n');
    }
  }

  Future<void> close() async {
    _pushTimer?.cancel();
    await socket.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WO-82-R3 · 纯长持 IDLE（G3 时序铁律）', () {
    test('推送主路径：挂载期收到 EXISTS → 返回 n>0，挂载期零命令写出', () async {
      final server = await _ScriptedImapServer.bind();
      server.pushExistsAfterIdle = true;
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
        final mountedAt = server.received.toString();
        final n = await client.waitForEvent(beat: const Duration(seconds: 10));
        expect(n, 5, reason: 'EXISTS 推送原样上抛（非 -1 哨兵）');
        expect(client.lastWakeReason, 'IDLE推送', reason: '归因可见');
        // G3：从挂载到 EXISTS 返回，客户端未发任何命令（挂载态保持）
        expect(server.received.toString(), mountedAt,
            reason: '挂载期零命令写出（不发 DONE/NOOP/SELECT）');
        expect(hops.join('|'), contains('IDLE 挂载'));
        expect(hops.join('|'), contains('IDLE 推送 EXISTS=5'));
        await client.close();
      } finally {
        ImapIdleClient.socketFactory = null;
        await server.close();
      }
    });

    test('G3 时序：EXISTS 返回后先 DONE（等 tag OK）→ UID SEARCH 在 DONE 之后',
        () async {
      final server = await _ScriptedImapServer.bind();
      server.pushExistsAfterIdle = true;
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
        expect(await client.waitForEvent(beat: const Duration(seconds: 10)), 5);

        // 🔴 挂载态返回点：此刻严禁已发出 UID SEARCH（G3 第④步的前置）
        expect(server.received.toString(), isNot(contains('UID SEARCH')),
            reason: '挂载态直接 UID SEARCH = 协议违规（BAD 断连）');

        // ②③ DONE → tag OK（stopIdle 内部等待 tagged 完成响应）
        await client.stopIdle();
        // ④ 之后才允许查件
        await client.fetchNewSince(0);

        final transcript = server.received.toString();
        final doneIdx = transcript.indexOf('DONE');
        final searchIdx = transcript.indexOf('UID SEARCH');
        expect(doneIdx, greaterThanOrEqualTo(0));
        expect(searchIdx, greaterThan(doneIdx),
            reason: 'G3：UID SEARCH 必须在 DONE 且 tag OK 之后（时序单点化）');
        await client.close();
      } finally {
        ImapIdleClient.socketFactory = null;
        await server.close();
      }
    });

    test('90s 兜底节拍：到点返回 null（挂载保持，无 DONE）+ 归因 兜底查件', () async {
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
        final mountedAt = server.received.toString();
        final sw = Stopwatch()..start();
        final n = await client.waitForEvent(beat: const Duration(milliseconds: 300));
        sw.stop();
        expect(n, isNull, reason: '节拍到点返回 null（旧版哨兵 -1 已退役）');
        expect(client.lastWakeReason, '兜底查件');
        expect(server.received.toString(), mountedAt,
            reason: '节拍返回时挂载保持——DONE 由调用方统一发起（G3 时序单点化）');
        expect(sw.elapsed.inMilliseconds, lessThan(5000));
        expect(server.received.toString(), isNot(contains(' NOOP')),
            reason: 'NOOP 已随 10s 拍一并退役');
        await client.close();
      } finally {
        ImapIdleClient.socketFactory = null;
        await server.close();
      }
    });

    test('死连：DONE 无响应 → stopIdle 抛 ImapClosedException（≤15s 暴露，即时重建语义）',
        () async {
      final server = await _ScriptedImapServer.bind();
      server.swallowDone = true; // 吞 DONE 的 tagged OK
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
        expect(await client.waitForEvent(beat: const Duration(milliseconds: 300)),
            isNull);
        final sw = Stopwatch()..start();
        Object? caught;
        try {
          await client.stopIdle();
        } catch (e) {
          caught = e;
        }
        sw.stop();
        expect(caught, isA<ImapClosedException>(),
            reason: 'DONE 无响应 = 死连 → 断连语义（上层即时重建），而非通用退避');
        expect(sw.elapsed.inSeconds, lessThan(15),
            reason: 'stopIdle 10s 超时 → 暴露点 ≤15s');
        await client.close();
      } finally {
        ImapIdleClient.socketFactory = null;
        await server.close();
      }
    }, timeout: const Timeout(Duration(seconds: 40)));
  });
}
