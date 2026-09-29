import 'package:flutter/services.dart';

/// WO-75 Phase B · 保活自检通道（只读状态 + 标准跳转，零生命周期改动）。
///
/// 裁定要点落地：
/// ① 电池优化忽略状态 = PowerManager.isIgnoringBatteryOptimizations 真实读取
///    （MethodChannel `com.twobot.companion/native_sensors`，Android 侧无缓存）；
/// ② 自启动白名单/最近任务锁定：MIUI 无公开检测 API——本服务【不提供】这两项的
///    检测值，只提供「跳系统页（可跳则跳）」，UI 一律走文字指引；
/// ③ 不触碰 foreground/onDestroy/START_STICKY 任何生命周期代码。
class KeepaliveCheckService {
  static const MethodChannel _channel =
      MethodChannel('com.twobot.companion/native_sensors');

  /// 电池优化是否已被忽略（真实状态；读取失败返回 null=未知，UI 显示「无法读取」）
  static Future<bool?> isIgnoringBatteryOptimizations() async {
    try {
      return await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 跳系统「请求忽略电池优化」对话框（标准 intent，Android 侧已带降级路径）
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    try {
      return await _channel
              .invokeMethod<bool>('requestIgnoreBatteryOptimizations') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 跳 MIUI 自启动管理页（可跳则跳；false=该 ROM 无此入口，UI 回退纯文字指引）
  static Future<bool> openAutostartSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openAutostartSettings') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
