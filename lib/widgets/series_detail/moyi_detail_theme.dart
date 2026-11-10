import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// 魔蚁 box 主题（只取配色与版式结构，不拷对方代码与品牌）：
///
/// - 深紫蓝渐变底：顶部深紫 `#2E1B62` → 中部 `#1A0F3C` → 底部 `#0E0724`。
/// - 粉紫点缀：主按钮粉 `#EC4899` → 紫 `#8B5CF6` 渐变；选中态青 `#22D3EE` →
///   蓝 `#3B82F6` 渐变；卡片描边紫 `#8B5CF6`。
/// - 标题白字金字：标题纯白粗体，集数行用金 `#F2C14E`。
/// - 圆角卡片 + 紫色描边：卡片圆角 16、描边紫 55% 透明度。
///
/// 适用范围：全 App 所有区域的背景（首页 / 频道 / 详情 / 短剧 / 影视 /
/// 直播 / 午夜 / 书架 / 我的 / 搜索 / 设置 / 播放页 / 弹窗 / 游戏面板），
/// 统一用同一套深紫蓝渐变底。不动首页 / 频道页 / 游戏 / 修仙境界逻辑
/// 以外的数据源、分类、导航、游戏数值、扣元宝规则。
/// 游戏战场本身（浮空仙山打斗场面）不动，只换游戏里的菜单、面板、弹窗背景。

/// 全区通用页面背景：深紫蓝渐变底 + 子内容。
///
/// 用法：把原来 `Scaffold(backgroundColor: ...)` 改成
/// `Scaffold(backgroundColor: Colors.transparent, body: MoyiPageBackground(child: ...))`，
/// 或在已有 body 外包一层。渐变值与 [moyiPageGradient] 同一套，禁止各页自定深浅。
class MoyiPageBackground extends StatelessWidget {
  const MoyiPageBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: moyiPageGradient),
      child: child,
    );
  }
}

/// 深底上的卡片 / 面板填充：深紫半透明（替代原来的浅色底、白色卡片底）。
const Color moyiDarkCardFill = Color(0x2EFFFFFF);

/// 深底上的卡片描边：紫 35% 透明度（比海报卡片的 55% 淡一档，适合大面积面板）。
const Color moyiDarkCardBorder = Color(0x59FFFFFF);

/// 深底上的正文：白 70%。
const Color moyiBodyOnDark = Color(0xB3FFFFFF);

/// 深底上的次要文字：白 55%。
const Color moyiMutedOnDark = Color(0x8CFFFFFF);

/// 弹窗 / 底部表的深底：实色深紫（渐变在小面积弹窗上看不出，用实色）。
const Color moyiSheetFill = Color(0xFF1A0F3C);

/// 底部表 / 弹窗里卡片的填充。
const Color moyiSheetCardFill = Color(0x2EFFFFFF);

/// 深紫蓝渐变底（对照魔蚁 box 首页与频道分类页的底色）。
const LinearGradient moyiPageGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [
    Color(0xFF2E1B62),
    Color(0xFF1A0F3C),
    Color(0xFF0E0724),
  ],
  stops: [0.0, 0.55, 1.0],
);

/// 主按钮粉紫渐变（对照图里「马上看」按钮）。
const LinearGradient moyiPrimaryGradient = LinearGradient(
  begin: Alignment.centerLeft,
  end: Alignment.centerRight,
  colors: [Color(0xFFEC4899), Color(0xFF8B5CF6)],
);

/// 选中态青蓝渐变（对照频道页「热门」选中胶囊）。
const LinearGradient moyiSelectedGradient = LinearGradient(
  begin: Alignment.centerLeft,
  end: Alignment.centerRight,
  colors: [Color(0xFF22D3EE), Color(0xFF3B82F6)],
);

/// 魔蚁紫（描边 / 强调色）。
const Color moyiPurple = Color(0xFF8B5CF6);

/// 深紫（当前集浅底等紫色填充）。
const Color moyiPurpleDeep = Color(0xFF7C3AED);

/// 魔蚁粉（主按钮起点）。
const Color moyiPink = Color(0xFFEC4899);

/// 魔蚁青（选中胶囊起点）。
const Color moyiCyan = Color(0xFF22D3EE);

/// 深紫蓝渐变顶（详情页顶部色带 / 渐变罩的起点）。
const Color moyiBandTop = Color(0xFF2E1B62);

/// 标题旁的金字（集数行 / 金色点缀）。
const Color moyiGold = Color(0xFFF2C14E);

/// 圆角卡片 + 紫色描边（对照图里海报卡片的紫色描边）。
BoxDecoration moyiCardDecoration({double radius = 16, Color? fill}) =>
    BoxDecoration(
      color: fill ?? Colors.white.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: moyiPurple.withValues(alpha: 0.55), width: 1),
    );

/// 详情页标题：白字粗体（剧照背景上）。
const TextStyle moyiTitleStyle = TextStyle(
  fontSize: 17,
  height: 1.45,
  fontWeight: FontWeight.w700,
  color: Colors.white,
);

/// 集数 / 状态行：金字。
const TextStyle moyiGoldLineStyle = TextStyle(
  fontSize: 13,
  height: 1.5,
  fontWeight: FontWeight.w600,
  color: moyiGold,
);

/// 剧照背景：剧照原图整幅显示，**不模糊**（不用 BackdropFilter /
/// ImageFilter.blur），只盖一层深紫蓝渐变罩保证文字可读：顶部半透、
/// 中部透出剧照、下缘收进深紫底。
///
/// [imageUrl] 为空时只画深紫蓝渐变底。调用方按「剧照优先、海报回落」
/// 算好地址传进来。
class MoyiDetailBackground extends StatelessWidget {
  const MoyiDetailBackground({
    super.key,
    required this.imageUrl,
    required this.child,
  });

  final String imageUrl;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: imageUrl.isEmpty
              ? const DecoratedBox(decoration: BoxDecoration(gradient: moyiPageGradient))
              : CachedNetworkImage(
                  key: const ValueKey('moyi-detail-background-image'),
                  imageUrl: imageUrl,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => const DecoratedBox(
                    decoration: BoxDecoration(gradient: moyiPageGradient),
                  ),
                  placeholder: (_, _) => const DecoratedBox(
                    decoration: BoxDecoration(gradient: moyiPageGradient),
                  ),
                ),
        ),
        // 深色渐变罩：只用渐变，不用模糊；剧照在中上部完整透出来。
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x8C1A0F3C),
                  Color(0x401A0F3C),
                  Color(0xE60E0724),
                ],
                stops: [0.0, 0.45, 1.0],
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// 粉紫渐变主按钮（对照图里「马上看」）：粉 → 紫渐变、白字粗体。
///
/// [enabled] 为 false 时退成灰底灰字；[borderRadius] 默认 14，短剧详情
/// 的药丸按钮传 [StadiumBorder] 同款大圆角。
class MoyiGradientButton extends StatelessWidget {
  const MoyiGradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.trailing,
    this.enabled = true,
    this.height = 44,
    this.borderRadius = 14,
    this.fontSize = 14,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Widget? trailing;
  final bool enabled;
  final double height;
  final double borderRadius;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final active = enabled && onPressed != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(borderRadius),
        onTap: active ? onPressed : null,
        child: Ink(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            gradient: active ? moyiPrimaryGradient : null,
            color: active ? null : Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(borderRadius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: Colors.white),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 4),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
