// 播放页布局入口迁移（2026-11-27 播放器内嵌批）：设置页「外观」
// 里的「播放页布局」行已按用户令摘除，改从播放器 ⋮ 菜单进入；
// 偏好本体（PlayerLayoutPreferences）不动、存量值不丢。本文件
// 改验：①设置页外观里不再有这一行；②偏好往返仍完整（菜单侧
// 读写的是同一份）。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/player_layout_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlayerLayoutPreferences.mode.value = PlayerLayoutMode.immersive;
    themeModeNotifier.value = ThemeMode.light;
  });

  tearDown(() {
    PlayerLayoutPreferences.mode.value = PlayerLayoutMode.immersive;
    themeModeNotifier.value = ThemeMode.system;
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> mountSettings(
    WidgetTester tester, {
    Size window = const Size(430, 900),
  }) async {
    await tester.binding.setSurfaceSize(window);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: const SettingsPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('设置页外观里不再有播放页布局行（已迁入播放器菜单）', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await mountSettings(tester);
      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();
      expect(find.text('播放页布局'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('桌面设置台同样不再有播放页布局行', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await mountSettings(tester, window: const Size(1280, 800));
      expect(find.text('主题模式'), findsOneWidget);
      expect(find.text('播放页布局'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('偏好往返不丢：save 写键、decode 读回同一值（菜单侧共用）', () async {
    await PlayerLayoutPreferences.save(PlayerLayoutMode.split);
    final sp = await SharedPreferences.getInstance();
    expect(sp.getString(PlayerLayoutPreferences.key), 'split');
    expect(
      PlayerLayoutPreferences.decode(
        sp.getString(PlayerLayoutPreferences.key),
      ),
      PlayerLayoutMode.split,
    );
  });
}
