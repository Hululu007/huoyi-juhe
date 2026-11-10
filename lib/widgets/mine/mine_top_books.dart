import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../../models/reading_stats.dart';
import '../../services/poster_cache.dart';
import '../home/home_design.dart';
import '../home/home_media_card.dart';
import '../home/home_shelf.dart';
import '../home/home_sheet.dart';
import '../series_detail/moyi_detail_theme.dart';

typedef MineOpenEntry = void Function(Map<String, dynamic> entry);

/// 读得最多：按时长排的前 5 本，超过 5 本时右上角「全部」打开完整列表。
/// 取代旧统计页的 最近阅读 / 最近封面 / 阅读排行 三块。
class MineTopBooks extends StatelessWidget {
  static const previewCount = 5;

  final List<ReadingRankItem> rank;
  final MineOpenEntry onOpen;

  const MineTopBooks({super.key, required this.rank, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MineSectionHeader(
          title: '读得最多',
          action: rank.length > previewCount
              ? GestureDetector(
                  onTap: () => showMineRankSheet(context, rank, onOpen),
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '全部',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.2,
                          color: palette.eink ? palette.muted : moyiMutedOnDark,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        LucideIcons.chevron_right,
                        size: 13,
                        color: palette.eink ? palette.muted : moyiMutedOnDark,
                      ),
                    ],
                  ),
                )
              : null,
        ),
        if (rank.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: homeGutter),
            child: Text(
              '读过的书会按时长排在这里',
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: palette.eink ? palette.muted : moyiMutedOnDark,
              ),
            ),
          )
        else
          for (var i = 0; i < rank.length && i < previewCount; i++)
            MineRankRow(
              rank: i + 1,
              item: rank[i],
              onTap: () => onOpen(rank[i].entry),
            ),
      ],
    );
  }
}

/// 我的页分区头：与首页 HomeSectionHeader 同版式（19sp w700），
/// 只把标题色换成深底白字——共享头走 palette.ink，浅色下在深紫渐变
/// 底上读不清，这里不改共享组件，本地画一个。
class _MineSectionHeader extends StatelessWidget {
  final String title;
  final Widget? action;

  const _MineSectionHeader({required this.title, this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        homeGutter,
        homeSectionGap,
        homeGutter,
        homeHeaderGap,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 19,
                height: 1.25,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
                color: Colors.white,
              ),
            ),
          ),
          action ?? const SizedBox.shrink(),
        ],
      ),
    );
  }
}

/// 完整排行。点一行先收起弹层，再交给 [onOpen] 打开原内容。
Future<void> showMineRankSheet(
  BuildContext context,
  List<ReadingRankItem> rank,
  MineOpenEntry onOpen,
) async {
  await showHomeSheet<void>(
    context: context,
    title: '全部 ${rank.length} 本',
    contentPadding: EdgeInsets.zero,
    children: [
      for (var i = 0; i < rank.length; i++)
        MineRankRow(
          rank: i + 1,
          item: rank[i],
          onTap: () {
            Navigator.pop(context);
            onOpen(rank[i].entry);
          },
        ),
    ],
  );
}

class MineRankRow extends StatelessWidget {
  final int rank;
  final ReadingRankItem item;
  final VoidCallback onTap;

  const MineRankRow({
    super.key,
    required this.rank,
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return HomePressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      semanticLabel: item.title,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: homeGutter,
          vertical: 7,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: Text(
                '$rank',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: rank <= 3
                      ? (palette.eink ? palette.accentText : moyiGold)
                      : (palette.eink ? palette.muted : moyiMutedOnDark),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            _Cover(url: item.entry['cover']?.toString() ?? ''),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                      color: palette.eink ? palette.ink : Colors.white,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _meta(item.entry),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: palette.eink ? palette.muted : moyiMutedOnDark,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatReadingDuration(item.minutes),
              style: TextStyle(
                fontSize: 12,
                height: 1.3,
                color: palette.eink ? palette.muted : moyiMutedOnDark,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 类型 · 读到第几章 · 最近打开日期；缺的项直接省略。
String _meta(Map<String, dynamic> entry) {
  final kind = entry['kind']?.toString() ?? 'book';
  final episode = (entry['episode'] as num?)?.toInt();
  final time = (entry['time'] as num?)?.toInt() ?? 0;
  final opened = DateTime.fromMillisecondsSinceEpoch(time);
  return [
    homeKindLabel(kind),
    if (episode != null)
      isVideoKind(kind) ? '看到第${episode + 1}集' : '读到第${episode + 1}章',
    if (time > 0) '最近 ${opened.month}月${opened.day}日',
  ].join(' · ');
}

class _Cover extends StatelessWidget {
  final String url;

  const _Cover({required this.url});

  static const _width = 36.0;
  static const _height = 48.0;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final placeholder = Container(
      width: _width,
      height: _height,
      color: palette.eink ? palette.soft : moyiDarkCardFill,
      child: Icon(
        LucideIcons.book_open,
        size: 16,
        color: palette.eink ? palette.muted : moyiMutedOnDark,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: url.isEmpty
          ? placeholder
          : CachedNetworkImage(
              cacheManager: PosterCache.instance,
              imageUrl: url,
              width: _width,
              height: _height,
              fit: BoxFit.cover,
              memCacheWidth: 108,
              memCacheHeight: 144,
              errorWidget: (_, _, _) => placeholder,
            ),
    );
  }
}
