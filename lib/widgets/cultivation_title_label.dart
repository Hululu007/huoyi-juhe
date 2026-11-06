import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/cultivation.dart';

/// 称号文字 + 专属特效（Flutter 实现，不依赖外部素材）。
///
/// 特效做法：渐变文字（ShaderMask）、辉光脉动（阴影透明度随呼吸变化）、
/// 流光扫过（一条亮带横向扫过文字）、上升光点（小圆点自下而上飘起）。
/// 特效柔和不刺眼；档案卡上当前称号的特效一眼看得出。
/// 未达成时 [dimmed] 为真，整体半透明（特效仍在，但 muted）。
class CultivationTitleLabel extends StatefulWidget {
  const CultivationTitleLabel({
    super.key,
    required this.title,
    required this.effect,
    this.style,
    this.dimmed = false,
  });

  final String title;
  final CultivationTitleEffect effect;
  final TextStyle? style;
  final bool dimmed;

  @override
  State<CultivationTitleLabel> createState() => _CultivationTitleLabelState();
}

class _CultivationTitleLabelState extends State<CultivationTitleLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseStyle =
        widget.style ??
        const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        );
    if (widget.effect == CultivationTitleEffect.none) {
      final label = Text(widget.title, style: baseStyle);
      return widget.dimmed ? Opacity(opacity: 0.45, child: label) : label;
    }
    final label = RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final t = _controller.value;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
            child: Stack(
              alignment: Alignment.center,
              children: [
                _effectText(t, baseStyle),
                if (_hasDots(widget.effect)) ..._dotWidgets(t),
              ],
            ),
          );
        },
      ),
    );
    return widget.dimmed ? Opacity(opacity: 0.5, child: label) : label;
  }

  bool _hasDots(CultivationTitleEffect effect) => switch (effect) {
    CultivationTitleEffect.purpleGlowDots ||
    CultivationTitleEffect.flameGlowDots ||
    CultivationTitleEffect.rainbowGlowDots ||
    CultivationTitleEffect.grandGlowDots => true,
    _ => false,
  };

  /// 渐变色与辉光色。
  (List<Color> gradient, Color glow) _palette(
    CultivationTitleEffect effect,
  ) => switch (effect) {
    CultivationTitleEffect.greenGlow => (
      [const Color(0xFF7ED491), const Color(0xFFD8F5DF)],
      const Color(0xFF4CAF50),
    ),
    CultivationTitleEffect.blueGlow => (
      [const Color(0xFF7FB3F0), const Color(0xFFD6E9FF)],
      const Color(0xFF2196F3),
    ),
    CultivationTitleEffect.goldShine => (
      [const Color(0xFFFFD54F), const Color(0xFFFFF3C4)],
      const Color(0xFFFFC107),
    ),
    CultivationTitleEffect.purpleGlowDots => (
      [const Color(0xFFB388FF), const Color(0xFFE9D5FF)],
      const Color(0xFF9C27B0),
    ),
    CultivationTitleEffect.flameGlowDots => (
      [const Color(0xFFFF8A65), const Color(0xFFFFD54F)],
      const Color(0xFFFF5722),
    ),
    CultivationTitleEffect.rainbowGlowDots => (
      [
        const Color(0xFFFF6B6B),
        const Color(0xFFFFD93D),
        const Color(0xFF6BCB77),
        const Color(0xFF4D96FF),
        const Color(0xFFB983FF),
      ],
      const Color(0xFFFFC107),
    ),
    // 前三特效称号：金色+彩虹底，最华丽。
    CultivationTitleEffect.grandGlowDots => (
      [
        const Color(0xFFFFD54F),
        const Color(0xFFFFF3C4),
        const Color(0xFFFFB300),
        const Color(0xFFFFF8E1),
      ],
      const Color(0xFFFFC107),
    ),
    CultivationTitleEffect.none => ([Colors.white], Colors.transparent),
  };

  Widget _effectText(double t, TextStyle baseStyle) {
    final (gradient, glow) = _palette(widget.effect);
    // 辉光脉动：阴影透明度与模糊随呼吸变化。
    final pulse = 0.5 + 0.5 * math.sin(t * math.pi * 2);
    final shadow = Shadow(
      color: glow.withValues(alpha: 0.35 + 0.35 * pulse),
      blurRadius: 6 + 5 * pulse,
    );
    final textStyle = baseStyle.copyWith(shadows: [shadow]);

    if (widget.effect == CultivationTitleEffect.goldShine) {
      return _shineText(t, textStyle);
    }
    if (widget.effect == CultivationTitleEffect.grandGlowDots) {
      return _grandText(t, textStyle, gradient, glow, pulse);
    }
    if (widget.effect == CultivationTitleEffect.rainbowGlowDots) {
      // 彩虹流光：渐变缓慢旋转，形成流动感。
      final angle = t * math.pi * 2;
      return ShaderMask(
        shaderCallback: (bounds) => LinearGradient(
          colors: gradient,
          transform: GradientRotation(angle * 0.5),
        ).createShader(bounds),
        blendMode: BlendMode.srcIn,
        child: Text(widget.title, style: textStyle),
      );
    }
    return ShaderMask(
      shaderCallback: (bounds) =>
          LinearGradient(colors: gradient).createShader(bounds),
      blendMode: BlendMode.srcIn,
      child: Text(widget.title, style: textStyle),
    );
  }

  /// 前三特效称号（最华丽）：大辉光 + 流光扫过 + 描边。
  /// 描边是底层一层描边字，渐变字盖在上面；流光是顶层亮带横扫。
  Widget _grandText(
    double t,
    TextStyle textStyle,
    List<Color> gradient,
    Color glow,
    double pulse,
  ) {
    final bigGlow = Shadow(
      color: glow.withValues(alpha: 0.55 + 0.35 * pulse),
      blurRadius: 14 + 8 * pulse,
    );
    final gradientStyle = textStyle.copyWith(shadows: [bigGlow]);
    final strokeStyle = textStyle.copyWith(
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = const Color(0xFF8D6E00).withValues(alpha: 0.85),
      shadows: const [],
    );
    final sweep = t;
    final begin = Alignment(-1.6 + 3.2 * sweep, 0);
    final end = Alignment(-1.0 + 3.2 * sweep, 0);
    return Stack(
      alignment: Alignment.center,
      children: [
        Text(widget.title, style: strokeStyle),
        ShaderMask(
          shaderCallback: (bounds) =>
              LinearGradient(colors: gradient).createShader(bounds),
          blendMode: BlendMode.srcIn,
          child: Text(widget.title, style: gradientStyle),
        ),
        ShaderMask(
          shaderCallback: (bounds) => LinearGradient(
            begin: begin,
            end: end,
            colors: const [
              Colors.transparent,
              Colors.white,
              Colors.transparent,
            ],
            stops: const [0.0, 0.5, 1.0],
          ).createShader(bounds),
          blendMode: BlendMode.srcIn,
          child: Text(widget.title, style: textStyle),
        ),
      ],
    );
  }

  /// 金色流光扫过：底字是金色，上层盖一层白色亮带，亮带横向扫过。
  Widget _shineText(double t, TextStyle textStyle) {
    // 亮带从左扫到右，扫完回到起点再扫。
    final sweep = t;
    final begin = Alignment(-1.6 + 3.2 * sweep, 0);
    final end = Alignment(-1.0 + 3.2 * sweep, 0);
    return Stack(
      alignment: Alignment.center,
      children: [
        Text(widget.title, style: textStyle),
        ShaderMask(
          shaderCallback: (bounds) => LinearGradient(
            begin: begin,
            end: end,
            colors: const [
              Colors.transparent,
              Colors.white,
              Colors.transparent,
            ],
            stops: const [0.0, 0.5, 1.0],
          ).createShader(bounds),
          blendMode: BlendMode.srcIn,
          child: Text(widget.title, style: textStyle),
        ),
      ],
    );
  }

  /// 上升光点：3 个小圆点自下而上飘起、渐渐淡出，错开相位。
  List<Widget> _dotWidgets(double t) {
    const slots = <double>[-0.85, 0.0, 0.85];
    const colors = <Color>[
      Color(0xFFE1BEE7),
      Color(0xFFFFF9C4),
      Color(0xFFBBDEFB),
    ];
    return [
      for (var i = 0; i < slots.length; i++)
        _risingDot(
          slot: slots[i],
          phase: (t + i / slots.length) % 1.0,
          color: colors[i % colors.length],
        ),
    ];
  }

  Widget _risingDot({
    required double slot,
    required double phase,
    required Color color,
  }) {
    // 从底部（y=1）升到顶部（y=-1），先淡入后淡出。
    final y = 1.0 - 2.0 * phase;
    final alpha = phase < 0.2 ? phase / 0.2 : 1 - (phase - 0.2) / 0.8;
    return Align(
      alignment: Alignment(slot, y),
      child: Opacity(
        opacity: alpha.clamp(0.0, 1.0) * 0.9,
        child: Container(
          width: 3.5,
          height: 3.5,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.6),
                blurRadius: 4,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
