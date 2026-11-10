import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import 'home_media_card.dart';
import 'home_moyi_style.dart';

/// 魔蚁式大轮播的选片口径（对照魔蚁 neon 首页的 `_featured`）：
/// 有封面的优先、最多 6 张；一张有封面的都没有时退回前 6 张
/// （封面由 [StoryCover] 的几何占位兜底，整区不因此消失）。
List<MediaItem> moyiCarouselItems(
  List<MediaItem> items, {
  int max = 6,
}) {
  final withCover = [
    for (final item in items)
      if (item.cover.trim().isNotEmpty) item,
  ];
  final picked = withCover.isEmpty ? items : withCover;
  return picked.take(max).toList();
}

/// 魔蚁式大轮播：居中大卡、左右露出相邻卡片边缘、圆点指示器，
/// 卡片底部是标题 + 分类标签彩色圆点 + 粉色「马上看」按钮。
///
/// 结构对照魔蚁 neon 首页：`PageView(viewportFraction: .68)`、
/// 5 秒自动翻页、未选中卡缩放 .88 + 透明度 .55、底部深色玻璃面板。
/// 点卡片或点「马上看」都进当前 hero 的详情/播放（[onOpen]）。
class MoyiHeroCarousel extends StatefulWidget {
  final List<MediaItem> items;
  final void Function(MediaItem item) onOpen;

  const MoyiHeroCarousel({
    super.key,
    required this.items,
    required this.onOpen,
  });

  @override
  State<MoyiHeroCarousel> createState() => _MoyiHeroCarouselState();
}

class _MoyiHeroCarouselState extends State<MoyiHeroCarousel> {
  late final PageController _pages = PageController(viewportFraction: 0.68);
  Timer? _timer;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _armTimer();
  }

  @override
  void didUpdateWidget(MoyiHeroCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = oldWidget.items.firstOrNull?.id;
    final newId = widget.items.firstOrNull?.id;
    if (oldId != newId && _pages.hasClients) {
      _pages.jumpToPage(0);
      _page = 0;
    }
    _armTimer();
  }

  void _armTimer() {
    _timer?.cancel();
    if (widget.items.length < 2) return;
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted ||
          !_pages.hasClients ||
          !TickerMode.valuesOf(context).enabled) {
        return;
      }
      final next = (_page + 1) % widget.items.length;
      _pages.animateToPage(
        next,
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Column(
          key: const ValueKey('moyi-hero'),
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              // 手机上是宽 × 0.92（390 宽 → 约 359 高，与参考图同比例）；
              // 宽窗封顶 420：桌面/大屏上轮播再高会把推荐流与短页自动续载
              // 一起顶出首屏（maxScrollExtent 变大后 _maybeLoadMore 不触发）。
              height: (width * 0.92).clamp(0.0, 420.0),
              child: PageView.builder(
                controller: _pages,
                itemCount: items.length,
                onPageChanged: (page) => setState(() => _page = page),
                itemBuilder: (context, index) =>
                    _heroCard(items[index], index == _page, width),
              ),
            ),
            if (items.length > 1) _dots(items.length),
          ],
        );
      },
    );
  }

  Widget _heroCard(MediaItem item, bool active, double width) {
    final tags = _heroTags(item);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: width * 0.012, vertical: 8),
      child: AnimatedScale(
        scale: active ? 1 : 0.88,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          opacity: active ? 1 : 0.55,
          duration: const Duration(milliseconds: 260),
          child: GestureDetector(
            key: ValueKey('moyi-hero-${item.id}'),
            onTap: () => widget.onOpen(item),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: MoyiStyle.purple.withValues(alpha: 0.45),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: MoyiStyle.purple.withValues(alpha: 0.25),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    StoryCover(
                      item: item,
                      cacheWidth:
                          (width * 0.68 * MediaQuery.devicePixelRatioOf(context))
                              .ceil(),
                    ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: const [0.35, 0.72, 1],
                            colors: [
                              Colors.transparent,
                              const Color(0xFF0B0617).withValues(alpha: 0.55),
                              const Color(0xFF0B0617).withValues(alpha: 0.95),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 10,
                      right: 10,
                      bottom: 12,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFF1A0F2E,
                          ).withValues(alpha: 0.82),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                height: 1.1,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                            if (tags.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  for (var i = 0; i < tags.length; i++) ...[
                                    if (i > 0) const SizedBox(width: 7),
                                    _tagDot(
                                      tags[i],
                                      MoyiStyle.tagDotColors[i %
                                          MoyiStyle.tagDotColors.length],
                                    ),
                                  ],
                                ],
                              ),
                            ],
                            const SizedBox(height: 10),
                            GestureDetector(
                              key: ValueKey('moyi-hero-watch-${item.id}'),
                              behavior: HitTestBehavior.opaque,
                              onTap: () => widget.onOpen(item),
                              child: Container(
                                height: 34,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  gradient: MoyiStyle.hotGradient,
                                  borderRadius: BorderRadius.circular(17),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      LucideIcons.play,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      '马上看',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
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
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// hero 卡底部的分类标签：真实分类优先，其次推荐理由，再次 badge，
  /// 都没有时用种类名；最多 3 个，不编造。
  static List<String> _heroTags(MediaItem item) {
    final tags = <String>[
      ...item.categories,
      for (final tag in item.recTags) tag.text,
      if (item.badge.isNotEmpty) item.badge,
      homeKindLabel(item.kind),
    ].where((tag) => tag.trim().isNotEmpty).toList();
    return tags.take(3).toList();
  }

  Widget _tagDot(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.8), blurRadius: 6),
            ],
          ),
        ),
        const SizedBox(width: 3),
        Text(
          label,
          style: const TextStyle(fontSize: 9.5, color: Color(0xFFD3C6EA)),
        ),
      ],
    );
  }

  Widget _dots(int count) {
    return Padding(
      key: const Key('moyi-hero-dots'),
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 2.5),
              width: i == _page ? 16 : 5,
              height: 4,
              decoration: BoxDecoration(
                gradient: i == _page ? MoyiStyle.hotGradient : null,
                color: i == _page
                    ? null
                    : Colors.white.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    );
  }
}
