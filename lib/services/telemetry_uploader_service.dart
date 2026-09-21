import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/app_settings.dart';
import '../models/device_telemetry.dart';
import 'storage_service.dart';
import 'telemetry_mail_protocol.dart';
import 'telemetry_mail_transport.dart';

/// 上报结果回执模型（字段与既有调用点契约保持一致）
class UploadResult {
  final bool success;
  final int statusCode;
  final String message;
  final String? rawResponse;

  UploadResult({
    required this.success,
    required this.statusCode,
    required this.message,
    this.rawResponse,
  });
}

/// 云端中继通信与状态上报服务
///
/// WO-36：抽 Transport 分发 —— `relay`（旧 HTTP 中继，逻辑原样保留 = 回滚能力）
/// 与 `mail`（QQ 邮箱信道）。调用点 `upload(snapshot)` 签名与 [UploadResult] 契约均未变，
/// 故 background_task_service / home_screen 零改动。
class TelemetryUploaderService {
  /// 按当前设置的传输模式分发上报
  static Future<UploadResult> upload(
    DeviceTelemetry telemetry, {
    String? overrideRelayUrl,
    String? overrideToken,
  }) async {
    final settings = StorageService.loadSettings();
    if (settings.isMailMode) {
      // 邮箱信道的连接与凭据全部来自设置，relay 专用覆盖参数在此模式下不适用
      return _uploadViaMail(telemetry, settings);
    }
    return _uploadViaRelay(telemetry, overrideRelayUrl, overrideToken);
  }

  // ============================================================
  // Transport A：邮箱信道（WO-36）
  // ============================================================
  static Future<UploadResult> _uploadViaMail(
    DeviceTelemetry telemetry,
    AppSettings settings,
  ) async {
    final account = settings.mailAccount.trim();
    final authCode = settings.mailAuthCode.trim();

    if (account.isEmpty || authCode.isEmpty) {
      const msg = '邮箱模式未配置完整：请填写邮箱账号与授权码';
      await StorageService.recordReportResult(
        success: false,
        statusText: '配置缺失',
        errorMessage: msg,
      );
      return UploadResult(success: false, statusCode: 0, message: msg);
    }

    final subject = MailProtocol.buildSubject(
      DateTime.now().millisecondsSinceEpoch,
      prefix: settings.mailSubjectPrefix,
    );

    // §1：加密默认开启；加密失败 = 本封放弃，严禁明文降级
    final body = MailProtocol.encryptEnc1(jsonEncode(telemetry.toJson()), settings.mailCryptKey);
    if (body == null) {
      const msg = '加密失败（密钥须为 64 个 hex 字符），本封已放弃；系统不会降级为明文发送';
      await StorageService.recordReportResult(
        success: false,
        statusText: '加密失败',
        errorMessage: msg,
      );
      return UploadResult(success: false, statusCode: 0, message: msg);
    }

    final result = await SmtpMailer.send(
      config: MailAccountConfig(
        account: account,
        authCode: authCode,
        recipient: settings.effectiveMailRecipient,
      ),
      subject: subject,
      body: body,
    );

    await StorageService.recordReportResult(
      success: result.success,
      statusText: result.success ? '邮箱投递成功' : '邮箱投递失败',
      errorMessage: result.success ? null : result.message,
    );

    return UploadResult(
      success: result.success,
      statusCode: result.success ? 250 : 0,
      message: result.message,
    );
  }

  // ============================================================
  // Transport B：HTTP 中继（原路径，一字未改语义）
  // ============================================================
  static Future<UploadResult> _uploadViaRelay(
    DeviceTelemetry telemetry,
    String? overrideRelayUrl,
    String? overrideToken,
  ) async {
    final settings = StorageService.loadSettings();
    final baseUrl = (overrideRelayUrl ?? settings.relayUrl).trim();
    final token = (overrideToken ?? settings.deviceToken).trim();

    // 规范化 URL，补齐 /push 端点
    String targetUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');
    if (!targetUrl.endsWith('/push')) {
      targetUrl = '$targetUrl/push';
    }

    try {
      final uri = Uri.parse(targetUrl);
      final jsonBody = jsonEncode(telemetry.toJson());

      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'x-device-token': token,
            },
            body: jsonBody,
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        String msg = '上报成功 (HTTP 200)';
        try {
          final resObj = jsonDecode(response.body);
          if (resObj is Map && resObj['message'] != null) {
            msg = resObj['message'].toString();
          }
        } catch (_) {}

        await StorageService.recordReportResult(
          success: true,
          statusText: 'HTTP 200 OK',
        );

        return UploadResult(
          success: true,
          statusCode: 200,
          message: msg,
          rawResponse: response.body,
        );
      } else {
        String errMsg = 'HTTP ${response.statusCode}';
        try {
          final resObj = jsonDecode(response.body);
          if (resObj is Map && resObj['error'] != null) {
            errMsg = '$errMsg - ${resObj['error']}';
          }
        } catch (_) {
          errMsg = '$errMsg ${response.reasonPhrase ?? ""}';
        }

        await StorageService.recordReportResult(
          success: false,
          statusText: errMsg,
          errorMessage: errMsg,
        );

        return UploadResult(
          success: false,
          statusCode: response.statusCode,
          message: errMsg,
          rawResponse: response.body,
        );
      }
    } catch (e) {
      final errMsg = '网络异常: ${e.toString()}';
      await StorageService.recordReportResult(
        success: false,
        statusText: '连接超时/失败',
        errorMessage: errMsg,
      );

      return UploadResult(
        success: false,
        statusCode: 0,
        message: errMsg,
      );
    }
  }
}
