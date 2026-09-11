import 'package:flutter/material.dart';
import '../../utils/theme.dart';

/// 核心操作栏组件：手动测试与前台保活开关
class QuickActions extends StatelessWidget {
  final bool isServiceRunning;
  final bool isReporting;
  final bool hasLocationPermission;
  final ValueChanged<bool> onToggleService;
  final VoidCallback onTestReport;
  final VoidCallback onRequestPermission;

  const QuickActions({
    super.key,
    required this.isServiceRunning,
    required this.isReporting,
    required this.hasLocationPermission,
    required this.onToggleService,
    required this.onTestReport,
    required this.onRequestPermission,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 若未授予定位权限，显示温馨提示条（读取 WiFi SSID 需要）
        if (!hasLocationPermission)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.warningAmber.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppTheme.warningAmber.withOpacity(0.4),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.location_on_outlined,
                    color: AppTheme.warningAmber, size: 20),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '读取 WiFi 名称需开启系统定位权限',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.warningAmber,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: onRequestPermission,
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.warningAmber,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('立即授权', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),

        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              children: [
                // 1. 前台保活常驻开关
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Row(
                    children: [
                      Icon(Icons.shield_outlined,
                          size: 20, color: AppTheme.primaryCyan),
                      SizedBox(width: 8),
                      Text(
                        '后台常驻守护服务',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      isServiceRunning
                          ? '前台服务与通知已激活，抗击系统后台查杀'
                          : '关闭中（建议开启以确保起居与状态无感上报）',
                      style: TextStyle(
                        fontSize: 12,
                        color: isServiceRunning
                            ? AppTheme.accentEmerald
                            : AppTheme.textMuted,
                      ),
                    ),
                  ),
                  value: isServiceRunning,
                  activeColor: AppTheme.primaryCyan,
                  onChanged: onToggleService,
                ),
                const Divider(color: AppTheme.cardBorder, height: 20),

                // 2. 立即测试上报按钮
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.secondarySky,
                      side: const BorderSide(color: AppTheme.secondarySky),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: isReporting ? null : onTestReport,
                    icon: isReporting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppTheme.secondarySky,
                            ),
                          )
                        : const Icon(Icons.send_rounded, size: 18),
                    label: Text(
                      isReporting ? '正在向云端中继推送...' : '立即测试上报一次',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
