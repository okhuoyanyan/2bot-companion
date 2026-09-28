// WO-71 真实会话层探针（任务 A.1）：用 App 同款 ImapIdleClient 真连 imap.qq.com:993，
// 复现「SELECT 成功后卡 15 秒」。凭据从 NAS 侧 config 运行时读取，绝不打印。
// 运行：dart run tool/wo71_real_imap_probe.dart
// 判据：真实凭据存在才跑（文件缺失/无 authCode → SKIP 退出 0）
import 'dart:convert';
import 'dart:io';

import 'package:bot_companion/services/imap_idle_client.dart';

Future<void> main() async {
  const cfgPath = r'D:\2BOT-project\2BOT-NEW\config\config.json';
  final cfgFile = File(cfgPath);
  if (!cfgFile.existsSync()) {
    print('PROBE SKIP: config 不存在');
    exit(0);
  }
  final mail = (json.decode(cfgFile.readAsStringSync())
      as Map<String, dynamic>)['deviceTelemetry']['mail']
      as Map<String, dynamic>;
  final account = mail['account'] as String;
  final authCode = mail['authCode'] as String;
  if (account.isEmpty || authCode.isEmpty) {
    print('PROBE SKIP: 凭据为空');
    exit(0);
  }
  print('PROBE target=imap.qq.com:993 account=<redacted len=${account.length}>');

  final client = ImapIdleClient(
      config: ImapConfig(account: account, authCode: authCode));
  client.onCommandLog = (line) => print('PROBE $line');
  final sw = Stopwatch()..start();
  try {
    final units = await client.connect(timeout: const Duration(seconds: 10));
    print('PROBE connect OK ${sw.elapsedMilliseconds}ms '
        'units=${units.length} (uidValidity 见下方解析)');
    sw.reset();

    // 步骤 1：水位线 0 的增量搜索（SELECT 后的第一条命令——真机在此卡 15s）
    print('PROBE >> UID SEARCH UID 1:*');
    final r = await client.fetchNewSince(0, timeout: const Duration(seconds: 15));
    print('PROBE fetchNewSince OK ${sw.elapsedMilliseconds}ms '
        'mails=${r.mails.length} maxSeen=${r.maxSeenUid}');
  } catch (e) {
    print('PROBE FAILED at ${sw.elapsedMilliseconds}ms: ${e.runtimeType}: $e');
    exit(1);
  } finally {
    await client.close();
  }
  print('PROBE DONE');
}
