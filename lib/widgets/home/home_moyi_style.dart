import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

/// 魔蚁式首页的配色与段头（对照魔蚁 neon 首页，只借结构与配色数值，
/// 不拷对方代码、不带对方品牌）。
///
/// 粉紫点缀三色取自参考实现：粉 0xFFFF4FA3、紫 0xFFB14BFF、青 0xFF33E1FF；
/// 画布本身沿用 [HomePalette] 的深紫蓝（深色 #1E1D38），这里不另起一套底色。
class MoyiStyle {
  /// 粉：马上看按钮、热播段头渐变、轮播圆点。
  static const Color pink = Color(0xFFFF4FA3);

  /// 紫：卡片描边、段头渐变、品牌头像渐变。
  static const Color purple = Color(0xFFB14BFF);

  /// 青：HD 角标、标签彩色圆点之一。
  static const Color cyan = Color(0xFF33E1FF);

  /// 粉→紫：品牌头像、马上看按钮、圆点、段头竖线共用的渐变。
  static const LinearGradient hotGradient = LinearGradient(
    colors: [pink, purple],
  );

  /// 标签彩色圆点按位轮换的三色（粉 / 青 / 紫，与参考实现同序）。
  static const List<Color> tagDotColors = [pink, cyan, purple];
}

/// 热播推荐一段取推荐流的前几张：3 列 × 2 行，一屏正好两行。
const int moyiHotSectionCount = 6;

/// 魔蚁式段头：左侧 3dp 粉紫渐变竖线 + 标题，右端可选「全部 >」动作。
///
/// 与 [HomeSectionHeader] 不同：这里标题 17sp、竖线是渐变、动作是
/// 「全部」+ 右箭头（点进频道分类页），对应参考图「热播推荐 / 猜你想看」。
class MoyiSectionHeader extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  const MoyiSectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFFB9B3D6)
        : const Color(0xFF706C66);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 14, 8),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 15,
            decoration: BoxDecoration(
              gradient: MoyiStyle.hotGradient,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 17,
              height: 1.25,
              fontWeight: FontWeight.w800,
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.white
                  : const Color(0xFF262522),
            ),
          ),
          const Spacer(),
          if (actionLabel != null)
            GestureDetector(
              key: const Key('moyi_section_all'),
              behavior: HitTestBehavior.opaque,
              onTap: onAction,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    actionLabel!,
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                  Icon(
                    LucideIcons.chevron_right,
                    size: 14,
                    color: muted,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
