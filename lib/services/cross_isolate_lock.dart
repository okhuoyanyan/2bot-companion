/// ============================================================================
/// WO-69 第三轮整改 P2/P3 · 跨 isolate 原子锁（OS 级文件锁）
/// ============================================================================
/// 背景（架构师裁定 2026-09-27）：SharedPreferencesAsync 的「读-判断-写」非原子，
/// 双 isolate 同读旧值 → 同秒双 SMTP 会话（TOCTOU）。本工具用
/// Windows/Android 沿用 RandomAccessFile.lock；Linux 使用 OS flock，
/// 避开 fcntl 进程级锁可在同进程 isolate 重入的语义（WO-105）：
/// 后到者在锁上排队，先到者持锁完成「读-判-写-等待」全程。
///
/// 锁文件位于 Directory.systemTemp（Flutter 引擎在 Android 上将 TMPDIR 指向
/// 应用 cache 目录，同进程所有 isolate 共享同一 environ → 同一锁文件）。
/// 测试可经 lockDirOverride 注入临时目录。

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
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
  // WO-105：Linux 的 RandomAccessFile.lock 是进程级 fcntl 锁，不能互斥
  // 同进程 isolate。仅 Linux 用 open-file-description 级 flock；其他平台
  // 完整保留原路径（包括 Windows/Android 与 WO-70 重试耗尽政策）。
  if (Platform.isLinux) {
    return _linuxSynchronized(lockName, body,
        sleep: sleep, retryInterval: retryInterval, maxRetries: maxRetries);
  }
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

Future<T> _linuxSynchronized<T>(String lockName, Future<T> Function() body,
    {Future<void> Function(Duration)? sleep,
    required Duration retryInterval,
    required int maxRetries}) async {
  final doSleep = sleep ?? Future<void>.delayed;
  final lockFile = File('${resolveLockDir()}/wo69_$lockName.lock');
  _LinuxLock? lease;
  for (var attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      // Dart 创建文件；native open 不用 O_CREAT，因此没有 variadic mode 参数。
      final seed = await lockFile.open(mode: FileMode.append);
      await seed.close();
      lease = _LinuxLock.open(lockFile.path);
      if (!lease.tryLock()) throw StateError('Linux lock busy or unavailable');
      break;
    } catch (_) {
      lease?.close();
      lease = null;
      if (attempt < maxRetries) await doSleep(retryInterval);
    }
  }
  if (lease == null) {
    // 按批准裁定保留 WO-70 既有耗尽政策；不增加新的降级分支。
    return body();
  }
  try {
    return await body();
  } finally {
    try {
      lease.unlock();
    } finally {
      lease.close();
    }
  }
}

// SDK FFI 直接调用 libc，无新增包或外部命令。所有字段懒初始化，只有
// Platform.isLinux 分支调用，Windows/Android 不加载 native 符号。
class _LinuxLockBindings {
  static final instance = _LinuxLockBindings();
  final malloc = DynamicLibrary.process().lookupFunction<
      Pointer<Uint8> Function(UintPtr), Pointer<Uint8> Function(int)>('malloc');
  final free = DynamicLibrary.process().lookupFunction<
      Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>('free');
  final open = DynamicLibrary.process().lookupFunction<
      Int32 Function(Pointer<Uint8>, Int32),
      int Function(Pointer<Uint8>, int)>('open');
  final flock = DynamicLibrary.process()
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
          'flock');
  final close = DynamicLibrary.process()
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
}

class _LinuxLock {
  static const _openReadWrite = 2; // Linux O_RDWR
  static const _closeOnExec = 0x80000; // Linux O_CLOEXEC，子进程不继承锁 fd。
  static const _exclusive = 2; // LOCK_EX
  static const _nonBlocking = 4; // LOCK_NB
  static const _unlock = 8; // LOCK_UN
  final _LinuxLockBindings _api;
  int? _fd;

  _LinuxLock._(this._api, this._fd);

  factory _LinuxLock.open(String path) {
    final api = _LinuxLockBindings.instance;
    final bytes = utf8.encode(path);
    final nativePath = api.malloc(bytes.length + 1);
    if (nativePath == nullptr) {
      throw StateError('Linux lock path allocation failed');
    }
    try {
      final buffer = nativePath.asTypedList(bytes.length + 1);
      buffer.setAll(0, bytes);
      buffer[bytes.length] = 0;
      final fd = api.open(nativePath, _openReadWrite | _closeOnExec);
      if (fd < 0) throw FileSystemException('Linux lock open failed', path);
      return _LinuxLock._(api, fd);
    } finally {
      // open 成功、失败及 Dart 异常都释放 UTF-8 native 内存。
      api.free(nativePath);
    }
  }

  bool tryLock() => _api.flock(_fd!, _exclusive | _nonBlocking) == 0;

  void unlock() {
    _api.flock(_fd!, _unlock);
  }

  void close() {
    final fd = _fd;
    _fd = null; // 防止重复 close 误伤已被 OS 复用的 fd。
    if (fd != null) _api.close(fd);
  }
}
