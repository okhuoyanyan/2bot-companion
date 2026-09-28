import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bot_companion/views/widgets/calendar_sync_status_panel.dart';

/// ============================================================================
/// WO-71 闪屏返工 · 整改③ 单测
/// ============================================================================
/// 断言纪律（架构师验收判据的代码化）：
///   给定「状态文本由 1 行变 3 行」等输入变化 → 面板 size.height 必须【前后一致】
/// （任何内容更新都不得改变卡片高度——整页位移的直接根因）。
Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 400, child: child),
    ),
  );
}

void main() {
  testWidgets('状态文本 1 行变 3 行：面板高度前后一致', (tester) async {
    final empty = <String, dynamic>{};
    final full = <String, dynamic>{
      'lastAttemptAt': '2026-09-28T04:42:51.000',
      'lastResult': 'error',
      'lastError': 'IMAP 会话失败（第 2 次，5 分钟后重试）：IMAP 命令 LOGIN 失败（NO）',
      'lastSyncAt': '2026-09-28T04:40:00.000',
      'lastApplied': 411,
      'mode': 'backoff',
      'lastChannelMs': 929,
      'serverRunning': true,
      'serverPort': 18080,
      'serverUser': '2bot',
      'serverPass': 'V3fkUDdV6Exn',
      'storeCount': 411,
    };

    // 第一帧：空状态（1 行文本）
    await tester.pumpWidget(_wrap(CalendarSyncStatusPanel(
        state: empty, imapLog: const <dynamic>[])));
    await tester.pumpAndSettle();
    final h1 = tester.getSize(find.byType(CalendarSyncStatusPanel)).height;

    // 第二帧：满内容（多行文本 + 服务块 + IMAP 日志 6 条）
    await tester.pumpWidget(_wrap(CalendarSyncStatusPanel(
        state: full,
        imapLog: List.generate(6, (i) => 'IMAP == UID 完成 ${100 + i}ms'))));
    await tester.pumpAndSettle();
    final h2 = tester.getSize(find.byType(CalendarSyncStatusPanel)).height;

    expect(h1, equals(h2),
        reason: '空状态与满内容的面板高度必须一致（固定槽位纪律）；'
            '实测 h1=$h1 h2=$h2');
  });

  testWidgets('IMAP 命令日志 1 条变 6 条：高度一致（行数变化不推挤下方内容）', (tester) async {
    const one = <String>['IMAP >> UID [23B] 发送'];
    const six = [
      'IMAP == UID 完成 312ms head=C127 OK UID FETCH Co…',
      'IMAP << UID 首响应 (36B)',
      'IMAP .. FETCH FULL [批次 1/1, 1条] 等待响应…',
      'IMAP >> UID [36B] 发送',
      'IMAP == FETCH HDR 完成：1135 条中前缀命中 1 条',
      'IMAP == UID 完成 929ms head=C126 OK UID FETCH Co…',
    ];

    await tester.pumpWidget(_wrap(
        const CalendarSyncStatusPanel(state: {}, imapLog: one)));
    await tester.pumpAndSettle();
    final h1 = tester.getSize(find.byType(CalendarSyncStatusPanel)).height;

    await tester.pumpWidget(_wrap(
        const CalendarSyncStatusPanel(state: {}, imapLog: six)));
    await tester.pumpAndSettle();
    final h2 = tester.getSize(find.byType(CalendarSyncStatusPanel)).height;

    expect(h1, equals(h2), reason: 'IMAP 日志 1→6 条高度恒定；实测 h1=$h1 h2=$h2');
  });

  testWidgets('服务未运行（bgError 多行文本）与运行中：高度一致', (tester) async {
    const off = <String, dynamic>{
      'serverRunning': false,
      'bgError': '后台 isolate 异常: 某种很长的错误描述文字，可能换行',
    };
    const on = <String, dynamic>{
      'serverRunning': true,
      'serverPort': 18080,
      'serverUser': '2bot',
      'serverPass': 'V3fkUDdV6Exn',
      'storeCount': 411,
    };

    await tester.pumpWidget(_wrap(const CalendarSyncStatusPanel(
        state: off, imapLog: <dynamic>[])));
    await tester.pumpAndSettle();
    final h1 = tester.getSize(find.byType(CalendarSyncStatusPanel)).height;

    await tester.pumpWidget(_wrap(const CalendarSyncStatusPanel(
        state: on, imapLog: <dynamic>[])));
    await tester.pumpAndSettle();
    final h2 = tester.getSize(find.byType(CalendarSyncStatusPanel)).height;

    expect(h1, equals(h2), reason: '服务块 3 槽位固定高度；实测 h1=$h1 h2=$h2');
  });

  testWidgets('遥测闸门面板：0 条与 8 条高度一致', (tester) async {
    await tester.pumpWidget(_wrap(const TelemetryAttemptsPanel(attempts: [])));
    await tester.pumpAndSettle();
    final h1 = tester.getSize(find.byType(TelemetryAttemptsPanel)).height;

    final eight = List.generate(
        8,
        (i) => <String, dynamic>{
              'at': '2026-09-28T04:42:${20 + i < 60 ? 20 + i : i}.000',
              'gate': 'sent',
              'trigger': '服务启动/重启',
              'detail': '邮箱上报成功 (SMTP smtp.qq.com:465)',
            });
    await tester.pumpWidget(_wrap(TelemetryAttemptsPanel(attempts: eight)));
    await tester.pumpAndSettle();
    final h2 = tester.getSize(find.byType(TelemetryAttemptsPanel)).height;

    expect(h1, equals(h2), reason: '恒定 8 槽；实测 h1=$h1 h2=$h2');
  });
}
