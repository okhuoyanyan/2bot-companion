import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bot_companion/services/calendar_event_store.dart';
import 'package:bot_companion/services/cross_isolate_lock.dart';
import 'package:bot_companion/services/local_caldav_server.dart';

/// ============================================================================
/// WO-70 · 本机只读服务单测（事件模型 + HTTP 路由矩阵 + 只读契约）
/// ============================================================================
/// 服务器绑 127.0.0.1 随机端口。HTTP 客户端用【原始 socket】——
/// flutter_test 的 binding 会把 HttpClient 替换成一律 400 的假客户端
///（请求字节根本不出进程，_binding_io.dart setupHttpOverrides），raw socket
/// 是唯一不被污染的通道（字节级断言，更严格）。
const crlf = '\r\n';

CalendarEventStore buildStore() => CalendarEventStore()
  ..applyUpserts([
    {
      'uid': 'cal_1',
      'sequence': 0,
      'lastModifiedMs': 1727000000000,
      'dtstartMs': 1727100000000,
      'allDay': false,
      'endMs': 1727103600000,
      'summary': '体检, 复诊',
      'description': '带报告',
    },
    {
      'uid': 'cal_2',
      'sequence': 1,
      'lastModifiedMs': 1727000001000,
      'dtstartMs': 1727200000000,
      'allDay': true,
      'endMs': 1727286400000,
      'summary': '全天日程',
    },
  ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('事件模型', () {
    test('upsert / CANCELLED 墓碑 / 同 UID 复活', () {
      final store = buildStore();
      expect(store.events.length, 2);

      final r1 = store.applyUpserts([
        {'uid': 'cal_1', 'cancelled': true, 'lastModifiedMs': 1727111111111},
      ]);
      expect(r1.removed, 1);
      expect(store.events.containsKey('cal_1'), isFalse);
      expect(store.tombstones['cal_1'], 1727111111111);

      store.applyUpserts([
        {
          'uid': 'cal_1',
          'sequence': 2,
          'dtstartMs': 1727100000000,
          'allDay': false,
        },
      ]);
      expect(store.events.containsKey('cal_1'), isTrue);
      expect(store.tombstones.containsKey('cal_1'), isFalse);
    });

    test('ctag/sync-token 随内容变化（#54 同源教训）', () {
      final store = buildStore();
      final c0 = store.ctag;
      store.applyUpserts([
        {
          'uid': 'cal_3',
          'sequence': 0,
          'dtstartMs': 1727300000000,
          'allDay': false,
        },
      ]);
      expect(store.ctag, isNot(c0), reason: '内容变化 → ctag 必跃迁');
      expect(store.syncToken, startsWith('data:,'));
    });

    test('renderFullIcs：VCALENDAR + VEVENT + 全天形态', () {
      final ics = buildStore().renderFullIcs();
      expect(ics, contains('BEGIN:VCALENDAR'));
      expect(ics, contains('UID:cal_1'));
      expect(ics, contains('UID:cal_2'));
      expect(ics, contains('DTSTART;VALUE=DATE:'));
      expect(ics, contains('SUMMARY:体检\\, 复诊'));
      expect(ics.endsWith('END:VCALENDAR'), isTrue);
    });
  });

  group('本机服务路由矩阵（真 HTTP over raw socket）', () {
    late LocalCalDavServer server;
    late int port;
    const user = '2bot';
    const pass = 'test-pass-12';

    Future<({int status, Map<String, String> headers, String body})> req(
      String method,
      String path, {
      String? body,
      String? authOverride,
    }) async {
      final sock = await Socket.connect('127.0.0.1', port);
      final sb = StringBuffer('$method $path HTTP/1.1$crlf'
          'Host: 127.0.0.1$crlf'
          'Authorization: Basic '
          '${base64.encode(utf8.encode(authOverride ?? '$user:$pass'))}$crlf');
      if (body != null) {
        sb.write('Content-Type: application/xml; charset=utf-8$crlf');
        sb.write('Content-Length: ${utf8.encode(body).length}$crlf');
      }
      sb.write('Connection: close$crlf$crlf');
      if (body != null) sb.write(body);
      sock.write(sb.toString());
      // 字节级收集（chunk 大小按字节计，多字节 UTF-8 可能跨块）
      final rawBytes = <int>[];
      await for (final chunk in sock) {
        rawBytes.addAll(chunk);
      }
      sock.destroy();
      // 找头部边界（字节）
      var headEnd = -1;
      for (var i = 0; i < rawBytes.length - 3; i++) {
        if (rawBytes[i] == 13 &&
            rawBytes[i + 1] == 10 &&
            rawBytes[i + 2] == 13 &&
            rawBytes[i + 3] == 10) {
          headEnd = i;
          break;
        }
      }
      final headBytes = rawBytes.sublist(0, headEnd);
      var bodyBytes = rawBytes.sublist(headEnd + 4);
      final head = utf8.decode(headBytes);
      // chunked 解码（dart:io HttpServer 对无 Content-Length 响应用分块传输）
      final headLower = head.toLowerCase();
      if (headLower.contains('transfer-encoding: chunked')) {
        final decoded = <int>[];
        var i = 0;
        while (i < bodyBytes.length) {
          var j = i;
          while (j + 1 < bodyBytes.length &&
              !(bodyBytes[j] == 13 && bodyBytes[j + 1] == 10)) {
            j++;
          }
          final sizeStr =
              String.fromCharCodes(bodyBytes.sublist(i, j)).split(';').first.trim();
          final size = int.parse(sizeStr, radix: 16);
          if (size == 0) break;
          decoded.addAll(bodyBytes.sublist(j + 2, j + 2 + size));
          i = j + 2 + size + 2;
        }
        bodyBytes = decoded;
      }
      final respBody = utf8.decode(bodyBytes, allowMalformed: true);
      final statusLine = head.split(crlf).first;
      final status = int.parse(
          RegExp(r'HTTP/1\.1 (\d+)').firstMatch(statusLine)!.group(1)!);
      final hs = <String, String>{};
      for (final line in head.split(crlf).skip(1)) {
        final idx = line.indexOf(':');
        if (idx > 0) {
          hs[line.substring(0, idx).trim().toLowerCase()] =
              line.substring(idx + 1).trim();
        }
      }
      return (status: status, headers: hs, body: respBody);
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      server = LocalCalDavServer(store: buildStore(), password: pass);
      await server.start(preferredPort: 32100);
      port = server.port;
    });

    tearDown(() async {
      await server.stop();
    });

    test('端口绑定回环 + 顺延', () {
      expect(port, 32100);
      expect(server.isRunning, isTrue);
    });

    test('无凭据 → 401 + WWW-Authenticate', () async {
      final r = await req('GET', '/calendar.ics', authOverride: 'nonsense');
      expect(r.status, 401);
      expect(r.headers['www-authenticate'], contains('Basic'));
    });

    test('发现链：/ → principal → home → 集合', () async {
      final root = await req('PROPFIND', '/');
      expect(root.status, 207);
      expect(root.body, contains('/principals/2bot/'));
      expect(root.body, contains('current-user-principal'));

      final prin = await req('PROPFIND', '/principals/2bot/');
      expect(prin.status, 207);
      expect(prin.body, contains('calendar-home-set'));
      expect(prin.body, contains('/calendars/2bot/'));

      final home = await req('PROPFIND', '/calendars/2bot/');
      expect(home.status, 207);
      expect(home.body, contains('<c:calendar/>'));
      expect(home.body, contains('getctag'));
      expect(home.body, contains('sync-token'));
      expect(home.body, contains('supported-calendar-component-set'));
    });

    test('GET /.well-known/caldav → 301', () async {
      final r = await req('GET', '/.well-known/caldav');
      expect(r.status, 301);
      expect(r.headers['location'], '/');
    });

    test('REPORT sync-collection：全量 + 墓碑 404', () async {
      server.store.applyUpserts([
        {'uid': 'cal_1', 'cancelled': true, 'lastModifiedMs': 1727111111111},
      ]);
      final r = await req('REPORT', '/calendars/2bot/default/',
          body: '<B:sync-collection xmlns:B="urn:ietf:params:xml:ns:caldav"/>');
      expect(r.status, 207);
      expect(r.body, contains('sync-token'));
      expect(r.body, contains('cal_2'));
      expect(r.body, contains('cal_1'));
      expect(r.body, contains('404 Not Found'));
    });

    test('REPORT calendar-multiget：按 href 返回 / 缺失 404', () async {
      final r = await req('REPORT', '/calendars/2bot/default/',
          body: '<C:calendar-multiget xmlns:C="urn:ietf:params:xml:ns:caldav">'
              '<D:href xmlns:D="DAV:">/calendars/2bot/default/cal_2.ics</D:href>'
              '<D:href xmlns:D="DAV:">/calendars/2bot/default/none.ics</D:href>'
              '</C:calendar-multiget>');
      expect(r.status, 207);
      expect(r.body, contains('cal_2'));
      expect(r.body, contains('全天日程'));
      expect(r.body, contains('404 Not Found'));
    });

    test('REPORT calendar-query：time-range 过滤', () async {
      final r = await req('REPORT', '/calendars/2bot/default/',
          body: '<C:calendar-query xmlns:C="urn:ietf:params:xml:ns:caldav" '
              'xmlns:D="DAV:" xmlns:g="urn:ietf:params:xml:ns:caldav:time-range">'
              '<D:prop><D:getetag/><C:calendar-data/></D:prop>'
              '<C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter '
              'name="VEVENT">'
              '<g:time-range start="20240923T000000Z" '
              'end="20240923T235959Z"/>'
              '</C:comp-filter></C:filter></C:comp-filter>'
              '</C:calendar-query>');
      expect(r.status, 207);
      expect(r.body, contains('cal_1'), reason: 'cal_1 落在 2024-09-23 窗口内');
      expect(r.body, isNot(contains('cal_2')), reason: 'cal_2 在窗口外');
    });

    test('GET 单事件：200 + ETag；缺失 → 404', () async {
      final r = await req('GET', '/calendars/2bot/default/cal_1.ics');
      expect(r.status, 200);
      expect(r.headers['etag'], isNotNull);
      expect(r.headers['content-type'], contains('text/calendar'));
      expect(r.body, contains('UID:cal_1'));
      expect(r.body.endsWith('END:VEVENT'), isTrue);

      final r404 = await req('GET', '/calendars/2bot/default/none.ics');
      expect(r404.status, 404);
    });

    test('GET /calendar.ics：完整 VCALENDAR + ETag + Last-Modified', () async {
      final r = await req('GET', '/calendar.ics');
      expect(r.status, 200);
      expect(r.headers['content-type'], contains('text/calendar'));
      expect(r.headers['etag'], isNotNull);
      expect(r.headers['last-modified'], isNotNull);
      expect(r.body, contains('X-WR-CALNAME:2BOT 日历'));
      expect(r.body, contains('BEGIN:VCALENDAR'));
    });

    test('只读契约：PUT/DELETE/POST 一律 403', () async {
      expect(
        (await req('PUT', '/calendars/2bot/default/x.ics', body: 'x')).status,
        403,
      );
      expect(
        (await req('DELETE', '/calendars/2bot/default/cal_1.ics')).status,
        403,
      );
      expect(
        (await req('POST', '/calendars/2bot/default/', body: 'x')).status,
        403,
      );
    });
  });

  group('P2 闸门非阻塞语义（WO-70 §7 闪屏修复）', () {
    test('锁竞争时轮询等待而非阻塞：并发体都在限期内完成且串行', () async {
      final tmp = await Directory.systemTemp.createTemp('wo70_poll_test');
      lockDirOverride = tmp.path;
      try {
        // 互斥语义（检测员整改②）：锁只保证【不同时在临界区】，不保证 FIFO。
        // 用进入/离开时间戳断言临界区不重叠；先到先执行由调度决定。
        final inside = <int, DateTime>{};
        final exit = <int, DateTime>{};
        Future<int> worker(int id) => crossIsolateSynchronized('poll', () async {
              inside[id] = DateTime.now();
              await Future<void>.delayed(const Duration(milliseconds: 120));
              exit[id] = DateTime.now();
              return id;
            });
        final t0 = DateTime.now();
        final results = await Future.wait([worker(1), worker(2)]);
        expect(results.toSet(), {1, 2}, reason: '两者都必须完成（无饿死）');
        // 临界区互斥：后进者的【进入时刻】必须 ≥ 先出者的【离开时刻】
        //（时间线不得重叠；先后顺序由调度决定，不作为断言）
        final firstExit = exit.values.reduce((a, b) => a.isBefore(b) ? a : b);
        final lastInside = inside.values.reduce((a, b) => a.isAfter(b) ? a : b);
        expect(
          lastInside.isAfter(firstExit) || lastInside.isAtSameMomentAs(firstExit),
          isTrue,
          reason: '临界区必须互斥：lastInside=$lastInside 应晚于 firstExit=$firstExit',
        );
        // 非阻塞轮询：总耗时 ≈ 串行两段 120ms + 重试粒度，不叠加 3s 阻塞
        expect(DateTime.now().difference(t0).inMilliseconds, lessThan(1500),
            reason: '等待必须异步让出（闪屏修复硬性规则①②），不叠加 3s 阻塞');
      } finally {
        lockDirOverride = null;
        await tmp.delete(recursive: true);
      }
    });
  });
}
