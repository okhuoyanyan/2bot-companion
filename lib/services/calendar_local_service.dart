import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'calendar_event_store.dart';
import 'local_caldav_server.dart';

/// ============================================================================
/// WO-70 · 本机只读服务生命周期 + 事件库宿主（后台任务 isolate 内运行）
/// ===========================================================================
/// 服务运行与 IMAP 会话解耦：开关开即启动（IMAP 失败不影响对外服务）。=
/// 单例持有事件库与 HttpServer；IMAP 同步管线经 [EventStoreCalendarGateway]
/// 写入事件库；服务对系统日历（ICS URL 订阅）与 KashCal（CalDAV）提供只读出口。


class CalendarLocalService {
  CalendarLocalService._internal();
  static final CalendarLocalService instance = CalendarLocalService._internal();

  CalendarEventStore store = CalendarEventStore();
  LocalCalDavServer? _server;

  bool get isRunning => _server?.isRunning ?? false;
  int get port => _server?.port ?? 0;
  String? username; // 固定 '2bot'
  String? password;

  static const String _kStore = 'pref_calendar_event_store';
  static const String _kCalUser = 'pref_calendar_user';
  static const String _kCalPass = 'pref_calendar_pass';
  static const String _kServerPort = 'pref_calendar_server_port';

  /// 读取库 + 凭据（幂等；后台 isolate 启动时调用）
  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kStore);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = json.decode(raw);
        if (decoded is Map<String, dynamic>) {
          store = CalendarEventStore.fromJson(decoded);
        }
      } catch (_) {}
    }
    username = p.getString(_kCalUser) ?? '2bot';
    password ??= p.getString(_kCalPass);
    if (password == null || password!.length < 12) {
      password = _generatePassword();
      await p.setString(_kCalPass, password!);
    }
    await p.setString(_kCalUser, username!);
  }

  String _generatePassword() {
    const chars =
        'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    return List.generate(12, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  /// 启动本机服务（幂等；端口占用自动顺延并回写实际端口供 UI 显示）
  Future<void> ensureStarted() async {
    if (isRunning) return;
    await load();
    final pass = password ?? _generatePassword();
    password = pass;
    await SharedPreferences.getInstance()
        .then((p) => p.setString(_kCalPass, pass));
    final server = LocalCalDavServer(store: store, password: pass);
    await server.start();
    _server = server;
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kServerPort, server.port);
  }

  Future<void> ensureStopped() async {
    await _server?.stop();
    _server = null;
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kServerPort, 0);
  }

  /// 应用一批事件并持久化（同步管线调用）
  Future<({int applied, int removed, int inStore})> applyAndPersist(
      List<Map<String, dynamic>> events) async {
    final r = store.applyUpserts(events);
    final p = await SharedPreferences.getInstance();
    await p.setString(_kStore, json.encode(store.toJson()));
    return (applied: r.applied, removed: r.removed, inStore: store.events.length);
  }
}
