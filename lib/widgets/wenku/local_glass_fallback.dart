// 本地最小等效，不是上游原文。
//
// 上游 GlassControls / GlassIconButton / JellyTapSurface 的实现依赖
// liquid_glass_easy 整包（液态玻璃着色器 + 控制器），本树不引入。
// 这里只保留调用点用到的同一签名，渲染为普通 Material 控件：
// 设置面板取 classic 外观时，chip / toggle 两处玻璃分支本来就不会走到
// （见 reader_appearance_sheet.dart 的 AppUiScope 包裹）；
// slider 与点按面走普通渲染，行为与上游 classic 分支一致。
// 签名与上游 upstream/master 18161a89 的 glass_controls.dart、
// wenku_glass.dart 逐项对齐，调用点一字不用改。
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'src/app_haptics.dart';

abstract final class GlassControls {
  static Widget toggle(
    BuildContext context, {
    Key? key,
    required bool value,
    required FutureOr<void> Function(bool)? onChanged,
    bool haptics = true,
    bool optimistic = true,
    String? semanticLabel,
    Color? accentColor,
    Color? trackColor,
    Color? thumbColor,
    Color? tint,
    bool plainFallback = false,
  }) {
    final sw = Switch(
      key: key,
      value: value,
      onChanged: onChanged == null
          ? null
          : (next) {
              if (haptics) AppHaptics.play(context, HapticCue.selection);
              onChanged(next);
            },
      thumbColor: thumbColor == null
          ? null
          : WidgetStatePropertyAll(thumbColor),
      trackColor: accentColor == null && trackColor == null
          ? null
          : WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? accentColor
                  : trackColor,
            ),
      overlayColor: accentColor == null
          ? null
          : WidgetStatePropertyAll(accentColor.withValues(alpha: 0.12)),
    );
    if (semanticLabel == null) return sw;
    return Semantics(label: semanticLabel, child: sw);
  }

  static Widget slider(
    BuildContext context, {
    Key? key,
    required double value,
    required ValueChanged<double>? onChanged,
    double min = 0,
    double max = 1,
    int? divisions,
    bool haptics = true,
    bool compact = false,
    Color? accentColor,
    Color? trackColor,
    Color? thumbColor,
    Color? tint,
    ValueChanged<double>? onChangeStart,
    ValueChanged<double>? onChangeEnd,
    String Function(double value)? semanticFormatter,
  }) {
    final slider = Slider(
      key: key,
      value: value,
      onChanged: onChanged,
      min: min,
      max: max,
      divisions: divisions,
      onChangeStart: onChangeStart,
      onChangeEnd: onChangeEnd,
      semanticFormatterCallback: semanticFormatter,
    );
    if (accentColor == null && trackColor == null && thumbColor == null) {
      return slider;
    }
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: accentColor,
        inactiveTrackColor: trackColor,
        thumbColor: thumbColor ?? accentColor,
        overlayColor: accentColor?.withValues(alpha: 0.12),
      ),
      child: slider,
    );
  }

  static Widget chip(
    BuildContext context, {
    Key? key,
    required Widget child,
    required bool selected,
    required VoidCallback? onPressed,
    Color? tint,
  }) {
    return Semantics(
      key: key,
      selected: selected,
      button: true,
      child: Material(
        color: tint ?? Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: child,
          ),
        ),
      ),
    );
  }
}

class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
    this.haptic = HapticCue.action,
    this.liveGlass = true,
    this.transparent = false,
    this.pageHeight,
    this.compactMainPage = false,
  }) : child = null;

  const GlassIconButton.custom({
    super.key,
    required this.child,
    required this.label,
    required this.onPressed,
    this.haptic = HapticCue.action,
    this.liveGlass = true,
    this.transparent = false,
    this.pageHeight,
    this.compactMainPage = false,
  }) : icon = null,
       color = null;

  final IconData? icon;
  final Widget? child;
  final String label;
  final VoidCallback? onPressed;
  final Color? color;
  final HapticCue? haptic;
  final bool liveGlass;
  final bool transparent;
  final double? pageHeight;
  final bool compactMainPage;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: label,
      onPressed: onPressed == null
          ? null
          : () {
              final cue = haptic;
              if (cue != null) AppHaptics.play(context, cue);
              onPressed!();
            },
      icon: child ?? Icon(icon, color: color),
    );
  }
}

class JellyTapSurface extends StatelessWidget {
  const JellyTapSurface({
    super.key,
    this.tapKey,
    required this.child,
    required this.onTap,
    this.haptic = HapticCue.action,
  });

  final Widget child;
  final Key? tapKey;
  final VoidCallback? onTap;
  final HapticCue? haptic;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: tapKey,
        onTap: onTap == null
            ? null
            : () {
                final cue = haptic;
                if (cue != null) AppHaptics.play(context, cue);
                onTap!();
              },
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        child: child,
      ),
    );
  }
}
