// DRAFT — target: lib/actress/code_meta_section.dart (copy into the
// smart-match worktree after the user gives the go-ahead; see REPORT.md).
//
// 详情页智能匹配区（2026-11-23 用户令）：按番号查三站元数据、查不到
// 按标题兜底，只显示演员与导演（番号只作匹配键、不显示；厂商、
// 年份不显示）。只加显示，不改播放链路（不碰 _playWork、不碰取流、
// 不写库、不联网、不加关注按钮）。查不到元数据、或元数据里既无
// 导演又无演员时什么都不画（不显示空字段）。
//
// 演员行样式按红果详情页截图：小头像 + 只显示名字（2026-11-24
// 用户令：去掉主演/配角，只留名字）。
// 头像地址来自女优库（who's 头像），有地址显示真照片，没有地址时
// ActressAvatar 回落到名字首字圆圈。
import 'package:flutter/material.dart';

import 'actress_adapter_models.dart';
import 'actress_widgets.dart';
import 'jav_code_meta.dart';
import 'whos_json_index.dart';

/// 详情页智能匹配区：自包含，详情页只插一行即可。
/// 找不到元数据（或资源缺失）时不占位置。
/// 详情页演员匹配入口（详情页头区演员行与 [CodeMetaSection] 共用）：
/// 两个索引并行加载（420 码管导演 + who's.json 管演员，339,526 码），
/// 任一加载失败时走空索引、match 只用另一边，不挡详情页。
/// 匹配先按番号、再按标题兜底（见 [JavCodeMeta.match]）；查不到时
/// 返回 null，调用方不画演员区。
Future<CodeMeta?> loadCodeMetaForDrama({
  required String dramaId,
  required String title,
  required String sourceId,
  String remark = '',
}) async {
  try {
    final results = await Future.wait([
      JavCodeMeta.instance,
      WhosJsonIndex.instance,
    ]);
    final map = results[0] as JavCodeMeta;
    final whos = results[1] as WhosJsonIndex;
    final matched = map.match(
      id: dramaId,
      title: title,
      sourceId: sourceId,
      whosIndex: whos,
    );
    if (matched != null) return matched;
    // 主匹配落空且备注（remark 通道常带番号）与标题不同时，用备注
    // 当标题再兜底一次（标题兜底会从备注里抠番号 / 按名查）。
    final trimmedRemark = remark.trim();
    if (trimmedRemark.isNotEmpty && trimmedRemark != title.trim()) {
      return map.match(
        id: dramaId,
        title: trimmedRemark,
        sourceId: sourceId,
        whosIndex: whos,
      );
    }
    return null;
  } catch (_) {
    // 资源缺失/损坏时不挡详情页：调用方直接不显示演员区。
    return null;
  }
}

class CodeMetaSection extends StatefulWidget {
  const CodeMetaSection({
    super.key,
    required this.dramaId,
    required this.title,
    this.sourceId = '',
  });

  /// 从 Drama 建（详情页用这个）。
  factory CodeMetaSection.forDrama(Drama drama) => CodeMetaSection(
    dramaId: drama.id,
    title: drama.title,
    sourceId: drama.sourceId,
  );

  /// 详情页 drama.id（如 `json:chaoliu:rki-6042`、`code_RKI-6042`）。
  final String dramaId;

  /// 详情页标题（番号查不到时作兜底键）。
  final String title;

  /// 详情页 drama.sourceId（extractAvId 兜底用）。
  final String sourceId;

  @override
  State<CodeMetaSection> createState() => _CodeMetaSectionState();
}

class _CodeMetaSectionState extends State<CodeMetaSection> {
  CodeMeta? _meta;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(CodeMetaSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dramaId != widget.dramaId ||
        oldWidget.title != widget.title) {
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final generation = ++_generation;
    // 先清掉旧的，防详情页切到另一部时短暂串台。
    setState(() => _meta = null);
    final meta = await _loadMeta();
    if (!mounted || generation != _generation) return;
    setState(() => _meta = meta);
  }

  Future<CodeMeta?> _loadMeta() => loadCodeMetaForDrama(
    dramaId: widget.dramaId,
    title: widget.title,
    sourceId: widget.sourceId,
  );

  @override
  Widget build(BuildContext context) {
    final meta = _meta;
    if (meta == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final cast = meta.castWithAvatars;
    // 只加演员和导演：既无导演又无演员时什么都不画（番号只作匹配键、
    // 不显示；厂商、年份不显示）。
    if (meta.director.isEmpty && cast.isEmpty) {
      return const SizedBox.shrink();
    }
    final facts = <({String label, String value})>[
      if (meta.director.isNotEmpty) (label: '导演', value: meta.director),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('演员与导演', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 8),
              Text(
                // 演员来自 who's 索引、导演没有时，来源标 who's 索引；
                // 否则标三站元数据（导演只来自 420 码）。
                meta.fromWhos && meta.director.isEmpty ? 'who\'s 索引' : '三站元数据',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (facts.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final fact in facts)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${fact.label}：${fact.value}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          if (cast.isNotEmpty) ...[
            const SizedBox(height: 4),
            for (final actor in cast)
              _ActorRow(
                key: ValueKey('code-meta-actor-${actor.name}'),
                name: actor.name,
                avatarUrl: actor.avatarUrl,
              ),
          ],
        ],
      ),
    );
  }
}

/// 演员行：小头像（真照片，没有时回落名字首字圆圈）+ 只显示名字
///（2026-11-24 用户令：主演/配角去掉）。
class _ActorRow extends StatelessWidget {
  const _ActorRow({super.key, required this.name, required this.avatarUrl});

  final String name;
  final String avatarUrl;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          ActressAvatar(avatarUrl: avatarUrl, name: name, radius: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
