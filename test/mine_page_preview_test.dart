import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'preview_test_support.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/cultivation_titles_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/widgets/mine/cultivation_profile_card.dart';

/// 我的页预览图：测试渲染出 PNG，不构建整包。
///
/// 渲染深色「道友档案」卡（横向宽卡：左边信息 + 右边精修人物大图，
/// 境界徽章 + 境界大字 + 等级 + 观影时长/看过多少部 + 主修/境界行 +
/// 金色进度条 + 总修为/到下一境界 + 药丸标签 + 当前称号），
/// 数据用修为服务真实落盘的一份档案（结丹期 中期、Lv.59）。
/// 人物是资源图（按性别切换，白发女修/蓝金男修），不是手画小人。
///
/// 测试环境默认字体没有中文会出方框，这里先把系统里的
/// Noto Sans CJK SC 载进来当主题字体，字才能正常显示。
Future<void> _loadCjkFonts(WidgetTester tester) async {
  // 字体走共享支撑拿可移植路径（见 preview_test_support.dart）：
  // 此前写死的 /home/hatch/flutter/... 与 pub-cache 绝对路径在 CI 机上
  // 不存在，一跑就报 PathNotFoundException。
  await loadPreviewFonts(tester);
}


/// 建一份档案：黄枫谷、天道、青色道袍；小说 20 分钟、漫画 10 分钟、
/// 听书 5 分钟、影视 10 分钟、短剧 2 集，共 1950 修为（结丹期 中期）。
Future<void> _seedProfile(CultivationGender gender) async {
  SharedPreferences.setMockInitialValues({});
  final service = CultivationService.instance;
  await service.resetForTest();
  await service.ensureInitialized();
  await service.createProfile(
    gender: gender,
    sect: '黄枫谷',
    profession: '天道',
    costumeId: 'qing',
  );
  await service.addSeconds(CultivationCategory.novel, 1200);
  await service.addSeconds(CultivationCategory.comic, 600);
  await service.addSeconds(CultivationCategory.audio, 300);
  await service.addSeconds(CultivationCategory.video, 600);
  await service.addDramaEpisodeCompleted();
  await service.addDramaEpisodeCompleted();
  expect(service.totalXp, 1950);
  expect(service.snapshot.realm.displayName, '结丹期 中期');
  expect(service.snapshot.level, 59);
}

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

void main() {
  testWidgets('预览：我的页道友档案卡', (tester) async {
    await _loadCjkFonts(tester);

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    // 档案：男、黄枫谷、天道、青色道袍；小说 20 分钟、漫画 10 分钟、
    // 听书 5 分钟、影视 10 分钟、短剧 2 集，共 1950 修为（结丹期 中期）。
    await _seedProfile(CultivationGender.male);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'NotoSansCJK'),
        home: RepaintBoundary(
          key: const ValueKey<String>('mine-preview'),
          child: Scaffold(
            backgroundColor: const Color(0xFF0F0F14),
            body: SingleChildScrollView(
              child: CultivationProfileCard(
                totalTitles: 12,
                onOpenTitles: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('◆ 道友档案 ◆'), findsOneWidget);
    expect(find.text('道友档案'), findsOneWidget);
    expect(find.text('结丹期 中期'), findsOneWidget);
    expect(find.text('Lv.59'), findsOneWidget);
    expect(find.textContaining('1950'), findsWidgets);

    // 等人物图解码完成再截图，不然右边是空白。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pump();

    await _capture(
      tester,
      const ValueKey<String>('mine-preview'),
      'mine_page_cultivation',
    );
  });

  testWidgets('预览：我的页道友档案卡（女）', (tester) async {
    await _loadCjkFonts(tester);

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    // 女性档案：女、黄枫谷、天道、青色道袍；同样的 1950 修为 /
    // 结丹期 中期 / Lv.59。右边人物图按性别切到白发女修。
    await _seedProfile(CultivationGender.female);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'NotoSansCJK'),
        home: RepaintBoundary(
          key: const ValueKey<String>('mine-preview-female'),
          child: Scaffold(
            backgroundColor: const Color(0xFF0F0F14),
            body: SingleChildScrollView(
              child: CultivationProfileCard(
                totalTitles: 12,
                onOpenTitles: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('◆ 道友档案 ◆'), findsOneWidget);
    expect(find.text('道友档案'), findsOneWidget);
    expect(find.text('结丹期 中期'), findsOneWidget);
    expect(find.text('Lv.59'), findsOneWidget);
    expect(find.text('性别·女'), findsOneWidget);
    expect(find.textContaining('1950'), findsWidgets);

    // 等人物图解码完成再截图，不然右边是空白。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pump();

    await _capture(
      tester,
      const ValueKey<String>('mine-preview-female'),
      'mine_page_cultivation_female',
    );
  });

  // 顺带确认排行榜页能正常实例化（入口在卡上）。
  test('排行榜页可构造', () {
    expect(const CultivationTitlesPage(), isNotNull);
  });
}
