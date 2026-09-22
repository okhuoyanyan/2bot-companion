import 'package:flutter/material.dart';
import '../../models/app_settings.dart';
import '../../utils/constants.dart';
import '../../utils/theme.dart';

/// 配置表单提交值（WO-36：扩展传输模式与邮箱参数；WO-37：扩展节流档位、静默保活与事件开关）
class ConfigFormValues {
  final String relayUrl;
  final String deviceToken;
  final int intervalMinutes;
  final String transportMode;
  final String mailAccount;
  final String mailRecipient;
  final String mailSubjectPrefix;
  final String mailAuthCode;
  final String mailCryptKey;
  final int throttleIntervalSeconds;
  final int silenceTimeoutHours;
  final Map<String, bool> eventSwitches;

  const ConfigFormValues({
    required this.relayUrl,
    required this.deviceToken,
    required this.intervalMinutes,
    required this.transportMode,
    required this.mailAccount,
    required this.mailRecipient,
    required this.mailSubjectPrefix,
    required this.mailAuthCode,
    required this.mailCryptKey,
    required this.throttleIntervalSeconds,
    required this.silenceTimeoutHours,
    required this.eventSwitches,
  });
}

/// 云端中继 / 邮箱信道与行为偏好配置卡片
class ConfigCard extends StatefulWidget {
  final AppSettings initialSettings;
  final void Function(ConfigFormValues values) onSave;

  const ConfigCard({
    super.key,
    required this.initialSettings,
    required this.onSave,
  });

  @override
  State<ConfigCard> createState() => _ConfigCardState();
}

class _ConfigCardState extends State<ConfigCard> {
  late final TextEditingController _urlController;
  late final TextEditingController _tokenController;
  late final TextEditingController _mailAccountController;
  late final TextEditingController _mailRecipientController;
  late final TextEditingController _mailAuthCodeController;
  late final TextEditingController _mailKeyController;
  late final TextEditingController _subjectPrefixController;
  late final TextEditingController _silenceHoursController;
  late int _selectedThrottleSeconds;
  late String _transportMode;
  late Map<String, bool> _eventSwitches;
  bool _obscureToken = true;
  bool _obscureAuthCode = true;
  bool _obscureKey = true;

  bool get _isMailMode => _transportMode == AppConstants.transportMail;

  @override
  void initState() {
    super.initState();
    final s = widget.initialSettings;
    _urlController = TextEditingController(text: s.relayUrl);
    _tokenController = TextEditingController(text: s.deviceToken);
    _mailAccountController = TextEditingController(text: s.mailAccount);
    _mailRecipientController = TextEditingController(text: s.mailRecipient);
    _mailAuthCodeController = TextEditingController(text: s.mailAuthCode);
    _mailKeyController = TextEditingController(text: s.mailCryptKey);
    _subjectPrefixController = TextEditingController(text: s.mailSubjectPrefix);
    _silenceHoursController =
        TextEditingController(text: s.silenceTimeoutHours.toString());
    _selectedThrottleSeconds = s.throttleIntervalSeconds;
    _transportMode = s.transportMode;
    _eventSwitches = Map<String, bool>.from(s.eventSwitches);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    _mailAccountController.dispose();
    _mailRecipientController.dispose();
    _mailAuthCodeController.dispose();
    _mailKeyController.dispose();
    _subjectPrefixController.dispose();
    _silenceHoursController.dispose();
    super.dispose();
  }

  void _resetToDefault() {
    setState(() {
      _urlController.text = AppConstants.defaultRelayUrl;
      _tokenController.text = AppConstants.defaultDeviceToken;
      _subjectPrefixController.text = AppConstants.defaultSubjectPrefix;
      _selectedThrottleSeconds = AppConstants.defaultThrottleSeconds;
      _silenceHoursController.text =
          AppConstants.defaultSilenceTimeoutHours.toString();
      _eventSwitches = Map<String, bool>.from(AppSettings.defaultEventSwitches);
      // 邮箱凭据刻意不参与「恢复默认」——避免误清空管理员已配置的密钥
    });
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _submit() {
    final url = _urlController.text.trim();
    final token = _tokenController.text.trim();
    final mailAccount = _mailAccountController.text.trim();
    final mailKey = _mailKeyController.text.trim();
    final authCode = _mailAuthCodeController.text.trim();
    final silenceHours = int.tryParse(_silenceHoursController.text.trim()) ??
        AppConstants.defaultSilenceTimeoutHours;

    if (_isMailMode) {
      // 邮箱模式的必填校验（relay 字段保留但不再强校验）
      if (mailAccount.isEmpty) {
        _toast('⚠️ 邮箱模式下必须填写邮箱账号');
        return;
      }
      if (authCode.isEmpty && widget.initialSettings.mailAuthCode.isEmpty) {
        _toast('⚠️ 邮箱模式下必须填写授权码');
        return;
      }
      if (mailKey.isEmpty && widget.initialSettings.mailCryptKey.isEmpty) {
        _toast('⚠️ 邮箱模式下必须填写加密密钥（64 个 hex 字符）');
        return;
      }
      if (mailKey.isNotEmpty && !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(mailKey)) {
        _toast('⚠️ 加密密钥必须是 64 个十六进制字符（32 字节）');
        return;
      }
    } else {
      if (url.isEmpty) {
        _toast('⚠️ 中继服务 URL 不能为空');
        return;
      }
      if (token.isEmpty) {
        _toast('⚠️ 鉴权 Token 不能为空');
        return;
      }
    }

    widget.onSave(ConfigFormValues(
      relayUrl: url,
      deviceToken: token,
      intervalMinutes: AppConstants.defaultIntervalMinutes,
      transportMode: _transportMode,
      mailAccount: mailAccount,
      mailRecipient: _mailRecipientController.text.trim(),
      mailSubjectPrefix: _subjectPrefixController.text.trim().isEmpty
          ? AppConstants.defaultSubjectPrefix
          : _subjectPrefixController.text.trim(),
      // 留空 = 保持既有凭据不变（避免 UI 未回显时误清空）
      mailAuthCode: authCode,
      mailCryptKey: mailKey,
      throttleIntervalSeconds: _selectedThrottleSeconds,
      silenceTimeoutHours: silenceHours,
      eventSwitches: _eventSwitches,
    ));
  }

  Widget _secretField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required bool obscured,
    required VoidCallback onToggle,
    String? helper,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscured,
      style: const TextStyle(fontSize: 13, fontFamily: 'monospace', color: AppTheme.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 3,
        prefixIcon: Icon(icon, size: 20, color: AppTheme.textSecondary),
        suffixIcon: IconButton(
          icon: Icon(
            obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            size: 20,
            color: AppTheme.textMuted,
          ),
          onPressed: onToggle,
        ),
      ),
    );
  }

  List<Widget> _buildEventSwitchList() {
    final list = [
      {'key': 'unlock', 'title': '屏幕解锁', 'desc': '用户解锁进入桌面'},
      {'key': 'lock', 'title': '屏幕锁屏', 'desc': '息屏或进入锁屏状态'},
      {'key': 'app_switch', 'title': '应用切换', 'desc': '当前活跃前台应用变更'},
      {'key': 'location', 'title': '到家/离家', 'desc': 'WiFi SSID 切换 (白名单立即发送)'},
      {'key': 'power', 'title': '充放电切换', 'desc': '连接充电器或断开电源'},
      {'key': 'battery_threshold', 'title': '电量阈值跨档', 'desc': '跨过 80% / 20% / 10% (≤20% 立即发)'},
      {'key': 'battery_full', 'title': '充电完成', 'desc': '电量充至 100%'},
      {'key': 'music', 'title': '音乐启停', 'desc': '媒体播放器开始或停止播放'},
      {'key': 'bluetooth', 'title': '蓝牙音频接断', 'desc': '蓝牙音频设备连接或断开'},
      {'key': 'steps', 'title': '步数里程碑', 'desc': '当日累计步数每跨 500 步'},
      {'key': 'silence_timeout', 'title': '静默保活超时', 'desc': '长期无事件保活上报'},
    ];

    return list.map((item) {
      final key = item['key']!;
      final enabled = _eventSwitches[key] ?? true;
      return SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
        dense: true,
        title: Text(
          item['title']!,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.textPrimary),
        ),
        subtitle: Text(
          item['desc']!,
          style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
        ),
        activeColor: AppTheme.primaryCyan,
        value: enabled,
        onChanged: (val) {
          setState(() {
            _eventSwitches[key] = val;
          });
        },
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.tune_rounded, size: 20, color: AppTheme.secondarySky),
                    SizedBox(width: 8),
                    Text(
                      '传输信道与上报设置',
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

            // 0. 传输模式（WO-36：relay / mail，切换即切换信道 = 配置级回滚）
            const Text(
              '传输模式',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                ChoiceChip(
                  label: const Text('云端中继 (relay)'),
                  selected: !_isMailMode,
                  selectedColor: AppTheme.primaryCyan.withOpacity(0.2),
                  backgroundColor: const Color(0xFF0F172A),
                  labelStyle: TextStyle(
                    fontSize: 12,
                    color: !_isMailMode ? AppTheme.primaryCyan : AppTheme.textSecondary,
                  ),
                  onSelected: (_) => setState(() => _transportMode = AppConstants.transportRelay),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('邮箱信道 (mail)'),
                  selected: _isMailMode,
                  selectedColor: AppTheme.primaryCyan.withOpacity(0.2),
                  backgroundColor: const Color(0xFF0F172A),
                  labelStyle: TextStyle(
                    fontSize: 12,
                    color: _isMailMode ? AppTheme.primaryCyan : AppTheme.textSecondary,
                  ),
                  onSelected: (_) => setState(() => _transportMode = AppConstants.transportMail),
                ),
              ],
            ),
            const SizedBox(height: 18),

            // ============ 邮箱模式字段 ============
            if (_isMailMode) ...[
              TextField(
                controller: _mailAccountController,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace', color: AppTheme.textPrimary),
                decoration: const InputDecoration(
                  labelText: '邮箱账号 (收发同源)',
                  hintText: 'your-account@qq.com',
                  prefixIcon: Icon(Icons.alternate_email_rounded, size: 20, color: AppTheme.textSecondary),
                ),
              ),
              const SizedBox(height: 14),
              _secretField(
                controller: _mailAuthCodeController,
                label: '邮箱授权码',
                hint: 'SMTP/IMAP 授权码（非登录密码）',
                icon: Icons.lock_outline_rounded,
                obscured: _obscureAuthCode,
                onToggle: () => setState(() => _obscureAuthCode = !_obscureAuthCode),
                helper: '存于系统安全存储（Android Keystore），不会明文落盘',
              ),
              const SizedBox(height: 14),
              _secretField(
                controller: _mailKeyController,
                label: '加密密钥 (32 字节 hex)',
                hint: '64 个十六进制字符，需与 NAS 侧一致',
                icon: Icons.enhanced_encryption_rounded,
                obscured: _obscureKey,
                onToggle: () => setState(() => _obscureKey = !_obscureKey),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _mailRecipientController,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace', color: AppTheme.textPrimary),
                decoration: const InputDecoration(
                  labelText: '收件地址 (留空 = 发给自己)',
                  hintText: '单邮箱自发自收时留空即可',
                  prefixIcon: Icon(Icons.move_to_inbox_rounded, size: 20, color: AppTheme.textSecondary),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _subjectPrefixController,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace', color: AppTheme.textPrimary),
                decoration: const InputDecoration(
                  labelText: '邮件主题前缀',
                  hintText: AppConstants.defaultSubjectPrefix,
                  prefixIcon: Icon(Icons.label_outline_rounded, size: 20, color: AppTheme.textSecondary),
                ),
              ),
            ],

            // ============ relay 字段（旧配置完整保留）============
            if (!_isMailMode) ...[
              TextField(
                controller: _urlController,
                keyboardType: TextInputType.url,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace', color: AppTheme.textPrimary),
                decoration: const InputDecoration(
                  labelText: '中继服务地址 (Relay Base URL)',
                  hintText: 'https://your-relay-service.vercel.app',
                  prefixIcon: Icon(Icons.cloud_queue_rounded, size: 20, color: AppTheme.textSecondary),
                ),
              ),
              const SizedBox(height: 14),
              _secretField(
                controller: _tokenController,
                label: '设备鉴权密钥 (x-device-token)',
                hint: '填入您在云端中继配置的自定义 Token',
                icon: Icons.vpn_key_rounded,
                obscured: _obscureToken,
                onToggle: () => setState(() => _obscureToken = !_obscureToken),
              ),
            ],
            const SizedBox(height: 18),

            // ============ WO-37 节流调度窗口时长 ============
            const Text(
              '节流调度窗口时长 (WO-37)',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 6),
            const Text(
              '非白名单事件在此窗口内合并为 1 次发送；白名单（到家/离家、电量≤20%、服务启动）无视窗口立即上报。',
              style: TextStyle(fontSize: 11, color: AppTheme.textMuted, height: 1.4),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: AppConstants.throttleOptions.map((secs) {
                final isSelected = (_selectedThrottleSeconds == secs);
                final label = secs == 90
                    ? '90 秒 (默认)'
                    : (secs == 180 ? '180 秒 (3分钟)' : '600 秒 (10分钟)');
                return ChoiceChip(
                  label: Text(label),
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
                        _selectedThrottleSeconds = secs;
                      });
                    }
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 18),

            // ============ WO-37 静默保活超时 ============
            TextField(
              controller: _silenceHoursController,
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace', color: AppTheme.textPrimary),
              decoration: const InputDecoration(
                labelText: '静默保活超时（小时）',
                hintText: '默认 6，填 0 为关闭',
                helperText: '长期无事件时单发保活元事件，区分手机安静与通道离线（严禁周期心跳）',
                helperMaxLines: 2,
                prefixIcon: Icon(Icons.hourglass_empty_rounded, size: 20, color: AppTheme.textSecondary),
              ),
            ),
            const SizedBox(height: 18),

            // ============ WO-37 11 项事件独立触发开关 ============
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                initiallyExpanded: false,
                leading: const Icon(Icons.toggle_on_outlined, color: AppTheme.primaryCyan, size: 20),
                title: const Text(
                  '事件触发独立开关 (11 项)',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
                subtitle: const Text(
                  '按需启用或屏蔽特定感知事件',
                  style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                ),
                children: _buildEventSwitchList(),
              ),
            ),
            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.check_rounded, size: 18),
                label: Text(_isMailMode ? '保存邮箱配置' : '保存中继配置'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
