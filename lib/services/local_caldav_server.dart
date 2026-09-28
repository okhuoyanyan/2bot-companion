// ============================================================================
// WO-70 · 本机只读服务（唯一对外出口）
// ============================================================================
// 仅绑 127.0.0.1；零新依赖（dart:io HttpServer）。
// 入口（WO-73 起）：
//   GET /calendar.ics?token=<独立令牌>    → 系统日历「URL 订阅」（不认 Basic）
//   /.well-known/caldav（GET/HEAD/PROPFIND）→ 免认证 301（RFC 6764 发现入口）
//   CalDAV: / → /principals/2bot/ → /calendars/2bot/（→ /calendars/2bot/default/）
//                                        → KashCal「CalDAV 账户」（仍 Basic）
// 响应形状对齐 NAS 侧 src/core/caldav-server.js（已与 KashCal 实测互通）。
// 只读：PUT/DELETE/POST 一律 403。认证：Basic（用户名 2bot）+ ICS 独立令牌。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../utils/constants.dart';
import 'calendar_event_store.dart';

class LocalCalDavServer {
  final CalendarEventStore store;
  final String password; // Basic 口令（用户名固定 2bot）
  HttpServer? _server;
  int port = 0;

  LocalCalDavServer({required this.store, required this.password});

  bool get isRunning => _server != null;
  String get url => 'http://127.0.0.1:$port';

  // ------------------------------------------------------------------
  // WO-73 · ICS 订阅独立令牌（与 Basic 口令相互独立，仅用于 GET /calendar.ics?token=）
  // ------------------------------------------------------------------
  // 存储走 SharedPreferencesAsync 直读平台层（WO-70 实证：legacy prefs 与
  // Async 门面在 Android 上是两套存储，跨 isolate 不可互见）。服务端【每个
  // 请求直读】——设置页侧重置写入后，旧令牌在下一个请求即失效，无需通知
  // 后台 isolate。令牌绝不进任何日志（logcat 零明文）。
  static const String icsTokenKey = 'pref_calendar_ics_token';

  /// 生成 16 字节随机令牌 → 32 个 hex 字符（≥24，规格 §2.1）
  static String generateIcsToken() {
    final rnd = Random.secure();
    return List<int>.generate(16, (_) => rnd.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// 常量时间比较（防时序侧信道）：长度差折叠进累积差，不提前返回
  static bool constantTimeEquals(String a, String b) {
    var diff = a.length ^ b.length;
    final n = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final ca = i < a.length ? a.codeUnitAt(i) : 0;
      final cb = i < b.length ? b.codeUnitAt(i) : 0;
      diff |= ca ^ cb;
    }
    return diff == 0;
  }

  /// 载入既有令牌；缺失或过短则生成并持久化（幂等）
  static Future<String> ensureIcsToken() async {
    final prefs = SharedPreferencesAsync();
    final cur = await prefs.getString(icsTokenKey);
    if (cur != null && cur.length >= 24) return cur;
    final t = generateIcsToken();
    await prefs.setString(icsTokenKey, t);
    return t;
  }

  /// 一键重置：写入新随机令牌（旧令牌下一请求即失效，无需重启服务）
  static Future<String> rotateIcsToken() async {
    final t = generateIcsToken();
    await SharedPreferencesAsync().setString(icsTokenKey, t);
    return t;
  }

  String? _icsToken; // 启动时副本：仅供本 isolate 内展示/测试；鉴权不走它
  String get icsToken => _icsToken ?? '';

  /// 绑定回环 18080 起，占用自动顺延（最多尝试 20 个端口）。
  Future<void> start({int preferredPort = 18080}) async {
    for (var p = preferredPort; p < preferredPort + 20; p++) {
      try {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, p);
        port = p;
        break;
      } on SocketException {
        continue; // 端口占用 → 顺延
      }
    }
    if (_server == null) {
      throw StateError('18080-18099 全部占用，本机服务无法启动');
    }
    _server!.listen(_handle, onError: (Object _) {});
    try {
      _icsToken = await ensureIcsToken();
    } catch (_) {
      _icsToken = null; // 令牌读取失败 → 订阅入口 fail-closed（一律 401）
    }
  }

  Future<void> stop() async {
    await _server?.close(force: false);
    _server = null;
    port = 0;
  }

  // ------------------------------------------------------------------
  // 请求处理
  // ------------------------------------------------------------------

  Future<void> _handle(HttpRequest req) async {
    try {
      final method = req.method.toUpperCase();
      final path = req.uri.path;

      // —— WO-73 §6 BUG 修复：RFC 6764 发现入口【免认证 301】——
      // 原 301 分支在 Basic 认证之后：未认证先 401，严格的 CalDAV 客户端在
      // 发现第一步即放弃（管理员实机「登录成功但 0 个日历」）。空体重定向，
      // 不泄露任何数据。
      if (path == '/.well-known/caldav' &&
          (method == 'GET' || method == 'HEAD' || method == 'PROPFIND')) {
        req.response.statusCode = 301;
        req.response.headers.set('Location', '/principals/2bot/');
        await req.response.close();
        return;
      }

      // —— WO-73 §2：仅 /calendar.ics 认【独立令牌】；其余全部仍强制 Basic ——
      if (path == '/calendar.ics') {
        if (!await _checkIcsToken(req)) {
          req.response.statusCode = 401;
          req.response.headers.set(
              'WWW-Authenticate', 'Basic realm="2bot", charset="UTF-8"');
          await req.response.close();
          return;
        }
      } else if (!_checkAuth(req)) {
        req.response.statusCode = 401;
        req.response.headers.set(
            'WWW-Authenticate', 'Basic realm="2bot", charset="UTF-8"');
        await req.response.close();
        return;
      }
      if (method != 'GET' &&
          method != 'HEAD' &&
          method != 'OPTIONS' &&
          method != 'PROPFIND' &&
          method != 'REPORT') {
        // 只读服务：写操作一律 403（硬性要求 5）
        req.response.statusCode = 403;
        await req.response.close();
        return;
      }

      switch (method) {
        case 'OPTIONS':
          req.response.headers.set('DAV', '1, 3, calendar-access');
          req.response.headers.set(
              'Allow', 'OPTIONS, GET, HEAD, PROPFIND, REPORT');
          req.response.statusCode = 200;
          await req.response.close();
          return;
        case 'PROPFIND':
          await _propfind(req, path, req.headers.value('Depth') ?? '1');
          return;
        case 'REPORT':
          final body = await utf8.decoder.bind(req).join();
          await _report(req, path, body);
          return;
        case 'GET':
        case 'HEAD':
          await _get(req, path, headOnly: method == 'HEAD');
          return;
      }
      req.response.statusCode = 405;
      await req.response.close();
    } catch (_) {
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  }

  bool _checkAuth(HttpRequest req) {
    final auth = req.headers.value('Authorization');
    if (auth == null || !auth.startsWith('Basic ')) return false;
    try {
      final decoded = utf8.decode(base64.decode(auth.substring(6).trim()));
      final idx = decoded.indexOf(':');
      if (idx < 0) return false;
      return decoded.substring(0, idx) == '2bot' &&
          decoded.substring(idx + 1) == password;
    } catch (_) {
      return false;
    }
  }

  /// WO-73：订阅令牌校验。token 只从 query 读取（禁 ?user=&pass= 形态，
  /// 口令绝不进 URL）；每请求直读平台层 → 设置页重置即时生效；
  /// 读取失败按拒绝处理（fail-closed）。
  Future<bool> _checkIcsToken(HttpRequest req) async {
    final given = req.uri.queryParameters['token'];
    if (given == null || given.isEmpty) return false;
    String? expected;
    try {
      expected = await SharedPreferencesAsync().getString(icsTokenKey);
    } catch (_) {
      return false;
    }
    if (expected == null || expected.length < 24) return false;
    return constantTimeEquals(given, expected);
  }

  Future<void> _propfind(HttpRequest req, String path, String depth) async {
    final xml = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="utf-8"?>');

    if (path == '/' || path == '') {
      // 发现链第 1 步：current-user-principal
      xml
        ..writeln(
            '<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">')
        ..writeln('  <d:response>')
        ..writeln('    <d:href>/</d:href>')
        ..writeln('    <d:propstat>')
        ..writeln('      <d:prop>')
        ..writeln(
            '        <d:current-user-principal><d:href>/principals/2bot/</d:href></d:current-user-principal>')
        ..writeln('      </d:prop>')
        ..writeln('      <d:status>HTTP/1.1 200 OK</d:status>')
        ..writeln('    </d:propstat>')
        ..writeln('  </d:response>')
        ..write('</d:multistatus>');
      await _xml207(req, xml.toString());
      return;
    }
    if (path == '/principals/2bot/' || path == '/principals/2bot') {
      // 发现链第 2 步：principal + calendar-home-set（对齐 NAS §6.1 形状）
      xml
        ..writeln(
            '<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">')
        ..writeln('  <d:response>')
        ..writeln('    <d:href>/principals/2bot/</d:href>')
        ..writeln('    <d:propstat>')
        ..writeln('      <d:prop>')
        ..writeln(
            '        <d:current-user-principal><d:href>/principals/2bot/</d:href></d:current-user-principal>')
        ..writeln('        <d:principal-URL><d:href>/principals/2bot/</d:href></d:principal-URL>')
        ..writeln(
            '        <c:calendar-home-set><d:href>/calendars/2bot/</d:href></c:calendar-home-set>')
        ..writeln('        <d:resourcetype><d:principal/></d:resourcetype>')
        ..writeln('        <d:displayname>2bot</d:displayname>')
        ..writeln('      </d:prop>')
        ..writeln('      <d:status>HTTP/1.1 200 OK</d:status>')
        ..writeln('    </d:propstat>')
        ..writeln('  </d:response>')
        ..write('</d:multistatus>');
      await _xml207(req, xml.toString());
      return;
    }
    if (path == '/calendars/2bot/' || path == '/calendars/2bot') {
      // 发现链第 3 步：home 集合（depth 1 时附日历集合）
      xml
        ..writeln(
            '<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/">')
        ..writeln('  <d:response>')
        ..writeln('    <d:href>/calendars/2bot/</d:href>')
        ..writeln('    <d:propstat>')
        ..writeln('      <d:prop>')
        ..writeln('        <d:resourcetype><d:collection/></d:resourcetype>')
        ..writeln('        <d:displayname>Calendars</d:displayname>')
        ..writeln('      </d:prop>')
        ..writeln('      <d:status>HTTP/1.1 200 OK</d:status>')
        ..writeln('    </d:propstat>')
        ..writeln('  </d:response>');
      if (depth != '0') {
        final ctag = store.ctag;
        xml
          ..writeln('  <d:response>')
          ..writeln('    <d:href>/calendars/2bot/default/</d:href>')
          ..writeln('    <d:propstat>')
          ..writeln('      <d:prop>')
          ..writeln(
              '        <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>')
          ..writeln(
              '        <d:displayname>${AppConstants.calendarDisplayName}</d:displayname>')
          ..writeln('        <cs:getctag>$ctag</cs:getctag>')
          ..writeln('        <c:getctag>$ctag</c:getctag>')
          ..writeln('        <d:sync-token>${store.syncToken}</d:sync-token>')
          ..writeln('        <c:supported-calendar-component-set>')
          ..writeln('          <c:comp name="VEVENT"/>')
          ..writeln('        </c:supported-calendar-component-set>')
          ..writeln(
              '        <d:current-user-privilege-set><d:privilege><d:read/></d:privilege><d:privilege><d:read-free-busy/></d:privilege></d:current-user-privilege-set>')
          ..writeln('      </d:prop>')
          ..writeln('      <d:status>HTTP/1.1 200 OK</d:status>')
          ..writeln('    </d:propstat>')
          ..writeln('  </d:response>');
      }
      xml.write('</d:multistatus>');
      await _xml207(req, xml.toString());
      return;
    }
    if (path == '/calendars/2bot/default/' || path == '/calendars/2bot/default') {
      // 日历集合：depth 1 → 集合属性 + 每事件 href/getetag（对齐 NAS §6.3）
      final ctag = store.ctag;
      xml
        ..writeln(
            '<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/">')
        ..writeln('  <d:response>')
        ..writeln('    <d:href>/calendars/2bot/default/</d:href>')
        ..writeln('    <d:propstat>')
        ..writeln('      <d:prop>')
        ..writeln(
            '        <d:resourcetype><d:collection/><c:calendar/></d:resourcetype>')
        ..writeln(
            '        <d:displayname>${AppConstants.calendarDisplayName}</d:displayname>')
        ..writeln('        <cs:getctag>$ctag</cs:getctag>')
        ..writeln('        <c:getctag>$ctag</c:getctag>')
        ..writeln('        <d:sync-token>${store.syncToken}</d:sync-token>')
        ..writeln('        <c:supported-calendar-component-set>')
        ..writeln('          <c:comp name="VEVENT"/>')
        ..writeln('        </c:supported-calendar-component-set>')
        ..writeln(
            '        <d:current-user-privilege-set><d:privilege><d:read/></d:privilege></d:current-user-privilege-set>')
        ..writeln('      </d:prop>')
        ..writeln('      <d:status>HTTP/1.1 200 OK</d:status>')
        ..writeln('    </d:propstat>')
        ..writeln('  </d:response>');
      if (depth != '0') {
        for (final e in store.events.values) {
          final ics = e.toIcs();
          xml
            ..writeln('  <d:response>')
            ..writeln('    <d:href>/calendars/2bot/default/${Uri.encodeComponent(e.uid)}.ics</d:href>')
            ..writeln('    <d:propstat>')
            ..writeln('      <d:prop>')
            ..writeln('        <d:getetag>${store.etagOf(ics)}</d:getetag>')
            ..writeln('      </d:prop>')
            ..writeln('      <d:status>HTTP/1.1 200 OK</d:status>')
            ..writeln('    </d:propstat>')
            ..writeln('  </d:response>');
        }
      }
      xml.write('</d:multistatus>');
      await _xml207(req, xml.toString());
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  Future<void> _report(HttpRequest req, String path, String body) async {
    const base = '/calendars/2bot/default/';
    final xml = StringBuffer();
    final token = store.syncToken;

    if (body.contains('sync-collection')) {
      // RFC 6578 增量同步：全量 + 墓碑 404（对齐 NAS §7.1）
      xml
        ..writeln('<?xml version="1.0" encoding="utf-8"?>')
        ..writeln(
            '<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">')
        ..writeln('  <d:sync-token>$token</d:sync-token>');
      for (final e in store.events.values) {
        final ics = e.toIcs();
        xml
          ..writeln('  <d:response>')
          ..writeln('    <d:href>$base${Uri.encodeComponent(e.uid)}.ics</d:href>')
          ..writeln('    <d:propstat>')
          ..writeln('      <d:prop>')
          ..writeln('        <d:getetag>${store.etagOf(ics)}</d:getetag>')
          ..writeln(
              '        <c:calendar-data>${_escapeXml(_crlf(ics))}</c:calendar-data>')
          ..writeln('      </d:prop>')
          ..writeln('      <d:status>HTTP/1.1 200 OK</d:status>')
          ..writeln('    </d:propstat>')
          ..writeln('  </d:response>');
      }
      for (final uid in store.tombstones.keys) {
        xml
          ..writeln('  <d:response>')
          ..writeln('    <d:href>$base${Uri.encodeComponent(uid)}.ics</d:href>')
          ..writeln('    <d:status>HTTP/1.1 404 Not Found</d:status>')
          ..writeln('  </d:response>');
      }
      xml.write('</d:multistatus>');
      await _xml207(req, xml.toString());
      return;
    }

    if (body.contains('calendar-multiget')) {
      // RFC 4791 multiget：按请求 href 逐个返回（对齐 NAS §7.2）
      final hrefRe = RegExp(r'<(?:[a-zA-Z]+:)?href[^>]*>([^<]+)</(?:[a-zA-Z]+:)?href>');
      final requested =
          hrefRe.allMatches(body).map((m) => m.group(1)!.trim()).toList();
      xml
        ..writeln('<?xml version="1.0" encoding="utf-8"?>')
        ..writeln(
            '<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">');
      for (final href in requested) {
        final name = href.split('/').last.replaceAll(RegExp(r'\.ics$', caseSensitive: false), '');
        final uid = Uri.decodeComponent(name);
        final found = store.events[uid];
        if (found != null) {
          final ics = found.toIcs();
          xml
            ..writeln('  <d:response>')
            ..writeln('    <d:href>$href</d:href>')
            ..writeln('    <d:propstat>')
            ..writeln('      <d:prop>')
            ..writeln('        <d:getetag>${store.etagOf(ics)}</d:getetag>')
            ..writeln(
                '        <c:calendar-data>${_escapeXml(_crlf(ics))}</c:calendar-data>')
            ..writeln('      </d:prop>')
            ..writeln('      <d:status>HTTP/1.1 200 OK</d:status>')
            ..writeln('    </d:propstat>')
            ..writeln('  </d:response>');
        } else {
          xml
            ..writeln('  <d:response>')
            ..writeln('    <d:href>$href</d:href>')
            ..writeln('    <d:status>HTTP/1.1 404 Not Found</d:status>')
            ..writeln('  </d:response>');
        }
      }
      xml.write('</d:multistatus>');
      await _xml207(req, xml.toString());
      return;
    }

    // 7.3 calendar-query（通用/含 time-range 过滤）
    DateTime? rangeStart;
    DateTime? rangeEnd;
    final startM = RegExp(r'<g:start>([^<]+)</g:start>').firstMatch(body);
    final endM = RegExp(r'<g:end>([^<]+)</g:end>').firstMatch(body);
    // time-range 兼容两种形态：子元素 <g:start>…</g:start> 与
    // <g:time-range start="…" end="…"/> 属性（客户端实现不一）
    final trM =
        RegExp(r'<g:time-range[^>]*start="([^"]+)"[^>]*end="([^"]+)"').firstMatch(body);
    DateTime? parseIcsDt(String? v) {
      if (v == null) return null;
      final m = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z?$')
          .firstMatch(v.trim());
      if (m == null) return null;
      return DateTime.utc(
          int.parse(m.group(1)!),
          int.parse(m.group(2)!),
          int.parse(m.group(3)!),
          int.parse(m.group(4)!),
          int.parse(m.group(5)!),
          int.parse(m.group(6)!));
    }
    rangeStart = parseIcsDt(startM?.group(1)) ?? parseIcsDt(trM?.group(1));
    rangeEnd = parseIcsDt(endM?.group(1)) ?? parseIcsDt(trM?.group(2));

    xml
      ..writeln('<?xml version="1.0" encoding="utf-8"?>')
      ..writeln(
          '<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">');
    for (final e in store.events.values) {
      if (rangeEnd != null && e.dtstartMs >= rangeEnd.millisecondsSinceEpoch) {
        continue;
      }
      if (rangeStart != null &&
          (e.endMs ?? e.dtstartMs) <= rangeStart.millisecondsSinceEpoch) {
        continue;
      }
      final ics = e.toIcs();
      xml
        ..writeln('  <d:response>')
        ..writeln('    <d:href>$base${Uri.encodeComponent(e.uid)}.ics</d:href>')
        ..writeln('    <d:propstat>')
        ..writeln('      <d:prop>')
        ..writeln('        <d:getetag>${store.etagOf(ics)}</d:getetag>')
        ..writeln(
            '        <c:calendar-data>${_escapeXml(_crlf(ics))}</c:calendar-data>')
        ..writeln('      </d:prop>')
        ..writeln('      <d:status>HTTP/1.1 200 OK</d:status>')
        ..writeln('    </d:propstat>')
        ..writeln('  </d:response>');
    }
    xml.write('</d:multistatus>');
    await _xml207(req, xml.toString());
  }

  Future<void> _get(HttpRequest req, String path,
      {required bool headOnly}) async {
    if (path == '/calendar.ics') {
      final body = store.renderFullIcs();
      req.response.headers.set('Content-Type', 'text/calendar; charset=utf-8');
      req.response.headers.set('ETag', store.etagOf(body));
      req.response.headers.set(
          'Last-Modified', HttpDate.format(DateTime.now().toUtc()));
      req.response.statusCode = 200;
      if (!headOnly) req.response.write(body);
      await req.response.close();
      return;
    }
    if (path.startsWith('/calendars/2bot/default/') &&
        path.endsWith('.ics')) {
      final name = path.split('/').last.replaceAll('.ics', '');
      final uid = Uri.decodeComponent(name);
      final found = store.events[uid];
      if (found == null) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final body = _crlf(found.toIcs());
      req.response.headers.set('Content-Type', 'text/calendar; charset=utf-8');
      req.response.headers.set('ETag', store.etagOf(found.toIcs()));
      if (found.lastModifiedMs != null) {
        req.response.headers.set('Last-Modified', HttpDate.format(
            DateTime.fromMillisecondsSinceEpoch(found.lastModifiedMs!,
                isUtc: true)));
      }
      req.response.statusCode = 200;
      if (!headOnly) req.response.write(body);
      await req.response.close();
      return;
    }
    if (path == '/' || path == '') {
      req.response.statusCode = 200;
      req.response.headers.set('Content-Type', 'text/plain; charset=utf-8');
      req.response.write('2BOT companion local read-only calendar service');
      await req.response.close();
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  Future<void> _xml207(HttpRequest req, String xml) async {
    req.response.headers.set('Content-Type', 'application/xml; charset=utf-8');
    req.response.statusCode = 207;
    req.response.write(xml);
    await req.response.close();
  }

  /// ICS 行尾统一 CRLF（契约：CRLF 行尾）
  String _crlf(String s) => s.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');

  String _escapeXml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
