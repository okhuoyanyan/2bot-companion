import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:bot_companion/services/calendar_event_store.dart';
import 'package:bot_companion/services/local_caldav_server.dart';
import 'package:bot_companion/services/calendar_local_service.dart';
import 'package:bot_companion/services/storage_service.dart';

const retryWindow = Duration(milliseconds: 80);
const retryInterval = Duration(milliseconds: 20);

LocalCalDavServer shortRetryServer(CalendarEventStore store, String password) =>
    LocalCalDavServer(
        store: store,
        password: password,
        retryWindow: retryWindow,
        retryInterval: retryInterval);

class RecordingPortServer extends LocalCalDavServer {
  final List<Duration?> windows;
  RecordingPortServer(CalendarEventStore store, String password, this.windows,
      void Function(int, bool) onUnavailable)
      : super(
            store: store,
            password: password,
          retryWindow: const Duration(milliseconds: 80),
          retryInterval: const Duration(milliseconds: 20),
            onPortUnavailable: onUnavailable);

  @override
  Future<void> start({int preferredPort = 18080, Duration? retryFor}) {
    windows.add(retryFor);
    return super.start(preferredPort: preferredPort, retryFor: retryFor);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData(const {});
  });

  test('WO102: 18080 被占用时不静默服务于另一个端口', () async {
    final blocker =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 18080);
    final server = shortRetryServer(CalendarEventStore(), 'test-only-pass');
    addTearDown(() async {
      await server.stop();
      await blocker.close();
    });
    await server.start();
    expect(server.isRunning, isFalse, reason: '占用超窗应未运行，禁止顺延到 ${server.port}');
    expect(server.port, 0);
    final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 18081);
    await unused.close();
  });

  test('WO102: 默认窗口 60s、间隔 500ms；测试均注入短窗口', () {
    expect(LocalCalDavServer.defaultRetryWindow, const Duration(seconds: 60));
    expect(LocalCalDavServer.defaultRetryInterval,
        const Duration(milliseconds: 500));
  });

  test('WO102: 窗内释放占用后同一次 start 接管 18080', () async {
    final blocker =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 18080);
    final server = shortRetryServer(CalendarEventStore(), 'test-only-pass');
    final unavailable = Completer<void>();
    final observed = LocalCalDavServer(
        store: server.store,
        password: server.password,
        retryInterval: retryInterval,
        retryWindow: const Duration(seconds: 1),
        onPortUnavailable: (_, exhausted) {
          if (!exhausted && !unavailable.isCompleted) unavailable.complete();
        });
    addTearDown(() async {
      await observed.stop();
      await blocker.close();
    });
    final start = observed.start();
    await unavailable.future;
    expect(observed.isRunning, isFalse);
    await blocker.close();
    await start;
    expect(observed.isRunning, isTrue);
    expect(observed.port, 18080);
  });

  test('WO102 G1: 超窗后的每个 tick 立即尝试；释放后下一 tick 接管', () async {
    final blocker =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 18080);
    var failures = 0;
    var servers = 0;
    final windows = <Duration?>[];
    final local = CalendarLocalService.forTesting(serverFactory: (store, pass) {
      servers++;
      return RecordingPortServer(store, pass, windows, (_, exhausted) {
        if (!exhausted) failures++;
      });
    });
    addTearDown(() async {
      await local.ensureStopped();
      await blocker.close();
    });
    await StorageService.saveCalendarSyncState(
        {'mode': 'idle', 'lastResult': 'ok'});
    await local.ensureStarted();
    expect(local.isRunning, isFalse);
    expect(local.port, 0);
    final degraded = await StorageService.loadCalendarSyncStateFresh();
    expect(degraded['serverRunning'], isFalse);
    expect(degraded['serverPort'], 0);
    expect(degraded['mode'], 'idle');
    final initialFailures = failures;
    // This tick must attempt, finish immediately while still occupied, and
    // not enter another multi-attempt retry window (G1).
    await local.ensureStarted();
    expect(servers, 2);
    expect(failures, initialFailures + 1);
    expect(windows, [null, Duration.zero], reason: '降级 tick 必须立即重绑，不再进入初始重试窗口');
    await blocker.close();
    await local.ensureStarted();
    expect(servers, 3);
    expect(windows.last, Duration.zero);
    expect(local.isRunning, isTrue);
    expect(local.port, 18080);
    final recovered = await StorageService.loadCalendarSyncStateFresh();
    expect(recovered['serverRunning'], isTrue);
    expect(recovered['serverPort'], 18080);
    expect(recovered['lastResult'], 'ok');
  });

  test('WO102: 历史漂移在占用时告警，释放后热切归位且保留库和凭据', () async {
    final blocker =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 18080);
    final store = CalendarEventStore()
      ..applyUpserts([
        {
          'uid': 'wo102-event',
          'sequence': 1,
          'dtstartMs': DateTime.now().millisecondsSinceEpoch,
          'summary': 'port test'
        }
      ]);
    final legacy = shortRetryServer(store, 'test-only-pass');
    await legacy.start(preferredPort: 18081);
    final local = CalendarLocalService.forTesting(initialServer: legacy);
    final warnings = <String>[];
    addTearDown(() async {
      await local.ensureStopped();
      await blocker.close();
    });
    await runZoned(() => local.ensureStarted(),
        zoneSpecification:
            ZoneSpecification(print: (_, __, ___, line) => warnings.add(line)));
    expect(warnings.any((s) => s.contains('WARNING') && s.contains('18081')),
        isTrue);
    expect(warnings.any((s) => s.contains('retry exhausted')), isTrue);
    expect(warnings.join('\n'), isNot(contains(legacy.password)));
    expect(local.port, 18081);
    expect(legacy.isRunning, isTrue);
    final drifted = await StorageService.loadCalendarSyncStateFresh();
    expect(drifted['serverRunning'], isTrue);
    expect(drifted['serverPort'], 18081);
    await blocker.close();
    await local.ensureStarted();
    expect(local.port, 18080);
    expect(legacy.isRunning, isFalse);
    expect(identical(local.store, store), isTrue);
    expect(local.store.events.containsKey('wo102-event'), isTrue);
    expect(local.password, 'test-only-pass');
  });

  test('WO102: 同时 ensureStarted 只有一条绑定链；停止取消重试且不复活', () async {
    final blocker =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 18080);
    final unavailable = Completer<void>();
    var created = 0;
    final local = CalendarLocalService.forTesting(serverFactory: (store, pass) {
      created++;
      return LocalCalDavServer(
          store: store,
          password: pass,
          retryWindow: const Duration(seconds: 1),
          retryInterval: retryInterval,
          onPortUnavailable: (_, __) {
            if (!unavailable.isCompleted) unavailable.complete();
          });
    });
    addTearDown(() async {
      await local.ensureStopped();
      await blocker.close();
    });
    final first = local.ensureStarted();
    final second = local.ensureStarted();
    await unavailable.future;
    await local.ensureStopped();
    await Future.wait([first, second]);
    expect(created, 1);
    await blocker.close();
    expect(local.isRunning, isFalse);
    expect(local.port, 0);
    final stopped = await StorageService.loadCalendarSyncStateFresh();
    expect(stopped['serverRunning'], isFalse);
    expect(stopped['serverPort'], 0);
    await local.ensureStarted();
    expect(local.port, 18080);
    expect(created, 2);
  });
}
