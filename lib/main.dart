import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/background_task_service.dart';
import 'services/storage_service.dart';
import 'utils/theme.dart';
import 'views/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. 设置沉浸式暗黑状态栏与导航栏
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppTheme.background,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // 2. 初始化持久化存储
  await StorageService.init();

  // 3. 初始化前台常驻保活服务配置
  BackgroundTaskService.init();

  // 4. 若此前开启了前台常驻服务，开机或启动时自动恢复保活
  final settings = StorageService.loadSettings();
  if (settings.isServiceEnabled) {
    await BackgroundTaskService.startService(settings.intervalMinutes);
  }

  runApp(const BotCompanionApp());
}

/// 2BOT 伴侣端根 Widget
class BotCompanionApp extends StatelessWidget {
  const BotCompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '2BOT 伴侣',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const HomeScreen(),
    );
  }
}
