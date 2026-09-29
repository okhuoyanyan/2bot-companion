import 'package:flutter/material.dart';

import '../../services/keepalive_check_service.dart';
import '../../utils/theme.dart';

/// WO-75 Phase B · 保活自检卡（设置卡内嵌；文案诚实纪律见各注释）。
///
/// 裁定落点：
/// - 三项 = 电池优化（真实状态+标准请求）/ 自启动（MIUI 无 API → 纯指引+可跳则跳）/
///   最近任务锁定（无 API → 纯指引）；
/// - 诚实红线：「划掉后台=系统强制停止，重开即恢复」必须写明，绝不暗示 App 能
///   自愈 force-stop（HyperOS SwipeUpClean 为系统级停止，任何应用侧设置都拦不住）；
/// - 状态刷新只在【首次构建】与用户点「刷新」时发生（不挂定时器，
///   遵守 WO-71 闪屏纪律：本卡不产生周期性高度变化）；
/// - 零生命周期改动：不注册 receiver、不请求任何新权限、不碰前台服务。
class KeepaliveCheckCard extends StatefulWidget {
  const KeepaliveCheckCard({super.key});

  @override
  State<KeepaliveCheckCard> createState() => _KeepaliveCheckCardState();
}

class _KeepaliveCheckCardState extends State<KeepaliveCheckCard> {
  bool? _batteryIgnoring; // null = 读取失败（未知），UI 显示「无法读取」
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _checking = true);
    final v = await KeepaliveCheckService.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() {
      _batteryIgnoring = v;
      _checking = false;
    });
  }

  Future<void> _requestIgnore() async {
    await KeepaliveCheckService.requestIgnoreBatteryOptimizations();
    // 系统对话框返回后刷新真实状态（不猜测结果）
    await _refresh();
  }

  Future<void> _openAutostart() async {
    final opened = await KeepaliveCheckService.openAutostartSettings();
    if (!mounted) return;
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前 ROM 无自启动管理入口，请按下方文字步骤手动操作')),
      );
    }
  }

  Widget _row({
    required IconData icon,
    required String title,
    required Widget status,
    required String step,
    VoidCallback? onAction,
    String? actionLabel,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: AppTheme.textSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary)),
              ),
              status,
              if (onAction != null) ...[
                const SizedBox(width: 4),
                TextButton(
                  onPressed: onAction,
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.primaryCyan,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(actionLabel ?? '操作',
                      style: const TextStyle(fontSize: 11)),
                ),
              ],
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 21, top: 2),
            child: Text(step,
                style: const TextStyle(
                    fontSize: 10, color: AppTheme.textMuted, height: 1.4)),
          ),
        ],
      ),
    );
  }

  Widget _batteryStatus() {
    if (_checking) {
      return const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.5));
    }
    switch (_batteryIgnoring) {
      case true:
        return const Text('✓ 已忽略',
            style: TextStyle(fontSize: 11, color: Color(0xFF10B981)));
      case false:
        return const Text('✗ 受限',
            style: TextStyle(fontSize: 11, color: Color(0xFFF59E0B)));
      default:
        return const Text('? 无法读取',
            style: TextStyle(fontSize: 11, color: AppTheme.textMuted));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.cardBorder),
        borderRadius: BorderRadius.circular(8),
        color: const Color(0xFF0F172A),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_outlined,
                  size: 15, color: AppTheme.secondarySky),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('保活自检（WO-75）',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textPrimary)),
              ),
              TextButton(
                onPressed: _checking ? null : _refresh,
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.textMuted,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('刷新', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // ① 电池优化：真实状态 + 标准 intent 请求
          _row(
            icon: Icons.battery_saver_outlined,
            title: '电池优化忽略',
            status: _batteryStatus(),
            step: '受限时后台易被 ROM 清杀。点「请求忽略」→ 系统对话框选「允许」。',
            onAction: _requestIgnore,
            actionLabel: '请求忽略',
          ),
          // ② 自启动（MIUI）：无公开检测 API——只有指引，不显示任何检测状态
          _row(
            icon: Icons.rocket_launch_outlined,
            title: '自启动（MIUI 无检测 API，仅指引）',
            status: const SizedBox.shrink(),
            step: '安全中心 → 应用管理 → 权限 → 自启动管理 → 允许「2BOT 伴侣」。',
            onAction: _openAutostart,
            actionLabel: '打开安全中心',
          ),
          // ③ 最近任务锁定：无 API——只有指引
          _row(
            icon: Icons.lock_outline_rounded,
            title: '最近任务锁定（仅指引）',
            status: const SizedBox.shrink(),
            step: '最近任务界面 → 长按「2BOT 伴侣」卡片 → 点锁形图标。',
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text(
              '诚实说明：划掉后台 = 系统强制停止（HyperOS SwipeUpClean），'
              '上述任何设置都不能阻止它；服务随 App 死亡属系统设计。'
              '重开 App 即恢复本机服务，无需其它操作。',
              style: TextStyle(fontSize: 10, color: AppTheme.textMuted, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
