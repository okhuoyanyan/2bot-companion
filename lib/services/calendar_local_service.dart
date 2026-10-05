import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:meta/meta.dart';

import 'calendar_event_store.dart';
import 'local_caldav_server.dart';
import 'storage_service.dart';

/// ============================================================================
/// WO-70 · 本机只读服务生命周期 + 事件库宿主（后台任务 isolate 内运行）
/// ===========================================================================
/// 服务运行与 IMAP 会话解耦：开关开即启动（IMAP 失败不影响对外服务）。=
/// 单例持有事件库与 HttpServer；IMAP 同步管线经 [EventStoreCalendarGateway]
/// 写入事件库；服务对系统日历（ICS URL 订阅）与 KashCal（CalDAV）提供只读出口。

class CalendarLocalService {
  CalendarLocalService._internal();
  static final CalendarLocalService instance = CalendarLocalService._internal();

  @visibleForTesting
  CalendarLocalService.forTesting({
    LocalCalDavServer? initialServer,
    LocalCalDavServer Function(CalendarEventStore, String)? serverFactory,
  }) : _serverFactory = serverFactory {
    if (initialServer != null) {
      _server = initialServer;
      store = initialServer.store;
      password = initialServer.password;
      username = '2bot';
      _loaded = true;
    }
  }

  CalendarEventStore store = CalendarEventStore();
  LocalCalDavServer? _server;
  LocalCalDavServer? _pendingServer;
  LocalCalDavServer Function(CalendarEventStore, String)? _serverFactory;
  Future<void>? _starting;
  Future<void>? _stopping;
  bool _loaded = false;
  bool _degraded = false;
  int _generation = 0;

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
    const chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    return List.generate(12, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  /// 18080 is the client contract. Subsequent degraded ticks bind once,
  /// immediately; only the initial start waits through the 60s retry window.
  Future<void> ensureStarted() {
    if (_stopping != null) return _stopping!.then((_) => ensureStarted());
    if (_starting != null) return _starting!;
    if (isRunning && port == LocalCalDavServer.contractPort) {
      return Future<void>.value();
    }
    final future = _ensureStarted(_generation);
    _starting = future;
    return future.whenComplete(() {
      if (identical(_starting, future)) _starting = null;
    });
  }

  void _portUnavailable(int requestedPort, bool exhausted) {
    // Only port and lifecycle status: never interpolate credentials/errors.
    // ignore: avoid_print
    print(exhausted
        ? '[WO102] WARNING port=$requestedPort retry exhausted; degraded; next tick retries immediately'
        : '[WO102] WARNING port=$requestedPort unavailable; retrying same port');
  }

  Future<void> _publishState() async {
    final state = await StorageService.loadCalendarSyncStateAsync();
    state['serverRunning'] = isRunning;
    state['serverPort'] = port;
    state['serverUser'] = username;
    state['serverPass'] = password;
    state['storeCount'] = store.events.length;
    await StorageService.saveCalendarSyncState(state);
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kServerPort, port);
  }

  Future<void> _ensureStarted(int generation) async {
    final drifted = isRunning && port != LocalCalDavServer.contractPort;
    if (drifted) {
      _degraded = true;
      // ignore: avoid_print
      print('[WO102] WARNING port=$port drifted; reclaiming 18080');
    }
    if (!_loaded) {
      await load();
      _loaded = true;
    }
    if (generation != _generation) return;
    final pass = password ?? _generatePassword();
    password = pass;
    await SharedPreferences.getInstance()
        .then((p) => p.setString(_kCalPass, pass));
    if (generation != _generation) return;
    await _publishState();
    if (generation != _generation) return;
    final server = _serverFactory?.call(store, pass) ??
        LocalCalDavServer(
            store: store, password: pass, onPortUnavailable: _portUnavailable);
    _pendingServer = server;
    try {
      await server.start(retryFor: _degraded ? Duration.zero : null);
      if (generation != _generation) {
        await server.stop();
        return;
      }
      if (server.isRunning) {
        final previous = _server;
        _server = server;
        await previous?.stop();
        final recovered = _degraded;
        _degraded = false;
        // ignore: avoid_print
        print('[WO102] ${recovered ? "RECOVERED" : "READY"} port=18080');
      } else {
        _degraded = true;
      }
      await _publishState();
    } finally {
      if (identical(_pendingServer, server)) _pendingServer = null;
    }
  }

  Future<void> ensureStopped() {
    if (_stopping != null) return _stopping!;
    _generation++;
    final future = _ensureStopped();
    _stopping = future;
    return future.whenComplete(() {
      if (identical(_stopping, future)) _stopping = null;
    });
  }

  Future<void> _ensureStopped() async {
    await _pendingServer?.stop();
    await _starting;
    await _server?.stop();
    _server = null;
    _degraded = false;
    await _publishState();
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
