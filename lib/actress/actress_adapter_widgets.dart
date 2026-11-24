// 适配层：女优库模块在魔蚁侧依赖的 DramaTile / dramaGridDelegate
//（原 lib/widgets.dart 的同名件）。魔蚁 widgets.dart 整文件 770 行，
//还依赖 AppLayout / glassDesign / Lucide 等整站件；女优库只用
//DramaTile（视频卡）与 dramaGridDelegate（网格代理），本文件只搬
//这两个，形态照魔蚁原样：封面 2:3 + 标题两行 + 副标题一行。
//
// 差异：封面直接用 drama.cover（CachedNetworkImage），不走仓储
// cover() 懒取——女优库卡片的封面就是库里/站方给的地址；repository
// 参数只为接口兼容而保留。封面上不画“共 N 集”角标（霓虹卡片的
// 双画教训：NeonPoster 与 DramaCover 同角叠画；副标题已带番号/集数）。

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'actress_adapter_models.dart' show Drama;
import 'actress_adapter_repository.dart' show AppRepository;

class DramaTile extends StatelessWidget {
  const DramaTile({
    super.key,
    required this.drama,
    required this.repository,
    required this.onTap,
    this.subtitle,
    this.focusNode,
    this.onFocus,
    this.actions,
    this.badge,
    this.topBadge,
    this.tagText,
    this.selected,
    this.onMore,
    this.onLongPress,
  });

  final Drama drama;

  /// 接口兼容保留：本实现不调它（封面直接用 drama.cover）。
  final AppRepository repository;
  final VoidCallback onTap;
  final String? subtitle;
  final FocusNode? focusNode;
  final VoidCallback? onFocus;
  final Widget? actions;
  final String? badge;
  final String? topBadge;
  final String? tagText;
  final bool? selected;
  final VoidCallback? onMore;
  final VoidCallback? onLongPress;

  static double titleHeight(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(14) * 2.6;

  static double subtitleHeight(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(12) * 1.3;

  static double extentFor(BuildContext context, double width) =>
      (width * 1.5 + 13 + titleHeight(context) + subtitleHeight(context))
          .ceilToDouble();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final cover = drama.cover.trim();
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 2 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: cover.isEmpty
                ? Container(
                    color: colors.surfaceContainerHighest,
                    child: Icon(
                      Icons.movie_creation_outlined,
                      size: 40,
                      color: colors.onSurfaceVariant,
                    ),
                  )
                : CachedNetworkImage(
                    imageUrl: cover,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => Container(
                      color: colors.surfaceContainerHighest,
                    ),
                    errorWidget: (_, _, _) => Container(
                      color: colors.surfaceContainerHighest,
                      child: Icon(
                        Icons.movie_creation_outlined,
                        size: 40,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          drama.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (subtitle != null && subtitle!.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
        if (tagText != null && tagText!.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            tagText!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
    final tile = InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(14),
      child: content,
    );
    if (focusNode == null && onFocus == null && actions == null) return tile;
    return Focus(
      focusNode: focusNode,
      onFocusChange: (focused) {
        if (focused) onFocus?.call();
      },
      child: Stack(
        children: [
          tile,
          if (actions != null)
            Positioned(top: 4, right: 4, child: actions!),
        ],
      ),
    );
  }
}

SliverGridDelegate dramaGridDelegate(
  BuildContext context,
  double width, {
  /// 卡片内容超出默认格高时补的高度。DramaTile 的 tagText 行
  /// （上间距 4 + 一行副标题高）不在 extentFor 里，带 tagText
  /// 的卡要把这段补上，否则 Column 溢出。
  double extraExtent = 0,
}) {
  final columns = width < 600 ? 3 : (width / 180).floor().clamp(4, 9);
  final spacing = width < 600 ? 10.0 : 18.0;
  final tileWidth = (width - (columns - 1) * spacing) / columns;
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    mainAxisSpacing: videoGridMainAxisSpacing(tileWidth),
    crossAxisSpacing: spacing,
    mainAxisExtent: DramaTile.extentFor(context, tileWidth) + extraExtent,
  );
}

double videoGridMainAxisSpacing(double tileWidth) =>
    (tileWidth * 0.10).clamp(8.0, 16.0);
