import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/category_front.dart';
import 'package:fqapp/pages/category_page.dart';

import 'preview_test_support.dart';

/// 分类页（阅读分支）霓虹深色主题预览图：测试渲染出 PNG，不构建整包。
///
/// 2026-11-24 用户截图 2 的问题：分类页在浅色系统主题下跟随
/// HomePalette 走浅色（#EAF2F8 底、#ECECEC chip、#969696 灰字），与
/// App 深紫蓝霓虹主题脱节。改后非墨水屏一律走霓虹深底——这里特意用
/// 默认浅色 MaterialApp 泵页，验的就是浅色主题下也出深色霓虹页。
void main() {
  testWidgets('预览：分类页阅读分支（霓虹深色）', (tester) async {
    await loadPreviewFonts(tester, lucide: true);
    SharedPreferences.setMockInitialValues({});

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    final front = CategoryFront.fromPayload({
      'code': 0,
      'data': {
        'rule': {
          'tab': [
            {'name': '出版', 'value': '4'},
            {'name': '男生', 'value': '1'},
            {'name': '女生', 'value': '2'},
            {'name': '有声书', 'value': '3'},
            {'name': '短剧', 'value': '5'},
          ],
          'dim': [
            {'name': '全部', 'value': '0'},
            {'name': '主题', 'value': '1048576'},
            {'name': '角色', 'value': '3145728'},
            {'name': '情节', 'value': '4194304'},
          ],
        },
        'down_category': [
          {'name': '都市', 'dim': '1048576', 'id': '1', 'tag': 1},
          {'name': '玄幻', 'dim': '1048576', 'id': '2'},
          {'name': '女帝', 'dim': '3145728', 'id': '3'},
          {'name': '穿越', 'dim': '4194304', 'id': '4'},
          {'name': '系统', 'dim': '1048576', 'id': '5'},
          {'name': '重生', 'dim': '4194304', 'id': '6'},
        ],
      },
    });

    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('category_dark_preview'),
        child: MaterialApp(
          // 特意不指定深色主题：默认浅色主题下也要出霓虹深底。
          theme: ThemeData(fontFamily: 'NotoSansCJK'),
          home: CategoryPage(loader: ({int tab = 1}) async => front),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 顶栏、左栏、分组、chip 都在屏上。
    expect(find.text('男生'), findsOneWidget);
    expect(find.text('热门标签'), findsWidgets);
    expect(find.byKey(const ValueKey('category_tile_1_都市')), findsWidgets);

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('category_dark_preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('previews/category_page_dark.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  });
}
