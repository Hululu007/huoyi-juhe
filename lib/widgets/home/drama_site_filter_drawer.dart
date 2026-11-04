import 'package:flutter/material.dart';

import '../../services/xbpq_content.dart';

/// 站点筛选的右侧抽屉：筛选分类不再以横滚行铺在列表上方，统一收进
/// 从右侧滑出的面板。点选项即时生效（外层重拉第一页），面板不关闭，
/// 方便连续挑多组；清除筛选回到全部。
class DramaSiteFilterDrawer extends StatelessWidget {
  const DramaSiteFilterDrawer({
    super.key,
    required this.groups,
    required this.selected,
    required this.onSelected,
    required this.onClear,
    required this.onClose,
  });

  final List<XbpqFilterGroup> groups;
  final Map<String, String> selected;
  final void Function(String groupKey, String value) onSelected;
  final VoidCallback onClear;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = selected.entries.where((e) => e.value.isNotEmpty).length;
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Text(
                    active > 0 ? '筛选·$active' : '筛选',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(Icons.close),
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                children: [
                  for (final group in groups) ...[
                    Text(
                      group.key,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final option in group.options)
                          ChoiceChip(
                            label: Text(option.name),
                            selected:
                                (selected[group.key] ?? '') == option.value,
                            onSelected: (_) =>
                                onSelected(group.key, option.value),
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onClear,
                      child: const Text('清除筛选'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: onClose,
                      child: const Text('完成'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
