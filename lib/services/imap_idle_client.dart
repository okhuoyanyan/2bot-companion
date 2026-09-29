import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../utils/constants.dart';

/// ============================================================================
/// WO-69 · 自写 IMAP4rev1 + IDLE 客户端（dart:io SecureSocket，零外部依赖）
/// ============================================================================
/// 平台真相对齐（NAS 侧 imap-client.mjs「QQ 邮箱 IMAP 平台真相表」2026-09-21 实测沉淀）：
///  1. **文本搜索键一律不可用**（SUBJECT/TEXT 被 QQ 忽略并返回全量）→ 检索走
///     `UID SEARCH UID n:*` 粗筛 + 客户端拉 SUBJECT 头精筛；
///  2. **flag 落不上**（\Seen 永不生效）→ "已处理"语义由 UID 水位线承载，本客户端只读不标记；
///  3. **literal 必须按字节收**（响应可能被 TCP 分片切开）→ [ImapAssembler] 严格按
///     `{n}` 字节数判定收满，未收满继续等下一个分片；
///  4. 凭据红线：授权码绝不进入任何日志/错误文案（LOGIN 命令零转写）。
///
/// IDLE 实测结论（WO-69 开工首验 2026-09-26，真机真邮箱）：
///  - SMTP 投递（MTA 入信）→ IDLE 推 `* n EXISTS` 约 1.2 秒（主路径成立）；
///  - 单次 IDLE 30.0 分钟被服务端断开（= RFC 2177 的 29 分钟重发纪律上限）→
///    调用方须按 ≤29 分钟周期 DONE+重发 IDLE（25 分钟节拍由上层编排）。
/// 连接/会话参数（凭据来自 flutter_secure_storage 缓存，不落明文）
class ImapConfig {
  final String account;
  final String authCode;
  final String host;
  final int port;

  const ImapConfig({
    required this.account,
    required this.authCode,
    this.host = AppConstants.defaultImapHost,
    this.port = AppConstants.defaultImapPort,
  });

  bool get isReady => account.trim().isNotEmpty && authCode.trim().isNotEmpty;
}

/// 一条装配完成的 IMAP 响应单元：首行 [head] + 内嵌 literal 文本 [literals]
/// （FETCH 形如 `* 1 FETCH (UID 7 BODY[] {4512}` + <4512 字节> + 独立一行 `)`）
class ImapUnit {
  final String head;
  final List<String> literals;

  const ImapUnit(this.head, this.literals);

  bool get isUntagged => head.startsWith('* ');
  bool get isContinuation => head.startsWith('+');

  /// tagged 响应的 tag（如 `C101`）；untagged/continuation 返回 null
  String? get tag {
    final t = head.split(' ').first;
    return (t == '*' || t == '+') ? null : t;
  }

  /// tagged 响应状态（OK/NO/BAD）
  String? get status {
    if (tag == null) return null;
    final parts = head.split(' ');
    return parts.length > 1 ? parts[1].toUpperCase() : null;
  }
}

class ImapClosedException implements Exception {
  final String reason;
  ImapClosedException(this.reason);
  @override
  String toString() => 'IMAP 连接已关闭: $reason';
}

class ImapCommandException implements Exception {
  final String command;
  final String status;
  ImapCommandException(this.command, this.status);
  @override
  String toString() => 'IMAP 命令 $command 失败（$status）';
}

/// IMAP literal 感知响应装配器（零 IO 纯状态机，单测可按任意分片喂字节）
class ImapAssembler {
  static final RegExp _literalTail = RegExp(r'\{(\d+)\}$');

  Uint8List _data = Uint8List(0);
  int _pos = 0;
  String? _pendingHead; // 收 literal 前的行头（未完成单元）
  int _literalDeclared = 0; // 当前待收 literal 的声明字节数
  final List<String> _pendingLiterals = <String>[];
  final List<ImapUnit> _units = <ImapUnit>[];

  /// 喂入任意长度的字节分片（片界可在 literal 中间/行中间）
  void add(List<int> chunk) {
    if (chunk.isEmpty) return;
    try {
      _drainAdd(chunk);
    } catch (_) {
      rethrow;
    }
  }

  void _drainAdd(List<int> chunk) {
    final merged = Uint8List(_data.length - _pos + chunk.length);
    merged.setRange(0, _data.length - _pos, _data, _pos);
    merged.setRange(_data.length - _pos, merged.length, chunk);
    _data = merged;
    _pos = 0;
    _drain();
  }

  /// 是否还有待取单元
  bool get hasUnits => _units.isNotEmpty;

  /// 取出全部已装配单元
  List<ImapUnit> takeUnits() {
    final out = List<ImapUnit>.of(_units);
    _units.clear();
    return out;
  }

  void _drain() {
    while (true) {
      if (_pendingHead != null) {
        // literal 接收态：严格按声明字节数收取（收不满等下一分片）
        final need = _literalDeclared;
        if (_data.length - _pos < need) return;
        final literalBytes = Uint8List.sublistView(_data, _pos, _pos + need);
        _pendingLiterals.add(utf8.decode(literalBytes, allowMalformed: true));
        _pos += need;
        final head = _pendingHead!;
        _pendingHead = null;
        _finishUnit(head);
        continue;
      }
      final crlf = _indexOfCrlf();
      if (crlf < 0) return; // 行未收满
      final lineBytes = Uint8List.sublistView(_data, _pos, crlf);
      _pos = crlf + 2;
      final line = utf8.decode(lineBytes, allowMalformed: true);
      final m = _literalTail.firstMatch(line);
      if (m != null) {
        _pendingHead = line; // 进入 literal 接收态
        _literalDeclared = int.parse(m.group(1)!);
        continue;
      }
      _finishUnit(line);
    }
  }

  void _finishUnit(String head) {
    _units.add(ImapUnit(head, List<String>.of(_pendingLiterals)));
    _pendingLiterals.clear();
    if (_pos > 64 * 1024) {
      // 缓冲压缩：防止大邮件残留导致内存膨胀
      _data = Uint8List.sublistView(_data, _pos);
      _pos = 0;
    }
  }

  int _indexOfCrlf() {
    for (var i = _pos; i < _data.length - 1; i++) {
      if (_data[i] == 13 && _data[i + 1] == 10) return i;
    }
    return -1;
  }
}

/// 从 SUBJECT 头部值里匹配日历前缀（客户端精筛：QQ 文本搜索键不可用）
bool subjectMatchesPrefix(String headerText, String prefix) {
  for (final rawLine in headerText.split('\n')) {
    final line = rawLine.trimRight();
    if (line.toUpperCase().startsWith('SUBJECT:')) {
      return line.substring(8).trim().contains(prefix);
    }
  }
  return false;
}

final RegExp _fetchUidPattern =
    RegExp(r'^\*\s+\d+\s+FETCH\s+\(.*?UID\s+(\d+)', caseSensitive: false);

/// FETCH 头响应解析：从单元中提取 (uid, subjectHeader)
({int uid, String header})? parseHeaderFetchUnit(ImapUnit unit) {
  final m = _fetchUidPattern.firstMatch(unit.head);
  if (m == null) return null;
  return (
    uid: int.parse(m.group(1)!),
    header: unit.literals.isNotEmpty ? unit.literals.first : '',
  );
}

/// FETCH 全文响应解析：提取 (uid, 原始邮件全文)
({int uid, String raw})? parseFullFetchUnit(ImapUnit unit) {
  final m = _fetchUidPattern.firstMatch(unit.head);
  if (m == null) return null;
  return (
    uid: int.parse(m.group(1)!),
    raw: unit.literals.isNotEmpty ? unit.literals.first : '',
  );
}

/// SELECT 响应里的 UIDVALIDITY（水位线失效检测唯一依据，与 NAS 同口径）
int? parseUidValidity(List<ImapUnit> units) {
  for (final u in units) {
    final m = RegExp(r'\[UIDVALIDITY\s+(\d+)\]', caseSensitive: false)
        .firstMatch(u.head);
    if (m != null) return int.parse(m.group(1)!);
  }
  return null;
}

/// WO-71 整改 B：EXISTS 推送解析（**必须有捕获组**——此前 `^\*\s+\d+\s+EXISTS`
/// 无捕获组却调用 group(1)! ⇒ 收到推送即 RangeError 崩溃）
int? parseExistsCount(String head) {
  final m =
      RegExp(r'^\*\s+(\d+)\s+EXISTS', caseSensitive: false).firstMatch(head);
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

/// SEARCH 响应解析 → UID 列表
List<int> parseSearchUids(List<ImapUnit> units) {
  for (final u in units) {
    final m = RegExp(r'^\*\s+SEARCH\b(.*)$', caseSensitive: false)
        .firstMatch(u.head);
    if (m != null) {
      return m
          .group(1)!
          .trim()
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .map((s) => int.tryParse(s) ?? 0)
          .where((n) => n > 0)
          .toList();
    }
  }
  return [];
}

/// IMAP 字符串转义（LOGIN 参数用；与 NAS 侧 escapeImapString 同语义）
String _escapeImapString(String s) =>
    s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

/// 拉取到的一封日历邮件
class CalendarMail {
  final int uid;
  final String subject;
  final String raw;

  const CalendarMail({
    required this.uid,
    required this.subject,
    required this.raw,
  });
}

/// IMAP IDLE 客户端驱动（把命令序列打到 SecureSocket 上）
///
/// 生命周期：[connect] → ( [startIdle] ⇄ [waitForEvent] / [stopIdle] → [fetchNewSince] )* → [close]
/// 所有命令 10 秒超时；IDLE 等待节拍由调用方给定。
class ImapIdleClient {
  final ImapConfig config;
  final int tagSeed;

  Socket? _socket;
  StreamSubscription<Uint8List>? _sub;
  final ImapAssembler _assembler = ImapAssembler();
  Completer<void>? _dataWaiter;
  bool _closedByServer = false;
  Object? _streamError;
  int _tagCounter;
  bool _loggedIn = false;
  String? _idleTag;
  final List<ImapUnit> _scratch = <ImapUnit>[];

  /// WO-71 修复「SELECT 成功后卡死」的核心：
  /// `_readUnit` 一次 takeUnits 会取走整批单元，test 命中 return 时
  /// **同批剩余单元必须保留**（此前直接丢弃 → LOGIN/SELECT 响应被丢 →
  /// 之后所有命令永等超时，真机 15s 卡死）。所有消费者统一从本队列取。
  final List<ImapUnit> _unitQueue = <ImapUnit>[];

  /// 从队列/assembler 取下一个单元（内部消费统一入口）
  ImapUnit? _nextUnit() {
    if (_unitQueue.isNotEmpty) return _unitQueue.removeAt(0);
    if (_assembler.hasUnits) {
      _unitQueue.addAll(_assembler.takeUnits());
      if (_unitQueue.isNotEmpty) return _unitQueue.removeAt(0);
    }
    return null;
  }

  /// WO-71 任务 A.4：命令级可观测——每条命令的 发送/首响应/完成/耗时。
  /// 行格式：`IMAP <命令> <阶段> <详情>`；设置页与 logcat 共用。
  void Function(String line)? onCommandLog;

  DateTime? _cmdStart;
  String _cmdName = '';
  bool _firstResponseLogged = false;

  void _log(String s) {
    onCommandLog?.call(s);
  }

  /// WO-71 ④：socket 工厂注入（录制回放测试用；生产 = SecureSocket 直连）
  @visibleForTesting
  static Future<Socket> Function(String host, int port, Duration timeout)?
      socketFactory;

  ImapIdleClient({required this.config, this.tagSeed = 100})
      : _tagCounter = tagSeed;

  bool get isConnected => _socket != null;

  String _nextTag() {
    _tagCounter++;
    return 'C$_tagCounter';
  }

  void _onData(Uint8List chunk) {
    // WO-71：直接喂装配器（消除 _raw/takeBytes 中间层与唤醒时序竞态）
    _assembler.add(chunk);
    _wakeDataWaiter();
  }

  /// 唤醒等待数据的协程
  void _wakeDataWaiter() {
    final w = _dataWaiter;
    if (w != null && !w.isCompleted) {
      _dataWaiter = null;
      w.complete();
    }
  }

  /// WO-71 ④：测试注入口——把字节同步喂进装配器数据路径（等价 socket onData）
  @visibleForTesting
  void debugFeedBytes(Uint8List chunk) => _onData(chunk);

  /// WO-71 ④：命令写出回调（回放轨在此同步注入响应字节）
  @visibleForTesting
  void Function(String cmd)? debugHookOnCommand;

  /// WO-78-R3 ①：IDLE 生命周期日志出口（每跳一行：挂载/重挂/NOOP/推送/断开）。
  /// print 必发 logcat（WO-70 先例）；onLifecycleLog 由上层接入设置页 imapLog 环。
  void Function(String line)? onLifecycleLog;
  DateTime? _idleMountedAt;

  /// WO-78-R3 返工：最近一次唤醒原因（'IDLE推送' / 'NOOP夹带' / 'NOOP查件'）——
  /// 上层作为拉取日志的触发原因（归因可观测）
  String lastWakeReason = '';

  void _life(String msg) {
    final line =
        '[WO78-R3] ${DateTime.now().toIso8601String().substring(11, 19)} $msg';
    // ignore: avoid_print
    print(line);
    try {
      onLifecycleLog?.call(line);
    } catch (_) {}
  }
  /// WO-71 ④：命令完成回调
  @visibleForTesting
  Future<void> Function()? debugHookOnAfterCommand;

  /// 等待装配器出现新单元（WO-71：直喂版——数据路径只有 assembler 一份）
  Future<void> _waitForData(Duration timeout) async {
    while (!_assembler.hasUnits) {
      if (_closedByServer || _streamError != null) {
        throw ImapClosedException('${_streamError ?? '服务端关闭连接'}');
      }
      final w = Completer<void>();
      _dataWaiter = w;
      try {
        await w.future.timeout(timeout);
      } on TimeoutException {
        if (identical(_dataWaiter, w)) _dataWaiter = null;
        rethrow;
      }
    }
  }

  /// 读取单元直到 [test] 命中；期间无关单元交 [collect]（可为 null = 丢弃）
  Future<ImapUnit> _readUnit({
    required Duration timeout,
    required bool Function(ImapUnit) test,
    void Function(ImapUnit)? collect,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final unit = _nextUnit();
      if (unit != null) {
        if (!_firstResponseLogged) {
          _firstResponseLogged = true;
          _log('IMAP << $_cmdName 首响应 (${unit.head.length}B)');
        }
        if (test(unit)) {
          _log('IMAP == $_cmdName 完成 '
              '${DateTime.now().difference(_cmdStart ?? DateTime.now()).inMilliseconds}ms '
              'head=${unit.head.length > 60 ? unit.head.substring(0, 60) : unit.head}');
          return unit;
        }
        if (unit.head.toUpperCase().contains('* BYE')) {
          throw ImapClosedException('服务端 BYE');
        }
        collect?.call(unit);
        continue;
      }
      final remain = deadline.difference(DateTime.now());
      if (remain <= Duration.zero) {
        throw TimeoutException('IMAP 等待响应超时', timeout);
      }
      try {
        await _waitForData(
            remain < const Duration(seconds: 1) ? remain : const Duration(seconds: 1));
      } on TimeoutException {
        continue;
      }
    }
  }

  void _send(String line) {
    final parts = line.split(' ');
    final name = parts.length > 1 ? parts[1] : parts.first;
    _cmdName = name;
    _cmdStart = DateTime.now();
    _firstResponseLogged = false;
    // WO-71 整改⑤：命令级可观测（发送阶段，带参数规模）
    _log('IMAP >> $name [${line.length}B] 发送');
    _socket?.write('$line\r\n');
    debugHookOnCommand?.call(line);
  }

  /// 连接 + LOGIN + SELECT INBOX。返回 SELECT 期间的 untagged 单元（含 UIDVALIDITY）。
  Future<List<ImapUnit>> connect({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final socket = await (socketFactory != null
        ? socketFactory!(config.host, config.port, timeout)
        : SecureSocket.connect(config.host, config.port, timeout: timeout));
    _socket = socket;
    _sub = socket.listen(_onData, onError: (Object e) {
      _streamError = e;
      _wakeWaiter();
    }, onDone: () {
      _closedByServer = true;
      _wakeWaiter();
    });

    // 1. 问候语
    final greeting = await _readUnit(
      timeout: timeout,
      test: (u) => u.isUntagged,
    );
    if (!greeting.head.toUpperCase().contains(' OK')) {
      await close();
      throw ImapCommandException('GREETING', 'BAD');
    }

    // 2. LOGIN（命令原文零转写：授权码不进任何异常/日志/转写）
    final loginTag = _nextTag();
    _send('$loginTag LOGIN "${_escapeImapString(config.account)}" '
        '"${_escapeImapString(config.authCode)}"');
    final loginResp = await _readUnit(
      timeout: timeout,
      test: (u) => u.tag == loginTag,
    );
    if (loginResp.status != 'OK') {
      await close();
      throw ImapCommandException('LOGIN', loginResp.status ?? 'NO');
    }
    _loggedIn = true;

    // 3. SELECT INBOX
    final selTag = _nextTag();
    _send('$selTag SELECT INBOX');
    final selResp = await _readUnit(
      timeout: timeout,
      test: (u) => u.tag == selTag,
      collect: _scratch.add,
    );
    if (selResp.status != 'OK') {
      await close();
      throw ImapCommandException('SELECT', selResp.status ?? 'NO');
    }
    final selUntagged = List<ImapUnit>.of(_scratch);
    _scratch.clear();
    return selUntagged;
  }

  /// WO-78-R3 返工②诊断：QQ 的 EXISTS 计数与 UID 水位线【不同轴】（实测 R2 邮件
  /// 未入 INBOX 时 EXISTS 恒定，而水位线体系可见）——新件判据一律以 UID 水位线
  /// （fetchNewSince 粗筛）为准，EXISTS 仅作夹带提示。NOOP 节拍返回 -1 哨兵，
  /// 由上层做轻量 UID SEARCH 查件。


  Future<void> _wakeWaiter() async {
    final w = _dataWaiter;
    if (w != null && !w.isCompleted) {
      _dataWaiter = null;
      w.complete();
    }
  }

  /// 启动 IDLE。返回 true = 服务器接受（收到 continuation `+`）。
  Future<bool> startIdle({Duration timeout = const Duration(seconds: 10)}) async {
    final tag = _nextTag();
    _send('$tag IDLE');
    final cont = await _readUnit(
      timeout: timeout,
      test: (u) => u.tag == tag || u.isContinuation,
    );
    if (cont.isContinuation) {
      _idleTag = tag;
      _idleMountedAt = DateTime.now();
      _life(_reAttach ? 'IDLE 重挂（NOOP 节拍循环）' : 'IDLE 挂载');
      _reAttach = true;
      return true;
    }
    _life('IDLE 被服务器拒绝（tagged NO/BAD）');
    return false; // 服务器拒绝 IDLE（tagged NO/BAD）
  }

  /// WO-78-R3：是否为 NOOP 节拍循环中的重挂（仅用于生命周期日志措辞）
  bool _reAttach = false;

  /// WO-71 整改 A：UID FETCH 分批上限（单行命令 ≤~2KB，远低于 QQ 丢弃阈值）
  static const int fetchBatchSize = 50;

  /// IDLE 等待。返回 EXISTS 通知里的消息数；节拍到点（应 DONE+重发）返回 null；
  /// 服务端断开/BYE 抛 [ImapClosedException]。
  /// WO-78 缺陷②：[noopBeat]（默认 60s）到点即 DONE→NOOP→重发 IDLE——
  /// ①静默死连（NAT 掉线/无线休眠，无 FIN）最坏聋到 25 分钟节拍，现在
  ///   ≤ noopBeat+10s 即被 NOOP 超时暴露；②NOOP 响应夹带积压 EXISTS 顺路带回。
  /// 零生命周期语义变化：上层循环不变。
  Future<int?> waitForEvent(
      {required Duration beat,
      Duration noopBeat = const Duration(seconds: 60)}) async {
    var deadline = DateTime.now().add(beat);
    var nextNoopAt = DateTime.now().add(noopBeat);
    while (true) {
      final now = DateTime.now();
      if (now.isAfter(nextNoopAt)) {
        // —— 保活节拍（WO-78-R3 返工最终形态）：DONE → 直接重发 IDLE → 哨兵 -1 ——
        // 实测归因：①QQ 对本连接的 IDLE 不推 EXISTS（静默期零推送行）；
        // ②QQ 对「IDLE 后发 NOOP」一律立即断连（每次 NOOP 后 服务端关闭连接）。
        // 故不发 NOOP：DONE→重发 IDLE 是 RFC 2177 标准循环；重挂成功即证明连接
        // 存活并返回哨兵 -1（上层走 UID 水位线查件）；重挂失败/超时=死连，
        // 转 ImapClosedException 由上层即时重建（连接即查件）。
        _life('保活节拍到点（${noopBeat.inSeconds}s）：DONE → 重发 IDLE');
        await stopIdle();
        bool accepted;
        try {
          accepted = await startIdle();
        } on TimeoutException {
          throw ImapClosedException('重发 IDLE 超时（死连）');
        }
        if (!accepted) {
          _life('重发 IDLE 被拒 → 重建会话');
          throw ImapClosedException('重发 IDLE 被拒（tagged NO/BAD）');
        }
        nextNoopAt = DateTime.now().add(noopBeat);
        deadline = DateTime.now().add(beat); // 重发即重置 25 分钟纪律窗口
        lastWakeReason = 'NOOP查件';
        return -1; // 哨兵：节拍到点，上层做轻量 UID 水位线查件
      }
      final remain = deadline.difference(now);
      if (remain <= Duration.zero) return null;
      try {
        if (_assembler.hasUnits) {
          for (final u in _assembler.takeUnits()) {
            final n = parseExistsCount(u.head);
            if (n != null) {
              final since = _idleMountedAt == null
                  ? '?'
                  : DateTime.now()
                      .difference(_idleMountedAt!)
                      .inSeconds
                      .toString();
              lastWakeReason = 'IDLE推送';
              _life('IDLE 推送 EXISTS=$n（挂载后 ${since}s）→ 立即增量');
              return n;
            }
            if (u.isContinuation) continue;
            if (u.head.toUpperCase().contains('* BYE')) {
              throw ImapClosedException('IDLE 期间服务端 BYE');
            }
            // 其它 untagged（EXPUNGE/RECENT 等）忽略
          }
          continue;
        }
        final untilNoop = nextNoopAt.difference(DateTime.now());
        final wait = untilNoop < remain ? untilNoop : remain;
        await _waitForData(wait < const Duration(seconds: 1)
            ? wait
            : const Duration(seconds: 1));
      } on TimeoutException {
        continue; // 1 秒轮询超时不是节拍超时
      }
    }
  }

  /// 结束 IDLE（DONE）
  Future<void> stopIdle({Duration timeout = const Duration(seconds: 10)}) async {
    final tag = _idleTag;
    if (tag == null) return;
    _idleTag = null;
    _send('DONE');
    final resp = await _readUnit(
      timeout: timeout,
      test: (u) => u.tag == tag,
    );
    if (resp.status != 'OK') {
      throw ImapCommandException('IDLE-DONE', resp.status ?? 'NO');
    }
  }

  /// WO-78 缺陷②：NOOP 保活探针（必须在 IDLE 之外发送——RFC 2177 期间只许 DONE）。
  /// 返回 NOOP 响应里夹带的 EXISTS 数（有→调用方立即增量）；死连接（写缓冲成功
  /// 而响应不到）→ 10s 超时抛出 → 上层重建会话。聋态窗口从最坏 25 分钟压到
  /// ≤ noopBeat+10s。
  Future<int?> noop({Duration timeout = const Duration(seconds: 10)}) async {
    final tag = _nextTag();
    _cmdStart ??= DateTime.now();
    _cmdName = 'NOOP';
    _life('NOOP 探针发出（兜底感知）');
    _send('$tag NOOP');
    int? exists;
    final resp = await _readUnit(
      timeout: timeout,
      test: (u) => u.tag == tag,
      collect: (u) {
        final n = parseExistsCount(u.head);
        if (n != null) exists = n;
      },
    );
    if (resp.status != 'OK') {
      throw ImapCommandException('NOOP', resp.status ?? 'NO');
    }
    return exists;
  }

  /// WO-78-R3 返工③：SELECT INBOX 读取当前 EXISTS（UID 序列重置防御用）。
  Future<int?> selectInboxExists({Duration timeout = const Duration(seconds: 10)}) async {
    final tag = _nextTag();
    _cmdStart ??= DateTime.now();
    _cmdName = 'SELECT';
    _send('$tag SELECT INBOX');
    int? exists;
    final resp = await _readUnit(
      timeout: timeout,
      test: (u) => u.tag == tag,
      collect: (u) {
        final n = parseExistsCount(u.head);
        if (n != null) exists = n;
      },
    );
    if (resp.status != 'OK') {
      throw ImapCommandException('SELECT', resp.status ?? 'NO');
    }
    return exists;
  }

  /// 增量拉取水位线之后的日历邮件。
  /// 返回：[mails]（UID 升序、仅前缀命中）与 [maxSeenUid]（本轮粗筛所见最大 UID——
  /// **空扫也要返回**，上层据此推进水位线，与 NAS 同口径）。
  Future<({List<CalendarMail> mails, int maxSeenUid})> fetchNewSince(
    int lastProcessedUid, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    // RFC 3501 怪癖：UID n:* 在 n 大于最大 UID 时返回最大 UID 那封——
    // 结果必须再按 `uid > lastProcessedUid` 过滤（NAS 侧同款处理）。
    final searchTag = _nextTag();
    _send('$searchTag UID SEARCH UID ${lastProcessedUid + 1}:*');
    final searchResp = await _readUnit(
      timeout: timeout,
      test: (u) => u.tag == searchTag,
      collect: _scratch.add,
    );
    if (searchResp.status != 'OK') {
      throw ImapCommandException('UID SEARCH', searchResp.status ?? 'NO');
    }
    final candidates = parseSearchUids(_scratch);
    final fresh = candidates.where((u) => u > lastProcessedUid).toList()..sort();
    final maxSeenUid =
        candidates.isEmpty ? 0 : candidates.reduce((a, b) => a > b ? a : b);
    if (fresh.isEmpty) {
      return (mails: const <CalendarMail>[], maxSeenUid: maxSeenUid);
    }

    // 客户端精筛：拉 SUBJECT 头（QQ 文本搜索键不可用的替代）。
    // WO-71 整改 A（致命）：`UID FETCH uid1,uid2,…` 单行超长（1129 个 UID ≈ 6KB，
    // RFC 3501 建议命令行 ≤1000 字节）→ QQ【静默丢弃】→ 15s 超时（真机实测复现）。
    // 修复：分批（每批 ≤[fetchBatchSize] 个 UID），批间让出事件循环；批次可观测。
    final matchedHeader = <int>[];
    final subjects = <int, String>{};
    final headerBatches = (fresh.length / fetchBatchSize).ceil();
    for (var b = 0; b < headerBatches; b++) {
      final batch = fresh.sublist(b * fetchBatchSize,
          (b + 1) * fetchBatchSize < fresh.length
              ? (b + 1) * fetchBatchSize
              : fresh.length);
      final headerTag = _nextTag();
      _send('$headerTag UID FETCH ${batch.join(',')} '
          '(UID BODY.PEEK[HEADER.FIELDS (SUBJECT)])');
      _log('IMAP .. FETCH HDR [批次 ${b + 1}/$headerBatches, '
          '${batch.length}条] 等待响应…');
      await _readUnit(
        timeout: timeout,
        test: (u) => u.tag == headerTag,
        collect: _scratch.add,
      );
      for (final u in _scratch) {
        final parsed = parseHeaderFetchUnit(u);
        if (parsed == null) continue;
        if (subjectMatchesPrefix(parsed.header, AppConstants.calSubjectPrefix)) {
          matchedHeader.add(parsed.uid);
          subjects[parsed.uid] = parsed.header;
        }
      }
      _scratch.clear();
      // 批间让出事件循环（不阻塞 isolate 其它定时器）
      await Future<void>.delayed(Duration.zero);
    }
    final matched = matchedHeader..sort();
    _log('IMAP == FETCH HDR 完成：${fresh.length} 条中前缀命中 ${matched.length} 条');
    if (matched.isEmpty) {
      return (mails: const <CalendarMail>[], maxSeenUid: maxSeenUid);
    }

    // 全文拉取（仅前缀命中集合）——同样分批
    final mails = <CalendarMail>[];
    final fullBatches = (matched.length / fetchBatchSize).ceil();
    for (var b = 0; b < fullBatches; b++) {
      final batch = matched.sublist(b * fetchBatchSize,
          (b + 1) * fetchBatchSize < matched.length
              ? (b + 1) * fetchBatchSize
              : matched.length);
      final fullTag = _nextTag();
      _send('$fullTag UID FETCH ${batch.join(',')} (UID BODY.PEEK[])');
      _log('IMAP .. FETCH FULL [批次 ${b + 1}/$fullBatches, '
          '${batch.length}条] 等待响应…');
      await _readUnit(
        timeout: timeout,
        test: (u) => u.tag == fullTag,
        collect: _scratch.add,
      );
      for (final u in _scratch) {
        final parsed = parseFullFetchUnit(u);
        if (parsed == null) continue;
        mails.add(CalendarMail(
          uid: parsed.uid,
          subject: subjects[parsed.uid] ?? '',
          raw: parsed.raw,
        ));
      }
      _scratch.clear();
      await Future<void>.delayed(Duration.zero);
    }
    mails.sort((a, b) => a.uid.compareTo(b.uid));
    return (mails: mails, maxSeenUid: maxSeenUid);
  }

  /// 登出并关闭（尽力而为，绝不抛出）
  Future<void> close() async {
    try {
      if (_loggedIn && _socket != null) {
        final tag = _nextTag();
        _send('$tag LOGOUT');
        await _readUnit(timeout: const Duration(seconds: 2), test: (u) => u.tag == tag)
            .timeout(const Duration(seconds: 3));
      }
    } catch (_) {
      // 尽力 LOGOUT：任何失败静默吞掉
    }
    try {
      await _sub?.cancel();
    } catch (_) {}
    try {
      _socket?.destroy();
    } catch (_) {}
    _socket = null;
    _sub = null;
    _loggedIn = false;
    _idleTag = null;
  }
}

