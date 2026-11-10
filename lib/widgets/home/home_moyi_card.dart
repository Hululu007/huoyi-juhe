import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import 'home_design.dart';
import 'home_media_card.dart';
import 'home_moyi_style.dart';
import 'home_shelf.dart';

/// 魔蚁式网格卡片（对照参考图与魔蚁 neon 首页的 NeonPoster）：
/// 圆角 14 + 紫色描边，标题与分类小字叠在封面底部渐变上，
/// 右上角 HD 角标只在条目自带 HD 信号时出现。
///
/// 新建文件，不动共用的 [HomeMediaCard]（频道页那路也在用）。
/// 封面复用 [StoryCover]（空封面时是几何占位，不联网）。

/// 条目是否自带 HD 信号：badge 或角标文字含 HD（不区分大小写）。
///
/// 上游 [MediaItem] 没有画质字段，所以只认这两个现成信号；
/// 参考实现里「每 3 张标一张 HD」是按下标硬标的假信号，这里不用——
/// 没有信号就不标，不硬标。
bool moyiIsHd(MediaItem item) {
  final badge = item.badge.trim().toLowerCase();
  if (badge.contains('hd')) return true;
  final tag = item.tag?.text.trim().toLowerCase() ?? '';
  return tag == 'hd' || tag.contains('hd');
}

/// 卡片底部的小字：真实分类优先，其次推荐理由，再次作者，
/// 都没有时用种类名（短剧 / 影视 / 小说 …），不编造。
String moyiCardSubtitle(MediaItem item) {
  if (item.categories.isNotEmpty) {
    return item.categories.take(2).join(' · ');
  }
  if (item.recTags.isNotEmpty) return item.recTags.first.text;
  if (item.author.isNotEmpty) return item.author;
  return homeKindLabel(item.kind);
}

class MoyiMediaCard extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onTap;

  /// 布局好的格宽：调用方已算好，卡片据此解码封面，省一次 LayoutBuilder。
  final double? coverWidth;

  const MoyiMediaCard({
    super.key,
    required this.item,
    required this.onTap,
    this.coverWidth,
  });

  @override
  Widget build(BuildContext context) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return _CardWidth(
      width: coverWidth,
      builder: (width) => HomePressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        semanticLabel: item.title,
        child: AspectRatio(
          aspectRatio: 5 / 7,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: MoyiStyle.purple.withValues(alpha: 0.55),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: MoyiStyle.purple.withValues(alpha: 0.18),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  StoryCover(
                    item: item,
                    cacheWidth: (width * pixelRatio).ceil(),
                  ),
                  if (moyiIsHd(item))
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        key: const Key('moyi_card_hd'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: MoyiStyle.cyan,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'HD',
                          style: TextStyle(
                            fontSize: 9,
                            height: 1,
                            fontWeight: FontWeight.w800,
                            color: Colors.black,
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(8, 18, 8, 8),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.82),
                          ],
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              height: 1.2,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            moyiCardSubtitle(item),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              height: 1.2,
                              color: Colors.white.withValues(alpha: 0.75),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 魔蚁式网格：手机 3 列（[homeShelfColumns] 在 <640dp 本来就是 3 列），
/// 列距 10、行距 12，格高 = 格宽 × 7/5（封面 5:7，标题叠在封面内，
/// 格子本身不再另留标题行）。
SliverGridDelegate moyiGridDelegate(BuildContext context, double gridWidth) {
  final columns = homeShelfColumns(context, gridWidth);
  final cardWidth = (gridWidth - (columns - 1) * 10) / columns;
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    crossAxisSpacing: 10,
    mainAxisSpacing: 12,
    mainAxisExtent: cardWidth * 1.4,
  );
}

/// 把调用方已知的格宽交给 child，[HomeMediaCard] 里的同款小工具
/// 是私有的，这里复制一份（只量宽度，不改共享文件）。
class _CardWidth extends StatelessWidget {
  final double? width;
  final Widget Function(double width) builder;

  const _CardWidth({required this.width, required this.builder});

  @override
  Widget build(BuildContext context) {
    final known = width;
    if (known != null) return builder(known);
    return LayoutBuilder(
      builder: (context, constraints) => builder(constraints.maxWidth),
    );
  }
}
