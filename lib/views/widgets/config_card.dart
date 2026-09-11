import 'package:flutter/material.dart';
import '../../utils/constants.dart';
import '../../utils/theme.dart';

/// 云端中继与行为偏好配置卡片
class ConfigCard extends StatefulWidget {
  final String initialRelayUrl;
  final String initialToken;
  final int initialIntervalMinutes;
  final Function(String url, String token, int interval) onSave;

  const ConfigCard({
    super.key,
    required this.initialRelayUrl,
    required this.initialToken,
    required this.initialIntervalMinutes,
    required this.onSave,
  });

  @override
  State<ConfigCard> createState() => _ConfigCardState();
}

class _ConfigCardState extends State<ConfigCard> {
  late final TextEditingController _urlController;
  late final TextEditingController _tokenController;
  late int _selectedInterval;
  bool _obscureToken = true;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.initialRelayUrl);
    _tokenController = TextEditingController(text: widget.initialToken);
    _selectedInterval = widget.initialIntervalMinutes;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  void _resetToDefault() {
    setState(() {
      _urlController.text = AppConstants.defaultRelayUrl;
      _tokenController.text = AppConstants.defaultDeviceToken;
      _selectedInterval = AppConstants.defaultIntervalMinutes;
    });
  }

  void _submit() {
    final url = _urlController.text.trim();
    final token = _tokenController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('⚠️ 中继服务 URL 不能为空')),
      );
      return;
    }
    if (token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('⚠️ 鉴权 Token 不能为空')),
      );
      return;
    }
    widget.onSave(url, token, _selectedInterval);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题栏与重置默认按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.tune_rounded,
                        size: 20, color: AppTheme.secondarySky),
                    SizedBox(width: 8),
                    Text(
                      '云端通信与中继设置',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textPrimary,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                TextButton.icon(
                  onPressed: _resetToDefault,
                  icon: const Icon(Icons.restore_rounded, size: 16),
                  label: const Text('恢复默认', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.textMuted,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 1. 中继 URL
            TextField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              style: const TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                color: AppTheme.textPrimary,
              ),
              decoration: const InputDecoration(
                labelText: '中继服务地址 (Relay Base URL)',
                hintText: 'https://2bot-relay.vercel.app',
                prefixIcon: Icon(Icons.cloud_queue_rounded,
                    size: 20, color: AppTheme.textSecondary),
              ),
            ),
            const SizedBox(height: 14),

            // 2. 鉴权 Token
            TextField(
              controller: _tokenController,
              obscureText: _obscureToken,
              style: const TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                color: AppTheme.textPrimary,
              ),
              decoration: InputDecoration(
                labelText: '设备鉴权密钥 (x-device-token)',
                hintText: 'telemetry_sec_8848',
                prefixIcon: const Icon(Icons.vpn_key_rounded,
                    size: 20, color: AppTheme.textSecondary),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureToken
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 20,
                    color: AppTheme.textMuted,
                  ),
                  onPressed: () {
                    setState(() {
                      _obscureToken = !_obscureToken;
                    });
                  },
                ),
              ),
            ),
            const SizedBox(height: 18),

            // 3. 定时频率选择
            const Text(
              '保底心跳频率 (定时静默上报)',
              style: TextStyle(
                fontSize: 13,
                color: AppTheme.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: AppConstants.availableIntervals.map((mins) {
                final isSelected = (_selectedInterval == mins);
                return ChoiceChip(
                  label: Text('$mins 分钟'),
                  selected: isSelected,
                  selectedColor: AppTheme.primaryCyan.withOpacity(0.2),
                  backgroundColor: const Color(0xFF0F172A),
                  labelStyle: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    color: isSelected ? AppTheme.primaryCyan : AppTheme.textSecondary,
                  ),
                  side: BorderSide(
                    color: isSelected ? AppTheme.primaryCyan : AppTheme.cardBorder,
                  ),
                  onSelected: (selected) {
                    if (selected) {
                      setState(() {
                        _selectedInterval = mins;
                      });
                    }
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 20),

            // 保存按钮
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.check_rounded, size: 18),
                label: const Text('保存中继配置'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
