@Timeout(Duration(minutes: 30))
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';

/// 魔蚁式首页的真机预览：用假数据 pump 真的 [HomePage]（品牌行 +
/// 大轮播 + 热播推荐 / 猜你想看两段），FontLoader 加载本机思源宋体 CJK
/// 后渲染成真 PNG（test/goldens/moyi_home_preview.png，再拷到
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
    if (!await File(regular).exists() || !await File(bold).exists()) {
      markTestSkipped('本机没有 NotoSerifCJK 字体，跳过预览图渲染');
      return;
    }
    final loader = FontLoader('PreviewFont');
    for (final path in [regular, bold]) {
      loader.addFont(
        File(path).readAsBytes().then((bytes) => ByteData.view(bytes.buffer)),
      );
    }
    await loader.load();
    // ignore: avoid_print
    print('MOYI_PREVIEW preview font loaded');
    // 图标字体：不载入则顶栏搜索/刷新与轮播「马上看」播放图标变方框
    //（频道分类预览同款做法）。
    final iconBytes = File(
      '/home/hatch/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).readAsBytesSync();
    final iconLoader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.view(iconBytes.buffer)));
    await iconLoader.load();
    // ignore: avoid_print
    print('MOYI_PREVIEW material icons loaded');
    final lucideBytes = File(
      '/home/hatch/.pub-cache/hosted/pub.dev/flutter_lucide-1.59.0/lib/fonts/lucide.ttf',
    ).readAsBytesSync();
    final lucideLoader = FontLoader('packages/flutter_lucide/lucide')
      ..addFont(Future.value(ByteData.view(lucideBytes.buffer)));
    await lucideLoader.load();
    // ignore: avoid_print
    print('MOYI_PREVIEW lucide loaded');
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
            fontFamily: 'PreviewFont',
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
    expect(find.text('猜你想看'), findsOneWidget);
    expect(find.text('马上看'), findsOneWidget);
    await expectLater(
      find.byType(HomePage),
      matchesGoldenFile('goldens/moyi_home_preview.png'),
    );
  });
}
