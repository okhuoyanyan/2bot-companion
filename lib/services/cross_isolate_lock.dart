/// ============================================================================
/// WO-69 第三轮整改 P2/P3 · 跨 isolate 原子锁（OS 级文件锁）
/// ============================================================================
/// 背景（架构师裁定 2026-09-27）：SharedPreferencesAsync 的「读-判断-写」非原子，
/// 双 isolate 同读旧值 → 同秒双 SMTP 会话（TOCTOU）。本工具用
/// RandomAccessFile.lock（FileLock.exclusive）提供跨 isolate（同进程）真互斥：
/// 后到者在锁上排队，先到者持锁完成「读-判-写-等待」全程。
///
/// 锁文件位于 Directory.systemTemp（Flutter 引擎在 Android 上将 TMPDIR 指向
/// 应用 cache 目录，同进程所有 isolate 共享同一 environ → 同一锁文件）。
/// 测试可经 lockDirOverride 注入临时目录。

import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';

/// 测试注入点：锁文件目录（生产 = Directory.systemTemp）
@visibleForTesting
String? lockDirOverride;

/// 锁/戳文件目录解析（生产语义：override 优先，否则系统临时目录）。
/// 公开给同包服务（smtp 盖章文件与锁同目录），避免生产代码触测测试钩子告警。
String resolveLockDir() => lockDirOverride ?? Directory.systemTemp.path;

/// WO-70 §7 闪屏修复：锁获取【严禁阻塞等待】——`blockingExclusive` 在主
/// isolate 上会把调用链卡住最长 minSessionGap（闪屏回归根因）。改为
/// 【非阻塞尝试 + 异步让出重试】：拿不到锁 → 异步 sleep 后重试（事件循环
/// 始终空闲，任何 isolate 的 UI/遥测链路都不被卡死），有界重试后降级放行。
Future<T> crossIsolateSynchronized<T>(
  String lockName,
  Future<T> Function() body, {
  Future<void> Function(Duration)? sleep,
  Duration retryInterval = const Duration(milliseconds: 200),
  int maxRetries = 20,
}) async {
  final doSleep = sleep ?? Future<void>.delayed;
  final dir = lockDirOverride ?? Directory.systemTemp.path;
  final lockFile = File('$dir/wo69_$lockName.lock');
  RandomAccessFile? raf;
  var locked = false;
  for (var attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      raf ??= await lockFile.open(mode: FileMode.append);
      // 非阻塞尝试：exclusive 在 busy 时立即抛 PathAccessException（Windows 实测）
      await raf.lock(FileLock.exclusive);
      locked = true;
      break;
    } catch (_) {
      try {
        await raf?.close();
      } catch (_) {}
      raf = null;
      if (attempt < maxRetries) await doSleep(retryInterval);
    }
  }
  if (!locked) {
    // 有界重试耗尽（锁被长占）：降级为无锁执行——观测/发送是可容忍弱语义的路径，
    // 绝不允许为锁阻塞任何 isolate（WO-70 §7 硬性规则①）
    return body();
  }
  try {
    return await body();
  } finally {
    try {
      await raf?.unlock();
    } catch (_) {}
    try {
      await raf?.close();
    } catch (_) {}
  }
}
