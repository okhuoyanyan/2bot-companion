import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bot_companion/models/app_settings.dart';
import 'package:bot_companion/models/device_telemetry.dart';
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
}) {
  return DeviceTelemetry(
    battery: BatteryInfo(level: batteryLevel, isCharging: false),
    wifi: WifiInfo(connected: true, ssid: 'Office'),
    screenLocked: false,
    foregroundApp: app,
    // timestamp 每次采集必然不同——指纹必须剔除它，否则去重永不生效
    timestamp: DateTime.now().millisecondsSinceEpoch,
    isMusicActive: false,
    isBluetoothAudio: false,
    stepsToday: 100,
  );
}
