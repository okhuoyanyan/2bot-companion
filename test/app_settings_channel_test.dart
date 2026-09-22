import 'package:flutter_test/flutter_test.dart';

import 'package:bot_companion/models/app_settings.dart';
import 'package:bot_companion/utils/constants.dart';

/// ============================================================================
/// WO-36-UI-FIX · 通信信道就绪状态纯函数（isChannelReady）单测
/// ============================================================================
/// 覆盖范围：
///   1. 四象限（mail完整 / mail不完整 / relay完整 / relay不完整）
///   2. 异常分支（mail 模式下加密 key 非 64 位十六进制格式时的拦截）
void main() {
  const valid64HexKey =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  group('AppSettings.isChannelReady 通信信道就绪判定', () {
    // ------------------------------------------------------------
    // 象限 1：mail 完整
    // ------------------------------------------------------------
    test('象限 1：mail 完整（账号、授权码有效，加密 key 为有效 64 hex）-> 就绪', () {
      final settings = AppSettings(
        transportMode: AppConstants.transportMail,
        mailAccount: 'user@example.com',
        mailAuthCode: 'auth-code-1234',
        mailCryptKey: valid64HexKey,
      );
      expect(settings.isMailMode, isTrue);
      expect(settings.isChannelReady, isTrue);
    });

    test('象限 1 变体：mail 完整且未指定加密 key（留空）-> 就绪', () {
      final settings = AppSettings(
        transportMode: AppConstants.transportMail,
        mailAccount: 'user@example.com',
        mailAuthCode: 'auth-code-1234',
        mailCryptKey: '',
      );
      expect(settings.isMailMode, isTrue);
      expect(settings.isChannelReady, isTrue);
    });

    // ------------------------------------------------------------
    // 象限 2：mail 不完整
    // ------------------------------------------------------------
    test('象限 2：mail 不完整（缺少发信账号）-> 未就绪', () {
      final settings = AppSettings(
        transportMode: AppConstants.transportMail,
        mailAccount: '',
        mailAuthCode: 'auth-code-1234',
        mailCryptKey: valid64HexKey,
      );
      expect(settings.isChannelReady, isFalse);
    });

    test('象限 2：mail 不完整（缺少授权码）-> 未就绪', () {
      final settings = AppSettings(
        transportMode: AppConstants.transportMail,
        mailAccount: 'user@example.com',
        mailAuthCode: '   ',
        mailCryptKey: valid64HexKey,
      );
      expect(settings.isChannelReady, isFalse);
    });

    // ------------------------------------------------------------
    // 象限 3：relay 完整
    // ------------------------------------------------------------
    test('象限 3：relay 完整（有效 token 且 URL 非占位符）-> 就绪', () {
      final settings = AppSettings(
        transportMode: AppConstants.transportRelay,
        relayUrl: 'https://relay.mydomain.com',
        deviceToken: 'my-secret-device-token',
      );
      expect(settings.isMailMode, isFalse);
      expect(settings.isChannelReady, isTrue);
    });

    // ------------------------------------------------------------
    // 象限 4：relay 不完整
    // ------------------------------------------------------------
    test('象限 4：relay 不完整（URL 为默认占位符）-> 未就绪', () {
      final settings = AppSettings(
        transportMode: AppConstants.transportRelay,
        relayUrl: AppConstants.defaultRelayUrl,
        deviceToken: 'my-secret-device-token',
      );
      expect(settings.isChannelReady, isFalse);
    });

    test('象限 4：relay 不完整（URL 为空）-> 未就绪', () {
      final settings = AppSettings(
        transportMode: AppConstants.transportRelay,
        relayUrl: '   ',
        deviceToken: 'my-secret-device-token',
      );
      expect(settings.isChannelReady, isFalse);
    });

    test('象限 4：relay 不完整（deviceToken 为空）-> 未就绪', () {
      final settings = AppSettings(
        transportMode: AppConstants.transportRelay,
        relayUrl: 'https://relay.mydomain.com',
        deviceToken: '',
      );
      expect(settings.isChannelReady, isFalse);
    });

    // ------------------------------------------------------------
    // 异常分支：加密 key 非法（非 64 hex）
    // ------------------------------------------------------------
    test('异常分支：mail 账号与授权码完整，但加密 key 长度非法（非 64 hex）-> 未就绪', () {
      final settings = AppSettings(
        transportMode: AppConstants.transportMail,
        mailAccount: 'user@example.com',
        mailAuthCode: 'auth-code-1234',
        mailCryptKey: 'abc123',
      );
      expect(settings.isChannelReady, isFalse);
    });

    test('异常分支：mail 账号与授权码完整，但加密 key 包含非十六进制字符 -> 未就绪', () {
      final settings = AppSettings(
        transportMode: AppConstants.transportMail,
        mailAccount: 'user@example.com',
        mailAuthCode: 'auth-code-1234',
        mailCryptKey: 'z' * 64,
      );
      expect(settings.isChannelReady, isFalse);
    });
  });
}
