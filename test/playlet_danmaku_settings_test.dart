import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/widgets/player/playlet_danmaku_settings.dart';

/// 弹幕设置面板（官方 `ay1/v.java` + `impl/danmaku/a.java`）：
/// 五项设置走官方 `danmaku_config` 的默认值与换算公式。
void main() {
  group('DanmakuSettings', () {
    test('defaults follow the official danmaku_config defaults', () {
      const settings = DanmakuSettings();
      // key_alpha=255、key_speed=NORMAL(3)、key_text_size=DEFAULT(3)。
      expect(settings.alpha, 255);
      expect(settings.speedTier, 3);
      expect(settings.lineCount, 4);
      expect(settings.lineSpaceTier, 2);
      expect(settings.sizeTier, 3);
      expect(settings.fontSize, 16);
      expect(settings.speed, 1.0);
      expect(settings.alphaPercent, 100);
    });

    test('alpha conversion follows the official m(p)/a(alpha) formulas', () {
      // m(p)=(p*255+50)/100、a(alpha)=(alpha*100+127)/255。
      expect(DanmakuSettings.alphaFromPercent(100), 255);
      expect(DanmakuSettings.alphaFromPercent(20), 51);
      expect(const DanmakuSettings(alpha: 128).alphaPercent, 50);
      expect(
        DanmakuSettings.alphaFromPercent(
          const DanmakuSettings(alpha: 51).alphaPercent,
        ),
        51,
      );
    });

    test('new fields default to the pre-extension behaviour', () {
      const settings = DanmakuSettings();
      expect(settings.fontPercent, 100);
      expect(settings.fullscreenFontPercent, 120);
      expect(settings.scrollDurationSec, 0);
      expect(settings.staticDurationSec, 4);
      expect(settings.lineHeightFactor, 1.6);
      expect(settings.fontWeightValue, 400);
      expect(settings.fontWeight, FontWeight.w400);
      expect(settings.strokeWidth, 0);
      expect(settings.displayAreaPercent, 0);
      // 百分比参与实际字号；全屏另用全屏百分比。
      expect(const DanmakuSettings(fontPercent: 150).fontSize, 24);
      expect(settings.fontSizeFor(fullscreen: false), 16);
      expect(settings.fontSizeFor(fullscreen: true), 19.2);
    });

    test('new field values are clamped to their ranges', () {
      final settings = const DanmakuSettings().copyWith(
        fontPercent: 999,
        fullscreenFontPercent: 1,
        scrollDurationSec: 1,
        staticDurationSec: 99,
        lineHeightFactor: 0.5,
        fontWeightValue: 450,
        strokeWidth: 1.3,
        displayAreaPercent: 5,
      );
      expect(settings.fontPercent, 200);
      expect(settings.fullscreenFontPercent, 50);
      expect(settings.scrollDurationSec, 3);
      expect(settings.staticDurationSec, 10);
      expect(settings.lineHeightFactor, 1.0);
      expect(settings.fontWeightValue, 500);
      expect(settings.strokeWidth, 1.5);
      expect(settings.displayAreaPercent, 10);
      // 0 是「沿用默认/自动」的哨兵，不能被钳成下限。
      expect(
        const DanmakuSettings().copyWith(scrollDurationSec: 0)
            .scrollDurationSec,
        0,
      );
      expect(
        const DanmakuSettings().copyWith(displayAreaPercent: 0)
            .displayAreaPercent,
        0,
      );
    });

    test('tier lookups map to the official enum values', () {
      expect(const DanmakuSettings(speedTier: 1).speed, 0.5);
      expect(const DanmakuSettings(speedTier: 2).speed, 0.7);
      expect(const DanmakuSettings(speedTier: 4).speed, 1.25);
      expect(const DanmakuSettings(speedTier: 5).speed, 1.5);
      expect(const DanmakuSettings(sizeTier: 1).fontSize, 12);
      expect(const DanmakuSettings(sizeTier: 5).fontSize, 20);
    });
  });

  testWidgets('new fields survive a save/load round trip', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // 旧存档（只有老键）读出来新字段全回默认值。
    await DanmakuSettings.save(const DanmakuSettings(alpha: 128));
    final legacy = await DanmakuSettings.load();
    expect(legacy.alpha, 128);
    expect(legacy.fontPercent, 100);
    expect(legacy.fullscreenFontPercent, 120);
    expect(legacy.scrollDurationSec, 0);
    expect(legacy.staticDurationSec, 4);
    expect(legacy.lineHeightFactor, 1.6);
    expect(legacy.fontWeightValue, 400);
    expect(legacy.strokeWidth, 0);
    expect(legacy.displayAreaPercent, 0);

    const changed = DanmakuSettings(
      fontPercent: 150,
      fullscreenFontPercent: 200,
      scrollDurationSec: 8,
      staticDurationSec: 6,
      lineHeightFactor: 2,
      fontWeightValue: 700,
      strokeWidth: 1.5,
      displayAreaPercent: 50,
    );
    await DanmakuSettings.save(changed);
    final restored = await DanmakuSettings.load();
    expect(restored.fontPercent, 150);
    expect(restored.fullscreenFontPercent, 200);
    expect(restored.scrollDurationSec, 8);
    expect(restored.staticDurationSec, 6);
    expect(restored.lineHeightFactor, 2);
    expect(restored.fontWeightValue, 700);
    expect(restored.strokeWidth, 1.5);
    expect(restored.displayAreaPercent, 50);
    expect(restored.fontSize, 24);
  });

  testWidgets('the panel reports slider changes live', (tester) async {
    final changes = <DanmakuSettings>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayletDanmakuSettingsPanel(
            settings: const DanmakuSettings(),
            landscape: false,
            onChanged: changes.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('适中'), findsWidgets);
    expect(find.text('4行'), findsOneWidget);
    expect(find.text('100%'), findsWidgets);

    // 显示区域滑杆（第 3 行）点轨道最左端：值 0 → 1 行。
    final region = tester.getRect(find.byType(Slider).at(2));
    await tester.tapAt(Offset(region.left + 2, region.center.dy));
    await tester.pump();
    expect(changes, isNotEmpty);
    expect(changes.last.lineCount, 1);
    await tester.pumpAndSettle();
    expect(find.text('1行'), findsOneWidget);
  });

  testWidgets('reset restores the official defaults', (tester) async {
    final changes = <DanmakuSettings>[];
    var resets = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayletDanmakuSettingsPanel(
            settings: const DanmakuSettings(alpha: 100, sizeTier: 5),
            landscape: false,
            onChanged: changes.add,
            onReset: () => resets++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('大'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('danmaku-settings-reset')));
    await tester.pump();
    expect(resets, 1);
    expect(changes.last, const DanmakuSettings());
    await tester.pumpAndSettle();
    // 复位后 alpha 回 255（100%）、速度回「适中」。
    expect(find.text('39%'), findsNothing);
    expect(find.text('100%'), findsWidgets);
    expect(find.text('适中'), findsWidgets);
  });

  testWidgets('the transparent background switch reports and persists', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final changes = <DanmakuSettings>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayletDanmakuSettingsPanel(
            settings: const DanmakuSettings(),
            landscape: false,
            onChanged: changes.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Switch switch_() => tester.widget<Switch>(
      find.byKey(const ValueKey('danmaku-settings-transparent')),
    );
    expect(switch_().value, isFalse);

    // 整行可点（与更多面板的开关行同一语义），不只认开关本身。
    await tester.tap(
      find.byKey(const ValueKey('danmaku-settings-transparent-row')),
    );
    await tester.pumpAndSettle();
    expect(changes.last.transparentBackground, isTrue);
    expect(switch_().value, isTrue);

    // 落盘后能读回：键在官方 danmaku_config 下，重置回默认时同时被写回。
    await DanmakuSettings.save(changes.last);
    expect((await DanmakuSettings.load()).transparentBackground, isTrue);
    await DanmakuSettings.save(const DanmakuSettings());
    expect((await DanmakuSettings.load()).transparentBackground, isFalse);
  });

  testWidgets('the landscape panel has no sheet handle', (tester) async {
    // 横屏是右侧全高面板（与选集抽屉同宽），拖拽手柄只属于底部 sheet。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayletDanmakuSettingsPanel(
            settings: const DanmakuSettings(),
            landscape: true,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('danmaku-settings-drag-handle')),
      findsNothing,
    );
    // 换成和选集抽屉同款的标题行（居中标题 + 左侧 ✕）。
    expect(find.text('弹幕设置'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-side-panel-close')),
      findsOneWidget,
    );
    // 横屏的「显示区域」按屏高密度换算。
    expect(find.text('1/4屏'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('danmaku-settings-transparent')),
      findsOneWidget,
    );
  });
}
