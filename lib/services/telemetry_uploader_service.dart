import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/device_telemetry.dart';
import 'storage_service.dart';

/// 上报结果回执模型
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
class TelemetryUploaderService {
  /// 向中继推送设备快照
  static Future<UploadResult> upload(
    DeviceTelemetry telemetry, {
    String? overrideRelayUrl,
    String? overrideToken,
  }) async {
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
