import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_test_support.dart';
import 'package:fqapp/pages/game_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/game_service.dart';

/// 游戏页删主页 hub 后的首屏预览图：测试渲染出 PNG，不构建整包。
///
/// 打开游戏页直接在战场（顶栏 + BOSS 血条 + 技能栏都在，
/// 没有「进入战斗」钮与主页立绘）。战场带动画与图片解码，
/// pumpAndSettle 会超时，改用 pump 推进 + runAsync 真等待
/// 图片解码后再抓图。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('预览：游戏页打开直达战场首屏', (tester) async {
    await loadPreviewFonts(tester, lucide: true);

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({});
    await CultivationService.instance.resetForTest();
    await GameService.instance.resetForTest();
    await GameService.instance.ensureInitialized();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'NotoSansCJK'),
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey<String>('game-battle-preview'),
            child: GamePage(
              active: false,
              onExit: () {},
              onOpenFilmTab: () {},
              onOpenDramaTab: () {},
              onSwitchToVideo: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    // 真等待：背景图 / 立绘图走真实异步解码，FakeAsync 里
    // pump 等不到，runAsync 里睡一会儿再 pump 才入画。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    // 开局即战场：没有主页 hub 的任何元素。
    expect(find.text('进入战斗'), findsNothing);
    expect(find.text('主页'), findsNothing);
    expect(find.text('紫电魔蚁 · BOSS'), findsOneWidget);
    expect(find.text('剑影分光'), findsOneWidget);

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey<String>('game-battle-preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          '/home/hatch/workspace/xiuxian_game_hub_del_20261127/'
          'preview_after_delete.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });

    // 收尾：换页 + 推 3 秒假时间清掉没法取消的 Future.delayed；
    // 再 reset 服务层，停掉 GameService 的 5 秒周期定时器
    // （不然测试结束时报 Pending timers）。
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    await tester.pump(const Duration(seconds: 3));
    await GameService.instance.resetForTest();
    await CultivationService.instance.resetForTest();
  });
}
