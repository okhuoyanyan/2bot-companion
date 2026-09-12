import 'dart:async';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/app_settings.dart';
import '../models/device_telemetry.dart';
import '../services/background_task_service.dart';
import '../services/storage_service.dart';
import '../services/telemetry_collector_service.dart';
import '../services/telemetry_uploader_service.dart';
import '../utils/theme.dart';
import 'widgets/config_card.dart';
import 'widgets/quick_actions.dart';
import 'widgets/status_card.dart';

/// 2BOT 伴侣端主界面
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late AppSettings _settings;
  DeviceTelemetry? _snapshot;
  bool _isRefreshing = false;
  bool _isReporting = false;
  bool _isServiceRunning = false;
  bool _hasLocationPermission = true;
  bool _isIgnoringBatteryOptimizations = true;
  bool _hasActivityPermission = true;
  bool _hasUsagePermission = true;
  bool _hasNotificationPermission = true;

  StreamSubscription<BatteryState>? _batterySubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadInitialData();
    _setupEventDrivenListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _batterySubscription?.cancel();
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshLocalSnapshot();
      _checkLocationPermission();
      _checkActivityPermission();
      _checkUsagePermission();
      _checkNotificationPermission();
      _checkServiceStatus();
    }
  }

  /// 初始化加载本地配置与状态
  Future<void> _loadInitialData() async {
    _settings = StorageService.loadSettings();
    _checkLocationPermission();
    _checkActivityPermission();
    _checkUsagePermission();
    _checkNotificationPermission();
    _checkServiceStatus();
    await _refreshLocalSnapshot();
  }

  /// 检查前台常驻服务实际运行状态
  Future<void> _checkServiceStatus() async {
    final running = await BackgroundTaskService.isRunning();
    if (mounted) {
      setState(() {
        _isServiceRunning = running;
      });
    }
  }

  /// 检查定位权限 (WiFi SSID 读取必需)
  Future<void> _checkLocationPermission() async {
    final granted = await Permission.location.isGranted;
    if (mounted) {
      setState(() {
        _hasLocationPermission = granted;
      });
    }
  }

  /// 检查健身运动权限 (步数读取必需)
  Future<void> _checkActivityPermission() async {
    final granted = await Permission.activityRecognition.isGranted;
    if (mounted) {
      setState(() {
        _hasActivityPermission = granted;
      });
    }
  }

  /// 检查使用情况访问权限 (屏幕使用时长统计必需)
  Future<void> _checkUsagePermission() async {
    final granted = await TelemetryCollectorService.hasUsagePermission();
    if (mounted) {
      setState(() {
        _hasUsagePermission = granted;
      });
    }
  }

  /// 检查通知发送权限 (Android 13+ 前台保活必需)
  Future<void> _checkNotificationPermission() async {
    final granted = await Permission.notification.isGranted;
    if (mounted) {
      setState(() {
        _hasNotificationPermission = granted;
      });
    }
  }

  /// 配置双驱动事件监听 (充放电插拔、WiFi 连接切换即时触发上报)
  void _setupEventDrivenListeners() {
    // 1. 电池状态改变监听
    _batterySubscription = Battery().onBatteryStateChanged.listen((state) {
      debugPrint('[EventDriver] 监测到电池充放电状态切换: $state');
      _triggerSilentReport();
    });

    // 2. 网络连通状态切换监听
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) {
      debugPrint('[EventDriver] 监测到网络连接状态变更: $results');
      _triggerSilentReport();
    });
  }

  /// 本地状态重新探测
  Future<void> _refreshLocalSnapshot() async {
    setState(() => _isRefreshing = true);
    try {
      final snap = await TelemetryCollectorService.collectSnapshot(
        isAppForeground: true,
      );
      if (mounted) {
        setState(() {
          _snapshot = snap;
          if (snap.isIgnoringBatteryOptimizations != null) {
            _isIgnoringBatteryOptimizations =
                snap.isIgnoringBatteryOptimizations!;
          }
          if (snap.hasUsagePermission != null) {
            _hasUsagePermission = snap.hasUsagePermission!;
          }
          _settings = StorageService.loadSettings();
        });
      }
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  /// 事件驱动型静默自动上报
  Future<void> _triggerSilentReport() async {
    try {
      final snap = await TelemetryCollectorService.collectSnapshot(
        isAppForeground: true,
      );
      await TelemetryUploaderService.upload(snap);
      if (mounted) {
        setState(() {
          _snapshot = snap;
          if (snap.isIgnoringBatteryOptimizations != null) {
            _isIgnoringBatteryOptimizations =
                snap.isIgnoringBatteryOptimizations!;
          }
          if (snap.hasUsagePermission != null) {
            _hasUsagePermission = snap.hasUsagePermission!;
          }
          _settings = StorageService.loadSettings();
        });
      }
    } catch (_) {}
  }

  /// 手动点击【立即测试上报一次】
  Future<void> _handleManualTestReport() async {
    setState(() => _isReporting = true);
    try {
      final snap = await TelemetryCollectorService.collectSnapshot(
        isAppForeground: true,
      );
      final result = await TelemetryUploaderService.upload(snap);

      if (!mounted) return;

      setState(() {
        _snapshot = snap;
        if (snap.isIgnoringBatteryOptimizations != null) {
          _isIgnoringBatteryOptimizations =
              snap.isIgnoringBatteryOptimizations!;
        }
        if (snap.hasUsagePermission != null) {
          _hasUsagePermission = snap.hasUsagePermission!;
        }
        _settings = StorageService.loadSettings();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                result.success ? Icons.check_circle_rounded : Icons.error_rounded,
                color: result.success ? AppTheme.accentEmerald : AppTheme.errorRose,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  result.success
                      ? '上报成功！${result.message}'
                      : '上报失败：${result.message}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) setState(() => _isReporting = false);
    }
  }

  /// 切换前台常驻保活服务开关
  Future<void> _handleToggleService(bool enable) async {
    if (enable) {
      final ok = await BackgroundTaskService.startService(_settings.intervalMinutes);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('⚠️ 启动常驻服务失败，请先授予通知发送权限！')),
        );
      }
    } else {
      await BackgroundTaskService.stopService();
    }
    await _checkServiceStatus();
  }

  /// 保存设置
  Future<void> _handleSaveConfig(String url, String token, int interval) async {
    await StorageService.saveConfig(
      relayUrl: url,
      deviceToken: token,
      intervalMinutes: interval,
    );

    // 若当前前台服务正在运行，热重启服务以应用新频率
    if (_isServiceRunning) {
      await BackgroundTaskService.startService(interval);
    }

    if (!mounted) return;
    setState(() {
      _settings = StorageService.loadSettings();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            Icon(Icons.check_circle_outline_rounded, color: AppTheme.accentEmerald, size: 20),
            SizedBox(width: 10),
            Text('中继与心跳配置已成功持久化保存！'),
          ],
        ),
      ),
    );
  }

  /// 申请 WiFi 定位权限
  Future<void> _handleRequestPermission() async {
    final ok = await TelemetryCollectorService.requestLocationPermission();
    if (mounted) {
      setState(() => _hasLocationPermission = ok);
      if (ok) {
        _refreshLocalSnapshot();
      }
    }
  }

  /// 申请电池优化白名单 (直达系统弹窗)
  Future<void> _handleRequestBatteryOptimization() async {
    await TelemetryCollectorService.requestIgnoreBatteryOptimizations();
    await _refreshLocalSnapshot();
  }

  /// 申请步数/健身运动权限
  Future<void> _handleRequestActivityPermission() async {
    final ok = await TelemetryCollectorService.requestActivityPermission();
    if (mounted) {
      setState(() => _hasActivityPermission = ok);
      if (ok) {
        _refreshLocalSnapshot();
      }
    }
  }

  /// 申请使用情况访问权限 (直达系统设置页)
  Future<void> _handleRequestUsagePermission() async {
    await TelemetryCollectorService.openUsageSettings();
    await _checkUsagePermission();
    await _refreshLocalSnapshot();
  }

  /// 申请通知发送权限 (保活必需)
  Future<void> _handleRequestNotificationPermission() async {
    final ok = await TelemetryCollectorService.requestNotificationPermission();
    if (mounted) {
      setState(() => _hasNotificationPermission = ok);
      if (ok) {
        _refreshLocalSnapshot();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppTheme.primaryCyan.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.radar_rounded,
                color: AppTheme.primaryCyan,
                size: 22,
              ),
            ),
            const SizedBox(width: 10),
            const Text('2BOT 伴侣'),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.cardBorder,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                'v1.3.0',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textSecondary,
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline_rounded, color: AppTheme.textSecondary),
            onPressed: () => _showAboutDialog(context),
            tooltip: '架构与开源协议说明',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshLocalSnapshot,
        color: AppTheme.primaryCyan,
        backgroundColor: AppTheme.cardSurface,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            // 0. 未配置密钥/端点引导横幅
            if (_settings.deviceToken.isEmpty ||
                _settings.relayUrl.contains('your-relay-service'))
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.warningAmber.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.warningAmber.withOpacity(0.4),
                  ),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.lock_clock_outlined,
                        color: AppTheme.warningAmber, size: 24),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '尚未配置云端中继密钥',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.warningAmber,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            '请在下方【云端通信与中继设置】中填入您自己部署的中继 URL 与私有 Token 即可开启自动上报。',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppTheme.textSecondary,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

            // 1. 实时状态看板卡片
            StatusCard(
              snapshot: _snapshot,
              lastReportTime: _settings.lastReportTime,
              lastReportStatus: _settings.lastReportStatus,
              isRefreshing: _isRefreshing,
              onRefresh: _refreshLocalSnapshot,
            ),

            // 2. 快捷操作与保活开关
            QuickActions(
              isServiceRunning: _isServiceRunning,
              isReporting: _isReporting,
              hasLocationPermission: _hasLocationPermission,
              isIgnoringBatteryOptimizations: _isIgnoringBatteryOptimizations,
              hasActivityPermission: _hasActivityPermission,
              hasUsagePermission: _hasUsagePermission,
              hasNotificationPermission: _hasNotificationPermission,
              batteryLevel: _snapshot?.batteryLevel,
              isCharging: _snapshot?.isCharging ?? false,
              onToggleService: _handleToggleService,
              onTestReport: _handleManualTestReport,
              onRequestPermission: _handleRequestPermission,
              onRequestBatteryOptimization: _handleRequestBatteryOptimization,
              onRequestActivityPermission: _handleRequestActivityPermission,
              onRequestUsagePermission: _handleRequestUsagePermission,
              onRequestNotificationPermission: _handleRequestNotificationPermission,
            ),

            // 3. 云端通信与中继配置卡片
            ConfigCard(
              initialRelayUrl: _settings.relayUrl,
              initialToken: _settings.deviceToken,
              initialIntervalMinutes: _settings.intervalMinutes,
              onSave: _handleSaveConfig,
            ),

            const SizedBox(height: 12),

            // 4. 底部极客声明
            const Center(
              child: Text(
                '2BOT Ecosystem • 100% Pure Open Source • Zero Commercial Ads',
                style: TextStyle(
                  fontSize: 11,
                  color: AppTheme.textMuted,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  void _showAboutDialog(BuildContext context) {
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
            Icon(Icons.terminal_rounded, color: AppTheme.primaryCyan),
            SizedBox(width: 8),
            Text('关于 2BOT 伴侣端', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '2bot-companion 是为 2BOT-NEW 双智能体管家定制的专属 Android 伴侣应用。',
              style: TextStyle(fontSize: 13, height: 1.5, color: AppTheme.textSecondary),
            ),
            SizedBox(height: 12),
            Text(
              '• 纯血开源：0 商业广告、0 追踪 SDK、极致轻量\n'
              '• 双驱动上报：插拔充放电/网络切换即时触发 + 定时保底\n'
              '• 隐私安全：所有数据仅流经您指定的个人 Vercel 中继',
              style: TextStyle(fontSize: 12, height: 1.6, color: AppTheme.textMuted),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭', style: TextStyle(color: AppTheme.primaryCyan)),
          ),
        ],
      ),
    );
  }
}
