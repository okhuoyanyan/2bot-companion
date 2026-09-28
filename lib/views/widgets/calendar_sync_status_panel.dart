import 'package:flutter/material.dart';

/// ============================================================================
/// WO-71 闪屏返工 · 日历同步状态面板（固定高度版）
/// ============================================================================
/// 根因（架构师连拍实测）：卡片内可变高度文本块改变行数 → 卡片高度变化 →
/// 下方内容位移（整页「跳」的直接原因）。
///
/// 纪律：**本面板内任何内容更新都不得改变面板总高度**——
/// 所有槽位用固定高度 SizedBox + 内部滚动/maxLines+ellipsis，
/// 空内容也渲染空槽占位（高度恒定）。行高常量集中定义（[_lineH]）。
///
/// 单测见 calendar_sync_status_panel_test.dart（1 行变 3 行高度不变断言）。
class CalendarSyncStatusPanel extends StatelessWidget {
  final Map<String, dynamic> state;
  final List<dynamic> imapLog;

  /// 单行高度（fontSize 10 的近似行高，所有槽位以此推导）
  static const double _lineH = 15;

  /// 状态行（上次尝试/成功/模式）槽位高度：固定 1 行
  static const double _statusH = _lineH + 2;

  /// 失败原因槽位高度：固定 2 行（maxLines 2 + ellipsis，空也占位）
  static const double _errorH = _lineH * 2;

  /// 服务块槽位高度：固定 3 行（服务行 + 订阅 URL + CalDAV；未运行时空槽占位）
  static const double _serverH = 4 + _lineH * 3;

  /// IMAP 命令块槽位高度：标题 1 行 + 6 条命令（固定，内部不滚动——
  /// 6 行为环上限，正好恒定）
  static const double _imapH = 4 + _lineH * 7;

  const CalendarSyncStatusPanel({
    super.key,
    required this.state,
    required this.imapLog,
  });

  Widget _slot(double height, Widget child) {
    return SizedBox(
      height: height,
      child: Align(
        alignment: Alignment.topLeft,
        child: child,
      ),
    );
  }

  Widget _fixedText(String text,
      {int? maxLines,
      double fontSize = 10,
      Color color = const Color(0xFF64748B)}) {
    return Text(
      text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: fontSize, color: color),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lastSyncAt = state['lastSyncAt'] as String?;
    final lastAttemptAt = state['lastAttemptAt'] as String?;
    final lastResult = state['lastResult'] as String?;
    final lastError = state['lastError'] as String?;
    final lastApplied = state['lastApplied'] as int?;
    final mode = (state['mode'] as String?) ?? '';
    final channelMs = state['lastChannelMs'] as int?;

    const modeTexts = {
      'idle': '推送在线 (IDLE)',
      'poll': '兜底轮询 (15 分钟)',
      'backoff': '故障退避中',
      'off': '未运行',
    };
    final modeText = modeTexts[mode] ?? (mode.isEmpty ? '' : '模式:$mode');
    final chText = channelMs != null ? ' · 通道往返 ${channelMs}ms' : '';

    final String statusText;
    if (lastAttemptAt == null || lastAttemptAt.isEmpty) {
      statusText = modeText.isEmpty ? '尚未尝试过' : '尚未尝试过 · $modeText';
    } else {
      final attemptAt = _fmtTime(lastAttemptAt);
      final syncText = (lastSyncAt == null || lastSyncAt.isEmpty)
          ? '无成功'
          : _fmtTime(lastSyncAt);
      final applied = lastApplied != null ? '（应用 $lastApplied 条）' : '';
      final resultText = (lastResult == 'ok' || lastResult == null)
          ? '成功$applied'
          : (lastResult == 'partial' ? '部分成功$applied' : '失败');
      statusText = '上次尝试：$attemptAt · $resultText · 上次成功：$syncText$chText'
          '${modeText.isEmpty ? '' : ' · $modeText'}';
    }
    final statusColor = (lastResult == 'ok' || lastResult == null)
        ? const Color(0xFF64748B)
        : const Color(0xFFF59E0B);

    final serverRunning = state['serverRunning'] as bool? ?? false;
    final serverPort = (state['serverPort'] as num?)?.toInt() ?? 0;
    final serverUser = '${state['serverUser'] ?? ''}';
    final serverPass = '${state['serverPass'] ?? ''}';
    final storeCount = (state['storeCount'] as num?)?.toInt() ?? 0;
    final bgError = '${state['bgError'] ?? ''}';

    // 服务块：3 个固定槽位（未运行时空槽占位，高度恒定）
    final serverLine1 = serverRunning
        ? '本机服务：运行中 · 端口 $serverPort · 库内 $storeCount 条'
        : (bgError.isEmpty ? '本机服务：未运行' : '本机服务：未运行 · $bgError');
    final serverLine2 =
        serverRunning ? '订阅 URL：http://127.0.0.1:$serverPort/calendar.ics' : '';
    final serverLine3 = serverRunning
        ? 'CalDAV：http://127.0.0.1:$serverPort/ · 用户 $serverUser · 口令 $serverPass'
        : '';

    // IMAP 命令：固定 6 槽（不足空槽占位，超出截断——环上限即 6）
    final cmds = imapLog.take(6).toList();
    final cmdSlots = List.generate(6, (i) {
      final l = i < cmds.length ? '${cmds[i]}' : '';
      return _fixedText(l, maxLines: 1, fontSize: 9);
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _slot(_statusH, _fixedText(statusText, maxLines: 2, color: statusColor)),
        // 失败原因槽：固定 2 行高度（空也占位——高度恒定纪律）
        _slot(
            _errorH,
            _fixedText(lastError == null || lastError.isEmpty
                ? ''
                : '失败原因：$lastError',
                maxLines: 2)),
        _slot(
            _serverH,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(serverLine1,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10,
                        color: serverRunning
                            ? const Color(0xFF10B981)
                            : const Color(0xFF64748B))),
                _fixedText(serverLine2, maxLines: 1),
                _fixedText(serverLine3, maxLines: 1),
              ],
            )),
        _slot(
            _imapH,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('IMAP 命令（最近 6 条）',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF94A3B8))),
                ...cmdSlots,
              ],
            )),
      ],
    );
  }

  String _fmtTime(String iso) {
    try {
      final dt = DateTime.parse(iso);
      String two(int v) => v.toString().padLeft(2, '0');
      return '${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
    } catch (_) {
      return iso;
    }
  }
}

/// 遥测闸门记录面板（固定高度版：标题 + 恒定 8 槽，0..8 条高度不变）
class TelemetryAttemptsPanel extends StatelessWidget {
  final List<Map<String, dynamic>> attempts;

  static const double _lineH = 14;

  const TelemetryAttemptsPanel({super.key, required this.attempts});

  @override
  Widget build(BuildContext context) {
    // 恒定 8 槽（0..8 条高度不变；空槽占位——高度恒定纪律）
    final slots = List.generate(8, (i) {
      if (i >= attempts.length) {
        return const SizedBox(height: _lineH);
      }
      final a = attempts[i];
      final at = _fmtTime('${a['at']}');
      final gate = '${a['gate']}';
      final trigger = '${a['trigger']}';
      final detail = a['detail'] == null ? '' : ' · ${a['detail']}';
      return SizedBox(
        height: _lineH,
        child: Text(
          '$at · [$gate] $trigger$detail',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 9, color: Color(0xFF64748B)),
        ),
      );
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        const Text(
          '遥测上报闸门记录（最近 8 次）',
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color(0xFF94A3B8)),
        ),
        const SizedBox(height: 4),
        ...slots,
      ],
    );
  }

  String _fmtTime(String iso) {
    try {
      final dt = DateTime.parse(iso);
      String two(int v) => v.toString().padLeft(2, '0');
      return '${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
    } catch (_) {
      return iso;
    }
  }
}
