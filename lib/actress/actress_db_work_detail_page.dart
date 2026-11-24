import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'actress_adapter_repository.dart';
import 'actress_adapter_store.dart';
import 'actress_adapter_player.dart';
import 'actress_generic_db.dart';
import 'code_meta_section.dart';

/// 外来库作品详情页（2026-11-22 用户令）：
/// 浏览链是 分类卡片 → 子分类卡片 → 视频卡片 → 这里 → 播放。
/// 详情页把库里这一行能给的信息全摆出来（封面大图、标题、番号、女优、
/// 分类、日期、播放地址），播放走现有播放链，不另起播放器。
class ActressDbWorkDetailPage extends StatelessWidget {
  const ActressDbWorkDetailPage({
    super.key,
    required this.work,
    required this.repository,
    required this.store,
  });

  final GenericDbWork work;
  final AppRepository repository;
  final LocalStore store;

  Future<void> _play(BuildContext context) async {
    if (!work.playable) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            work.playUrl.isEmpty
                ? '这条在库里没有播放地址（地址可能在另一张表，回列表点右上角「数据库字段」指定一下）'
                : '这条地址不是可播的 http 地址：${work.playUrl}',
          ),
        ),
      );
      return;
    }
    await pushPlayer<void>(
      context,
      detail: work.toJsonEntry().toDramaDetail(),
      initialIndex: 0,
      repository: repository,
      store: store,
    );
  }

  Future<void> _copyAddress(BuildContext context) async {
    if (work.playUrl.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: work.playUrl));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('播放地址已复制')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final title = work.displayTitle;
    final facts = <({String label, String value})>[
      if (work.code.isNotEmpty) (label: '番号', value: work.code),
      if (work.actress.isNotEmpty) (label: '女优', value: work.actress),
      if (work.category.isNotEmpty) (label: '分类', value: work.category),
      if (work.date.isNotEmpty) (label: '日期', value: work.date),
    ];
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 300,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: colors.surfaceContainerHighest),
                  if (work.coverUrl.isNotEmpty)
                    Image.network(
                      work.coverUrl,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => Icon(
                        Icons.movie_outlined,
                        size: 56,
                        color: colors.onSurfaceVariant,
                      ),
                    )
                  else
                    Icon(
                      Icons.movie_outlined,
                      size: 56,
                      color: colors.onSurfaceVariant,
                    ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black87],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 14,
                    child: Text(
                      title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
            sliver: SliverList.list(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        key: const ValueKey('db-work-detail-play'),
                        onPressed: () => _play(context),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(work.playable ? '立即播放' : '没有播放地址'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton.outlined(
                      tooltip: '复制播放地址',
                      onPressed: work.playUrl.isEmpty
                          ? null
                          : () => _copyAddress(context),
                      icon: const Icon(Icons.link_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
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
                CodeMetaSection(
                  dramaId: work.code,
                  title: work.displayTitle,
                ),
                const SizedBox(height: 18),
                Text(
                  '播放地址',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  work.playUrl.isEmpty ? '（库里这一行没有地址）' : work.playUrl,
                  style: const TextStyle(fontSize: 12, height: 1.5),
                ),
                const SizedBox(height: 18),
                Text(
                  '这个页面是从库文件里直接读出来的，改库请回列表点右上角「数据库字段」或「体检修复」。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
