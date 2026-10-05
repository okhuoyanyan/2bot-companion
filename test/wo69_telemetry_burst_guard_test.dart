import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:bot_companion/models/app_settings.dart';
import 'package:bot_companion/models/device_telemetry.dart';
import 'package:bot_companion/services/calendar_sync_service.dart';
import 'package:bot_companion/services/cross_isolate_lock.dart';
import 'package:bot_companion/services/imap_idle_client.dart';
import 'package:bot_companion/services/storage_service.dart';
import 'package:bot_companion/services/telemetry_mail_transport.dart';
import 'package:bot_companion/services/telemetry_throttle_scheduler.dart';
import 'package:bot_companion/services/telemetry_uploader_service.dart';

import 'calendar_sync_service_test.dart' show FakeGateway, FakeSource, scan;

/// ============================================================================
/// WO-69 · 突发旁路防御单测（追补整改 + 驳回整改 + 第三轮整改 P1/P2）
/// ============================================================================
/// 三道闸：闸A SMTP 正文出网后禁止重试；闸B 调度层载荷去重；闸C 失败冷却 +
/// 白名单同类限频 + SMTP 跨 isolate 串行（OS 级文件锁）。全部零真连。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WO-105 OS 锁防复发', () {
    test('真实 isolate 排队、临界区心跳、无关句柄关闭不提前放锁', () async {
      final tmp = await Directory.systemTemp.createTemp('wo105_lock_');
      lockDirOverride = tmp.path;
      final release = Completer<void>();
      final entered = Completer<void>();
      final signals = ReceivePort();
      final firstAction = Completer<String>();
      var contenderEntered = false;
      var heartbeats = 0;
      final subscription = signals.listen((message) {
        if (message == 'entered') contenderEntered = true;
        if (!firstAction.isCompleted) firstAction.complete(message as String);
      });
      final heartbeat = Timer.periodic(const Duration(milliseconds: 10), (_) {
        heartbeats++;
      });
      final holder = crossIsolateSynchronized('guard', () async {
        entered.complete();
        await release.future;
      });
      Future<void>? contender;
      try {
        await entered.future.timeout(const Duration(seconds: 2));
        contender = _wo105SpawnContender(tmp.path, signals.sendPort);
        expect(await firstAction.future.timeout(const Duration(seconds: 2)),
            'retry', reason: '真实 isolate 必须遇到 OS 锁竞争，不能重入');
        final unrelated = await File('${tmp.path}/wo69_guard.lock')
            .open(mode: FileMode.append);
        await unrelated.close();
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(contenderEntered, isFalse,
            reason: '同文件无关句柄关闭不得解除持有者锁');
        expect(heartbeats, greaterThanOrEqualTo(3),
            reason: '锁竞争期间事件循环必须持续响应');
        release.complete();
        await Future.wait([holder, contender]).timeout(const Duration(seconds: 3));
        expect(contenderEntered, isTrue, reason: '释放后排队者必须接管');
        print('[WO105] OS guard queued=true unrelatedCloseSafe=true '
            'heartbeats=$heartbeats takeover=$contenderEntered');
      } finally {
        if (!release.isCompleted) release.complete();
        await holder;
        if (contender != null) await contender;
        heartbeat.cancel();
        await subscription.cancel();
        signals.close();
        lockDirOverride = null;
        await tmp.delete(recursive: true);
        expect(tmp.existsSync(), isFalse);
      }
    });

    test('Unicode 锁路径异常释放后可重获，重复调用无残留 fd', () async {
      final tmp = await Directory.systemTemp.createTemp('wo105_临界_😀_');
      lockDirOverride = tmp.path;
      var bodies = 0;
      var retries = 0;
      try {
        for (var i = 0; i < 20; i++) {
          await expectLater(crossIsolateSynchronized<void>('临界_😀', () async {
            if (Platform.isLinux) {
              expect(_wo105OpenLockDescriptors(tmp.path), 1,
                  reason: '临界区持有真实 OS fd');
            }
            throw StateError('controlled failure');
          }), throwsStateError);
          await crossIsolateSynchronized('临界_😀', () async {
            bodies++;
          }, sleep: (_) async { retries++; });
          if (Platform.isLinux) {
            expect(_wo105OpenLockDescriptors(tmp.path), 0,
                reason: '异常与正常路径均不得泄漏锁 fd');
          }
        }
        expect(bodies, 20);
        expect(retries, 0, reason: '每轮异常都必须释放锁，下一调用立即取得');
        print('[WO105] Unicode lock exceptionLoops=20 reacquired=$bodies '
            'retries=$retries remainingLockFds='
            '${Platform.isLinux ? _wo105OpenLockDescriptors(tmp.path) : 'not-applicable'}');
      } finally {
        lockDirOverride = null;
        await tmp.delete(recursive: true);
        expect(tmp.existsSync(), isFalse);
      }
    });

    test('不同锁名可并行，不能以全局互斥替代 OS 文件锁', () async {
      final tmp = await Directory.systemTemp.createTemp('wo105_names_');
      lockDirOverride = tmp.path;
      final bothEntered = Completer<void>();
      final release = Completer<void>();
      var count = 0;
      Future<void> worker(String name) => crossIsolateSynchronized(name, () async {
        if (++count == 2) bothEntered.complete();
        await release.future;
      });
      final workers = Future.wait([worker('one'), worker('two')]);
      try {
        await bothEntered.future.timeout(const Duration(seconds: 2));
        expect(count, 2);
      } finally {
        release.complete();
        await workers;
        lockDirOverride = null;
        await tmp.delete(recursive: true);
        expect(tmp.existsSync(), isFalse);
      }
    });
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.init();
    SmtpMailer.resetForTest();
  });

  group('闸A：SMTP 正文出网后不重试（防同 payload 重复投递）', () {
    test('SmtpSession：正文命令产出即 messageTransmitted=true', () {
      final s = SmtpSession(
        clientName: 't',
        account: 'a@example.invalid',
        authCode: 'FIXTURE',
        from: 'a@example.invalid',
        to: 'a@example.invalid',
        message: 'H\r\n\r\nB',
      );
      expect(s.messageTransmitted, isFalse, reason: '正文未出网前不得标记');
      s.onResponseLine('220 ready');
      s.onResponseLine('250 ok');
      s.onResponseLine('334 u');
      s.onResponseLine('334 p');
      s.onResponseLine('235 ok');
      s.onResponseLine('250 ok');
      s.onResponseLine('250 ok');
      s.onResponseLine('354 end data');
      expect(s.messageTransmitted, isTrue, reason: '正文命令一经产出即视为已出网（不可重试）');
    });

    test('resolveSendFailure：正文出网后任何异常 → 不重试、按已投递返回', () {
      final s = SmtpSession(
        clientName: 't',
        account: 'a@example.invalid',
        authCode: 'FIXTURE',
        from: 'a@example.invalid',
        to: 'a@example.invalid',
        message: 'B',
      );
      s.onResponseLine('220 ready');
      s.onResponseLine('250 ok');
      s.onResponseLine('334 u');
      s.onResponseLine('334 p');
      s.onResponseLine('235 ok');
      s.onResponseLine('250 ok');
      s.onResponseLine('250 ok');
      s.onResponseLine('354 end data'); // 正文出网，250 永不到达（被限流时恰恰如此）

      final resolved =
          SmtpMailer.resolveSendFailure(s, 'TimeoutException after 5s', 1, false);
      expect(resolved, isNotNull, reason: '不得返回 null（返回 null = 允许重试 = 重复投递）');
      expect(resolved!.success, isTrue,
          reason: '按已投递返回：调度层据此推进水位，杜绝 535 自锁');
      expect(resolved.attempts, 1);
    });

    test('resolveSendFailure：正文未出网（如 AUTH 被 535 拒）→ 允许重试', () {
      final s = SmtpSession(
        clientName: 't',
        account: 'a@example.invalid',
        authCode: 'FIXTURE',
        from: 'a@example.invalid',
        to: 'a@example.invalid',
        message: 'B',
      );
      s.onResponseLine('220 ready');
      s.onResponseLine('250 ok');
      s.onResponseLine('535 rate limited');
      expect(s.messageTransmitted, isFalse);
      expect(
        SmtpMailer.resolveSendFailure(s, 'SMTP 阶段 2 期望响应码 334，实际收到 535', 1, true),
        isNull,
        reason: '正文未出网 → 走既有重试路径（全新会话，非同 payload 重复投递）',
      );
    });

    test('最小会话间隔：连续两次 send，第二次等待 ≥ minSessionGap', () async {
      final delays = <Duration>[];
      var now = DateTime(2026, 9, 27, 3);
      SmtpMailer.nowProvider = () => now;
      SmtpMailer.delayProvider = (d) async {
        delays.add(d);
        now = now.add(d);
      };
      try {
        await SmtpMailer.send(
          config:
              const MailAccountConfig(account: 'a@example.invalid', authCode: 'X'),
          subject: 'S1',
          body: 'B',
          connectTimeout: const Duration(milliseconds: 50),
        );
        await SmtpMailer.send(
          config:
              const MailAccountConfig(account: 'a@example.invalid', authCode: 'X'),
          subject: 'S2',
          body: 'B',
          connectTimeout: const Duration(milliseconds: 50),
        );
        expect(delays.any((d) => d == SmtpMailer.minSessionGap), isTrue,
            reason: '第二次会话必须等满最小间隔（同秒连发被结构性排除）');
      } finally {
        SmtpMailer.nowProvider = DateTime.now;
        SmtpMailer.delayProvider = Future<void>.delayed;
      }
    });
  });

  group('闸B：调度层载荷去重（非白名单路径；白名单/保活豁免）', () {
    late TelemetryThrottleScheduler scheduler;
    late int uploadCount;
    DateTime fakeNow = DateTime(2026, 9, 27, 4);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.init();
      scheduler = TelemetryThrottleScheduler.instance;
      scheduler.resetForTest();
      scheduler.isBackgroundOwner = true; // 闸B 用例模拟后台发送者
      uploadCount = 0;
      fakeNow = DateTime(2026, 9, 27, 4);
      scheduler.nowProvider = () => fakeNow;
      scheduler.snapshotCollector = ({bool isAppForeground = false}) async =>
          createSnap(batteryLevel: 85, app: 'com.a');
      scheduler.uploader = (snapshot) async {
        uploadCount++;
        return UploadResult(success: true, statusCode: 200, message: 'OK');
      };
    });

    test('同状态快照（timestamp 除外）窗口过期后仍不重投（去重窗口 10 分钟）', () async {
      final settings = AppSettings(throttleIntervalSeconds: 1);
      await scheduler.triggerEvent(TelemetryTrigger.power,
          settingsOverride: settings);
      expect(uploadCount, 1);

      fakeNow = fakeNow.add(const Duration(seconds: 2));
      await scheduler.triggerEvent(TelemetryTrigger.power,
          settingsOverride: settings);
      expect(uploadCount, 1, reason: '同一 payload 不得重复投递（急件②）');
      expect(scheduler.dedupSkippedCount, 1);
    });

    test('状态真实变化 → 正常投递（去重不得吞掉真事件）', () async {
      final settings = AppSettings(throttleIntervalSeconds: 1);
      await scheduler.triggerEvent(TelemetryTrigger.power,
          settingsOverride: settings);
      expect(uploadCount, 1);

      scheduler.snapshotCollector = ({bool isAppForeground = false}) async =>
          createSnap(batteryLevel: 85, app: 'com.b');
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      await scheduler.triggerEvent(TelemetryTrigger.appSwitch,
          settingsOverride: settings);
      expect(uploadCount, 2);
    });

    test('去重窗口过期（快进 11 分钟）→ 允许重投', () async {
      final settings = AppSettings(throttleIntervalSeconds: 1);
      await scheduler.triggerEvent(TelemetryTrigger.power,
          settingsOverride: settings);
      expect(uploadCount, 1);

      fakeNow = fakeNow.add(const Duration(minutes: 11));
      await scheduler.triggerEvent(TelemetryTrigger.power,
          settingsOverride: settings);
      expect(uploadCount, 2, reason: '去重窗口过期后允许重投');
    });

    test('静默保活豁免去重（无变化也必须报，WO-37 契约）', () async {
      final settings = AppSettings(throttleIntervalSeconds: 1);
      await scheduler.triggerEvent(TelemetryTrigger.silenceTimeout,
          settingsOverride: settings);
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      await scheduler.triggerEvent(TelemetryTrigger.silenceTimeout,
          settingsOverride: settings);
      expect(uploadCount, 2, reason: '保活若被去重，NAS 无法区分安静与离线');
    });
  });

  group('驳回缺陷一：白名单同类限频 + SMTP 跨 isolate 串行', () {
    test('白名单同类事件 60s 限频：第二次并入合并路径（WiFi/电量抖动不再连发）', () async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.init();
      final scheduler = TelemetryThrottleScheduler.instance;
      scheduler.resetForTest();
      scheduler.isBackgroundOwner = true; // 模拟后台发送者
      var n = 0;
      DateTime fakeNow = DateTime(2026, 9, 27, 6);
      scheduler.nowProvider = () => fakeNow;
      var ssid = 'Home_5G';
      scheduler.snapshotCollector = ({bool isAppForeground = false}) async =>
          createSnap(batteryLevel: 85, app: 'com.a', ssid: ssid);
      scheduler.uploader = (snapshot) async {
        n++;
        return UploadResult(success: true, statusCode: 200, message: 'OK');
      };

      final settings = AppSettings();
      await scheduler.triggerEvent(TelemetryTrigger.location,
          settingsOverride: settings);
      expect(n, 1, reason: '首次到家/离家立即发');

      // SSID 抖动（内容不同，去重拦不住）→ 同类白名单 60s 限频命中 → 并入合并路径
      ssid = 'Home_5G_2';
      await scheduler.triggerEvent(TelemetryTrigger.location,
          settingsOverride: settings);
      expect(n, 1, reason: '60s 内同类白名单事件不得立即连发（驳回缺陷一实测 5-30s 一封的来源）');
      expect(scheduler.isDirty, isTrue, reason: '事件标脏，窗口期满合并发出');

      fakeNow = fakeNow.add(const Duration(seconds: 61));
      await scheduler.triggerEvent(TelemetryTrigger.location,
          settingsOverride: settings);
      expect(n, 2);
    });

    test('SMTP 会话间隔闸：第二次 send 的首个等待 = minSessionGap', () async {
      final delays = <Duration>[];
      var now = DateTime(2026, 9, 27, 7);
      SmtpMailer.nowProvider = () => now;
      SmtpMailer.delayProvider = (d) async {
        delays.add(d);
        now = now.add(d);
      };
      try {
        await SmtpMailer.send(
          config:
              const MailAccountConfig(account: 'a@example.invalid', authCode: 'X'),
          subject: 'S1',
          body: 'B',
          connectTimeout: const Duration(milliseconds: 50),
        );
        await SmtpMailer.send(
          config:
              const MailAccountConfig(account: 'a@example.invalid', authCode: 'X'),
          subject: 'S2',
          body: 'B',
          connectTimeout: const Duration(milliseconds: 50),
        );
        // 第一次 send 的等待 = 会话内重试退避 1s/3s；第二次 send 的首个等待 = 会话间隔闸 3s
        expect(delays.length, greaterThanOrEqualTo(3));
        expect(delays[2], SmtpMailer.minSessionGap,
            reason: '同秒 ×2 被结构性排除（会话间隔闸强制 3s），事件不丢');
      } finally {
        SmtpMailer.nowProvider = DateTime.now;
        SmtpMailer.delayProvider = Future<void>.delayed;
      }
    });
  });

  group('驳回缺陷二：首次全量分批 + 幂等续传', () {
    test('120 条事件 → 分 3 批（50/50/20）逐批记台账', () async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.init();
      final scheduler = TelemetryThrottleScheduler.instance;
      scheduler.resetForTest();
      const crlf = '\r\n';
      final ics = StringBuffer('BEGIN:VCALENDAR$crlf');
      for (var i = 0; i < 120; i++) {
        ics.write('BEGIN:VEVENT$crlf'
            'UID:cal_$i$crlf'
            'DTSTART:20260928T090000Z$crlf'
            'DURATION:PT1H$crlf'
            'END:VEVENT$crlf');
      }
      ics.write('END:VCALENDAR$crlf');
      final encoded = base64.encode(utf8.encode(ics.toString()));
      final raw = 'Subject: X-2BOT-CAL-20260927-1000$crlf'
          'Content-Type: multipart/mixed; boundary=B$crlf$crlf'
          '--B$crlf'
          'Content-Type: text/calendar; name=calendar.ics$crlf'
          'Content-Transfer-Encoding: base64$crlf$crlf'
          '$encoded$crlf--B--$crlf';
      final source = FakeSource(
        uidValidity: 1,
        result: scan(
          [CalendarMail(uid: 900, subject: 'cal', raw: raw)],
          900,
        ),
      );
      final batches = <List<Map<String, dynamic>>>[];
      final svc = CalendarSyncService.test(
        settingsProvider: () => AppSettings(
          calendarSyncEnabled: true,
          mailAccount: 'fixture@example.invalid',
          mailAuthCode: 'FIXTURE',
        ),
        sourceFactory: (_) => source,
        gateway: FakeGateway(onUpsert: (batch) => batches.add(batch)),
      );
      await svc.debugSyncIncrement(source, 0);
      expect(batches.length, 3, reason: '120 条 → 50/50/20 三批（单批过重=驳回缺陷二(b)）');
      expect(batches[0].length, 50);
      expect(batches[1].length, 50);
      expect(batches[2].length, 20);
      final ledger = StorageService.loadCalendarEventLedger();
      expect(ledger.length, 120, reason: '逐批记台账，中断可幂等续传');
      expect(StorageService.loadCalendarWatermark().lastProcessedUid, 900);
    });
  });

  group('裸奔口收口：前台刷新走调度器（triggerTelemetryRefresh）', () {
    test('同状态连跳 → 只投一次；状态变化 → 正常投递', () async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.init();
      final scheduler = TelemetryThrottleScheduler.instance;
      scheduler.resetForTest();
      scheduler.isBackgroundOwner = true; // 验证后台路径的去重合并
      var app = 'com.x';
      fakeClock = DateTime(2026, 9, 27, 5);
      scheduler.nowProvider = () => fakeClock;
      scheduler.snapshotCollector = ({bool isAppForeground = false}) async =>
          createSnap(batteryLevel: 60, app: app);
      var n = 0;
      scheduler.uploader = (snapshot) async {
        n++;
        return UploadResult(success: true, statusCode: 200, message: 'OK');
      };

      await scheduler.triggerTelemetryRefresh();
      expect(n, 1);
      fakeClock = fakeClock.add(const Duration(seconds: 2));
      await scheduler.triggerTelemetryRefresh();
      expect(n, 1, reason: '同状态刷新必须被去重合并');
      fakeClock = fakeClock.add(const Duration(seconds: 2));
      await scheduler.triggerTelemetryRefresh();
      expect(n, 1);

      app = 'com.y';
      fakeClock = fakeClock.add(const Duration(seconds: 91));
      await scheduler.triggerTelemetryRefresh();
      expect(n, 2);
    });
  });

  group('P2 强制项：跨 isolate 真并发（OS 级锁竞争，架构师指定）', () {
    test('双 isolate 同时 send → 会话建立时刻间隔 ≥ minSessionGap（零同秒）', () async {
      final tmp = await Directory.systemTemp.createTemp('wo69_gate_test');
      lockDirOverride = tmp.path;
      final logBase = '${tmp.path}/sessions';
      Future<void> isolateEntry(String id) async {
        lockDirOverride = tmp.path;
        SmtpMailer.resetForTest();
        final ownLog = '$logBase-$id';
        SmtpMailer.socketFactoryForTest = (host, port, timeout) async {
          // 会话建立即记录真实墙钟（每 isolate 独立日志，规避并发 append 竞争）
          await File(ownLog).writeAsString(
              '${DateTime.now().microsecondsSinceEpoch}',
              mode: FileMode.write,
              flush: true);
          throw StateError('connection refused (test stub)');
        };
        await SmtpMailer.send(
          config:
              const MailAccountConfig(account: 'a@example.invalid', authCode: 'X'),
          subject: 'S',
          body: 'B',
          backoff: const [],
          connectTimeout: const Duration(milliseconds: 50),
        );
      }

      try {
        // 两个【真实 isolate】同时发起（静态门闸按 isolate 隔离，正是被测竞争面）
        final reports = await Future.wait([
          Isolate.run(() => isolateEntry('A').then((_) => '$logBase-A')),
          Isolate.run(() => isolateEntry('B').then((_) => '$logBase-B')),
        ]);
        final stamps = <int>[];
        for (final f in reports) {
          final line = await File(f).readAsString();
          stamps.add(int.parse(line.trim()));
        }
        stamps.sort();
        expect(stamps.length, 2, reason: '两个 isolate 各一次会话建立');
        final gapUs = stamps[1] - stamps[0];
        // 100ms 容差：Timer 舍入抖动（语义=约 3s 串行，杜绝同秒）
        expect(gapUs,
            greaterThanOrEqualTo(
                SmtpMailer.minSessionGap.inMicroseconds - 100000),
            reason: 'OS 级文件锁保证双 isolate 会话严格串行——同秒 ×2 结构性排除'
                '（实测间隔 ${gapUs / 1e6}s）');
      } finally {
        lockDirOverride = null;
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    });
  });

  group('P1：lastSyncAt 只在成功时推进（尝试/成功分离）', () {
    test('通道写失败 → lastSyncAt 不得被伪报；恢复成功后才推进', () async {
      SharedPreferences.setMockInitialValues({});
      // 本用例显式重挂 Async 内存平台（写端走 SharedPreferencesAsync，读端须同存储）
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(const {});
      StorageService.resetForTest();
      await StorageService.init();
      final scheduler = TelemetryThrottleScheduler.instance;
      scheduler.resetForTest();
      Object? thrown;
      var fail = true;
      const crlf = '\r\n';
      final p1Ics = 'BEGIN:VCALENDAR$crlf'
          'BEGIN:VEVENT$crlf'
          'UID:cal_p1$crlf'
          'SEQUENCE:0$crlf'
          'DTSTART:20260928T090000Z$crlf'
          'DURATION:PT1H$crlf'
          'END:VEVENT$crlf'
          'END:VCALENDAR$crlf';
      final p1MailRaw = 'Subject: X-2BOT-CAL-20260927-1100$crlf'
          'Content-Type: multipart/mixed; boundary=B$crlf$crlf'
          '--B$crlf'
          'Content-Type: text/calendar; name=calendar.ics$crlf'
          'Content-Transfer-Encoding: base64$crlf$crlf'
          '${base64.encode(utf8.encode(p1Ics))}$crlf'
          '--B--$crlf';
      final source = FakeSource(
        uidValidity: 1,
        result: scan(
          [CalendarMail(uid: 910, subject: 'cal', raw: p1MailRaw)],
          910,
        ),
      );
      final svc = CalendarSyncService.test(
        settingsProvider: () => AppSettings(
          calendarSyncEnabled: true,
          mailAccount: 'fixture@example.invalid',
          mailAuthCode: 'FIXTURE',
        ),
        sourceFactory: (_) => source,
        gateway: FakeGateway(onUpsert: (batch) {
          if (fail) throw StateError('通道未激活(模拟)');
        }),
      );
      await svc.debugSyncIncrement(source, 0).catchError((e) {
        thrown = e;
        return 0;
      });
      expect(thrown, isNotNull);
      var state = await StorageService.loadCalendarSyncStateAsync();
      expect(state['lastResult'], 'error');
      expect(state['lastSyncAt'], isNull,
          reason: 'P1：失败不得写 lastSyncAt（首次配置失败即伪报成功时间）');

      fail = false;
      await svc.debugSyncIncrement(source, 0);
      state = await StorageService.loadCalendarSyncStateAsync();
      expect(state['lastResult'], 'ok');
      expect(state['lastSyncAt'], isNotNull, reason: '成功才推进 lastSyncAt');
    });
  });

  group('WO-70 §7：前台 isolate 只置待发标记（闪屏修复）', () {
    test('前台 dispatch 不发送、置 pendingKick；后台 owner 正常发送', () async {
      SharedPreferences.setMockInitialValues({});
      // async 门面无静态 mock → 直接替换平台实例（shared_preferences_platform_interface 导出）
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(const {});
      await StorageService.init();
      final scheduler = TelemetryThrottleScheduler.instance;
      scheduler.resetForTest();
      scheduler.isBackgroundOwner = false; // 主 isolate 身份
      var n = 0;
      scheduler.snapshotCollector = ({bool isAppForeground = false}) async =>
          createSnap(batteryLevel: 60, app: 'com.fg');
      scheduler.uploader = (snapshot) async {
        n++;
        return UploadResult(success: true, statusCode: 200, message: 'OK');
      };

      await scheduler.triggerEvent(TelemetryTrigger.power,
          settingsOverride: AppSettings());
      expect(n, 0, reason: '前台 isolate 严禁发送（闪屏修复硬性规则②）');
      expect(scheduler.isDirty, isTrue);
      expect(await StorageService.takeTelemetryPendingKick(), isTrue,
          reason: '置待发标记，交后台 30s tick 接力');

      // 后台所有者恢复发送能力
      scheduler.isBackgroundOwner = true;
      await scheduler.triggerEvent(TelemetryTrigger.power,
          settingsOverride: AppSettings());
      expect(n, 1, reason: '后台 owner 正常发送');
    });
  });
}

Future<void> _wo105SpawnContender(String dir, SendPort signals) =>
    Isolate.run(() async {
      lockDirOverride = dir;
      await crossIsolateSynchronized('guard', () async {
        signals.send('entered');
      }, retryInterval: const Duration(milliseconds: 30), maxRetries: 80,
          sleep: (delay) async {
        signals.send('retry');
        await Future<void>.delayed(delay);
      });
    });

int _wo105OpenLockDescriptors(String dir) {
  var count = 0;
  for (final entry in Directory('/proc/self/fd').listSync()) {
    try {
      if (Link(entry.path).targetSync().startsWith('$dir/wo69_')) count++;
    } on FileSystemException {
      // /proc 的枚举句柄在 listSync 返回时已关闭；其编号可能已消失。
    }
  }
  return count;
}

DateTime fakeClock = DateTime(2026, 9, 27, 5);

DeviceTelemetry createSnap({
  required int batteryLevel,
  required String app,
  String ssid = 'Office',
}) {
  return DeviceTelemetry(
    battery: BatteryInfo(level: batteryLevel, isCharging: false),
    wifi: WifiInfo(connected: true, ssid: ssid),
    screenLocked: false,
    foregroundApp: app,
    // timestamp 每次采集必然不同——指纹必须剔除它，否则去重永不生效
    timestamp: DateTime.now().millisecondsSinceEpoch,
    isMusicActive: false,
    isBluetoothAudio: false,
    stepsToday: 100,
  );
}
