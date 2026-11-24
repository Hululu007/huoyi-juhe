// 适配层：女优库模块在魔蚁侧依赖的 Neon 配色（原 lib/neon/neon_ui.dart
// 的 Neon 常量子集）。魔蚁 neon_ui.dart 整文件 1194 行，还依赖
// lucide_icons_flutter 与 AppThemeConfig——修仙版没有这两样，
// 女优库实际只用 Neon 的 9 个颜色/渐变（见下），本文件只搬这 9 个，
// 不搬 NeonPill / NeonAppBar / NeonCapsuleBar / NeonPoster 等组件
// （actress_neon.dart 里用到的组件都是它自己定义的 ActressNeonPill
// 与 actressNeonAppBar / actressNeonCardDecoration，不依赖 neon_ui
// 的组件；注释里提到的“形制照 NeonCapsuleBar”只是尺寸口径）。
//
// 色值与魔蚁 v42 一字不差（底 #120B20、卡面 #191029、
// 卡面高亮 #22143A、紫 #B14BFF、紫罗兰 #7B4BFF、粉 #FF4FA3、
// 青 #33E1FF、字白、次字 #B4A5CE）。

import 'package:flutter/material.dart';

class Neon {
  Neon._();

  static const bg = Color(0xFF120B20);
  static const bgDeep = Color(0xFF0B0617);
  static const surface = Color(0xFF191029);
  static const surfaceHigh = Color(0xFF22143A);
  static const surfaceGlass = Color(0xFF1B1030);

  static const purple = Color(0xFFB14BFF);
  static const violet = Color(0xFF7B4BFF);
  static const pink = Color(0xFFFF4FA3);
  static const magenta = Color(0xFFA021A8);
  static const cyan = Color(0xFF33E1FF);
  static const blue = Color(0xFF5B8CFF);
  static const teal = Color(0xFF10A9CD);

  static const text = Color(0xFFFFFFFF);
  static const textDim = Color(0xFFB4A5CE);
  static const textFaint = Color(0xFF7E6E9C);

  static const edgeGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [purple, cyan],
  );
  static const hotGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFFFF5FC8), Color(0xFF8A5BFF)],
  );
  static const cyanGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF39F0FF), Color(0xFF3E8BFF)],
  );
  static const pageGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0, .45, 1],
    colors: [Color(0xFF1B0F32), Color(0xFF100A1E), Color(0xFF141622)],
  );

  static Color glow(Color color, double alpha) =>
      color.withValues(alpha: alpha);

  static BoxShadow bloom(Color color, {double blur = 22, double spread = 0}) =>
      BoxShadow(
        color: glow(color, .45),
        blurRadius: blur,
        spreadRadius: spread,
      );

  static const titleStyle = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w800,
    color: text,
    height: 1.1,
  );
  static const brandStyle = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w700,
    color: textDim,
    letterSpacing: 2,
  );
}
