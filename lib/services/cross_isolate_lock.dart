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

/// 在名为 [lockName] 的 OS 级文件锁内执行 [body]（同进程跨 isolate 真互斥）。
/// 锁获取失败（如目录不可写）→ 降级为直接执行（调用方须容忍弱化语义）。
Future<T> crossIsolateSynchronized<T>(
  String lockName,
  Future<T> Function() body,
) async {
  final dir = lockDirOverride ?? Directory.systemTemp.path;
  final lockFile = File('$dir/wo69_$lockName.lock');
  RandomAccessFile? raf;
  try {
    raf = await lockFile.open(mode: FileMode.append);
    // 必须 blockingExclusive（阻塞等待）：exclusive 在 Windows 上是非阻塞语义，
    // 第二个锁会立即抛 PathAccessException——被降级 catch 吞掉后即退化为无锁并发
    //（第三轮实测：0.0s 间隔同秒双会话的根因）。
    await raf.lock(FileLock.blockingExclusive);
  } catch (_) {
    // 锁不可用（目录不可写/平台不支持）：降级为无锁执行，绝不阻断上报主链
    raf?.close();
    return body();
  }
  try {
    return await body();
  } finally {
    try {
      await raf.unlock();
    } catch (_) {}
    try {
      await raf.close();
    } catch (_) {}
  }
}
