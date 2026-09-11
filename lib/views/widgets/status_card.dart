import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/device_telemetry.dart';
import '../../utils/theme.dart';

/// 实时物理状态看板卡片
class StatusCard extends StatelessWidget {
  final DeviceTelemetry? snapshot;
  final DateTime? lastReportTime;
  final String? lastReportStatus;
  final bool isRefreshing;
  final VoidCallback onRefresh;

  const StatusCard({
    super.key,
    required this.snapshot,
    required this.lastReportTime,
    required this.lastReportStatus,
    required this.isRefreshing,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final hasReport = lastReportTime != null;
    final timeStr = hasReport
        ? DateFormat('MM-dd HH:mm:ss').format(lastReportTime!)
        : '暂无上报记录';
    final isSuccess = lastReportStatus?.contains('200') ?? false;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部：标题与实时刷新按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSuccess
                            ? AppTheme.accentEmerald
                            : AppTheme.warningAmber,
                        boxShadow: [
                          BoxShadow(
                            color: (isSuccess
                                    ? AppTheme.accentEmerald
                                    : AppTheme.warningAmber)
                                .withOpacity(0.5),
                            blurRadius: 8,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      '设备感知实时看板',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textPrimary,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                IconButton(
                  icon: isRefreshing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppTheme.primaryCyan,
                          ),
                        )
                      : const Icon(Icons.refresh_rounded,
                          size: 20, color: AppTheme.textSecondary),
                  onPressed: isRefreshing ? null : onRefresh,
                  tooltip: '重新探测本地状态',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 18),

            // 三项核心硬件指示项
            Row(
              children: [
                // 1. 电量卡
                Expanded(
                  child: _buildMetricTile(
                    icon: snapshot?.battery.isCharging ?? false
                        ? Icons.battery_charging_full_rounded
                        : Icons.battery_std_rounded,
                    iconColor: snapshot?.battery.isCharging ?? false
                        ? AppTheme.accentEmerald
                        : AppTheme.secondarySky,
                    label: '当前电量',
                    value: snapshot != null
                        ? '${snapshot!.battery.level}%'
                        : '--',
                    subValue: snapshot?.battery.isCharging ?? false
                        ? '充电中 ⚡'
                        : '放电中',
                  ),
                ),
                const SizedBox(width: 12),

                // 2. WiFi / 网络
                Expanded(
                  child: _buildMetricTile(
                    icon: (snapshot?.wifi.connected ?? false)
                        ? Icons.wifi_rounded
                        : Icons.wifi_off_rounded,
                    iconColor: (snapshot?.wifi.connected ?? false)
                        ? AppTheme.primaryCyan
                        : AppTheme.textMuted,
                    label: '当前网络',
                    value: (snapshot?.wifi.connected ?? false)
                        ? (snapshot!.wifi.ssid.isNotEmpty
                            ? snapshot!.wifi.ssid
                            : '已连 WiFi')
                        : '移动蜂窝',
                    subValue: (snapshot?.wifi.connected ?? false)
                        ? '无线局域网'
                        : '蜂窝数据',
                  ),
                ),
                const SizedBox(width: 12),

                // 3. 锁屏活跃
                Expanded(
                  child: _buildMetricTile(
                    icon: (snapshot?.screenLocked ?? false)
                        ? Icons.lock_outline_rounded
                        : Icons.lock_open_rounded,
                    iconColor: (snapshot?.screenLocked ?? false)
                        ? AppTheme.textMuted
                        : AppTheme.accentEmerald,
                    label: '屏幕状态',
                    value: (snapshot?.screenLocked ?? false) ? '息屏锁屏' : '活跃亮屏',
                    subValue: (snapshot?.screenLocked ?? false) ? '待机休眠' : '前台使用',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Divider(color: AppTheme.cardBorder, height: 1),
            const SizedBox(height: 14),

            // 底部：最后上报时间与服务端回执
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      const Icon(Icons.history_rounded,
                          size: 16, color: AppTheme.textMuted),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '最近上报: $timeStr',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: isSuccess
                        ? AppTheme.accentEmerald.withOpacity(0.12)
                        : AppTheme.errorRose.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.parse(
                      BorderSide(
                        color: isSuccess
                            ? AppTheme.accentEmerald.withOpacity(0.4)
                            : AppTheme.errorRose.withOpacity(0.4),
                      ),
                    ),
                  ),
                  child: Text(
                    lastReportStatus ?? '未同步',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isSuccess
                          ? AppTheme.accentEmerald
                          : AppTheme.errorRose,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricTile({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
    required String subValue,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: iconColor, size: 22),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            subValue,
            style: TextStyle(
              fontSize: 10,
              color: iconColor.withOpacity(0.8),
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
