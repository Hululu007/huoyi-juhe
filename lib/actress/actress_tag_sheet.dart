import 'package:flutter/material.dart';

import 'actress_neon.dart';

/// 女优库标签筛选底部弹窗（2026-11-24 用户令：who's.json 分类是日本AV，
/// 标签在数据库里，底部弹窗显示里面的标签）。
///
/// 样式照用户给过的“全部站源”弹窗：标题 + 数量在顶，标签 chips 带
/// 作品数、可滚动、选中高亮；最前是“全部”（清空筛选）。
///
/// 纯展示 widget：数据由调用方查好传进来（视频库模式走数据库的
/// dbTags，通用模式走 GenericDbReader.tagFacet；没有标签时 [tags]
/// 为空，这里如实显示“暂无标签”，不编）。
/// 点标签回传标签名，点“全部”回传空串，调用方据此设筛选并关弹窗。
class ActressTagSheet extends StatelessWidget {
  const ActressTagSheet({
    super.key,
    required this.tags,
    required this.selected,
    required this.onSelected,
  });

  /// 全部标签（已按作品数倒序）；空 = 该库没有标签维度。
  final List<(String, int)> tags;

  /// 当前选中的标签；空 = 全部。
  final String selected;

  /// 点标签回传标签名；点“全部”回传 ''。
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Text(
                '标签',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                tags.isEmpty ? '暂无标签' : '${tags.length} 个',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        if (tags.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
            child: Text(
              '这个数据库里没有标签数据',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          )
        else
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActressNeonPill(
                    key: const ValueKey('actress-tag-all'),
                    label: '全部',
                    selected: selected.isEmpty,
                    onTap: () => onSelected(''),
                  ),
                  for (final tag in tags)
                    ActressNeonPill(
                      key: ValueKey('actress-tag-${tag.$1}'),
                      label: '${tag.$1}（${tag.$2}）',
                      selected: selected == tag.$1,
                      onTap: () => onSelected(tag.$1),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
