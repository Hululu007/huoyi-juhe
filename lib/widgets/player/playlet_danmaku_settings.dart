/// 短剧弹幕设置：官方 `ay1/v.java` 的四滑杆 + 恢复默认。
///
/// 持久化键与官方同名 SP `danmaku_config`（`impl/danmaku/a.java:38-127`）：
/// - `key_alpha` 默认 255（不透明），设置面板按 20%..100% 换算
///   （`m(p)=(p*255+50)/100`、`a(alpha)=(alpha*100+127)/255`）
/// - `key_speed` 默认 NORMAL=3；5 档 0.5/0.7/1.0/1.25/1.5（`DanmakuSpeed`）
/// - `key_line_count`（竖屏行数）1..4，官方默认来自服务端配置，
///   本地取 4；`key_line_space`（横屏密度）默认 QUARTER=2
/// - `key_text_size` 默认 DEFAULT=3（16sp）；5 档 12/14/16/18/20sp
///   （`DanmakuTextSize.java:114-118`）
///
/// 官方恢复默认 = 五键全 remove 回出厂（`a.java:92-96`）+ Toast
/// 「设置成功」（`eyr`/2131107533）。横竖屏滑杆语义不同：竖屏调行数、
/// 横屏调显示区域密度（`v.java:958-991`）。
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_side_panel.dart';

/// 官方 `danmaku_config` 五项设置的本地镜像。
class DanmakuSettings {
  const DanmakuSettings({
    this.alpha = 255,
    this.speedTier = 3,
    this.lineCount = 4,
    this.lineSpaceTier = 2,
    this.sizeTier = 3,
    this.transparentBackground = false,
    this.fontPercent = 100,
    this.fullscreenFontPercent = 120,
    this.scrollDurationSec = 0,
    this.staticDurationSec = 4,
    this.lineHeightFactor = 1.6,
    this.fontWeightValue = 400,
    this.strokeWidth = 0,
    this.displayAreaPercent = 0,
  });

  /// 0..255；面板以 20..100% 呈现。
  final int alpha;

  /// 1..5（慢..快），对应 [speedMultipliers]。
  final int speedTier;

  /// 竖屏轨道行数 1..4。
  final int lineCount;

  /// 横屏显示区域密度 1..4（单行/1/4屏/1/2屏/3/4屏）。
  final int lineSpaceTier;

  /// 字号档位 1..5。
  final int sizeTier;

  /// 弹幕气泡不画 40% 黑底，只留文字。
  final bool transparentBackground;

  /// 字号百分比 50..200（100=档位原字号），实际字号 = 档位字号 × 本值/100。
  final int fontPercent;

  /// 全屏时的字号百分比 50..250，见 [fontSizeFor]。
  final int fullscreenFontPercent;

  /// 滚动弹幕飞行时长（秒）；0=沿用旧基准（竖屏 10s/横屏 12s），
  /// 非 0 时钳 3..20 且不再分横竖屏。
  final double scrollDurationSec;

  /// 静态（顶部/底部）弹幕停留时长（秒），钳 2..10。
  final double staticDurationSec;

  /// 行高系数，钳 1.0..2.5；轨道间距 = 字号 × 本值 + 2.4。
  final double lineHeightFactor;

  /// 字体粗细，只允许 100..900 整百。
  final int fontWeightValue;

  /// 文字描边粗细，钳 0..3、0.5 步进；0=不描边。
  final double strokeWidth;

  /// 显示区域百分比；0=沿用旧口径（竖屏行数/横屏密度），
  /// 非 0 时钳 10..100，轨道数按屏高 × 本值% / 行距算。
  final int displayAreaPercent;

  /// 官方键之外的本地开关（官方气泡底色写死）。
  static const transparentKey = 'key_bg_transparent';

  static const spName = 'danmaku_config';
  static const speedMultipliers = [0.5, 0.7, 1.0, 1.25, 1.5];
  static const textSizes = [12.0, 14.0, 16.0, 18.0, 20.0];

  /// `DanmakuLineSpace`：SINGLE(1)/QUARTER(2)/HALF(3)/THREE_QUARTER(4)
  /// 对应屏高占比；SINGLE 官方直接取 1 行。
  static const lineSpaceFactors = [1.0, 0.25, 0.5, 0.75];
  static const speedLabels = ['慢', '较慢', '适中', '较快', '快'];
  static const sizeLabels = ['小', '较小', '适中', '较大', '大'];
  static const lineSpaceLabels = ['单行', '1/4屏', '1/2屏', '3/4屏'];

  double get speed => speedMultipliers[speedTier.clamp(1, 5) - 1];

  /// 档位字号 × 字号百分比。
  double get fontSize =>
      textSizes[sizeTier.clamp(1, 5) - 1] * fontPercentClamped / 100;

  /// 全屏用 [fullscreenFontPercent]，其余用 [fontPercent]。
  double fontSizeFor({required bool fullscreen}) =>
      textSizes[sizeTier.clamp(1, 5) - 1] *
      (fullscreen ? fullscreenFontPercentClamped : fontPercentClamped) /
      100;

  int get fontPercentClamped => fontPercent.clamp(50, 200);
  int get fullscreenFontPercentClamped =>
      fullscreenFontPercent.clamp(50, 250);
  double get scrollDurationSecClamped =>
      normalizeScrollDurationSec(scrollDurationSec);
  double get staticDurationSecClamped => staticDurationSec.clamp(2.0, 10.0);
  double get lineHeightFactorClamped => lineHeightFactor.clamp(1.0, 2.5);
  int get fontWeightValueClamped => normalizeFontWeightValue(fontWeightValue);
  double get strokeWidthClamped => normalizeStrokeWidth(strokeWidth);
  int get displayAreaPercentClamped =>
      normalizeDisplayAreaPercent(displayAreaPercent);

  /// 对应的 Flutter 字重（100..900 整百 → FontWeight.values 下标）。
  FontWeight get fontWeight =>
      FontWeight.values[(fontWeightValueClamped ~/ 100) - 1];

  static double normalizeScrollDurationSec(double value) {
    if (!value.isFinite || value <= 0) return 0;
    return value.clamp(3.0, 20.0);
  }

  static int normalizeFontWeightValue(int value) {
    final clamped = value.clamp(100, 900);
    return (clamped / 100).round() * 100;
  }

  static double normalizeStrokeWidth(double value) {
    if (!value.isFinite) return 0;
    final clamped = value.clamp(0.0, 3.0);
    return (clamped * 2).round() / 2;
  }

  static int normalizeDisplayAreaPercent(int value) {
    if (value <= 0) return 0;
    return value.clamp(10, 100);
  }

  DanmakuSettings copyWith({
    int? alpha,
    int? speedTier,
    int? lineCount,
    int? lineSpaceTier,
    int? sizeTier,
    bool? transparentBackground,
    int? fontPercent,
    int? fullscreenFontPercent,
    double? scrollDurationSec,
    double? staticDurationSec,
    double? lineHeightFactor,
    int? fontWeightValue,
    double? strokeWidth,
    int? displayAreaPercent,
  }) => DanmakuSettings(
    alpha: alpha ?? this.alpha,
    speedTier: speedTier ?? this.speedTier,
    lineCount: lineCount ?? this.lineCount,
    lineSpaceTier: lineSpaceTier ?? this.lineSpaceTier,
    sizeTier: sizeTier ?? this.sizeTier,
    transparentBackground: transparentBackground ?? this.transparentBackground,
    fontPercent: (fontPercent ?? this.fontPercent).clamp(50, 200),
    fullscreenFontPercent: (fullscreenFontPercent ?? this.fullscreenFontPercent)
        .clamp(50, 250),
    scrollDurationSec: normalizeScrollDurationSec(
      scrollDurationSec ?? this.scrollDurationSec,
    ),
    staticDurationSec: (staticDurationSec ?? this.staticDurationSec).clamp(
      2.0,
      10.0,
    ),
    lineHeightFactor: (lineHeightFactor ?? this.lineHeightFactor).clamp(
      1.0,
      2.5,
    ),
    fontWeightValue: normalizeFontWeightValue(
      fontWeightValue ?? this.fontWeightValue,
    ),
    strokeWidth: normalizeStrokeWidth(strokeWidth ?? this.strokeWidth),
    displayAreaPercent: normalizeDisplayAreaPercent(
      displayAreaPercent ?? this.displayAreaPercent,
    ),
  );

  /// 官方 `a(alpha)=(alpha*100+127)/255`：不透明度百分比。
  int get alphaPercent => (alpha * 100 + 127) ~/ 255;

  /// 官方 `m(p)=(p*255+50)/100`：滑杆百分比 → alpha。
  static int alphaFromPercent(int percent) => (percent * 255 + 50) ~/ 100;

  static Future<DanmakuSettings> load() async {
    final store = await SharedPreferences.getInstance();
    int read(String key, int fallback) =>
        store.getInt('$spName/$key') ?? fallback;
    double readDouble(String key, double fallback) {
      final value = store.get('$spName/$key');
      return value is num ? value.toDouble() : fallback;
    }

    // 旧存档没有新键时全部回默认值，行为与扩展前一致。
    return DanmakuSettings(
      alpha: read('key_alpha', 255).clamp(0, 255),
      speedTier: read('key_speed', 3).clamp(1, 5),
      lineCount: read('key_line_count', 4).clamp(1, 4),
      lineSpaceTier: read('key_line_space', 2).clamp(1, 4),
      sizeTier: read('key_text_size', 3).clamp(1, 5),
      transparentBackground: store.getBool('$spName/$transparentKey') ?? false,
      fontPercent: read('key_font_percent', 100).clamp(50, 200),
      fullscreenFontPercent: read('key_fullscreen_font_percent', 120).clamp(
        50,
        250,
      ),
      scrollDurationSec: normalizeScrollDurationSec(
        readDouble('key_scroll_duration_sec', 0),
      ),
      staticDurationSec: readDouble('key_static_duration_sec', 4).clamp(
        2.0,
        10.0,
      ),
      lineHeightFactor: readDouble('key_line_height_factor', 1.6).clamp(
        1.0,
        2.5,
      ),
      fontWeightValue: normalizeFontWeightValue(read('key_font_weight', 400)),
      strokeWidth: normalizeStrokeWidth(
        readDouble('key_stroke_width', 0),
      ),
      displayAreaPercent: normalizeDisplayAreaPercent(
        read('key_display_area_percent', 0),
      ),
    );
  }

  static Future<void> save(DanmakuSettings settings) async {
    final store = await SharedPreferences.getInstance();
    await store.setInt('$spName/key_alpha', settings.alpha);
    await store.setInt('$spName/key_speed', settings.speedTier);
    await store.setInt('$spName/key_line_count', settings.lineCount);
    await store.setInt('$spName/key_line_space', settings.lineSpaceTier);
    await store.setInt('$spName/key_text_size', settings.sizeTier);
    await store.setBool(
      '$spName/$transparentKey',
      settings.transparentBackground,
    );
    await store.setInt('$spName/key_font_percent', settings.fontPercentClamped);
    await store.setInt(
      '$spName/key_fullscreen_font_percent',
      settings.fullscreenFontPercentClamped,
    );
    await store.setDouble(
      '$spName/key_scroll_duration_sec',
      settings.scrollDurationSecClamped,
    );
    await store.setDouble(
      '$spName/key_static_duration_sec',
      settings.staticDurationSecClamped,
    );
    await store.setDouble(
      '$spName/key_line_height_factor',
      settings.lineHeightFactorClamped,
    );
    await store.setInt('$spName/key_font_weight', settings.fontWeightValueClamped);
    await store.setDouble('$spName/key_stroke_width', settings.strokeWidthClamped);
    await store.setInt(
      '$spName/key_display_area_percent',
      settings.displayAreaPercentClamped,
    );
  }
}

/// 弹幕设置面板：四个滑杆 + 恢复默认。几何沿用官方（`v.java:1050-1073`）：
/// 竖屏整宽底部，横屏 372dp 右对齐——由宿主的 bottom sheet 约束实现。
class PlayletDanmakuSettingsPanel extends StatefulWidget {
  const PlayletDanmakuSettingsPanel({
    super.key,
    required this.settings,
    required this.landscape,
    this.onChanged,
    this.onReset,
    this.onClose,
  });

  final DanmakuSettings settings;
  final bool landscape;

  /// 任一滑杆变化即回调（官方经 `UpdateDanmakuConfigEvent` 实时生效）。
  final ValueChanged<DanmakuSettings>? onChanged;
  final VoidCallback? onReset;

  /// ✕ 的行为。默认直接 pop；从视频设置级联进来时传「pop 回视频设置」，
  /// 这样按 ✕ 是退回上一层而不是一路掉回画面。
  final VoidCallback? onClose;

  @override
  State<PlayletDanmakuSettingsPanel> createState() =>
      _PlayletDanmakuSettingsPanelState();
}

class _PlayletDanmakuSettingsPanelState
    extends State<PlayletDanmakuSettingsPanel> {
  late DanmakuSettings _settings = widget.settings;

  void _update(DanmakuSettings settings) {
    setState(() => _settings = settings);
    widget.onChanged?.call(settings);
  }

  @override
  Widget build(BuildContext context) {
    final opacityProgress = _settings.alphaPercent - 20;
    return SafeArea(
      // 竖屏是底部 sheet（顶部由 sheet 自己让开），横屏是右侧全高面板，
      // 需要自己让出顶部安全区。
      top: widget.landscape,
      // 横屏面板贴右缘，左边那条安全区是屏幕另一侧的挖孔，不能让。
      left: false,
      child: Column(
        key: const ValueKey('danmaku-settings-panel'),
        mainAxisSize: MainAxisSize.min,
        children: [
          // 横屏是右侧全高面板（与选集抽屉同宽），没有可拖拽的底部 sheet，
          // 手柄会让人以为是能从底边拉起的弹层；换成同一款标题行。
          if (!widget.landscape)
            SizedBox(
              key: const ValueKey('danmaku-settings-drag-handle'),
              height: 20,
              width: double.infinity,
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0x33FFFFFF),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            )
          else
            PlayerSidePanelHeader(
              title: '弹幕设置',
              onClose: widget.onClose ?? () => Navigator.pop(context),
            ),
          // 横屏面板只有一块屏高（真机约 361dp），64dp 标题 + 六个设置项
          // 再加底部安全区就顶出去了——Column 溢出会画黄黑警示条。收进
          // `Flexible` 的滚动区：竖屏 sheet 仍按内容高度收紧，横屏超出时
          // 可以滚，不再溢出。
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _sliderRow(
                    key: 'danmaku-settings-opacity',
                    label: '不透明度',
                    value: opacityProgress.clamp(0, 80).toDouble(),
                    max: 80,
                    label2: '${_settings.alphaPercent}%',
                    onChanged: (v) => _update(
                      _settings.copyWith(
                        alpha: DanmakuSettings.alphaFromPercent(v.round() + 20),
                      ),
                    ),
                  ),
                  _sliderRow(
                    key: 'danmaku-settings-speed',
                    label: '弹幕速度',
                    value: (_settings.speedTier - 1).toDouble(),
                    max: 4,
                    divisions: 4,
                    label2:
                        DanmakuSettings.speedLabels[_settings.speedTier - 1],
                    onChanged: (v) =>
                        _update(_settings.copyWith(speedTier: v.round() + 1)),
                  ),
                  _sliderRow(
                    key: 'danmaku-settings-region',
                    label: '显示区域',
                    value: _regionValue,
                    max: 3,
                    divisions: 3,
                    label2: _regionLabel,
                    onChanged: (v) => _update(_withRegion(v.round() + 1)),
                  ),
                  _sliderRow(
                    key: 'danmaku-settings-size',
                    label: '字号',
                    value: (_settings.sizeTier - 1).toDouble(),
                    max: 4,
                    divisions: 4,
                    label2: DanmakuSettings.sizeLabels[_settings.sizeTier - 1],
                    onChanged: (v) =>
                        _update(_settings.copyWith(sizeTier: v.round() + 1)),
                  ),
                  _backgroundRow(),
                  _sliderRow(
                    key: 'danmaku-settings-display-area',
                    label: '显示区域%',
                    value: _settings.displayAreaPercentClamped.toDouble(),
                    max: 100,
                    label2: _settings.displayAreaPercentClamped == 0
                        ? '自动'
                        : '${_settings.displayAreaPercentClamped}%',
                    onChanged: (v) => _update(
                      _settings.copyWith(displayAreaPercent: v.round()),
                    ),
                  ),
                  _sliderRow(
                    key: 'danmaku-settings-font-percent',
                    label: '字体大小%',
                    value: _settings.fontPercentClamped.toDouble(),
                    min: 50,
                    max: 200,
                    label2: '${_settings.fontPercentClamped}%',
                    onChanged: (v) =>
                        _update(_settings.copyWith(fontPercent: v.round())),
                  ),
                  _sliderRow(
                    key: 'danmaku-settings-fullscreen-font-percent',
                    label: '全屏字体%',
                    value: _settings.fullscreenFontPercentClamped.toDouble(),
                    min: 50,
                    max: 250,
                    label2: '${_settings.fullscreenFontPercentClamped}%',
                    onChanged: (v) => _update(
                      _settings.copyWith(fullscreenFontPercent: v.round()),
                    ),
                  ),
                  _sliderRow(
                    key: 'danmaku-settings-scroll-duration',
                    label: '滚动时长',
                    value: _settings.scrollDurationSecClamped,
                    max: 20,
                    label2: _settings.scrollDurationSecClamped == 0
                        ? '默认'
                        : '${_settings.scrollDurationSecClamped.toStringAsFixed(1)}秒',
                    onChanged: (v) =>
                        _update(_settings.copyWith(scrollDurationSec: v)),
                  ),
                  _sliderRow(
                    key: 'danmaku-settings-static-duration',
                    label: '静态时长',
                    value: _settings.staticDurationSecClamped,
                    min: 2,
                    max: 10,
                    label2:
                        '${_settings.staticDurationSecClamped.toStringAsFixed(1)}秒',
                    onChanged: (v) =>
                        _update(_settings.copyWith(staticDurationSec: v)),
                  ),
                  _sliderRow(
                    key: 'danmaku-settings-line-height',
                    label: '弹幕行高',
                    value: _settings.lineHeightFactorClamped,
                    min: 1,
                    max: 2.5,
                    label2: _settings.lineHeightFactorClamped.toStringAsFixed(
                      1,
                    ),
                    onChanged: (v) =>
                        _update(_settings.copyWith(lineHeightFactor: v)),
                  ),
                  _sliderRow(
                    key: 'danmaku-settings-font-weight',
                    label: '字体粗细',
                    value: (_settings.fontWeightValueClamped ~/ 100).toDouble(),
                    min: 1,
                    max: 9,
                    divisions: 8,
                    label2: '${_settings.fontWeightValueClamped}',
                    onChanged: (v) => _update(
                      _settings.copyWith(fontWeightValue: v.round() * 100),
                    ),
                  ),
                  _sliderRow(
                    key: 'danmaku-settings-stroke-width',
                    label: '描边粗细',
                    value: _settings.strokeWidthClamped,
                    max: 3,
                    divisions: 6,
                    label2: _settings.strokeWidthClamped.toStringAsFixed(1),
                    onChanged: (v) =>
                        _update(_settings.copyWith(strokeWidth: v)),
                  ),
                ],
              ),
            ),
          ),
          // 恢复默认固定在面板底部、不随设置行滚动，新行变多后也够得着。
          Semantics(
            key: const ValueKey('danmaku-settings-reset-row'),
            button: true,
            child: InkWell(
              key: const ValueKey('danmaku-settings-reset'),
              onTap: () {
                // 官方恢复默认回五键出厂值并 Toast「设置成功」。
                _update(const DanmakuSettings());
                widget.onReset?.call();
              },
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 16),
                width: double.infinity,
                child: const Text('恢复默认', style: _labelStyle),
              ),
            ),
          ),
        ],
      ),
    );
  }

  double get _regionValue =>
      (widget.landscape ? _settings.lineSpaceTier : _settings.lineCount) - 1.0;
  String get _regionLabel => widget.landscape
      ? DanmakuSettings.lineSpaceLabels[_settings.lineSpaceTier - 1]
      : '${_settings.lineCount}行';

  DanmakuSettings _withRegion(int tier) => _settings.copyWith(
    lineCount: widget.landscape ? null : tier,
    lineSpaceTier: widget.landscape ? tier : null,
  );

  /// 弹幕背景透明：整行可点，Switch 自身不重复响应（与更多面板的
  /// 开关行同一语义）。
  Widget _backgroundRow() => GestureDetector(
    key: const ValueKey('danmaku-settings-transparent-row'),
    behavior: HitTestBehavior.opaque,
    onTap: () => _update(
      _settings.copyWith(
        transparentBackground: !_settings.transparentBackground,
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 10, 2),
      child: Row(
        children: [
          const Expanded(child: Text('弹幕背景透明', style: _labelStyle)),
          Switch(
            key: const ValueKey('danmaku-settings-transparent'),
            value: _settings.transparentBackground,
            onChanged: (value) =>
                _update(_settings.copyWith(transparentBackground: value)),
          ),
        ],
      ),
    ),
  );

  Widget _sliderRow({
    required String key,
    required String label,
    required double value,
    required double max,
    double min = 0,
    int? divisions,
    required String label2,
    required ValueChanged<double> onChanged,
  }) => Padding(
    key: ValueKey(key),
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
    child: Row(
      children: [
        SizedBox(width: 76, child: Text(label, style: _labelStyle)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: label2,
            activeColor: const Color(0xFFFA6725),
            inactiveColor: const Color(0x33FFFFFF),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(label2, textAlign: TextAlign.end, style: _labelStyle),
        ),
      ],
    ),
  );
}

const _labelStyle = TextStyle(fontSize: 14, color: Colors.white);
