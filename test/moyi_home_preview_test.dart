@Timeout(Duration(minutes: 30))
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';

import 'preview_test_support.dart';

/// 魔蚁式首页的真机预览：用假数据 pump 真的 [HomePage]（品牌行 +
/// 大轮播 + 热播推荐 / 猜你想看两段），字体走共享支撑
/// （preview_test_support.dart：思源宋体 CJK + MaterialIcons +
/// Lucide，runAsync 里做真 IO）后渲染成真 PNG
/// （test/goldens/moyi_home_preview.png，再拷到
/// ~/workspace/moyi_style_preview/home.png）。
///
/// 只在有中文字体的机器上跑：字体文件不在就跳过，不让这张图拖垮
/// 没有字体的环境。封面全空（不联网），卡片走几何占位封面。
///
/// 超时放宽到 30 分钟：本机编整个 App 的测试 dill 就要十来分钟，
/// 默认 10 分钟超时会在首跑编译时就掐掉测试。
void main() {
  testWidgets('moyi style home preview', (tester) async {
    const regular =
        '/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc';
    const bold = '/usr/share/fonts/opentype/noto/NotoSerifCJK-Bold.ttc';
    // 同步查存在：旧写法用 await File().exists()，真 IO 落在
    // FakeAsync 区里等不到回包，测试直接挂死到 10 分钟超时。
    if (!File(regular).existsSync() || !File(bold).existsSync()) {
      markTestSkipped('本机没有 NotoSerifCJK 字体，跳过预览图渲染');
      return;
    }
    // 字体走共享支撑（runAsync 里做真 IO）：旧写法三处全是本机
    // 写死路径（/home/hatch/flutter/.../MaterialIcons-Regular.otf、
    // /home/hatch/.pub-cache/.../flutter_lucide-1.59.0/...），CI 机
    // 上不存在；且直接 await FontLoader.load() 在 FakeAsync 区里
    // 挂死，是 CI 上 10 分钟超时的根因。
    await loadPreviewFonts(tester, serif: true, lucide: true);
    // ignore: avoid_print
    print('MOYI_PREVIEW fonts loaded');

    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    MediaItem book(String id, String title, List<String> categories) =>
        MediaItem(
          id: id,
          title: title,
          cover: '',
          author: '',
          badge: '',
          ep: '',
          kind: 'book',
          categories: categories,
        );
    final items = [
      book('b1', '一念星沉，钟总暗恋我十年', ['爱情', '都市爱情']),
      book('b2', '万籁渐有声第二季', ['爱情', '都市爱情']),
      book('b3', '一把杀猪刀，供出女状元', ['家庭', '家庭温情']),
      book('b4', '一根暖气管温暖一栋楼', ['剧情', '都市']),
      book('b5', '一缸靛蓝，逆风翻盘', ['剧情', '逆袭']),
      book('b6', '0号觉醒', ['脑洞', '系统']),
      book('b7', '一条裙子掀家庭风波', ['剧情', '逆袭']),
      book('b8', '一刀昭雪', ['剧情', '重生']),
      book('b9', '不就是一碗泡面', ['剧情', '逆袭']),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              homepageLoader:
                  ({
                    int tabType = 2,
                    int offset = 0,
                    String? sessionId,
                  }) async => HomepagePage(
                    items: items,
                    nextOffset: null,
                    sessionId: null,
                  ),
              searchLoader: (query, {int page = 1}) async => const [],
            ),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            // 与 loadPreviewFonts(serif: true) 载入的字体族同名
            // （旧写法把同一批字载成 'PreviewFont'）。
            fontFamily: 'NotoSerifCJK',
            brightness: Brightness.dark,
          ),
          home: const HomePage(),
        ),
      ),
    );
    // 骨架/入场动画都是一次性的，不用 pumpAndSettle 等到天荒地老；
    // 轮播 5 秒定时器在 fake async 里要到 5 秒才翻页，1.5 秒内不会动。
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    // ignore: avoid_print
    print('MOYI_PREVIEW pumped');

    expect(find.text('凡人修仙观影传'), findsOneWidget);
    expect(find.text('热播推荐'), findsOneWidget);
    // 「猜你想看」在两段网格后半段：844 高画布下它在首屏外，
    // CustomScrollView 懒加载还没建出，直接断言必是 0 个；
    // 先滚进视口再断言，断言完滚回顶部再比金图。
    // scrollable 必须显式指 CustomScrollView：页里不止一个
    // Scrollable（轮播 PageView 也是），默认 find.byType(Scrollable)
    // 会因「太多元素」炸掉。
    await tester.scrollUntilVisible(
      find.text('猜你想看'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('猜你想看'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('凡人修仙观影传'),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    // 轮播 PageView 会同时建出相邻两页，「马上看」出现 2 次，只断存在。
    expect(find.text('马上看'), findsWidgets);
    await expectLater(
      find.byType(HomePage),
      matchesGoldenFile('goldens/moyi_home_preview.png'),
    );
  });
}
