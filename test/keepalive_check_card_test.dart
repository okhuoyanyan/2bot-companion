import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bot_companion/services/keepalive_check_service.dart';
import 'package:bot_companion/views/widgets/keepalive_check_card.dart';

/// WO-75 Phase B · 保活自检卡单测
/// 断言现状对照（改前 b05c418）：保活自检 UI 不存在；电池状态无任何 UI 出口
/// （PowerManager 读取仅在遥测快照里）；本组为新增行为，红灯在实现前已实证
///（MissingPluginException 形态 + 编译面）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.twobot.companion/native_sensors');
  final calls = <String, Object?>{};
  bool? mockIgnoring;
  bool? mockAutostartOpened;

  Future<Object?> handler(MethodCall call) async {
    calls[call.method] = call.arguments;
    switch (call.method) {
      case 'isIgnoringBatteryOptimizations':
        return mockIgnoring;
      case 'requestIgnoreBatteryOptimizations':
        return true;
      case 'openAutostartSettings':
        return mockAutostartOpened;
    }
    return null;
  }

  setUp(() {
    calls.clear();
    mockIgnoring = true;
    mockAutostartOpened = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('KeepaliveCheckService（真实读取 + 标准跳转）', () {
    test('电池状态透传：true / false / 异常→null（不伪造）', () async {
      mockIgnoring = true;
      expect(await KeepaliveCheckService.isIgnoringBatteryOptimizations(), isTrue);
      mockIgnoring = false;
      expect(await KeepaliveCheckService.isIgnoringBatteryOptimizations(), isFalse);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null); // 无 handler = 平台异常路径
      expect(await KeepaliveCheckService.isIgnoringBatteryOptimizations(), isNull,
          reason: '读取失败必须显示「无法读取」，不得猜测');
    });

    test('请求忽略 / 自启动跳转：均走标准通道', () async {
      expect(await KeepaliveCheckService.requestIgnoreBatteryOptimizations(),
          isTrue);
      expect(calls['requestIgnoreBatteryOptimizations'], isNull,
          reason: '无参数调用');
      expect(await KeepaliveCheckService.openAutostartSettings(), isTrue);
      expect(calls['openAutostartSettings'], isNull);
    });
  });

  group('保活自检卡（诚实文案纪律）', () {
    Future<void> pumpCard(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: KeepaliveCheckCard())),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('三项齐备：电池真实状态 / 自启动指引 / 最近任务指引', (tester) async {
      mockIgnoring = true;
      await pumpCard(tester);
      expect(find.text('保活自检（WO-75）'), findsOneWidget);
      expect(find.text('电池优化忽略'), findsOneWidget);
      expect(find.text('✓ 已忽略'), findsOneWidget,
          reason: '真实状态读取结果必须可见');
      expect(find.textContaining('自启动（MIUI 无检测 API'), findsOneWidget,
          reason: 'MIUI 项必须明示「无检测 API」，严禁伪造检测状态');
      expect(find.textContaining('最近任务锁定（仅指引）'), findsOneWidget);
      expect(find.text('✗ 受限'), findsNothing,
          reason: '状态为已忽略时不得显示受限');
    });

    testWidgets('受限态：显示 ✗ 并提供标准请求入口', (tester) async {
      mockIgnoring = false;
      await pumpCard(tester);
      expect(find.text('✗ 受限'), findsOneWidget);
      expect(find.text('请求忽略'), findsOneWidget);
      await tester.tap(find.text('请求忽略'));
      await tester.pumpAndSettle();
      expect(calls['requestIgnoreBatteryOptimizations'], isNull,
          reason: '点了请求 → 通道被调用');
      // 请求后状态自动重读（mock 仍 false）
      expect(find.text('✗ 受限'), findsOneWidget);
    });

    testWidgets('诚实红线：写明划掉后台=系统强制停止，且不得暗示自愈', (tester) async {
      await pumpCard(tester);
      expect(
          find.textContaining('划掉后台 = 系统强制停止'), findsOneWidget,
          reason: '裁定④：必须写明划掉后台的语义');
      expect(find.textContaining('重开 App 即恢复'), findsOneWidget);
      expect(find.textContaining('上述任何设置都不能阻止'), findsOneWidget,
          reason: '不得暗示 App 能自愈 force-stop');
    });
  });
}
