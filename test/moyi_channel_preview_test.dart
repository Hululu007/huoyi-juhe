import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'preview_test_support.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/category_page.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/unified_video_categories.dart';
import 'package:fqapp/services/video_category_tags.dart';

/// 魔蚁风频道分类页预览图：测试渲染出真 PNG，不构建整包。
///
/// 按图 1/图 2 拍：顶部「频道分类」大标题 + 搜索/奖杯圆钮、筛选行
/// （全部类型/热门/最新/完结）、左栏本站真实内容分类、右侧 2 列大卡
/// （左高右矮、HD/NEW 角标、底部标题 + 分类小字）、深紫蓝渐变底。
/// 底部导航是应用壳的七项（游戏/首页/短剧/影视/直播/书架/我的），
/// 本页不动它，预览里只占位标出位置。
///
/// 测试环境默认字体没有中文会出方框，这里把系统里的
/// Noto Serif CJK SC 与 Lucide 图标字体载进来当主题字体。
Future<void> _loadFonts(WidgetTester tester) async {
  // 字体走共享支撑拿可移植路径（见 preview_test_support.dart）：
  // 此前写死的 /home/hatch/flutter/... 与 pub-cache 绝对路径在 CI 机上
  // 不存在，一跑就报 PathNotFoundException。
  await loadPreviewFonts(tester, serif: true, lucide: true);
}


Future<void> _capture(
  WidgetTester tester,
  ValueKey<String> boundaryKey,
  String path,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(boundaryKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

UnifiedVideoCategories _previewUnified() => parseUnifiedVideoCategories('''
{
  "version": 1,
  "site_count": 5,
  "total_site_count": 5,
  "sites_without_categories": [],
  "categories": {
    "漫剧": [
      {"siteId": "a", "path": "/cat/mj"},
      {"siteId": "b", "path": "/cat/mj"},
      {"siteId": "c", "path": "/cat/mj"},
      {"siteId": "d", "path": "/cat/mj"},
      {"siteId": "e", "path": "/cat/mj"}
    ],
    "AI剧": [
      {"siteId": "a", "path": "/cat/ai"},
      {"siteId": "b", "path": "/cat/ai"}
    ],
    "小说": [
      {"siteId": "a", "path": "/cat/novel"},
      {"siteId": "b", "path": "/cat/novel"}
    ],
    "听书": [{"siteId": "a", "path": "/cat/audio"}],
    "冒险": [{"siteId": "a", "path": "/cat/adv"}],
    "剧情": [{"siteId": "a", "path": "/cat/drama"}],
    "古装": [{"siteId": "a", "path": "/cat/costume"}],
    "奇幻": [{"siteId": "a", "path": "/cat/fantasy"}],
    "宫廷": [{"siteId": "a", "path": "/cat/court"}],
    "家庭": [{"siteId": "a", "path": "/cat/family"}],
    "家族": [{"siteId": "a", "path": "/cat/clan"}],
    "年代": [{"siteId": "a", "path": "/cat/era"}],
    "总裁": [{"siteId": "a", "path": "/cat/ceo"}],
    "恋爱": [{"siteId": "a", "path": "/cat/love"}],
    "悬疑": [{"siteId": "a", "path": "/cat/mystery"}],
    "推荐": [{"siteId": "a", "path": "/cat/rec"}]
  },
  "tags": {
    "都市爱情": [{"siteId": "a", "url": "/tag/love", "browsable": true}]
  }
}
''');

void main() {
  testWidgets('预览：魔蚁风频道分类页', (tester) async {
    await _loadFonts(tester);
    SharedPreferences.setMockInitialValues({});

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: 'NotoSerifCJK',
          brightness: Brightness.dark,
        ),
        home: RepaintBoundary(
          key: const ValueKey<String>('moyi-channel-preview'),
          child: Scaffold(
            backgroundColor: const Color(0xFF1E1445),
            body: CategoryPage(
              videoSiteId: 'a',
              openVideoTab: true,
              videoLoader: _fakeSingle,
              unifiedLoader: () async => _previewUnified(),
              unifiedClientForSite: (_) => _PreviewClient(),
            ),
            bottomNavigationBar: BottomNavigationBar(
              type: BottomNavigationBarType.fixed,
              currentIndex: 3,
              backgroundColor: const Color(0xFF241A4D),
              selectedItemColor: const Color(0xFFF061FF),
              unselectedItemColor: Colors.white54,
              selectedFontSize: 11,
              unselectedFontSize: 11,
              onTap: (_) {},
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.videogame_asset),
                  label: '游戏',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.home),
                  label: '首页',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.movie),
                  label: '短剧',
                ),
                BottomNavigationBarItem(icon: Icon(Icons.tv), label: '影视'),
                BottomNavigationBarItem(
                  icon: Icon(Icons.live_tv),
                  label: '直播',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.bookmark),
                  label: '书架',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.person),
                  label: '我的',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('频道分类'), findsOneWidget);
    expect(find.byKey(const ValueKey('moyi_left_漫剧')), findsOneWidget);
    expect(find.text('0号觉醒'), findsOneWidget);
    expect(find.text('NEW'), findsOneWidget);
    expect(find.text('HD'), findsOneWidget);
    expect(find.text('影视'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _capture(
      tester,
      const ValueKey<String>('moyi-channel-preview'),
      previewOutPath('channel.png'),
    );
  });
}

Future<VideoCategoryData> _fakeSingle(String siteId) async =>
    const VideoCategoryData(
      siteId: 'a',
      siteName: '测试站',
      hotTags: ['本站热'],
      themes: [],
      roles: [],
      plots: [],
    );

class _PreviewClient extends DramaSiteContentClient {
  @override
  Future<List<DramaSiteCategory>> categories() async =>
      const [DramaSiteCategory('all', '全部')];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    return const DramaSiteCatalogPage(
      items: [
        DramaSiteItem(
          id: 'v1',
          title: '0号觉醒',
          cover: '',
          remark: '2026-11-09',
        ),
        DramaSiteItem(
          id: 'v2',
          title: '一念星沉，钟总暗恋我十年',
          cover: '',
          remark: '高清',
        ),
        DramaSiteItem(
          id: 'v3',
          title: '一把杀猪刀，供出女状元',
          cover: '',
          remark: '完结',
        ),
        DramaSiteItem(
          id: 'v4',
          title: '一条裙子掀家庭风波',
          cover: '',
          remark: '更新至12集',
        ),
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
