import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/search_discovery.dart';
import 'home_design.dart';
import '../series_detail/moyi_detail_theme.dart';

/// 官方书城顶栏（`res/layout/alx.xml` 的 `fua` 搜索行）。
///
/// 2026-10-26 首页重做后不再逐像素对齐官方：搜索框从 36dp / 6dp 圆角改成
/// 40dp / 20dp 的胶囊，右端「分类」入口同高同圆角。下面是官方的原尺寸，
/// 留作对照（文案与热搜轮换仍与官方一致）。
///
/// 官方在这一层是一条 51dp 的搜索行：`SearchWordDisplayView`（`h21`）占
/// 剩余宽度，左 16dp 右 16dp；右上角是「分类」入口 `i_y`（默认 gone，由
/// AB 位 `hasCategoryTab()==false` 时打开）——14dp 分类图 + 2dp 间隔 +
/// 14sp「分类」，高 `zl`=36dp，左右 padding 10dp，圆角 8dp 的白色底
/// （`skin_bg_top_right_holder_light` = `skin_color_search_bar_bg_v2_light`）。
///
/// 搜索框本体（`c5e.xml`）：36dp 高、6dp 圆角、白底；左侧 11dp 放大镜。
/// 官方框内的「识剧」图文入口（`search_image_icon_container`）按用户决定
/// 不做（2026-10-24，链路未接入），已删除。框内文案由 `search/cue/v` 的
/// 热搜词驱动（`SearchWordDisplayView` + `VerticalFlipper`，间隔取响应的
/// `rotate_interval_ms`）；没有词时回退静态提示语 `@string/duw`。
class HomeHero extends StatefulWidget {
  static const double searchBarHeight = 40;
  static const double searchBarRadius = 20;

  /// 搜索行在宽屏上的最大宽度。手机与平板永远吃不满这一档，只有桌面需要
  /// 它兜住：没有上限时窗口多宽、那条空胶囊就多宽，「分类」被挤到最右。
  /// 1120 ≈ 默认窗口的六列书卡宽（6×186 + 5×12 ≈ 1176，取整收一点），
  /// 左端与网格、分区头同一条 16dp 竖线。
  static const double maxToolbarWidth = 1120;

  /// 官方 `@string/duw`：`SearchWordDisplayView` 的默认文案。
  static const String searchHint = '请输入书名或作者名';

  /// 官方 `@string/gl`。
  static const String categoryLabel = '分类';

  /// 修仙版自己的品牌名（App 标题「凡人修仙观影传」），不用「魔蚁box」。
  static const String brandName = '凡人修仙观影传';

  /// 官方 `@string/gl`。
  final VoidCallback onSearch;

  /// 品牌行右端刷新圆钮的回调：null 时不显示刷新钮（测试与旧调用方）。
  final VoidCallback? onRefresh;

  /// 品牌名下方的小字：当前站名（短剧/影视分类下），没有站时传当前分类名。
  final String? brandSubtitle;

  /// 短剧区站点药丸上显示的站点名。null 时不显示药丸。
  final String? siteName;

  /// 站点药丸的点击回调。null 时药丸不可点。
  final VoidCallback? onSiteTap;

  /// 右上角「分类」入口。null 时不占位（与官方 `i_y` gone 一致）。
  final VoidCallback? onCategory;

  /// 搜索框热搜词（`/api/v1/search/cue`）。null 表示不接入——测试与离线
  /// 场景框内保持静态提示语；拉取失败同样回退静态提示语。
  final Future<SearchCue> Function()? cueLoader;

  const HomeHero({
    super.key,
    required this.onSearch,
    this.onRefresh,
    this.brandSubtitle,
    this.siteName,
    this.onSiteTap,
    this.onCategory,
    this.cueLoader,
  });

  @override
  State<HomeHero> createState() => _HomeHeroState();
}

class _HomeHeroState extends State<HomeHero> {
  List<String> _words = const [];
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final loader = widget.cueLoader;
    if (loader == null) return;
    // 热搜词是锦上添花：loader 同步或异步失败都不能波及页面，框内保持
    // 静态提示语即可。
    Future<SearchCue> future;
    try {
      future = loader();
    } catch (_) {
      return;
    }
    future
        .then((cue) {
          if (!mounted || cue.isEmpty) return;
          setState(() => _words = cue.words);
          _startRotation(cue.rotateIntervalMs);
        })
        .catchError((_) {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startRotation(int intervalMs) {
    // 官方 `VerticalFlipper` 也只在多于一条时有翻页的意义。
    if (_words.length < 2) return;
    _timer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      // 页面切走（IndexedStack 里未选中）时暂停轮换，回来后下一拍继续。
      if (!mounted || !TickerMode.valuesOf(context).enabled) return;
      setState(() => _index = (_index + 1) % _words.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    // 魔蚁式品牌行在上、搜索行在下。深色下顶栏罩一层深紫蓝渐变
    // （画布 #1E1D38 之上由 #2E1B5E 向透明过渡），浅色不罩。
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [_brandRow(palette), _searchRow(palette, animate)],
    );
    if (!palette.dark) return body;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF2E1B5E).withValues(alpha: 0.6),
            Colors.transparent,
          ],
        ),
      ),
      child: body,
    );
  }

  /// 品牌行（对照魔蚁首页顶栏）：粉紫渐变头像圆钮 + 品牌大字 +
  /// 当前站名小字，右端是搜索与刷新两个圆钮。
  ///
  /// 头像只是品牌标记，不跳「我的」页（那是底部导航的入口），所以不挂
  /// 点击回调；搜索圆钮与下方搜索框同进搜索页，刷新圆钮走页面下拉刷新
  /// 同一条刷新逻辑。
  Widget _brandRow(HomePalette palette) {
    final subtitle = widget.brandSubtitle ?? widget.siteName;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: HomeHero.maxToolbarWidth),
          child: Row(
            children: [
              Container(
                key: const Key('home_brand_avatar'),
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [Color(0xFFFF4FA3), Color(0xFFB14BFF)],
                  ),
                ),
                child: const Icon(
                  LucideIcons.user,
                  size: 22,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ShaderMask(
                      shaderCallback: (rect) => const LinearGradient(
                        colors: [moyiGold, Colors.white],
                      ).createShader(rect),
                      child: const Text(
                        HomeHero.brandName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 22,
                          height: 1.1,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    if (subtitle != null && subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: palette.muted),
                      ),
                    ],
                  ],
                ),
              ),
              _roundButton(
                key: const Key('home_brand_search'),
                icon: LucideIcons.search,
                tooltip: '搜索',
                palette: palette,
                onTap: widget.onSearch,
              ),
              const SizedBox(width: 8),
              if (widget.onRefresh != null)
                _roundButton(
                  key: const Key('home_brand_refresh'),
                  icon: LucideIcons.refresh_cw,
                  tooltip: '刷新',
                  palette: palette,
                  onTap: widget.onRefresh!,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 顶栏右端的圆形图标钮：半透明底 + 细白描边，对照魔蚁的圆钮。
  Widget _roundButton({
    required Key key,
    required IconData icon,
    required String tooltip,
    required HomePalette palette,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        key: key,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: palette.searchBar.withValues(alpha: 0.7),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Icon(icon, size: 18, color: palette.ink),
        ),
      ),
    );
  }

  Widget _searchRow(HomePalette palette, bool animate) {
    return Padding(
      // 官方 fua：paddingTop 6dp / paddingBottom 9dp，左右 16dp。
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      // 桌面宽窗里不再把搜索行拉满整条：2560 的窗口下一枚 2528 宽的空胶囊
      // 只剩一条灰带，「分类」还被推到窗口最右端。工具栏收到
      // [HomeHero.maxToolbarWidth]——约等于 6 张卡片的宽度，左端仍与网格、
      // 分区头同一条 16dp 竖线。
      //
      // 必须先过一层 [Align]：本 widget 挂在 `SliverToBoxAdapter` 里，sliver
      // 给的是**紧**的横向约束，`ConstrainedBox` 的 maxWidth 会被父约束用
      // `enforce` 抬回去（min=max=窗口宽），等于没封顶——实测 2560 的窗口里
      // 搜索胶囊仍是 2445.5 宽。`Align` 先把紧约束松成 0..宽，封顶才生效。
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: HomeHero.maxToolbarWidth),
          child: Row(
            children: [
              if (widget.siteName != null) ...[
                _sitePill(palette),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: HomePressable(
                  key: const Key('home_search_button'),
                  onTap: widget.onSearch,
                  borderRadius: BorderRadius.circular(HomeHero.searchBarRadius),
                  semanticLabel: HomeHero.searchHint,
                  child: Container(
                    height: HomeHero.searchBarHeight,
                    padding: const EdgeInsets.only(left: 16, right: 14),
                    decoration: BoxDecoration(
                      color: palette.searchBar,
                      borderRadius: BorderRadius.circular(
                        HomeHero.searchBarRadius,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          LucideIcons.search,
                          size: 15,
                          color: palette.muted,
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: _cueText(palette, animate)),
                      ],
                    ),
                  ),
                ),
              ),
              if (widget.onCategory != null) ...[
                const SizedBox(width: 16),
                _categoryPill(palette),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 热搜词轮换位：官方 `VerticalFlipper` 淡入淡出；无词时是静态提示语。
  Widget _cueText(HomePalette palette, bool animate) {
    final text = _words.isEmpty ? HomeHero.searchHint : _words[_index];
    final word = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      key: ValueKey<String>(text),
      style: TextStyle(fontSize: 13.5, color: palette.searchBarText),
    );
    if (!animate) return word;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.centerLeft,
        children: [...previousChildren, ?currentChild],
      ),
      child: word,
    );
  }

  /// 搜索行右端的「分类」入口：与搜索框同高同圆角的 40dp 胶囊。
  Widget _categoryPill(HomePalette palette) {
    return GestureDetector(
      key: const Key('home_category_button'),
      behavior: HitTestBehavior.opaque,
      onTap: widget.onCategory,
      child: Container(
        height: HomeHero.searchBarHeight,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: palette.searchBar,
          borderRadius: BorderRadius.circular(HomeHero.searchBarRadius),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.layout_grid, size: 15, color: palette.ink),
            const SizedBox(width: 5),
            Text(
              HomeHero.categoryLabel,
              style: TextStyle(fontSize: 13, color: palette.ink),
            ),
          ],
        ),
      ),
    );
  }

  /// 搜索行左端的站点药丸：与搜索框同高同圆角，显示当前短剧站点名。
  /// 搜索框仍是 Expanded，占剩余宽度，所以药丸一出现搜索框就往中间缩。
  Widget _sitePill(HomePalette palette) {
    return GestureDetector(
      key: const Key('home_site_button'),
      behavior: HitTestBehavior.opaque,
      onTap: widget.onSiteTap,
      child: Container(
        height: HomeHero.searchBarHeight,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: palette.searchBar,
          borderRadius: BorderRadius.circular(HomeHero.searchBarRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                widget.siteName!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: palette.ink),
              ),
            ),
            const SizedBox(width: 4),
            Icon(LucideIcons.chevron_down, size: 14, color: palette.ink),
          ],
        ),
      ),
    );
  }
}
