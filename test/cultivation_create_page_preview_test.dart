import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/cultivation_create_page.dart';
import 'package:fqapp/services/cultivation.dart';

/// 首次安装全屏创建人物界面预览图：测试渲染出 PNG，不构建整包。
///
/// 按凡人修仙传网页游戏选职业界面 charsel_1 定版：顶部职业三卡
/// （带小立绘头像）+ 中央站立大人物（发光台 + 身后大圆环）+
/// 职业名/招牌技能/介绍 + 男女切换 + 名字输入框（筛盅随机）+
/// 宗门 + 外观定制 + 道友 ID + 「开始修仙」按钮。
/// 女性版按凡人修真 2 宣传图女修气质画（长发、白花、金色长裙、
/// 轻纱袖）。男版默认天道，女版点「女」切换后出图。
///
/// 测试环境默认字体没有中文会出方框，这里先把系统里的
/// Noto Sans CJK SC 载进来当主题字体，字才能正常显示。
/// 站立人物与粒子特效带无限动画，pumpAndSettle 会超时，
/// 改用 pump 推进时长。
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

Future<void> _loadCjkFonts() async {
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
  // 图标字体：不载的话静音/性别/筛盅/刷新图标在测试图里是方框。
  final iconBytes = File(
    '/home/hatch/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ).readAsBytesSync();
  final iconLoader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.view(iconBytes.buffer)));
  await iconLoader.load();
}

Future<void> _pumpCreatePage(WidgetTester tester) async {
  await _loadCjkFonts();

  // 创建页内容比一屏长（职业卡 + 站立大人物 + 性别/名字/宗门/
  // 外观定制 + ID + 开始按钮），用高视口一次拍全，不然 ID/
  // 用户名/开始修仙在折叠线下面拍不到。
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 1500);
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({});
  await CultivationService.instance.resetForTest();

  var created = false;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'NotoSansCJK'),
      home: RepaintBoundary(
        key: const ValueKey<String>('create-preview'),
        child: CultivationCreatePage(
          onCreated: () => created = true,
        ),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));

  expect(find.text('踏入仙途'), findsOneWidget);
  expect(find.text('创建道友档案'), findsOneWidget);
  // 「天道」在职业卡与人物下方职业名处各出现一次。
  expect(find.text('天道'), findsWidgets);
  expect(find.text('逍遥'), findsOneWidget);
  expect(find.text('金刚'), findsOneWidget);
  expect(find.text('青元剑诀'), findsOneWidget);
  expect(find.text('开始修仙'), findsOneWidget);
  expect(find.textContaining('道友 ID'), findsOneWidget);
  expect(find.text('黄枫谷'), findsOneWidget);
  expect(find.text('青色道袍'), findsOneWidget);
  expect(created, isFalse);
}

void main() {
  testWidgets('预览：首次安装全屏创建人物界面（男版·天道）', (tester) async {
    await _pumpCreatePage(tester);

    await _capture(
      tester,
      const ValueKey<String>('create-preview'),
      'cultivation_character_create',
    );
  });

  testWidgets('预览：首次安装全屏创建人物界面（女版·天道）', (tester) async {
    await _pumpCreatePage(tester);

    // 点「女」切到女性版（凡人修真 2 女修气质：长发、白花、金色长裙、
    // 轻纱袖），等人物切过去再出图。
    await tester.tap(find.text('女'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('天道'), findsWidgets);
    expect(find.text('青元剑诀'), findsOneWidget);
    expect(find.text('开始修仙'), findsOneWidget);

    await _capture(
      tester,
      const ValueKey<String>('create-preview'),
      'cultivation_character_create_female',
    );
  });
}
