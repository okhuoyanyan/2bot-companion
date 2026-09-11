import 'package:flutter/material.dart';
import '../../utils/theme.dart';

/// 核心操作栏组件：手动测试与前台保活开关
class QuickActions extends StatelessWidget {
  final bool isServiceRunning;
  final bool isReporting;
  final bool hasLocationPermission;
  final bool isIgnoringBatteryOptimizations;
  final bool hasActivityPermission;
  final bool hasUsagePermission;
  final bool hasNotificationPermission;
  final int? batteryLevel;
  final bool isCharging;
  final ValueChanged<bool> onToggleService;
  final VoidCallback onTestReport;
  final VoidCallback onRequestPermission;
  final VoidCallback onRequestBatteryOptimization;
  final VoidCallback onRequestActivityPermission;
  final VoidCallback onRequestUsagePermission;
  final VoidCallback onRequestNotificationPermission;

  const QuickActions({
    super.key,
    required this.isServiceRunning,
    required this.isReporting,
    required this.hasLocationPermission,
    this.isIgnoringBatteryOptimizations = true,
    this.hasActivityPermission = true,
    this.hasUsagePermission = true,
    this.hasNotificationPermission = true,
    this.batteryLevel,
    this.isCharging = false,
    required this.onToggleService,
    required this.onTestReport,
    required this.onRequestPermission,
    required this.onRequestBatteryOptimization,
    required this.onRequestActivityPermission,
    required this.onRequestUsagePermission,
    required this.onRequestNotificationPermission,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 0. 低电量关怀预警 (电量 <= 20% 且未充电时提醒)
        if (batteryLevel != null && batteryLevel! <= 20 && !isCharging)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.errorRose.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppTheme.errorRose.withOpacity(0.5),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.battery_alert_rounded,
                    color: AppTheme.errorRose, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '🪫 手机当前电量仅剩 $batteryLevel%，请及时充电以防 2BOT 状态失联',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.errorRose,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),

        // 1. 系统电池白名单引导条 (未加白时提醒)
        if (!isIgnoringBatteryOptimizations)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
                const Icon(Icons.shield_outlined,
                    color: AppTheme.warningAmber, size: 20),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '⚠️ 尚未加入系统电池白名单，易被厂商后台查杀',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.warningAmber,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: onRequestBatteryOptimization,
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.warningAmber,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('一键加白',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),

        // 2. 屏幕使用时长授权引导条 (未开启使用情况访问权限时)
        if (!hasUsagePermission)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.primaryCyan.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppTheme.primaryCyan.withOpacity(0.4),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.insights_rounded,
                    color: AppTheme.primaryCyan, size: 20),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '📊 开启使用情况访问权限以感知今日屏幕时长',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.primaryCyan,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: onRequestUsagePermission,
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.primaryCyan,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('去授权',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),

        // 3. 通知权限引导条 (未授予时前台常驻服务无法发通知保活)
        if (!hasNotificationPermission)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.secondarySky.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppTheme.secondarySky.withOpacity(0.4),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.notifications_active_outlined,
                    color: AppTheme.secondarySky, size: 20),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '🔔 开启通知权限以确保后台常驻服务稳定保活',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.secondarySky,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: onRequestNotificationPermission,
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.secondarySky,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('去开启',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),

        // 4. 步数与健身运动权限提示
        if (!hasActivityPermission)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.secondarySky.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppTheme.secondarySky.withOpacity(0.4),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.directions_walk_rounded,
                    color: AppTheme.secondarySky, size: 20),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '开启健身运动权限可实时感知今日步数',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.secondarySky,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: onRequestActivityPermission,
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.secondarySky,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('点击授权',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),

        // 5. 若未授予定位权限，显示温馨提示条（读取 WiFi SSID 需要）
        if (!hasLocationPermission)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
                const SizedBox(height: 10),

                // 3. 国产主流手机后台防杀防休眠指引
                InkWell(
                  onTap: () => _showRomSurvivalGuide(context),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.help_outline_rounded,
                            size: 14, color: AppTheme.textMuted),
                        SizedBox(width: 6),
                        Text(
                          '国产主流机型（小米/华为/OPPO/vivo）后台保活指引',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ],
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

  /// 弹出主流国产 ROM 后台防杀设置详细指引
  void _showRomSurvivalGuide(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.cardBorder),
        ),
        title: const Row(
          children: [
            Icon(Icons.security_rounded, color: AppTheme.primaryCyan, size: 22),
            SizedBox(width: 8),
            Text('系统后台防杀保活指引', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: const [
              Text(
                '国产 Android 系统存在激进的后台杀进程机制。如需让 2BOT 伴侣端 24 小时稳定上报，请按您手机的品牌完成以下三步设置：',
                style: TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary, height: 1.5),
              ),
              SizedBox(height: 12),
              Text(
                '① 小米 / 红米 (HyperOS / MIUI)：',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.primaryCyan),
              ),
              Text(
                '• 应用管理 → 找到 2BOT 伴侣 → 开启【自启动】\n• 省电策略设为【无限制】\n• 多任务卡片界面下拉锁定本应用',
                style: TextStyle(
                    fontSize: 12, color: AppTheme.textMuted, height: 1.5),
              ),
              SizedBox(height: 10),
              Text(
                '② 华为 / 荣耀 (HarmonyOS / MagicOS)：',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.secondarySky),
              ),
              Text(
                '• 应用启动管理 → 找到 2BOT 伴侣 → 关闭“自动管理”\n• 改为手动开启：允许自启动、允许关联启动、允许后台活动',
                style: TextStyle(
                    fontSize: 12, color: AppTheme.textMuted, height: 1.5),
              ),
              SizedBox(height: 10),
              Text(
                '③ OPPO / 一加 / realme (ColorOS)：',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.accentEmerald),
              ),
              Text(
                '• 应用配置 → 电池 → 开启【允许完全后台行为】\n• 权限中开启【允许自启动】与【应用关联启动】',
                style: TextStyle(
                    fontSize: 12, color: AppTheme.textMuted, height: 1.5),
              ),
              SizedBox(height: 10),
              Text(
                '④ vivo / iQOO (OriginOS)：',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.warningAmber),
              ),
              Text(
                '• 权限管理 → 开启【自启动】\n• 电池 → 后台耗电管理 → 设为【允许后台高耗电】',
                style: TextStyle(
                    fontSize: 12, color: AppTheme.textMuted, height: 1.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child:
                const Text('我已知晓', style: TextStyle(color: AppTheme.primaryCyan)),
          ),
        ],
      ),
    );
  }
}
