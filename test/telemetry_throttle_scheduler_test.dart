import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bot_companion/models/app_settings.dart';
import 'package:bot_companion/models/device_telemetry.dart';
import 'package:bot_companion/services/storage_service.dart';
import 'package:bot_companion/services/telemetry_throttle_scheduler.dart';
import 'package:bot_companion/services/telemetry_uploader_service.dart';

/// 构造测试用 DeviceTelemetry 快照
DeviceTelemetry createMockSnapshot({
  int batteryLevel = 85,
  bool isCharging = false,
  bool screenLocked = false,
  String foregroundApp = 'com.example.app',
  String? wifiSsid = 'Office_WiFi',
  bool isMusicActive = false,
  bool isBluetoothAudio = false,
  int stepsToday = 100,
  List<AppUsageItem>? usageSummary,
  Map<String, String>? placeLabels,
}) {
  return DeviceTelemetry(
    battery: BatteryInfo(level: batteryLevel, isCharging: isCharging),
    wifi: WifiInfo(connected: wifiSsid != null, ssid: wifiSsid ?? ''),
    screenLocked: screenLocked,
    foregroundApp: foregroundApp,
    timestamp: DateTime.now().millisecondsSinceEpoch,
    isMusicActive: isMusicActive,
    isBluetoothAudio: isBluetoothAudio,
    stepsToday: stepsToday,
    usageSummary: usageSummary,
    placeLabels: placeLabels,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TelemetryThrottleScheduler scheduler;
  late int uploadCount;
  late List<DeviceTelemetry> uploadedSnapshots;
  late UploadResult uploadReturnValue;
  late int silenceScheduledHours;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.init();

    scheduler = TelemetryThrottleScheduler.instance;
    scheduler.resetForTest();
    uploadCount = 0;
    uploadedSnapshots = [];
    uploadReturnValue = UploadResult(
      success: true,
      statusCode: 200,
      message: 'OK',
    );
    silenceScheduledHours = -1;

    scheduler.snapshotCollector = ({bool isAppForeground = false}) async {
      return createMockSnapshot();
    };

    scheduler.uploader = (snapshot) async {
      uploadCount++;
      uploadedSnapshots.add(snapshot);
      return uploadReturnValue;
    };

    scheduler.silenceScheduler = (hours) {
      silenceScheduledHours = hours;
    };
  });

  tearDown(() {
    scheduler.resetForTest();
  });

  group('WO-37 节流调度器核心契约测试', () {
    test('1. 白名单事件不受限流窗口约束，立即发送', () async {
      final settings = AppSettings(
        throttleIntervalSeconds: 90,
        silenceTimeoutHours: 6,
      );

      // 首次发送（服务启动：白名单）
      await scheduler.triggerEvent(
        TelemetryTrigger.serviceRestart,
        settingsOverride: settings,
      );
      expect(uploadCount, equals(1));

      // 紧接着触发到家/离家（白名单）-> 必须立即上报，不得被 90s 限流拦截
      await scheduler.triggerEvent(
        TelemetryTrigger.location,
        settingsOverride: settings,
      );
      expect(uploadCount, equals(2));

      // 紧接着触发低电量（<=20% 白名单）-> 必须立即上报
      await scheduler.triggerEvent(
        TelemetryTrigger.batteryThreshold,
        batteryLevel: 15,
        settingsOverride: settings,
      );
      expect(uploadCount, equals(3));

      // 手动触发（白名单）-> 必须立即上报
      await scheduler.triggerEvent(
        TelemetryTrigger.manual,
        settingsOverride: settings,
      );
      expect(uploadCount, equals(4));
    });

    test('2. 非白名单事件限流窗口内合并为 1 次，距上次上报 >= T 才发送', () async {
      final settings = AppSettings(
        throttleIntervalSeconds: 90,
      );

      // 首次上报（非白名单屏幕锁屏，但上次上报为空，故立即发）
      await scheduler.triggerEvent(
        TelemetryTrigger.lock,
        settingsOverride: settings,
      );
      expect(uploadCount, equals(1));
      expect(scheduler.isDirty, isFalse);

      // 窗口内触发非白名单事件（应用切换）-> 应当标脏并拦截，不得立即发送
      await scheduler.triggerEvent(
        TelemetryTrigger.appSwitch,
        settingsOverride: settings,
      );
      expect(uploadCount, equals(1));
      expect(scheduler.isDirty, isTrue);

      // 窗口内再次触发非白名单事件（充放电切换）-> 维持标脏合并，仍不增加发送次数
      await scheduler.triggerEvent(
        TelemetryTrigger.power,
        settingsOverride: settings,
      );
      expect(uploadCount, equals(1));
      expect(scheduler.isDirty, isTrue);
    });

    test('3. 发送失败时仅递增连续失败计数，严禁引入定时重试', () async {
      final settings = AppSettings();
      uploadReturnValue = UploadResult(
        success: false,
        statusCode: 500,
        message: 'Network timeout',
      );

      await scheduler.triggerEvent(
        TelemetryTrigger.serviceRestart,
        settingsOverride: settings,
      );

      expect(uploadCount, equals(1));
      expect(scheduler.consecutiveFailures, equals(1));
      // 距上次成功上报时间仍为空
      expect(scheduler.lastSendTime, isNull);

      // 再次失败
      await scheduler.triggerEvent(
        TelemetryTrigger.manual,
        settingsOverride: settings,
      );
      expect(uploadCount, equals(2));
      expect(scheduler.consecutiveFailures, equals(2));
    });

    test('4. 静默超时单发保活机制（重排到期检查，0=关闭）', () async {
      final settings = AppSettings(silenceTimeoutHours: 6);

      await scheduler.triggerEvent(
        TelemetryTrigger.serviceRestart,
        settingsOverride: settings,
      );
      expect(uploadCount, equals(1));
      // 成功上报后触发原生硬件唤醒重排
      expect(silenceScheduledHours, equals(6));

      // 若配置为 0（关闭静默保活）
      final disabledSettings = AppSettings(silenceTimeoutHours: 0);
      await scheduler.triggerEvent(
        TelemetryTrigger.manual,
        settingsOverride: disabledSettings,
      );
      expect(uploadCount, equals(2));
      expect(silenceScheduledHours, equals(0));
    });

    test('5. 事件独立开关：禁用项被直接拦截过滤', () async {
      final settings = AppSettings(
        eventSwitches: {
          ...AppSettings.defaultEventSwitches,
          'app_switch': false, // 禁用应用切换事件
        },
      );

      await scheduler.triggerEvent(
        TelemetryTrigger.appSwitch,
        settingsOverride: settings,
      );

      // 被开关拦截，完全不触发快照采集与上报
      expect(uploadCount, equals(0));
      expect(scheduler.isDirty, isFalse);
    });
  });

  group('WO-37 状态差分扫描器（evaluateStateChange）测试', () {
    test('步数里程碑：499->500 触发，500->501 防重拦截', () async {
      final settings = AppSettings(throttleIntervalSeconds: 90);

      // 基线状态建立：499 步
      final snap499 = createMockSnapshot(stepsToday: 499);
      scheduler.snapshotCollector =
          ({bool isAppForeground = false}) async => snap499;
      await scheduler.triggerEvent(
        TelemetryTrigger.manual,
        settingsOverride: settings,
      );
      expect(uploadCount, equals(1));

      // 499 -> 500 步：跨过 500 步里程碑 (0 -> 1)，触发 steps 事件
      final snap500 = createMockSnapshot(stepsToday: 500);
      await scheduler.evaluateStateChange(snap500, settingsOverride: settings);
      // 因处于 90s 节流窗口，steps 被标脏合并
      expect(scheduler.isDirty, isTrue);

      // 模拟窗口到期并完成 500 步快照上报，基线确立为 500
      scheduler.snapshotCollector =
          ({bool isAppForeground = false}) async => snap500;
      scheduler.resetForTest();
      await scheduler.triggerEvent(TelemetryTrigger.manual, settingsOverride: settings);
      expect(uploadCount, equals(2));

      // 500 -> 501 步：同属于第 1 档（500~/500 == 1 == 501~/500），防重不触发
      final snap501 = createMockSnapshot(stepsToday: 501);
      await scheduler.evaluateStateChange(snap501, settingsOverride: settings);
      expect(scheduler.isDirty, isFalse);
    });

    test('电量阈值跨档：85->80 非白名单，80->20/10 白名单立即触发', () async {
      final settings = AppSettings(throttleIntervalSeconds: 90);

      // 基线状态建立：85%
      await scheduler.triggerEvent(
        TelemetryTrigger.manual,
        batteryLevel: 85,
        settingsOverride: settings,
      );
      expect(uploadCount, equals(1));

      // 85% -> 80%：跨过 80 档（非白名单，处于节流窗口内 -> 标脏）
      final snap80 = createMockSnapshot(batteryLevel: 80);
      await scheduler.evaluateStateChange(snap80, settingsOverride: settings);
      expect(scheduler.isDirty, isTrue);

      // 80% -> 20%：跨过 20 档（白名单 -> 立即上报）
      final snap20 = createMockSnapshot(batteryLevel: 20);
      await scheduler.evaluateStateChange(snap20, settingsOverride: settings);
      expect(uploadCount, equals(2));
      expect(scheduler.isDirty, isFalse);
    });
  });

  group('WO-37 字段真实化与模型序列化测试', () {
    test('usageSummary 增量摘要序列化与缺失省略（防假事实）', () {
      // 1. 基线缺失时，usageSummary 必须为 null，toJson 严格不包含该 key
      final snapWithoutUsage = DeviceTelemetry(
        battery: BatteryInfo(level: 90, isCharging: false),
        wifi: WifiInfo(connected: true, ssid: 'Home'),
        screenLocked: true,
        foregroundApp: 'None',
        timestamp: 1726999999000,
        usageSummary: null,
      );
      final json1 = snapWithoutUsage.toJson();
      expect(json1.containsKey('usageSummary'), isFalse);

      // 2. 有 usageSummary 时，正确序列化 Top-5 列表
      final snapWithUsage = DeviceTelemetry(
        battery: BatteryInfo(level: 90, isCharging: false),
        wifi: WifiInfo(connected: true, ssid: 'Home'),
        screenLocked: false,
        foregroundApp: '哔哩哔哩',
        timestamp: 1726999999000,
        usageSummary: [
          AppUsageItem(app: '哔哩哔哩', minutes: 8),
          AppUsageItem(app: '微信', minutes: 3),
        ],
      );
      final json2 = snapWithUsage.toJson();
      expect(json2.containsKey('usageSummary'), isTrue);
      final list = json2['usageSummary'] as List;
      expect(list.length, equals(2));
      expect(list[0]['app'], equals('哔哩哔哩'));
      expect(list[0]['minutes'], equals(8));

      // 3. 从 JSON 反序列化恢复
      final restored = DeviceTelemetry.fromJson(json2);
      expect(restored.usageSummary, isNotNull);
      expect(restored.usageSummary!.length, equals(2));
      expect(restored.usageSummary![0].app, equals('哔哩哔哩'));
      expect(restored.usageSummary![0].minutes, equals(8));
    });

    test('placeLabels 地点标注字典序列化与反序列化', () {
      final snap = DeviceTelemetry(
        battery: BatteryInfo(level: 50, isCharging: true),
        wifi: WifiInfo(connected: true, ssid: 'Home_WiFi'),
        screenLocked: false,
        foregroundApp: '网易云音乐',
        timestamp: 1726999999000,
        placeLabels: {
          'Home_WiFi': '家',
          'Company_Office': '公司',
        },
      );

      final json = snap.toJson();
      expect(json.containsKey('placeLabels'), isTrue);
      expect(json['placeLabels']['Home_WiFi'], equals('家'));

      final restored = DeviceTelemetry.fromJson(json);
      expect(restored.placeLabels, isNotNull);
      expect(restored.placeLabels!['Home_WiFi'], equals('家'));
      expect(restored.placeLabels!['Company_Office'], equals('公司'));
    });

    test('screenLocked 与 foregroundApp 读写真实值', () {
      final snap = DeviceTelemetry(
        battery: BatteryInfo(level: 70, isCharging: false),
        wifi: WifiInfo(connected: false, ssid: ''),
        screenLocked: false, // 真实解锁
        foregroundApp: '王者荣耀', // 真实前台应用
        timestamp: 1726999999000,
      );

      final json = snap.toJson();
      expect(json['screenLocked'], isFalse);
      expect(json['foregroundApp'], equals('王者荣耀'));

      final restored = DeviceTelemetry.fromJson(json);
      expect(restored.screenLocked, isFalse);
      expect(restored.foregroundApp, equals('王者荣耀'));
    });
  });
}
