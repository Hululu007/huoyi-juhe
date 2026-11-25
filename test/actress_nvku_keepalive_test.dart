// 进库不重载测试（2026-11-25，照魔蚁 nvku-keepalive 批移植）。
// - 第二次进库（全新页实例 + 全新假服务/假仓库）不再重查：文件夹、
//   标签、封面、分类、作品第一页全走会话缓存，假服务与假仓库的
//   调用计数不再涨。
// - 手动刷新（顶栏刷新钮）清缓存、重查一遍。
// - 女优 tab 切走再回来不重建：列表页 State 是同一个对象（切走时
//   仍挂在树里，只是藏起来），不再重跑 _bootstrap。
// - 首页/分类共用 _scroll：IndexedStack 下两页同时挂着，_onScroll
//   走 positions 迭代，滚到底不抛错（回归）。
// - 缓存本体单测：指纹、TTL、8 key 上限、clear。
// 不碰真库、不走网络：假影视库服务 + 假仓库 + 内存库。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_database.dart';
import 'package:fqapp/actress/actress_film_library.dart';
import 'package:fqapp/actress/actress_generic_db.dart';
import 'package:fqapp/actress/actress_mytv_bind.dart';
import 'package:fqapp/actress/actress_nvku_cache.dart';
import 'package:fqapp/actress/actress_nvku_page.dart';
import 'package:fqapp/actress/whos_local_library.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'actress_fixtures.dart';

/// 计数假影视库服务：调用次数可查，数据固定。
/// 文件夹 3 个（成人影片 3 部、国产精品 2 部、无码专区 1 部）；
/// 标签 2 个；封面取每类型第一条视频的 pic_url。
class _CountingFilmService extends FilmLibraryService {
  _CountingFilmService({required super.database});

  var openCalls = 0;
  var tagsCalls = 0;
  var foldersCalls = 0;
  var coversCalls = 0;

  var folders = <(String, int)>[
    ('成人影片', 3),
    ('国产精品', 2),
    ('无码专区', 1),
  ];

  var tagList = <(String, int)>[('中文字幕', 3), ('ハイビジョン', 2)];

  final works = <String, List<FilmLibraryEntry>>{
    '成人影片': [
      const FilmLibraryEntry(
        vodId: 'mida-619',
        title: '测试作品一',
        code: 'MIDA-619',
        coverUrl: 'https://example.test/mida619.jpg',
        playUrl: 'https://example.test/mida619.m3u8',
        typeName: '成人影片',
      ),
    ],
    '国产精品': [
      const FilmLibraryEntry(
        vodId: 'guo-001',
        title: '国产测试一',
        code: 'GUO-001',
        coverUrl: 'https://example.test/guo001.jpg',
        playUrl: 'https://example.test/guo001.m3u8',
        typeName: '国产精品',
      ),
    ],
    '无码专区': [
      const FilmLibraryEntry(
        vodId: 'wuma-001',
        title: '无码测试一',
        code: 'WUMA-001',
        playUrl: 'https://example.test/wuma001.m3u8',
        typeName: '无码专区',
      ),
    ],
  };

  @override
  Future<FilmLibraryOpenResult> open() async {
    openCalls++;
    return const FilmLibraryOpenResult(
      dbPath: '/fake/MYTV/db/女优库.db',
      displayPath: 'MYTV/db/女优库.db',
      strict: true,
      total: 6,
      schema: GenericDbSchema(tables: [], fingerprint: 'test'),
      domain: '',
    );
  }

  @override
  Future<({String key, List<(String, int)> values})> tags() async {
    tagsCalls++;
    return (key: 'video_tag.tag_name', values: tagList);
  }

  @override
  Future<List<(String, int)>> typeFolders({
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) async {
    foldersCalls++;
    return folders;
  }

  @override
  Future<Map<String, String>> typeFolderCovers({
    required List<String> typeNames,
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) async {
    coversCalls++;
    final covers = <String, String>{};
    for (final name in typeNames) {
      final first = await listFilms(
        typeName: name,
        videoTag: videoTag,
        category: category,
        genericTagKey: genericTagKey,
        offset: 0,
        limit: 1,
      );
      covers[name] = first.isEmpty ? '' : first.first.coverUrl;
    }
    return covers;
  }

  @override
  Future<List<FilmLibraryEntry>> listFilms({
    String category = '',
    String site = '',
    String actress = '',
    String query = '',
    String typeName = '',
    String videoTag = '',
    String genericTagKey = '',
    int offset = 0,
    int limit = 60,
  }) async {
    final rows = works[typeName] ?? const <FilmLibraryEntry>[];
    return rows.skip(offset).take(limit).toList();
  }
}

/// 计数假仓库：分类调用可查，目录沿用 FixtureRepository（记 requests）。
class _CountingRepository extends FixtureRepository {
  var categoriesCalls = 0;

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    categoriesCalls++;
    return const [
      CatalogCategory('c0', '有码 · 100'),
      CatalogCategory('c1', '无码 · 50'),
    ];
  }
}

ThemeData _testTheme() {
  final base = ThemeData.dark();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
  );
}

/// 真时间沉降：_boot 链里有真异步（本地库 ensureLoaded 等），假时间
/// pump 等不到它——用 runAsync 给真时间 + pump 帧 + 查条件轮询，
/// 直到条件成立或 10 秒用完（AGENTS.md 教训：pumpAndSettle 不等
/// 真异步 Future）。条件不传时只等一轮（给点按后的重建留时间）。
Future<void> _settleReal(
  WidgetTester tester, {
  bool Function()? until,
}) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    if (until != null && until()) return;
    if (until == null && i >= 1) return;
  }
}

void main() {
  group('NvkuEntryCache 本体', () {
    test('dbStamp：不存在的文件回空串', () {
      expect(NvkuEntryCache.dbStamp(''), '');
      expect(
        NvkuEntryCache.dbStamp('/no/such/file/女优库.db'),
        '',
      );
    });

    test('文件夹/标签/分类/作品：存取 + clear 全清', () {
      NvkuEntryCache.clearForTest();
      const stamp = '123|456';
      NvkuEntryCache.putFolders(
        stamp,
        folders: const [('成人影片', 3)],
        covers: const {'成人影片': 'https://example.test/a.jpg'},
      );
      NvkuEntryCache.putTags(
        stamp,
        strict: true,
        value: (key: 'video_tag.tag_name', values: const [('中文字幕', 3)]),
      );
      NvkuEntryCache.putSiteCategories(
        'nvku',
        const [CatalogCategory('c0', '有码 · 100')],
        offline: false,
      );
      NvkuEntryCache.putLocalCategories(
        stamp,
        const [CatalogCategory('new', '最新作品 · 6')],
      );
      NvkuEntryCache.putMainCategories(
        stamp,
        const [CatalogCategory('main:有码', '有码 · 100')],
      );
      const drama = Drama(id: 'nvku:1', source: 'nvku', title: '测试短剧');
      NvkuEntryCache.putWorksFirstPage(
        'new',
        '',
        rows: const [drama],
        hasMore: true,
      );
      expect(NvkuEntryCache.folders(stamp)?.folders, [('成人影片', 3)]);
      expect(NvkuEntryCache.tags(stamp, strict: true)?.key,
          'video_tag.tag_name');
      expect(NvkuEntryCache.siteCategories('nvku')?.items.length, 1);
      expect(NvkuEntryCache.localCategories(stamp)?.length, 1);
      expect(NvkuEntryCache.mainCategories(stamp)?.length, 1);
      final works = NvkuEntryCache.worksFirstPage('new', '');
      expect(works?.rows.length, 1);
      expect(works?.isFresh, isTrue);
      expect(works?.hasMore, isTrue);

      NvkuEntryCache.clear();
      expect(NvkuEntryCache.folders(stamp), isNull);
      expect(NvkuEntryCache.tags(stamp, strict: true), isNull);
      expect(NvkuEntryCache.siteCategories('nvku'), isNull);
      expect(NvkuEntryCache.localCategories(stamp), isNull);
      expect(NvkuEntryCache.mainCategories(stamp), isNull);
      expect(NvkuEntryCache.worksFirstPage('new', ''), isNull);
    });

    test('作品第一页 TTL：5 分钟内新鲜、过期不新鲜', () {
      final fresh = NvkuWorksEntry(
        rows: const [],
        hasMore: false,
        savedAt: DateTime.now(),
      );
      expect(fresh.isFresh, isTrue);
      final stale = NvkuWorksEntry(
        rows: const [],
        hasMore: false,
        savedAt: DateTime.now().subtract(const Duration(minutes: 6)),
      );
      expect(stale.isFresh, isFalse);
    });

    test('作品第一页最多 8 个 key，超了淘汰最老的', () {
      NvkuEntryCache.clearForTest();
      for (var i = 0; i < 9; i++) {
        NvkuEntryCache.putWorksFirstPage(
          'cat$i',
          '',
          rows: const [],
          hasMore: false,
        );
      }
      expect(NvkuEntryCache.worksFirstPage('cat0', ''), isNull);
      expect(NvkuEntryCache.worksFirstPage('cat8', ''), isNotNull);
    });
  });

  group('ActressNvkuPage 进库缓存', () {
    late LocalStore store;
    late MemoryActressDatabase db;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      NvkuEntryCache.clearForTest();
      store = LocalStore();
      db = MemoryActressDatabase();
      await ActressMytvBind.instance.ensureBound();
      // 预热本地库单例：_boot 里 WhosLocalLibrary.ensureLoaded() 首次
      // 跑要走真异步（开库/读目录），FakeAsync 下等不到它、_boot 会
      // 停在 _loadCategories、作品永不加载；setUp 在真异步区，先跑完
      // 一次、单例缓存住已完成的结果，页里再调立刻返回（真机上这步
      // 本来就是真异步、一次跑完就缓存，测试只是复现这个状态）。
      await WhosLocalLibrary.shared.ensureLoaded();
    });

    Future<void> pumpPage(
      WidgetTester tester, {
      required _CountingFilmService service,
      required _CountingRepository repository,
      bool tallViewport = true,
    }) async {
      if (tallViewport) {
        // 视口拉高：首页 ListView + 作品 GridView 都是懒加载，作品卡
        // 在默认 800×600 首屏外建不出来，断言不到标题。
        tester.view.physicalSize = const Size(800, 2000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: ActressNvkuPage(
            repository: repository,
            store: store,
            database: db,
            filmService: service,
          ),
        ),
      );
      // 等 _boot 全跑完：文件夹上屏 + 作品那一路已调过 catalog
      // （作品卡可能在 600px 视口之下、懒加载网格还没构建它，
      // 这里不断言标题可见，只断言取数跑完了；标题可见性由调用方
      // 用高视口断言）。
      await _settleReal(
        tester,
        until: () =>
            find.text('成人影片').evaluate().isNotEmpty &&
            repository.requests.isNotEmpty,
      );
    }

    testWidgets('第二次进库不再全量重查：全新页实例 + 全新服务/仓库',
        (tester) async {
      final service1 = _CountingFilmService(database: db);
      final repo1 = _CountingRepository();
      await pumpPage(tester, service: service1, repository: repo1);
      expect(find.text('成人影片'), findsOneWidget);
      expect(find.text('测试短剧'), findsOneWidget);
      expect(service1.tagsCalls, 1);
      expect(service1.foldersCalls, 1);
      expect(service1.coversCalls, 1);
      expect(repo1.categoriesCalls, 1);
      expect(repo1.requests, hasLength(1));

      // 离开演员库（页实例释放），再进一次：全新实例 + 全新服务/仓库。
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await _settleReal(tester);
      final service2 = _CountingFilmService(database: db);
      final repo2 = _CountingRepository();
      // 第二次进：作品走缓存，仓库 requests 不会再涨，等待条件只
      // 看文件夹上屏（不等 requests，否则 10 秒白等）。
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: ActressNvkuPage(
            repository: repo2,
            store: store,
            database: db,
            filmService: service2,
          ),
        ),
      );
      await _settleReal(
        tester,
        until: () => find.text('成人影片').evaluate().isNotEmpty,
      );

      // 数据立刻在（不用等重查），且第二份服务/仓库一次都没被调——
      // 开库本身每次都走（便宜的连接重开），查数据的几路全命中缓存。
      expect(find.text('成人影片'), findsOneWidget);
      expect(find.text('测试短剧'), findsOneWidget);
      expect(service2.openCalls, 1);
      expect(service2.tagsCalls, 0);
      expect(service2.foldersCalls, 0);
      expect(service2.coversCalls, 0);
      expect(repo2.categoriesCalls, 0);
      expect(repo2.requests, isEmpty);
    });

    testWidgets('顶栏刷新钮清缓存、重查一遍', (tester) async {
      final service = _CountingFilmService(database: db);
      final repo = _CountingRepository();
      await pumpPage(tester, service: service, repository: repo);
      expect(service.tagsCalls, 1);
      expect(repo.categoriesCalls, 1);
      expect(repo.requests, hasLength(1));

      await tester.tap(find.byTooltip('刷新'));
      // 等刷新那一轮重查完成（标签计数涨到 2 才算查完）。
      await _settleReal(tester, until: () => service.tagsCalls >= 2);

      expect(service.tagsCalls, 2);
      expect(service.foldersCalls, 2);
      expect(service.coversCalls, 2);
      expect(repo.categoriesCalls, 2);
      expect(repo.requests, hasLength(2));
      expect(find.text('成人影片'), findsOneWidget);
    });

    testWidgets('女优 tab 切走再回来：列表页 State 是同一个对象',
        (tester) async {
      final service = _CountingFilmService(database: db);
      final repo = _CountingRepository();
      await pumpPage(tester, service: service, repository: repo);

      // 底部 tab 用图标点：列表页里另有一颗“女优”性别胶囊，
      // 文案定位会撞上两个 widget。
      await tester.tap(find.byIcon(Icons.face_retouching_natural));
      await _settleReal(tester);
      // 切走后列表页藏在 IndexedStack 里（offstage、仍挂着），
      // 默认查找器会跳过藏起来的 widget，必须加 skipOffstage: false
      // 才能断言“常驻未卸载”；State 同一性是保活的直接证据。
      final listKey = find.byKey(
        const ValueKey('nvku-actress-list'),
        skipOffstage: false,
      );
      expect(listKey, findsOneWidget);
      final firstState = tester.state(listKey);

      // 切到首页再切回来：列表页仍挂在树里（只是藏起来），不是重建。
      await tester.tap(find.byIcon(Icons.grid_view_rounded));
      await _settleReal(tester);
      expect(listKey, findsOneWidget);
      await tester.tap(find.byIcon(Icons.face_retouching_natural));
      await _settleReal(tester);
      expect(listKey, findsOneWidget);
      final secondState = tester.state(listKey);
      expect(identical(firstState, secondState), isTrue);
    });

    testWidgets('首页滚到底：共用 _scroll 不抛错', (tester) async {
      final service = _CountingFilmService(database: db);
      final repo = _CountingRepository();
      await pumpPage(
        tester,
        service: service,
        repository: repo,
        tallViewport: false,
      );
      expect(find.text('成人影片'), findsOneWidget);
      // 首页 ListView 与分类页 GridView 共用 _scroll、同时挂在
      // IndexedStack 里：旧写法 _scroll.position 要求恰好挂一个
      // 位置，滚到底就抛错；现在走 positions 迭代，不应有异常。
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(find.text('成人影片'), findsOneWidget);
    });
  });
}
