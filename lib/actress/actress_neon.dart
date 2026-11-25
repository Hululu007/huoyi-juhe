import 'package:flutter/material.dart';

import 'actress_adapter_neon.dart';

export 'actress_adapter_neon.dart' show Neon;

/// 女优库模块霓虹样式（2026-11-21 用户令：照 whos-tv 霓虹版 HTML +
/// Neon 系统改，不另发明）。
///
/// 配色一律取 [Neon] 常量（底 #120B20、卡面 #191029、紫 #B14BFF、
/// 紫罗兰 #7B4BFF、粉 #FF4FA3、青 #33E1FF、字白、次字 #B4A5CE）。
/// NeonPill / NeonPoster / NeonCapsuleBar 等现成组件的颜色取当前
/// 主题 AppThemeConfig，换非霓虹主题时会变色、保不住令里给定的
/// 色值，所以这里直接取 Neon 常量、只复用它们的形制：选中态紫→
/// 青渐变 + 辉光（霓虹版 HTML .navbtn/.chip），卡片紫描边 + 外发
/// 光（.acard/.vcard），底部栏胶囊形制照 NeonCapsuleBar 的尺寸
/// （高 62、左右 14、安全区下 10、圆角 31）。
///
/// 只给女优库模块的新增/改动部分用（顶栏、导航钮、分类 chips、
/// 演员卡、视频卡、底部栏），不碰其它页。

/// 霓虹药丸钮（导航钮 / 分类 chips 同款）：未选中卡面底 + 紫罗兰
/// 描边 + 次字色；选中紫→青 135° 渐变 + 白字 + 紫青双辉光。
class ActressNeonPill extends StatelessWidget {
  const ActressNeonPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 14,
          vertical: compact ? 6 : 7,
        ),
        decoration: BoxDecoration(
          gradient: selected ? Neon.edgeGradient : null,
          color: selected ? null : Neon.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? Colors.transparent
                : Neon.violet.withValues(alpha: .8),
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Neon.purple.withValues(alpha: .45),
                    blurRadius: 18,
                    offset: const Offset(0, 5),
                  ),
                  BoxShadow(
                    color: Neon.cyan.withValues(alpha: .30),
                    blurRadius: 16,
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: compact ? 12.5 : 13.5,
            height: 1.0,
            fontWeight: FontWeight.w600,
            color: selected ? Neon.text : Neon.textDim,
          ),
        ),
      ),
    );
  }
}

/// 霓虹卡片描边（演员卡 / 视频卡同款）：卡面底 + 紫描边 + 外发光。
BoxDecoration actressNeonCardDecoration({double radius = 15}) {
  return BoxDecoration(
    color: Neon.surface,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: Neon.violet.withValues(alpha: .55)),
    boxShadow: [
      BoxShadow(
        color: Neon.purple.withValues(alpha: .18),
        blurRadius: 18,
      ),
    ],
  );
}

/// 霓虹顶栏（女优库模块三页同款）：深紫底 + 底边紫线 + 紫辉光。
AppBar actressNeonAppBar({
  required Widget? title,
  List<Widget>? actions,
  double? toolbarHeight,
}) {
  return AppBar(
    toolbarHeight: toolbarHeight,
    title: title,
    actions: actions,
    backgroundColor: Neon.bg,
    foregroundColor: Neon.text,
    surfaceTintColor: Colors.transparent,
    elevation: 4,
    shadowColor: Neon.purple.withValues(alpha: .22),
    shape: Border(
      bottom: BorderSide(color: Neon.purple.withValues(alpha: .45)),
    ),
  );
}

/// 注意（合并时删掉的部分）：原文件末尾的 ActressModuleTabBar（5 页签
/// 胶囊栏：排行榜 / 帧探索 / 专题 / 演员库 / 影片库）是活树的 5 页签
/// 形态，主聊明说不搬——主树保留 4 页签（首页/分类/女优/收藏），
/// 5 页签胶囊栏不在本次合并范围内，故此处不保留该类。

/// 海报上的透明播放键（详情页海报、卡片墙共用）：半透明黑圆底 + 白三角。
/// 不带文字、不是“立即播放”按钮；播放/暂停在播放器里。
/// - 不传 onPressed 时只是视觉提示，点按由外层（海报整块的手势）接；
/// - 传了 onPressed 时它是独立的 InkWell，点按直接播（卡片墙上点键
///   直接播、点卡片主体仍进详情，内层 InkWell 赢手势竞争）。
class PosterPlayBadge extends StatelessWidget {
  const PosterPlayBadge({super.key, this.onPressed, this.size = 56});

  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .45),
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.play_arrow, color: Colors.white, size: size * .62),
    );
    final pressed = onPressed;
    if (pressed == null) return badge;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: pressed,
        child: badge,
      ),
    );
  }
}
