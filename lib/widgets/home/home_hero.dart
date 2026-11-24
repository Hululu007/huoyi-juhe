import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'home_design.dart';
import '../series_detail/moyi_detail_theme.dart';

/// 首页顶栏：品牌行（头像 + 品牌大字 + 当前站名小字），右端三个 40dp 圆钮：
/// 搜索、刷新、分类。
///
/// 2026-11-24（用户 21:01 令 + 21:04 补充令）：搜索行整行删除——搜索框胶囊、
/// 站点药丸、分类胶囊与热搜词轮换（`cueLoader` / `SearchCue`）一并去掉。
/// 搜索入口是右端放大镜圆钮（`home_brand_search`，21:04 令明确保留，取代
/// 20:27「放大镜去掉」的旧令）；分类入口是右端布局网格圆钮
/// （`home_brand_category`，做成 40dp 圆钮而不是把胶囊原样搬上来——胶囊
/// 会把品牌大字挤到省略号）；站点入口并入头像（`home_brand_avatar`，点按
/// 走原来的 `onSiteTap` 站点列表弹窗，标题点按仍不做任何事）。分类导航排
/// （吸顶的 `HomeTabBarDelegate`）不用动：搜索行删掉后它自然顶到品牌行下方。
///
/// 官方对照（`res/layout/alx.xml` 的 `fua` 搜索行）留作历史：官方在这一层
/// 是一条 51dp 的搜索行：`SearchWordDisplayView`（`h21`）占剩余宽度，左
/// 16dp 右 16dp；右上角是「分类」入口 `i_y`（默认 gone，由 AB 位
/// `hasCategoryTab()==false` 时打开）——14dp 分类图 + 2dp 间隔 + 14sp
/// 「分类」，高 `zl`=36dp，左右 padding 10dp，圆角 8dp 的白色底
/// （`skin_bg_top_right_holder_light` =
/// `skin_color_search_bar_bg_v2_light`）。
///
/// 搜索框本体（`c5e.xml`）：36dp 高、6dp 圆角、白底；左侧 11dp 放大镜。
/// 官方框内的「识剧」图文入口（`search_image_icon_container`）按用户决定
/// 不做（2026-10-24，链路未接入），已删除。
class HomeHero extends StatelessWidget {
  /// 品牌行在宽屏上的最大宽度。手机与平板永远吃不满这一档，只有桌面需要
  /// 它兜住：没有上限时窗口多宽、那条工具栏就多宽，右端圆钮被推到窗口最右。
  /// 1120 ≈ 默认窗口的六列书卡宽（6×186 + 5×12 ≈ 1176，取整收一点），
  /// 左端与网格、分区头同一条 16dp 竖线。
  static const double maxToolbarWidth = 1120;

  /// 官方 `@string/gl`。
  static const String categoryLabel = '分类';

  /// 修仙版自己的品牌名（App 标题「凡人修仙观影传」），不用「魔蚁box」。
  static const String brandName = '凡人修仙观影传';

  /// 右上角放大镜圆钮的回调：搜索入口常驻。
  final VoidCallback onSearch;

  /// 品牌行右端刷新圆钮的回调：null 时不显示刷新钮（测试与旧调用方）。
  final VoidCallback? onRefresh;

  /// 品牌名下方的小字：当前站名（短剧/影视分类下），没有站时传当前分类名。
  final String? brandSubtitle;

  /// 头像的点击回调：站点列表入口。null 时头像不可点。
  final VoidCallback? onSiteTap;

  /// 右上角「分类」圆钮。null 时不占位（与官方 `i_y` gone 一致）。
  final VoidCallback? onCategory;

  const HomeHero({
    super.key,
    required this.onSearch,
    this.onRefresh,
    this.brandSubtitle,
    this.onSiteTap,
    this.onCategory,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    // 魔蚁式品牌行。深色下顶栏罩一层深紫蓝渐变（画布 #1E1D38 之上由
    // #2E1B5E 向透明过渡），浅色不罩。
    final body = _brandRow(palette);
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
  /// 当前站名小字，右端依次是搜索、刷新、分类三个 40dp 圆钮。
  ///
  /// 头像就是站点列表入口（搜索行左端的站点药丸已随搜索行删除，入口并到
  /// 这里）：点按走 `onSiteTap` 的站点列表弹窗；标题点按仍不做任何事。
  /// 刷新圆钮走页面下拉刷新同一条刷新逻辑。
  Widget _brandRow(HomePalette palette) {
    final subtitle = brandSubtitle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: HomeHero.maxToolbarWidth),
          child: Row(
            children: [
              _avatar(),
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
                onTap: onSearch,
              ),
              if (onRefresh != null) ...[
                const SizedBox(width: 8),
                _roundButton(
                  key: const Key('home_brand_refresh'),
                  icon: LucideIcons.refresh_cw,
                  tooltip: '刷新',
                  palette: palette,
                  onTap: onRefresh!,
                ),
              ],
              if (onCategory != null) ...[
                const SizedBox(width: 8),
                _roundButton(
                  key: const Key('home_brand_category'),
                  icon: LucideIcons.layout_grid,
                  tooltip: HomeHero.categoryLabel,
                  palette: palette,
                  onTap: onCategory!,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 站点入口头像：外观不变（44px 粉紫渐变圆钮 + 用户图标）。`onSiteTap`
  /// 非空时包一层点按 +「切换站点」提示，空时不挂点击。
  Widget _avatar() {
    final avatar = Container(
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
    );
    final onSiteTap = this.onSiteTap;
    if (onSiteTap == null) return avatar;
    return Tooltip(
      message: '切换站点',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onSiteTap,
        child: avatar,
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
}
