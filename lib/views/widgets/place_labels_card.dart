import 'package:flutter/material.dart';
import '../../services/storage_service.dart';
import '../../utils/theme.dart';

/// WO-37 地点标注卡片（SSID -> 家 / 公司 / 自定义）
class PlaceLabelsCard extends StatefulWidget {
  final Map<String, String> initialPlaceLabels;
  final VoidCallback onUpdated;

  const PlaceLabelsCard({
    super.key,
    required this.initialPlaceLabels,
    required this.onUpdated,
  });

  @override
  State<PlaceLabelsCard> createState() => _PlaceLabelsCardState();
}

class _PlaceLabelsCardState extends State<PlaceLabelsCard> {
  late Map<String, String> _labels;

  @override
  void initState() {
    super.initState();
    _labels = Map<String, String>.from(widget.initialPlaceLabels);
  }

  @override
  void didUpdateWidget(covariant PlaceLabelsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialPlaceLabels != widget.initialPlaceLabels) {
      _labels = Map<String, String>.from(widget.initialPlaceLabels);
    }
  }

  Future<void> _setLabel(String ssid, String? label) async {
    setState(() {
      if (label == null || label.trim().isEmpty) {
        _labels.remove(ssid);
      } else {
        _labels[ssid] = label.trim();
      }
    });
    await StorageService.savePlaceLabels(_labels);
    widget.onUpdated();
  }

  void _showCustomLabelDialog(String ssid) {
    final controller = TextEditingController(text: _labels[ssid] ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.cardBorder),
        ),
        title: Text('标注地点: $ssid', style: const TextStyle(fontSize: 15)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
          decoration: const InputDecoration(
            labelText: '自定义地点名称',
            hintText: '如：父母家、图书馆、健身房',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消', style: TextStyle(color: AppTheme.textMuted)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _setLabel(ssid, controller.text.trim());
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _showManualAddSsidDialog() {
    final ssidController = TextEditingController();
    final labelController = TextEditingController(text: '家');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.cardSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.cardBorder),
        ),
        title: const Text('手动添加 WiFi 地点', style: const TextStyle(fontSize: 15)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ssidController,
              autofocus: true,
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              decoration: const InputDecoration(
                labelText: 'WiFi 名称 (SSID)',
                hintText: '如：MyHome_5G',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: labelController,
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              decoration: const InputDecoration(
                labelText: '地点标签',
                hintText: '家 / 公司 / 自定义',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消', style: TextStyle(color: AppTheme.textMuted)),
          ),
          ElevatedButton(
            onPressed: () async {
              final s = ssidController.text.trim();
              final l = labelController.text.trim();
              if (s.isNotEmpty) {
                await StorageService.recordSsidSeen(s);
                await _setLabel(s, l.isEmpty ? '家' : l);
              }
              Navigator.of(ctx).pop();
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final recorded = StorageService.getRecordedSsids();
    final allSsids = <String>{...recorded.keys, ..._labels.keys}.toList();

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
                    Icon(Icons.place_rounded, size: 20, color: AppTheme.accentEmerald),
                    SizedBox(width: 8),
                    Text(
                      '地点标注 (家 / 公司归属)',
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
                  onPressed: _showManualAddSsidDialog,
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('手动添加', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.accentEmerald,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '手机本地收录所连接的 WiFi。点选标注后随报文同步给 NAS，为管家到家/离家推断提供精准种子。',
              style: TextStyle(fontSize: 11, color: AppTheme.textMuted, height: 1.4),
            ),
            const SizedBox(height: 14),

            if (allSsids.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.cardBorder),
                ),
                child: const Text(
                  '暂无已收录的 WiFi SSID。连接 WiFi 并完成一次探测，或点击右上角手动添加。',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
              )
            else
              Column(
                children: allSsids.map((ssid) {
                  final currentLabel = _labels[ssid];
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: currentLabel != null
                            ? AppTheme.accentEmerald.withOpacity(0.4)
                            : AppTheme.cardBorder,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.wifi_rounded, size: 16, color: AppTheme.textSecondary),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                ssid,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.textPrimary,
                                ),
                              ),
                            ),
                            if (currentLabel != null)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.accentEmerald.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: AppTheme.accentEmerald.withOpacity(0.5),
                                  ),
                                ),
                                child: Text(
                                  currentLabel,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: AppTheme.accentEmerald,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            ChoiceChip(
                              label: const Text('家'),
                              selected: currentLabel == '家',
                              selectedColor: AppTheme.accentEmerald.withOpacity(0.2),
                              backgroundColor: const Color(0xFF1E293B),
                              labelStyle: TextStyle(
                                fontSize: 11,
                                color: currentLabel == '家' ? AppTheme.accentEmerald : AppTheme.textSecondary,
                              ),
                              onSelected: (_) => _setLabel(ssid, '家'),
                            ),
                            ChoiceChip(
                              label: const Text('公司'),
                              selected: currentLabel == '公司',
                              selectedColor: AppTheme.accentEmerald.withOpacity(0.2),
                              backgroundColor: const Color(0xFF1E293B),
                              labelStyle: TextStyle(
                                fontSize: 11,
                                color: currentLabel == '公司' ? AppTheme.accentEmerald : AppTheme.textSecondary,
                              ),
                              onSelected: (_) => _setLabel(ssid, '公司'),
                            ),
                            ActionChip(
                              avatar: const Icon(Icons.edit_outlined, size: 12, color: AppTheme.textMuted),
                              label: const Text('自定义...'),
                              backgroundColor: const Color(0xFF1E293B),
                              labelStyle: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                              onPressed: () => _showCustomLabelDialog(ssid),
                            ),
                            if (currentLabel != null)
                              ActionChip(
                                avatar: const Icon(Icons.close_rounded, size: 12, color: AppTheme.textMuted),
                                label: const Text('清除'),
                                backgroundColor: const Color(0xFF1E293B),
                                labelStyle: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                                onPressed: () => _setLabel(ssid, null),
                              ),
                          ],
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
          ],
        ),
      ),
    );
  }
}
