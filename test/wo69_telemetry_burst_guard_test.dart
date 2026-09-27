import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bot_companion/models/app_settings.dart';
import 'package:bot_companion/models/device_telemetry.dart';
import 'package:bot_companion/services/calendar_sync_service.dart';

import 'calendar_sync_service_test.dart';
import 'package:bot_companion/services/imap_idle_client.dart';
import 'package:bot_companion/services/storage_service.dart';
import 'package:bot_companion/services/telemetry_mail_transport.dart';
import 'package:bot_companion/services/telemetry_throttle_scheduler.dart';
import 'package:bot_companion/services/telemetry_uploader_service.dart';

/// ============================================================================
/// WO-69 追补整改 · 突发旁路修复单测（架构师急件 2026-09-27 ②）
/// ============================================================================
/// 钉死三道闸：
///   闸A SMTP 正文出网后【禁止重试】（同 payload 重复投递 = 535 直接来源）；
///   闸B 调度层载荷去重（非白名单路径，剔除 timestamp 后同状态不重投）；
///   闸C 失败有界冷却 + 最小会话间隔（同秒连发被结构性排除）。
/// 全部零真连：transport 用脚本化假 socket，scheduler 用注入假 uploader。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      // 220 → EHLO → AUTH×3 → MAIL → RCPT → DATA → 正文
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

      final resolved = SmtpMailer.resolveSendFailure(
          s, 'TimeoutException after 5s', 1, false);
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
          config: const MailAccountConfig(
              account: 'a@example.invalid', authCode: 'X'),
          subject: 'S1',
          body: 'B',
          connectTimeout: const Duration(milliseconds: 50),
        );
        await SmtpMailer.send(
          config: const MailAccountConfig(
              account: 'a@example.invalid', authCode: 'X'),
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

      // 快进 2 秒：节流窗口（1s）已过 → dispatch 真正执行 → 命中去重
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

      // 状态变化：前台应用切换（内容不同 → 必须送达）
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

      // 快进 61s → 恢复立即发
      fakeNow = fakeNow.add(const Duration(seconds: 61));
      await scheduler.triggerEvent(TelemetryTrigger.location,
          settingsOverride: settings);
      expect(n, 2);
    });

    test('SMTP 跨 isolate 串行：持久化最近会话时刻，第二条会话等待 ≥3s', () async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.init();
      SmtpMailer.resetForTest();
      final delays = <Duration>[];
      var now = DateTime(2026, 9, 27, 7);
      SmtpMailer.nowProvider = () => now;
      SmtpMailer.delayProvider = (d) async {
        delays.add(d);
        now = now.add(d);
      };
      try {
        await SmtpMailer.send(
          config: const MailAccountConfig(
              account: 'a@example.invalid', authCode: 'X'),
          subject: 'S1',
          body: 'B',
          connectTimeout: const Duration(milliseconds: 50),
        );
        await SmtpMailer.send(
          config: const MailAccountConfig(
              account: 'a@example.invalid', authCode: 'X'),
          subject: 'S2',
          body: 'B',
          connectTimeout: const Duration(milliseconds: 50),
        );
        // 第一次 send 的等待序列 = 会话内重试退避 1s/3s；
        // 第二次 send 的首个等待 = 会话间隔闸强制 3s（本 isolate 静态闸先命中；
        // 跨 isolate 持久闸与之测量同一窗口，任一命中即保证 ≥3s 间隔）
        expect(delays.length, greaterThanOrEqualTo(3));
        expect(delays[2], SmtpMailer.minSessionGap,
            reason: '同秒 ×2 被结构性排除（会话间隔闸强制 3s），事件不丢');
      } finally {
        SmtpMailer.nowProvider = DateTime.now;
        SmtpMailer.delayProvider = Future<void>.delayed;
        SmtpMailer.resetForTest();
      }
    });
  });

  group('驳回缺陷二：首次全量分批 + 幂等续传', () {
    test('120 条事件 → 分 3 批（50/50/20）逐批记台账', () async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.init();
      final scheduler = TelemetryThrottleScheduler.instance;
      scheduler.resetForTest();
      final crlf = String.fromCharCodes([13, 10]);
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
        result: (
          mails: [CalendarMail(uid: 900, subject: 'cal', raw: raw)],
          maxSeenUid: 900,
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

      // 充电插拔时电量流秒级连跳三次（同状态）→ 旧实现发 3 封（同秒簇来源之一）
      await scheduler.triggerTelemetryRefresh();
      expect(n, 1);
      fakeClock = fakeClock.add(const Duration(seconds: 2));
      await scheduler.triggerTelemetryRefresh();
      expect(n, 1, reason: '同状态刷新必须被去重合并');
      fakeClock = fakeClock.add(const Duration(seconds: 2));
      await scheduler.triggerTelemetryRefresh();
      expect(n, 1);

      // 真实状态变化 → 送达（快进越过 90s 节流窗口）
      app = 'com.y';
      fakeClock = fakeClock.add(const Duration(seconds: 91));
      await scheduler.triggerTelemetryRefresh();
      expect(n, 2);
    });
  });
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
