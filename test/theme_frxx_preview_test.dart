import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/home/home_design.dart';

/// 凡人修仙传主题预览图：测试渲染出 PNG，不构建整包。
///
/// 一张图里同时放浅色与深色两段，三路颜色都看得见：
/// 浅色段（雾气底 #EAF2F8）：金主按钮、绿色灵气标签、天蓝图标——对应
/// 参考图②韩立（蓝天+绿灵气+金字）与图③剑修页（浅蓝白雾气底+蓝色图标）；
/// 深色段（深蓝紫底 #1E1D38）：亮金主按钮、绿灵气标签——对应参考图①
/// 游戏主界面（深蓝底+金字金光）。墨水屏逻辑不动，不在此图里。
///
/// 测试环境默认字体没有中文会出方框，这里先把系统里的
/// Noto Sans CJK SC 载进来当主题字体，字才能正常显示。
Future<void> _capture(
  WidgetTester tester,
  ValueKey<String> boundaryKey,
  String name,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(boundaryKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('previews/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

/// 一段主题色板：标题、主按钮（金）、灵气标签（绿）、天蓝图标行、进度条。
Widget _section({
  required ThemeData theme,
  required String label,
  required String title,
  required String body,
}) {
  final scheme = theme.colorScheme;
  return Theme(
    data: theme,
    child: Builder(
      builder: (context) {
        return Material(
          color: theme.scaffoldBackgroundColor,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.secondary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                body,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton(
                    onPressed: () {},
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                    ),
                    child: const Text('开始观看'),
                  ),
                  const SizedBox(width: 8),
                  Chip(
                    label: const Text('灵气'),
                    backgroundColor: scheme.secondaryContainer,
                    labelStyle: TextStyle(
                      color: scheme.onSecondaryContainer,
                      fontSize: 12,
                    ),
                    side: BorderSide.none,
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.play_circle_fill, color: scheme.tertiary, size: 28),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: 0.65,
                  minHeight: 6,
                  backgroundColor: scheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: scheme.outlineVariant, width: 0.6),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 48,
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(
                        Icons.auto_stories,
                        color: scheme.onPrimaryContainer,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '重生之我在都市修仙',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '张三 · 共 8 集',
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.check_circle,
                      color: HomePalette.accent,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        );
      },
    ),
  );
}

/// AppTheme 再叠加测试字体：AppTheme 本身不带 fontFamily，段落里
/// Theme(data: ...) 会盖掉 MaterialApp 的字体，这里补上，否则中文是方框。
ThemeData _themedWithFont(Brightness brightness) {
  final base = AppTheme.createTheme(brightness);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'NotoSansCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'NotoSansCJK'),
  );
}

void main() {
  testWidgets('预览：凡人修仙传主题（浅色+深色）', (tester) async {
    // 载入系统里的 Noto Sans CJK SC（简体中文），否则中文全是方框。
    final regularBytes = File(
      '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    ).readAsBytesSync();
    final boldBytes = File(
      '/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc',
    ).readAsBytesSync();
    final loader = FontLoader('NotoSansCJK')
      ..addFont(Future.value(ByteData.view(regularBytes.buffer)));
    await loader.load();
    final boldLoader = FontLoader('NotoSansCJK')
      ..addFont(Future.value(ByteData.view(boldBytes.buffer)));
    await boldLoader.load();

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 1100);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'NotoSansCJK'),
        home: RepaintBoundary(
          key: const ValueKey<String>('theme-frxx-preview'),
          child: Column(
            children: [
              Expanded(
                child: _section(
                  theme: _themedWithFont(Brightness.light),
                  label: '浅色 · 雾气底',
                  title: '凡人修仙观影传',
                  body: '浅蓝白雾气底，金主按钮、绿色灵气标签、天蓝图标。',
                ),
              ),
              Expanded(
                child: _section(
                  theme: _themedWithFont(Brightness.dark),
                  label: '深色 · 深蓝紫底',
                  title: '凡人修仙观影传',
                  body: '深蓝紫底，亮金主按钮、绿色灵气标签、天蓝图标。',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 两段标题都在，说明浅色与深色都渲染出来了。
    expect(find.text('凡人修仙观影传'), findsNWidgets(2));
    expect(find.text('浅色 · 雾气底'), findsOneWidget);
    expect(find.text('深色 · 深蓝紫底'), findsOneWidget);
    expect(find.text('开始观看'), findsNWidgets(2));
    expect(find.text('灵气'), findsNWidgets(2));

    await _capture(tester, const ValueKey<String>('theme-frxx-preview'), 'theme_frxx');
  });
}
