@Timeout(Duration(minutes: 30))
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';

import 'preview_test_support.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/reading_stats.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/widgets/home/drama_site_grid.dart';
import 'package:fqapp/widgets/home/home_hero.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';
import 'package:fqapp/widgets/home/home_moyi_carousel.dart';
import 'package:fqapp/widgets/home/home_moyi_style.dart';
import 'package:fqapp/widgets/mine/cultivation_profile_card.dart';
import 'package:fqapp/widgets/mine/mine_entries.dart';
import 'package:fqapp/widgets/mine/mine_heatmap.dart';
import 'package:fqapp/widgets/mine/mine_summary.dart';
import 'package:fqapp/widgets/mine/mine_top_books.dart';
import 'package:fqapp/widgets/series_detail/moyi_detail_theme.dart';

/// 五区背景换肤预览图：一次编译、五个测试，各出一张 PNG 到
/// ~/workspace/moyi_style_preview/（home/drama/video/midnight/mine）。
///
/// 做法：每个区都用真实的共享背景 [MoyiPageBackground]（首页/短剧/
/// 影视/午夜/我的五个真实页面包 body 用的就是它，见各页 grep），
/// 再叠各区真实的子组件（首页品牌行 HomeHero + 轮播 MoyiHeroCarousel
/// + 热播/猜你想看段头与 HomeMediaCard；短剧/影视/午夜用真实
/// DramaSiteGrid + 假客户端；我的用真实 CultivationProfileCard +
/// MineSummary/MineHeatmap/MineTopBooks/MineEntries）。
///
/// 不渲染整页 HomePage/DramaPage/VideoPage/MinePage 本体：它们在测试里
/// 要拉 SourceRegistry / homeProvider / LibraryStore 等真异步源，
/// 本机上次跑 HomePage 整页 3 次都挂在测试体执行阶段（isolate 近 0 CPU，
/// 疑似内存不足），这里只验「背景确实换成深紫蓝渐变 + 各区字与卡片
/// 在深底上可读」这一件事。
///
/// 封面全空（不联网），卡片走几何占位封面；字体先载 NotoSerifCJK +
/// MaterialIcons + Lucide，否则中文与图标全是方框。
final String _outDir = previewOutDir().path;

Future<void> _loadFonts(WidgetTester tester) async {
  // 字体走共享支撑拿可移植路径（见 preview_test_support.dart）：
  // 此前写死的 /home/hatch/flutter/... 与 pub-cache 绝对路径在 CI 机上
  // 不存在，一跑就报 PathNotFoundException。
  await loadPreviewFonts(tester, serif: true, lucide: true);
}


/// 成人站角标：粉底白字「18」+ 站名（不用 🔞 emoji，测试环境没有
/// 系统 emoji 字体、NotoSerifCJK 里也没有它，写了就是方框）。
Widget _adultLabel(String name, {double fontSize = 13}) {
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: const Color(0xFFEC4899),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text(
          '18',
          style: TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      const SizedBox(width: 6),
      Text(
        name,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: Colors.white,
          fontSize: fontSize,
        ),
      ),
    ],
  );
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
      final file = File('$_outDir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

/// 假短剧站客户端：分类 1 个、目录按传入标题出卡，详情/播放走空。
class _FakeClient extends DramaSiteContentClient {
  _FakeClient(this.titles);
  final List<String> titles;

  @override
  Future<List<DramaSiteCategory>> categories() async =>
      const [DramaSiteCategory('all', '全部')];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    return DramaSiteCatalogPage(
      items: [
        for (var i = 0; i < titles.length; i++)
          DramaSiteItem(id: 'v$i', title: titles[i], cover: ''),
      ],
      hasMore: false,
    );
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async =>
      const DramaSiteDetail(id: '', title: '', cover: '', episodes: []);

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async =>
      const DramaPlaySource(url: '');
}

MediaItem _film(String id, String title) => MediaItem(
  id: id,
  title: title,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'film',
  categories: const ['剧情'],
);

/// 我的页档案种子（与 mine_page_preview_test.dart 同款）：
/// 男、黄枫谷、天道、青色道袍；小说 20 分钟、漫画 10 分钟、
/// 听书 5 分钟、影视 10 分钟、短剧 2 集，共 1950 修为（结丹期 中期）。
Future<void> _seedProfile() async {
  SharedPreferences.setMockInitialValues({});
  final service = CultivationService.instance;
  await service.resetForTest();
  await service.ensureInitialized();
  await service.createProfile(
    gender: CultivationGender.male,
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
}

Widget _zoneShell({
  required String keyName,
  required Widget child,
  double height = 844,
}) {
  return MaterialApp(
    theme: ThemeData(
      fontFamily: 'NotoSerifCJK',
      brightness: Brightness.dark,
    ),
    home: RepaintBoundary(
      key: ValueKey<String>(keyName),
      child: child,
    ),
  );
}

void main() {
  testWidgets('预览：首页换肤（深紫蓝渐变底）', (tester) async {
    await _loadFonts(tester);
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 1150);
    addTearDown(tester.view.reset);

    final items = [
      _film('h1', '一念星沉，钟总暗恋我十年'),
      _film('h2', '万籁渐有声第二季'),
      _film('h3', '一把杀猪刀，供出女状元'),
      _film('h4', '一根暖气管温暖一栋楼'),
      _film('h5', '一缸靛蓝，逆风翻盘'),
      _film('h6', '0号觉醒'),
    ];
    // 轮播与品牌行都有 5 秒定时器：只 pump 几帧，不 pumpAndSettle。
    await tester.pumpWidget(
      _zoneShell(
        keyName: 'moyi-zone-home',
        height: 1150,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: MoyiPageBackground(
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  HomeHero(onSearch: () {}),
                  const SizedBox(height: 8),
                  MoyiHeroCarousel(items: items, onOpen: (_) {}),
                  const MoyiSectionHeader(title: '热播推荐'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        for (var i = 0; i < 3; i++)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: HomeMediaCard(
                                item: items[i],
                                onTap: () {},
                                coverWidth: 110,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const MoyiSectionHeader(title: '猜你想看'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        for (var i = 3; i < 6; i++)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: HomeMediaCard(
                                item: items[i],
                                onTap: () {},
                                coverWidth: 110,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('凡人修仙观影传'), findsOneWidget);
    expect(find.text('热播推荐'), findsOneWidget);
    expect(find.text('猜你想看'), findsOneWidget);
    expect(find.text('马上看'), findsWidgets);
    await _capture(tester, const ValueKey<String>('moyi-zone-home'), 'home');
  });

  testWidgets('预览：短剧区换肤（深紫蓝渐变底）', (tester) async {
    await _loadFonts(tester);
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 620);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _zoneShell(
        keyName: 'moyi-zone-drama',
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('短剧'),
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            foregroundColor: Colors.white,
          ),
          body: MoyiPageBackground(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Row(
                      children: [
                        for (final c in ['推荐', '漫剧', '小说', '听书'])
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: c == '推荐'
                                    ? const Color(0xFF8B5CF6)
                                    : moyiDarkCardFill,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: moyiDarkCardBorder),
                              ),
                              child: Text(
                                c,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                // DramaSiteGrid 本身就是 sliver（返回 SliverGrid），
                // 不能包在 Expanded / SliverToBoxAdapter 里（上一版
                // 三张图就是这么栽的），直接放进 slivers。
                DramaSiteGrid(
                  siteId: 'original', // 番茄短剧（短剧站表里有，卡片下标是「短剧」）
                  categoryId: 'all',
                  gridWidth: 358,
                  client: _FakeClient([
                    '一念星沉，钟总暗恋我十年',
                    '万籁渐有声第二季',
                    '一把杀猪刀，供出女状元',
                    '一根暖气管温暖一栋楼',
                    '一缸靛蓝，逆风翻盘',
                    '0号觉醒',
                  ]),
                  columns: 3,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('短剧'), findsWidgets); // 顶栏标题 + 6 张卡片下标「短剧」
    expect(find.text('一念星沉，钟总暗恋我十年'), findsOneWidget);
    await _capture(tester, const ValueKey<String>('moyi-zone-drama'), 'drama');
  });

  testWidgets('预览：影视区换肤（深紫蓝渐变底）', (tester) async {
    await _loadFonts(tester);
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 660);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _zoneShell(
        keyName: 'moyi-zone-video',
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('影视'),
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            foregroundColor: Colors.white,
            actions: [
              TextButton(
                onPressed: () {},
                child: const Text(
                  '分类',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
          // 与 VideoPage.build 同款结构：午夜区标题 + 站药丸 + 3 列网格。
          body: MoyiPageBackground(
            child: CustomScrollView(
              slivers: [
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      '午夜区',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: moyiDarkCardFill,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: moyiDarkCardBorder),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _adultLabel('91成人短剧', fontSize: 14),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.arrow_drop_down,
                            size: 20,
                            color: moyiMutedOnDark,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // DramaSiteGrid 本身就是 sliver，直接放进 slivers，
                // 不包 SliverToBoxAdapter（上一版三张图就是这么栽的）。
                DramaSiteGrid(
                  siteId: 'fake_video',
                  categoryId: 'all',
                  gridWidth: 390,
                  client: _FakeClient([
                    '测试剧目0',
                    '测试剧目1',
                    '测试剧目2',
                    '测试剧目3',
                    '测试剧目4',
                    '测试剧目5',
                  ]),
                  showFilterBar: false,
                  columns: 3,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('影视'), findsWidgets); // 顶栏标题 + 卡片下标「影视」
    expect(find.text('午夜区'), findsOneWidget);
    expect(find.textContaining('91成人短剧'), findsOneWidget);
    expect(find.text('测试剧目0'), findsOneWidget);
    await _capture(tester, const ValueKey<String>('moyi-zone-video'), 'video');
  });

  testWidgets('预览：午夜区换肤（深紫蓝渐变底）', (tester) async {
    await _loadFonts(tester);
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 1050);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _zoneShell(
        keyName: 'moyi-zone-midnight',
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('午夜区'),
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            foregroundColor: Colors.white,
          ),
          // 午夜分支本体：VideoPage 里「午夜区」标题 + 站切换药丸 +
          // 3 列 DramaSiteGrid（与 video_page.dart:525-600 同款）。
          body: MoyiPageBackground(
            child: CustomScrollView(
              slivers: [
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      '午夜区',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final s in ['91成人短剧', 'MissAV', '鉴黄师'])
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: s == '91成人短剧'
                                  ? const Color(0xFF8B5CF6)
                                  : moyiDarkCardFill,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: moyiDarkCardBorder),
                            ),
                            child: _adultLabel(s),
                          ),
                      ],
                    ),
                  ),
                ),
                // DramaSiteGrid 本身就是 sliver，直接放进 slivers。
                DramaSiteGrid(
                  siteId: 'fake_midnight',
                  categoryId: 'all',
                  gridWidth: 390,
                  client: _FakeClient([
                    '午夜剧目0',
                    '午夜剧目1',
                    '午夜剧目2',
                    '午夜剧目3',
                    '午夜剧目4',
                    '午夜剧目5',
                    '午夜剧目6',
                    '午夜剧目7',
                    '午夜剧目8',
                  ]),
                  showFilterBar: false,
                  columns: 3,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('午夜区'), findsWidgets);
    expect(find.textContaining('91成人短剧'), findsOneWidget);
    expect(find.textContaining('MissAV'), findsOneWidget);
    expect(find.text('午夜剧目0'), findsOneWidget);
    await _capture(
      tester,
      const ValueKey<String>('moyi-zone-midnight'),
      'midnight',
    );
  });

  testWidgets('预览：我的页换肤（深紫蓝渐变底）', (tester) async {
    await _loadFonts(tester);
    await _seedProfile();
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 900);
    addTearDown(tester.view.reset);

    final today = DateUtils.dateOnly(DateTime.now());
    await tester.pumpWidget(
      _zoneShell(
        keyName: 'moyi-zone-mine',
        height: 900,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('我的'),
            centerTitle: false,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            foregroundColor: Colors.white,
            actions: const [
              Icon(LucideIcons.settings, size: 21),
              SizedBox(width: 12),
            ],
          ),
          // 与 MinePage.build 非加载分支同款子组件顺序。
          body: MoyiPageBackground(
            child: ListView(
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              children: [
                CultivationProfileCard(totalTitles: 12, onOpenTitles: () {}),
                MineSummary(stats: ReadingStats.empty, today: today),
                MineHeatmap(stats: ReadingStats.empty, today: today),
                MineTopBooks(rank: const [], onOpen: (_) {}),
                const MineEntries(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    // 等人物图解码完成再截图，不然档案卡右边是空白。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pump();

    expect(find.text('◆ 道友档案 ◆'), findsOneWidget);
    expect(find.text('结丹期 中期'), findsOneWidget);
    expect(find.text('Lv.59'), findsOneWidget);
    await _capture(tester, const ValueKey<String>('moyi-zone-mine'), 'mine');
  });
}
