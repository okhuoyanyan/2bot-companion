import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:bot_companion/services/calendar_event_store.dart';
import 'package:bot_companion/services/cross_isolate_lock.dart';
import 'package:bot_companion/services/local_caldav_server.dart';

import 'wo74r2_baseline.dart';

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

    Future<({int status, Map<String, String> headers, String body, List<int> bodyBytes})> req(
      String method,
      String path, {
      String? body,
      String? authOverride,
      bool noAuth = false,
      String? depth,
    }) async {
      final sock = await Socket.connect('127.0.0.1', port);
      final sb = StringBuffer('$method $path HTTP/1.1$crlf'
          'Host: 127.0.0.1$crlf');
      // WO-73：noAuth = 完全不带 Authorization 头（免认证路径与 401 态的
      // 真实形态；原助手恒发 Basic 头，测不出「未认证」分支）
      if (!noAuth) {
        sb.write('Authorization: Basic '
            '${base64.encode(utf8.encode(authOverride ?? '$user:$pass'))}$crlf');
      }
      // WO-74：PROPFIND Depth 头（不发给默认=服务端按 1 处理，与生产一致）
      if (depth != null) {
        sb.write('Depth: $depth$crlf');
      }
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
      return (status: status, headers: hs, body: respBody, bodyBytes: bodyBytes);
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      // WO-73：令牌走 SharedPreferencesAsync 存储（与生产跨 isolate 读法一致），
      // 测试须挂内存平台实现——与 calendar_sync_service_test.dart:31 同款
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(const {});
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

    // ==================================================================
    // WO-73 §6 · /.well-known/caldav 免认证 301（BUG 修复）
    // 断言现状对照：原断言（改前 line 216-220）=【带 Basic 头】GET → 301 且
    // Location '/'；其未覆盖的 BUG 面是【不带认证 → 401】（301 被藏在认证之后）。
    // 修复契约：GET/HEAD/PROPFIND 不带认证 → 301 + Location /principals/2bot/
    // + 空体；其余一切仍强制 Basic。
    // ==================================================================
    test('不带认证 GET /.well-known/caldav → 301 + Location + 空体', () async {
      final r = await req('GET', '/.well-known/caldav', noAuth: true);
      expect(r.status, 301,
          reason: 'RFC 6764 发现入口不承载数据，必须匿名可达（原缺陷：未认证先 401）');
      expect(r.headers['location'], '/principals/2bot/');
      expect(r.body.trim(), isEmpty, reason: '免认证重定向不得在体里泄露任何数据');
    });

    test('不带认证 PROPFIND /.well-known/caldav → 同样 301', () async {
      final r = await req('PROPFIND', '/.well-known/caldav', noAuth: true);
      expect(r.status, 301);
      expect(r.headers['location'], '/principals/2bot/');
    });

    test('不带认证 HEAD /.well-known/caldav → 301', () async {
      final r = await req('HEAD', '/.well-known/caldav', noAuth: true);
      expect(r.status, 301);
      expect(r.headers['location'], '/principals/2bot/');
    });

    test('带认证 GET /.well-known/caldav → 同样 301（行为一致）', () async {
      final r = await req('GET', '/.well-known/caldav');
      expect(r.status, 301);
      expect(r.headers['location'], '/principals/2bot/');
    });

    test('免认证不扩面：其余路径不带认证 → 仍 401', () async {
      expect((await req('GET', '/', noAuth: true)).status, 401);
      expect((await req('GET', '/nonexistent', noAuth: true)).status, 401);
      expect((await req('PROPFIND', '/', noAuth: true)).status, 401);
      expect((await req('OPTIONS', '/', noAuth: true)).status, 401);
      expect((await req('GET', '/.well-known/other', noAuth: true)).status, 401);
      expect((await req('GET', '/calendar.ics', noAuth: true)).status, 401,
          reason: 'ICS 无 token = 未认证（免认证只属于 well-known 一条路）');
    });

    test('well-known 写方法不豁免：无认证 PUT → 401；带认证 PUT → 403', () async {
      expect(
        (await req('PUT', '/.well-known/caldav', noAuth: true, body: 'x')).status,
        401,
      );
      expect(
        (await req('PUT', '/.well-known/caldav', body: 'x')).status,
        403,
      );
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
      // WO-74-R2 P2 断言现状对照：原断言（a142184）钉裸尾 endsWith('END:VEVENT')
      // ——信封化后单事件正文以 END:VCALENDAR 收尾（故意变更，规格②）
      final r = await req('GET', '/calendars/2bot/default/cal_1.ics');
      expect(r.status, 200);
      expect(r.headers['etag'], isNotNull);
      expect(r.headers['content-type'], contains('text/calendar'));
      expect(r.body, contains('UID:cal_1'));
      expect(r.body.startsWith('BEGIN:VCALENDAR'), isTrue);
      expect(r.body.endsWith('END:VCALENDAR'), isTrue);

      final r404 = await req('GET', '/calendars/2bot/default/none.ics');
      expect(r404.status, 404);
    });

    test('GET /calendar.ics：完整 VCALENDAR + ETag + Last-Modified（带令牌）', () async {
      // WO-73 断言现状对照：原断言（改前 line 275-283）凭【默认 Basic 头】
      // 取 200——令牌化后 ICS 入口只认 token，此处改为无 Basic + 正确 token
      final r = await req(
          'GET', '/calendar.ics?token=${server.icsToken}',
          noAuth: true);
      expect(r.status, 200);
      expect(r.headers['content-type'], contains('text/calendar'));
      expect(r.headers['etag'], isNotNull);
      expect(r.headers['last-modified'], isNotNull);
      expect(r.body, contains('X-WR-CALNAME:2BOT 日历'));
      expect(r.body, contains('BEGIN:VCALENDAR'));
    });

    // ==================================================================
    // WO-73 §2/§3 · ICS 订阅独立令牌（四态 + 独立性 + 重置）
    // 断言现状对照：改前 /calendar.ics 只认 Basic（_checkAuth 先行，改前
    // line 59）；token 四态均为本单新契约，红灯在实现前实证。
    // ==================================================================
    test('令牌生成：≥24 字符、全 hex、两次生成不同', () {
      final t1 = LocalCalDavServer.generateIcsToken();
      final t2 = LocalCalDavServer.generateIcsToken();
      expect(t1.length, greaterThanOrEqualTo(24), reason: '规格 §2.1 硬约束');
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(t1), isTrue);
      expect(t1, isNot(t2), reason: '随机性');
    });

    test('启动即持久化令牌；服务持有可读副本', () {
      expect(server.icsToken.length, greaterThanOrEqualTo(24));
      expect(
        SharedPreferencesAsync().getString(LocalCalDavServer.icsTokenKey),
        completion(server.icsToken),
      );
    });

    test('常量时间比较：语义正确（等/异/前缀/长度差）', () {
      const f = LocalCalDavServer.constantTimeEquals;
      expect(f('abcdef', 'abcdef'), isTrue);
      expect(f('abcdef', 'abcdeX'), isFalse);
      expect(f('abcdef', 'abcdefX'), isFalse);
      expect(f('abc', ''), isFalse, reason: '前缀 ≠ 相等');
      expect(f('', ''), isTrue);
    });

    test('正确 token（无 Basic 头）→ 200 全量 VEVENT（2 条）', () async {
      final r = await req('GET', '/calendar.ics?token=${server.icsToken}',
          noAuth: true);
      expect(r.status, 200);
      expect(r.body, contains('BEGIN:VCALENDAR'));
      expect(r.body, contains('UID:cal_1'));
      expect(r.body, contains('UID:cal_2'),
          reason: '200 必须含库内全部事件（N=2）');
    });

    test('token 缺失 → 401（Basic 正确也不放行——令牌与口令相互独立）', () async {
      final rBasicOnly = await req('GET', '/calendar.ics');
      expect(rBasicOnly.status, 401,
          reason: '规格 §2.2：token 缺失仍 401；Basic 不是 ICS 入口的凭据');
      final rNone = await req('GET', '/calendar.ics', noAuth: true);
      expect(rNone.status, 401);
      expect(rNone.headers['www-authenticate'], contains('Basic'));
    });

    test('token 错误 / 截断 / 空 → 401', () async {
      final wrong =
          await req('GET', '/calendar.ics?token=${'0' * 32}', noAuth: true);
      expect(wrong.status, 401);
      final truncated = await req(
          'GET', '/calendar.ics?token=${server.icsToken.substring(0, 31)}',
          noAuth: true);
      expect(truncated.status, 401, reason: '前缀不得通过（常量时间比较的全等语义）');
      final empty = await req('GET', '/calendar.ics?token=', noAuth: true);
      expect(empty.status, 401);
    });

    test('带 token 的 PUT/DELETE/POST → 403（只读不变）', () async {
      final t = server.icsToken;
      expect(
        (await req('PUT', '/calendar.ics?token=$t', noAuth: true, body: 'x'))
            .status,
        403,
      );
      expect(
        (await req('DELETE', '/calendar.ics?token=$t', noAuth: true)).status,
        403,
      );
      expect(
        (await req('POST', '/calendar.ics?token=$t', noAuth: true, body: 'x'))
            .status,
        403,
      );
    });

    test('正确 token 用于其余路径 → 仍 401（令牌仅限 calendar.ics）', () async {
      final t = server.icsToken;
      expect((await req('GET', '/?token=$t', noAuth: true)).status, 401);
      expect((await req('PROPFIND', '/?token=$t', noAuth: true)).status, 401);
      expect(
        (await req('GET', '/calendars/2bot/default/cal_1.ics?token=$t',
                noAuth: true))
            .status,
        401,
      );
      expect((await req('OPTIONS', '/?token=$t', noAuth: true)).status, 401);
      expect((await req('GET', '/calendar.icss?token=$t', noAuth: true)).status,
          401,
          reason: '非精确路径匹配不豁免');
    });

    test('重置：旧 token 立即 401 / 新 token 立即 200（跨隔离写即时生效）', () async {
      final old = server.icsToken;
      final newTok = await LocalCalDavServer.rotateIcsToken();
      expect(newTok.length, greaterThanOrEqualTo(24));
      expect(newTok, isNot(old));
      expect(
        (await req('GET', '/calendar.ics?token=$old', noAuth: true)).status,
        401,
        reason: '旧令牌必须立即失效（服务端每请求直读平台层）',
      );
      expect(
        (await req('GET', '/calendar.ics?token=$newTok', noAuth: true)).status,
        200,
      );
    });

    test('令牌绝不进日志：服务端源码零日志调用 + 401 响应不回显 token', () async {
      // (a) 静态面：本服务文件不得出现任何日志调用——token 无进 logcat 的通道
      //（可断言「日志格式化函数不接收 token」的最强形态：根本没有日志函数）
      final src =
          File('lib/services/local_caldav_server.dart').readAsStringSync();
      expect(
        RegExp(r'\b(print|debugPrint|log|info|warning|severe)\s*\(')
            .hasMatch(src),
        isFalse,
        reason: 'logcat 无 token 明文的静态保证',
      );
      // (b) 响应面：401 的体与头不得回显令牌
      final r401 = await req('GET', '/calendar.ics?token=WRONG', noAuth: true);
      expect(r401.status, 401);
      expect(r401.body, isNot(contains(server.icsToken)));
      expect(r401.headers.values.join('|'), isNot(contains(server.icsToken)));
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

    // ==================================================================
    // WO-74 v2 · CalDAV 客户端兼容性（supported-report-set 两处同步携带 /
    //         calendar-user-address-set 双 href / 根 D1 列 calendar-home）
    // 断言现状对照（grep -n 复核于改前 main 352b5f8 的 lib/services/local_caldav_server.dart）：
    //  - `supported-report-set`：全文 0 处；`calendar-user-address-set`：全文 0 处；
    //  - `_propfind`（:219）四个分支属性集全部 writeln 硬编码；
    //  - 根分支恒只回 1 条目（无子资源）——规格 §1 实测「D1 仅 1 条目」即此。
    // v2 护栏 1：属性过滤【不做】，恒为全量属性块（无请求体/带请求体均同）。
    // ==================================================================
    test('home 集合声明 supported-report-set：三报告齐全（规格 §2.1①前置）', () async {
      final r = await req('PROPFIND', '/calendars/2bot/', depth: '0');
      expect(r.status, 207);
      expect(r.body, contains('supported-report-set'));
      expect(r.body, contains('<c:calendar-query/>'));
      expect(r.body, contains('<c:calendar-multiget/>'));
      expect(r.body, contains('<d:sync-collection/>'));
      expect(r.body, contains('displayname'),
          reason: 'v2 护栏1：全量属性块（多属性客户端自会忽略）');
    });

    test('日历集合（default）响应节点同样携带 supported-report-set + 三报告（§2.1②）', () async {
      final r = await req('PROPFIND', '/calendars/2bot/default/', depth: '0');
      expect(r.status, 207);
      expect(r.body, contains('supported-report-set'));
      expect(r.body, contains('<c:calendar-query/>'));
      expect(r.body, contains('<c:calendar-multiget/>'));
      expect(r.body, contains('<d:sync-collection/>'));
    });

    test('home Depth1 的【子响应节点】也携带 supported-report-set（§2.1①）', () async {
      final r = await req('PROPFIND', '/calendars/2bot/'); // Depth 缺省=1
      expect(r.status, 207);
      expect('supported-report-set'.allMatches(r.body).length,
          greaterThanOrEqualTo(2),
          reason: 'home 自身节点与子节点（default）都声明');
      expect('calendar-multiget'.allMatches(r.body).length,
          greaterThanOrEqualTo(2), reason: '子节点三报告缺一不可');
    });

    test('principal 返回 calendar-user-address-set 双 href（规格 §2.2·前置审细化）', () async {
      final r = await req('PROPFIND', '/principals/2bot/', depth: '0');
      expect(r.status, 207);
      expect(r.body, contains('calendar-user-address-set'));
      expect(r.body, contains('mailto:2bot@2bot.local'));
      expect(r.body, contains('<d:href>/principals/2bot/</d:href>'),
          reason: '第二个 href：principal 路径本身');
    });

    test('根 Depth1 列出 calendar-home /calendars/2bot/（规格 §2.3）；Depth0 不列', () async {
      final r1 = await req('PROPFIND', '/'); // 无体 = allprop 形态（既有形状）
      expect(r1.status, 207);
      expect(r1.body, contains('<d:href>/calendars/2bot/</d:href>'),
          reason: '不跟随 current-user-principal 链的客户端靠根扫描发现日历 home'
              '（两跳协议：根扫描见 home → home D1 见 c:calendar，后者由'
              '「既有形状不破坏」断言覆盖）');

      final r0 = await req('PROPFIND', '/', depth: '0');
      expect(r0.body, contains('current-user-principal'));
      expect(r0.body, isNot(contains('<d:href>/calendars/2bot/</d:href>')),
          reason: 'Depth 0 只回自身');
    });

    test('既有形状不破坏：allprop home D1 双条目 + c:calendar + getctag', () async {
      final r = await req('PROPFIND', '/calendars/2bot/');
      expect(r.status, 207);
      expect(r.body, contains('<c:calendar/>'));
      expect(r.body, contains('getctag'));
      expect(r.body, contains('<d:href>/calendars/2bot/default/</d:href>'));
    });

    // ==================================================================
    // WO-74-R2 Phase 1 · 快照护栏（护栏③）
    // 断言现状对照：基线 k* 常量由临时抓取脚本在【未改代码 5e57e31】上抓取后
    // 程序化生成（test/wo74r2_baseline.dart，非手抄）；本组证明加日志前后
    // PROPFIND 各层级与 REPORT 的 XML 正文 100% 逐字节一致。
    // 豁免（规格）：GET /calendar.ics 的 Last-Modified 是响应头且随时间变化，
    // 不在正文快照内（本组比对的是 body 字节，天然豁免）。
    // ==================================================================
    test('快照：PROPFIND 根 D1 逐字节吻合', () async {
      final r = await req('PROPFIND', '/');
      expect(r.status, 207);
      expect(r.bodyBytes, utf8.encode(baselineRootD1));
    });
    test('快照：PROPFIND principal 逐字节吻合', () async {
      final r = await req('PROPFIND', '/principals/2bot/');
      expect(r.status, 207);
      expect(r.bodyBytes, utf8.encode(baselinePrincipal));
    });
    test('快照：PROPFIND home D1 逐字节吻合', () async {
      final r = await req('PROPFIND', '/calendars/2bot/');
      expect(r.status, 207);
      expect(r.bodyBytes, utf8.encode(baselineHomeD1));
    });
    test('快照：PROPFIND default（Depth 缺省=D1，与基线抓取口径一致）逐字节吻合',
        () async {
      final r = await req('PROPFIND', '/calendars/2bot/default/');
      expect(r.status, 207);
      expect(r.bodyBytes, utf8.encode(baselineDefaultD0));
    });
    test('快照：REPORT sync-collection 逐字节吻合', () async {
      final r = await req('REPORT', '/calendars/2bot/default/',
          body: '<B:sync-collection xmlns:B="urn:ietf:params:xml:ns:caldav"/>');
      expect(r.status, 207);
      expect(r.bodyBytes, utf8.encode(baselineReportSync));
    });
    test('快照：REPORT calendar-multiget 逐字节吻合', () async {
      final r = await req('REPORT', '/calendars/2bot/default/',
          body: '<C:calendar-multiget xmlns:C="urn:ietf:params:xml:ns:caldav">'
              '<D:href xmlns:D="DAV:">/calendars/2bot/default/cal_2.ics</D:href>'
              '<D:href xmlns:D="DAV:">/calendars/2bot/default/none.ics</D:href>'
              '</C:calendar-multiget>');
      expect(r.status, 207);
      expect(r.bodyBytes, utf8.encode(baselineReportMultiget));
    });
    test('快照：REPORT calendar-query 逐字节吻合', () async {
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
      expect(r.bodyBytes, utf8.encode(baselineReportQuery));
    });
    test('快照：GET /calendar.ics 正文逐字节吻合（Last-Modified 头豁免）', () async {
      final r = await req('GET', '/calendar.ics?token=${server.icsToken}',
          noAuth: true);
      expect(r.status, 200);
      expect(r.bodyBytes, utf8.encode(baselineIcs));
    });

    // ==================================================================
    // WO-74-R2 Phase 1 · 访问记录行为（只落文件；凭据三禁；环形上限）
    // ==================================================================
    test('访问记录：格式/状态/字节齐全，且 token 与 Authorization 绝不落盘', () async {
      final tmp = await Directory.systemTemp.createTemp('wo74r2_access');
      LocalCalDavServer.accessLogDirOverride = tmp.path;
      final logFile = File('${tmp.path}/caldav_access.log');
      if (logFile.existsSync()) logFile.deleteSync();
      try {
        await req('GET', '/calendar.ics', noAuth: true); // 401（无 token）
        await req('GET', '/calendar.ics?token=${server.icsToken}',
            noAuth: true); // 200
        await req('GET', '/calendar.ics?token=WRONG', noAuth: true); // 401
        await req('GET', '/.well-known/caldav', noAuth: true); // 301
        await req('PUT', '/calendars/2bot/default/x.ics',
            body: 'x'); // 403
        await req('PROPFIND', '/calendars/2bot/default/', depth: '0'); // 207
        await LocalCalDavServer.accessWritesIdleForTest;

        expect(logFile.existsSync(), isTrue, reason: '日志必须落盘');
        final lines = logFile.readAsLinesSync();
        expect(lines.length, 6, reason: '六个请求六行');
        final b64pass = base64.encode(utf8.encode('$user:$pass'));
        for (final l in lines) {
          expect(l, matches(RegExp(
              r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+ '
              r'(GET|PUT|PROPFIND) \S+ \d{3} \d+(\.\d+?)ms \d+$')),
              reason: '格式：时间 方法 路径 状态 耗时ms 字节');
          expect(l.contains('token='), isFalse,
              reason: '凭据三禁①：query 绝不落盘');
          expect(l.contains(b64pass), isFalse, reason: '凭据三禁②');
          expect(l.toLowerCase().contains('authorization'), isFalse,
              reason: '凭据三禁②');
          expect(l.contains('体检'), isFalse, reason: '凭据三禁③：响应体不落盘');
        }
        expect(lines.any((l) => l.contains(' 401 ')), isTrue);
        expect(lines.any((l) => l.contains(' 200 ')), isTrue);
        expect(lines.any((l) => l.contains(' 301 ')), isTrue);
        expect(lines.any((l) => l.contains(' 403 ')), isTrue);
        expect(lines.any((l) => l.contains(' 207 ')), isTrue);
        final propfindLine = lines.firstWhere((l) => l.contains(' 207 '));
        final bytesField =
            int.parse(propfindLine.split(' ').last);
        expect(bytesField, greaterThan(500), reason: '207 载荷字节=XML 长度');
      } finally {
        LocalCalDavServer.accessLogDirOverride = null;
        if (tmp.existsSync()) {
          await tmp.delete(recursive: true);
        }
      }
    });

    test('环形缓冲上限：超过 _accessRingMax 后保持恒定', () {
      final before = LocalCalDavServer.accessRingSnapshot().length;
      for (var i = 0; i < 450; i++) {
        LocalCalDavServer.accessRingAddForTest('LINE$i');
      }
      final after = LocalCalDavServer.accessRingSnapshot();
      expect(after.length, 400, reason: '环形上限 400（200–500 规格带内）');
      expect(after.length, greaterThanOrEqualTo(before));
      expect(after.last, 'LINE449');
      // 清场：避免污染同套件后续用例的内存态
      LocalCalDavServer.accessRingClearForTest();
      expect(LocalCalDavServer.accessRingSnapshot(), isEmpty);
    });

    // ==================================================================
    // WO-74-R2 Phase 2 · calendar-data 信封
    // 断言现状对照（grep -n 复核于改前 a142184）：sync-collection/multiget/
    // calendar-query/单事件 GET 的 per-event calendar-data 均发【裸 BEGIN:VEVENT】
    // （calendar_event_store.dart:81-120 toIcs 无信封；per-event 出口 0 处
    // BEGIN:VCALENDAR）——ical4j 严格解析拒收 =「同步成功零显示」根因。
    // 聚合 /calendar.ics 本就正确（renderFullIcs 有信封），零改动。
    // ==================================================================
    group('WO-74-R2 Phase 2 · 信封', () {
      late LocalCalDavServer server;
      late int port;
      const pass2 = 'test-pass-12';

      setUp(() async {
        SharedPreferences.setMockInitialValues({});
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.withData(const {});
        server = LocalCalDavServer(store: buildStore(), password: pass2);
        await server.start(preferredPort: 33100);
        port = server.port;
      });
      tearDown(() async {
        await server.stop();
      });

      Future<String> reqBody(String method, String path, {String? body}) async {
        final sock = await Socket.connect('127.0.0.1', port);
        final sb = StringBuffer('$method $path HTTP/1.1$crlf'
            'Host: 127.0.0.1$crlf'
            'Authorization: Basic '
            '${base64.encode(utf8.encode('2bot:$pass2'))}$crlf');
        if (body != null) {
          sb.write('Content-Type: application/xml; charset=utf-8$crlf');
          sb.write('Content-Length: ${utf8.encode(body).length}$crlf');
        }
        sb.write('Connection: close$crlf$crlf');
        if (body != null) sb.write(body);
        sock.write(sb.toString());
        final rawBytes = <int>[];
        await for (final chunk in sock) {
          rawBytes.addAll(chunk);
        }
        sock.destroy();
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
        var bodyBytes = rawBytes.sublist(headEnd + 4);
        final head = utf8.decode(rawBytes.sublist(0, headEnd));
        if (head.toLowerCase().contains('transfer-encoding: chunked')) {
          final decoded = <int>[];
          var i = 0;
          while (i < bodyBytes.length) {
            var j = i;
            while (j + 1 < bodyBytes.length &&
                !(bodyBytes[j] == 13 && bodyBytes[j + 1] == 10)) {
              j++;
            }
            final sizeStr = String.fromCharCodes(bodyBytes.sublist(i, j))
                .split(';')
                .first
                .trim();
            final size = int.parse(sizeStr, radix: 16);
            if (size == 0) break;
            decoded.addAll(bodyBytes.sublist(j + 2, j + 2 + size));
            i = j + 2 + size + 2;
          }
          bodyBytes = decoded;
        }
        return utf8.decode(bodyBytes, allowMalformed: true);
      }

      void expectEnveloped(String seg) {
        expect(seg.startsWith('BEGIN:VCALENDAR'), isTrue,
            reason: '每段 calendar-data 必以 BEGIN:VCALENDAR 开头（RFC 4791 §5.1）');
        expect(seg.endsWith('END:VCALENDAR'), isTrue,
            reason: '每段 calendar-data 必以 END:VCALENDAR 结尾');
        expect(seg.contains('BEGIN:VEVENT'), isTrue);
        expect(seg.contains('END:VEVENT'), isTrue);
        expect(seg.indexOf('BEGIN:VCALENDAR'),
            lessThan(seg.indexOf('BEGIN:VEVENT')),
            reason: '信封在前，VEVENT 被包裹');
        expect(
            seg.indexOf('END:VEVENT'), lessThan(seg.indexOf('END:VCALENDAR')));
      }

      List<String> calendarDataSegments(String xml) => RegExp(
              r'<c:calendar-data>(.*?)</c:calendar-data>',
              dotAll: true)
          .allMatches(xml)
          .map((m) => m.group(1)!)
          .toList();

      test('store：toIcsWithEnvelope 结构（头四行 + 裸VEVENT 全文 + 收尾，CRLF）', () {
        final store = buildStore();
        final e = store.events['cal_1']!;
        final env = e.toIcsWithEnvelope();
        expect(env.startsWith('BEGIN:VCALENDAR\r\n'), isTrue);
        expect(env.contains('\r\nVERSION:2.0\r\n'), isTrue);
        expect(env.contains('\r\nPRODID:-//QQ-2BOT-NEW//CalDAV Server//CN\r\n'),
            isTrue);
        expect(env.contains('\r\nCALSCALE:GREGORIAN\r\n'), isTrue);
        expect('BEGIN:VCALENDAR'.allMatches(env).length, 1,
            reason: '信封不嵌套');
        expect(env.contains(e.toIcs().replaceAll('\n', '\r\n')), isTrue,
            reason: '承载现有裸 VEVENT 全文（仅行尾归一）');
        expect(env.endsWith('END:VEVENT\r\nEND:VCALENDAR'), isTrue);
        expect(env.replaceAll('\r\n', '').contains('\n'), isFalse,
            reason: '全 CRLF（无孤立 LF）');
      });

      test('sync-collection：每段 calendar-data 均带信封', () async {
        final r = await reqBody('REPORT', '/calendars/2bot/default/',
            body: '<B:sync-collection xmlns:B="urn:ietf:params:xml:ns:caldav"/>');
        final segs = calendarDataSegments(r);
        expect(segs.length, 2, reason: '库内 2 事件');
        for (final s in segs) {
          expectEnveloped(s);
        }
      });

      test('calendar-multiget：每段 calendar-data 均带信封', () async {
        final r = await reqBody('REPORT', '/calendars/2bot/default/',
            body: '<C:calendar-multiget xmlns:C="urn:ietf:params:xml:ns:caldav">'
                '<D:href xmlns:D="DAV:">/calendars/2bot/default/cal_1.ics</D:href>'
                '</C:calendar-multiget>');
        final segs = calendarDataSegments(r);
        expect(segs.length, 1);
        expectEnveloped(segs.first);
      });

      test('calendar-query：每段 calendar-data 均带信封', () async {
        final r = await reqBody('REPORT', '/calendars/2bot/default/',
            body: '<C:calendar-query xmlns:C="urn:ietf:params:xml:ns:caldav"/>');
        final segs = calendarDataSegments(r);
        expect(segs.length, 2);
        for (final s in segs) {
          expectEnveloped(s);
        }
      });

      test('单事件 GET：正文即信封（旧断言裸尾 END:VEVENT 同步改为信封尾）', () async {
        final body = await reqBody('GET', '/calendars/2bot/default/cal_1.ics');
        expect(body.startsWith('BEGIN:VCALENDAR'), isTrue);
        expect(body.endsWith('END:VCALENDAR'), isTrue);
        expectEnveloped(body);
      });

      test('etag 一致性：PROPFIND D1 事件 etag == 单事件 GET etag（同一信封字节）', () async {
        final propfind =
            await reqBody('PROPFIND', '/calendars/2bot/default/');
        final m = RegExp(
                r'<d:href>/calendars/2bot/default/cal_1\.ics</d:href>.*?<d:getetag>([^<]+)</d:getetag>',
                dotAll: true)
            .firstMatch(propfind);
        final listTag = m!.group(1)!;
        final sock = await Socket.connect('127.0.0.1', port);
        sock.write('GET /calendars/2bot/default/cal_1.ics HTTP/1.1$crlf'
            'Host: 127.0.0.1$crlf'
            'Authorization: Basic '
            '${base64.encode(utf8.encode('2bot:$pass2'))}$crlf'
            'Connection: close$crlf$crlf');
        final rawBytes = <int>[];
        await for (final chunk in sock) {
          rawBytes.addAll(chunk);
        }
        sock.destroy();
        final head = utf8.decode(rawBytes.sublist(0, rawBytes.length));
        final getTag =
            RegExp(r'[Ee][Tt][Aa][Gg]:\s*(\S+)').firstMatch(head)!.group(1)!;
        expect(listTag, getTag, reason: '列表 etag 必须与实际发送字节（信封版）一致');
      });

      test('守卫不回退：无 token 的 ICS 仍 401（聚合出口与令牌零改动）', () async {
        final r401 =
            await reqBody('GET', '/calendar.ics'); // 无 token
        expect(r401, isEmpty, reason: '401 空体：守卫语义不变');
      });
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
