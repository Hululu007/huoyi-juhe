// 本地专属分类路由 + 文件夹加载容错 + 海报播放键（2026-11-25）。
// - 排行榜/主分类/厂牌胶囊不走在线站源（蜘蛛会静默回落到“最新”分片，
//   点分类出的却是首页最新）；
// - 文件夹取数抛错不再永久转圈（摆文案 + 重试），总数慢时先出列表；
// - 详情页海报与卡片墙上的透明播放键（点键直接播，主体仍进详情）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_database.dart';
import 'package:fqapp/actress/actress_film_library.dart';
import 'package:fqapp/actress/actress_generic_db.dart';
import 'package:fqapp/actress/actress_mytv_bind.dart';
import 'package:fqapp/actress/actress_neon.dart';
import 'package:fqapp/actress/actress_nvku_cache.dart';
import 'package:fqapp/actress/actress_nvku_page.dart';
import 'package:fqapp/actress/actress_type_folders.dart';
import 'package:fqapp/actress/whos_local_library.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 在线站源替身：catalog 对任何分类都回同一条“在线最新剧”——
// 如果路由修好，点排行榜/主分类时它根本不该被调到；一旦调到，
// 网格里出现这条就是回归证据。
class _LocalOnlyRepository extends AppRepository {
  final catalogCategories = <String>[];

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => [
    CatalogCategory('new', '最新上架'),
    CatalogCategory('rank', '排行榜 · 449329'),
    CatalogCategory('main:LSP', 'LSP · 93687'),
  ];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    catalogCategories.add(category);
    return CatalogPage([
      const Drama(id: 'nvku:online-1', source: 'nvku', title: '在线最新剧'),
    ]);
  }

  @override
  Future<CatalogPage> searchAcross(
    List<String> sources,
    String query,
  ) async => CatalogPage(const []);

  @override
  Future<String> cover(Drama drama, {bool force = false}) async =>
      drama.cover;

  @override
  Future<DramaDetail> detail(Drama drama) async =>
      DramaDetail(drama, const []);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async => const PlaybackPlan(url: '', headers: {}, needsParse: false);
}

/// 假影视库服务：文件夹两个（成人影片 3 部、群交淫乱 2 部）。
class _FakeFilmService extends FilmLibraryService {
  _FakeFilmService({required super.database});

  var failList = false;
  Completer<void>? holdCount;

  final works = <String, List<FilmLibraryEntry>>{
    '成人影片': [
      const FilmLibraryEntry(
        vodId: 'mida-619',
        title: '测试作品一',
        code: 'MIDA-619',
        playUrl: 'https://example.test/mida619.m3u8',
        typeName: '成人影片',
      ),
    ],
    '群交淫乱': [
      const FilmLibraryEntry(
        vodId: 'qj-001',
        title: '测试作品甲',
        code: 'QJ-001',
        playUrl: 'https://example.test/qj001.m3u8',
        typeName: '群交淫乱',
      ),
      const FilmLibraryEntry(
        vodId: 'qj-002',
        title: '测试作品乙',
        code: 'QJ-002',
        playUrl: 'https://example.test/qj002.m3u8',
        typeName: '群交淫乱',
      ),
    ],
  };

  @override
  Future<FilmLibraryOpenResult> open() async {
    return const FilmLibraryOpenResult(
      dbPath: '/fake/MYTV/db/女优库.db',
      displayPath: 'MYTV/db/女优库.db',
      strict: true,
      total: 3,
      schema: GenericDbSchema(tables: [], fingerprint: 'test'),
      domain: '',
    );
  }

  @override
  Future<List<(String, int)>> typeFolders({
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) async => [('成人影片', 1), ('群交淫乱', 2)];

  @override
  Future<Map<String, String>> typeFolderCovers({
    required List<String> typeNames,
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) async => const {};

  @override
  Future<({String key, List<(String, int)> values})> tags() async =>
      (key: 'video_tag.tag_name', values: const <(String, int)>[]);

  @override
  Future<List<FilmLibraryEntry>> listFilms({
    String category = '',
    String site = '',
    String actress = '',
    String query = '',
    String typeName = '',
    String videoTag = '',
    String genericTagKey = '',
    required int offset,
    required int limit,
  }) async {
    if (failList) throw StateError('fake list failure');
    final list = works[typeName] ?? const [];
    return list.skip(offset).take(limit).toList();
  }

  @override
  Future<int> countFilms({
    String category = '',
    String site = '',
    String actress = '',
    String query = '',
    String typeName = '',
    String videoTag = '',
    String genericTagKey = '',
  }) async {
    final hold = holdCount;
    if (hold != null) await hold.future;
    return (works[typeName] ?? const []).length;
  }
}

ThemeData _testTheme() {
  final base = ThemeData.dark();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
  );
}

Future<void> _settle(WidgetTester tester) async {
  // 首屏加载里有真异步（绑定/读库走平台通道），FakeAsync 定步 pump
  // 等不到它完成；用预览测试同款真时间轮询（见 AGENTS.md 2026-11-18 条）。
  await tester.runAsync(() async {
    for (var i = 0; i < 30; i++) {
      try {
        await Future.delayed(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 100));
      } catch (_) {}
    }
  });
}

void main() {
  test('nvkuCategoryIsLocalOnly：排行榜/主分类/厂牌走本地，其余走在线', () {
    expect(nvkuCategoryIsLocalOnly('rank'), isTrue);
    expect(nvkuCategoryIsLocalOnly('main:LSP'), isTrue);
    expect(nvkuCategoryIsLocalOnly('main:有码'), isTrue);
    expect(nvkuCategoryIsLocalOnly('brand:ssis'), isTrue);
    expect(nvkuCategoryIsLocalOnly('new'), isFalse);
    expect(nvkuCategoryIsLocalOnly('c0'), isFalse);
    expect(nvkuCategoryIsLocalOnly(''), isFalse);
  });

  group('ActressNvkuPage 本地分类路由', () {
    late LocalStore store;
    late MemoryActressDatabase db;
    late _FakeFilmService service;
    late _LocalOnlyRepository repository;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      // 静态会话缓存跨测试串味：每个用例开始前清掉，否则前一个
      // 用例的假数据会让本用例的服务一次都不被调到（例如路由用例
      // 里“点回最新上架”应再调一次在线 catalog，缓存命中就调不到）。
      NvkuEntryCache.clearForTest();
      store = LocalStore();
      db = MemoryActressDatabase();
      service = _FakeFilmService(database: db);
      repository = _LocalOnlyRepository();
      await ActressMytvBind.instance.ensureBound();
    });

    Future<void> pumpPage(WidgetTester tester) async {
      // 视口拉高：首页 ListView + 作品 GridView 都是懒加载，作品卡
      // 在默认 800×600 首屏外建不出来，断言不到标题。
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
      // 等 _boot 走完（在线最新剧出现才算数）：真时间轮询，最多 30 秒。
      // 固定 6 秒在 VM 繁忙时不够，胶囊/作品时有时无（合跑第二页更慢）。
      await tester.runAsync(() async {
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find.text('在线最新剧').evaluate().isNotEmpty) return;
          await Future.delayed(const Duration(milliseconds: 500));
        }
      });
      await tester.pump();
    }

    // 排行榜与主分类胶囊的断言并在一个用例里：合跑时第二页 _boot
    // 会被前一页的残留状态拖住（单跑 8 秒过、合跑 30 秒等不到），
    // 一次 pump 测完两个胶囊，不依赖第二页。
    testWidgets('本地胶囊不调在线站源：排行榜与主分类', (tester) async {
      await pumpPage(tester);
      // 首页先走在线“最新上架”，在线剧在。
      expect(find.text('在线最新剧'), findsOneWidget);
      expect(repository.catalogCategories, contains('new'));

      // 点排行榜：不调在线 catalog，网格里也没有在线冒名那条。
      // 2026-11-26 口径变更（无库时内置 who's JSON 顶上）：本用例
      // 没绑外置库，本地库由内置目录顶着，排行榜出的是内置作品
      // 流，不再是旧口径的「暂时取不到作品」空态。
      await tester.tap(find.text('排行榜 · 449329'));
      await _settle(tester);
      expect(repository.catalogCategories, isNot(contains('rank')));
      expect(find.text('在线最新剧'), findsNothing);
      expect(find.text('暂时取不到作品'), findsNothing);
      expect(WhosLocalLibrary.shared.isAssetBacked, isTrue);
      expect(
        await WhosLocalLibrary.shared.countForAsync(category: 'rank'),
        greaterThan(0),
      );

      // 点回最新上架：在线剧回来（2026-11-25 进库缓存：同一分类 +
      // 搜索词的第一页 5 分钟内走缓存，不再调在线 catalog，所以
      // 'new' 的调用次数仍是首屏那 1 次，不是 2 次；剧在屏就是
      // 缓存命中的证据）。
      await tester.tap(find.text('最新上架'));
      await _settle(tester);
      expect(find.text('在线最新剧'), findsOneWidget);
      expect(
        repository.catalogCategories.where((c) => c == 'new').length,
        1,
      );

      // 点主分类：同样不调在线站源。
      // LSP 是横向胶囊条第三颗，滑出可视区就没建出来：先把条往左拖。
      await tester.drag(find.text('排行榜 · 449329'), const Offset(-300, 0));
      await tester.pump();
      await tester.tap(find.text('LSP · 93687'));
      await _settle(tester);
      expect(repository.catalogCategories, isNot(contains('main:LSP')));
      expect(find.text('在线最新剧'), findsNothing);
    });

    testWidgets('文件夹取数抛错摆重试，点重试后出列表', (tester) async {
      service.failList = true;
      await pumpPage(tester);
      await tester.tap(find.text('群交淫乱'));
      await _settle(tester);
      // 不再是永久转圈：失败文案 + 重试键。
      expect(
        find.text('这个类型暂时取不到作品，点下面重试'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('folder-retry')), findsOneWidget);
      service.failList = false;
      await tester.tap(find.byKey(const ValueKey('folder-retry')));
      await _settle(tester);
      expect(find.text('测试作品甲'), findsOneWidget);
      expect(find.text('测试作品乙'), findsOneWidget);
      expect(find.text('群交淫乱 · 共2条'), findsOneWidget);
    });

    testWidgets('总数慢时先出列表，数到了再补标题', (tester) async {
      service.holdCount = Completer<void>();
      await pumpPage(tester);
      await tester.tap(find.text('群交淫乱'));
      await _settle(tester);
      // 总数还卡着，列表已经出来了，标题仍显示加载中。
      expect(find.text('测试作品甲'), findsOneWidget);
      expect(find.text('群交淫乱 · 加载中…'), findsOneWidget);
      service.holdCount!.complete();
      service.holdCount = null;
      await _settle(tester);
      expect(find.text('群交淫乱 · 共2条'), findsOneWidget);
    });
  });

  group('海报播放键', () {
    testWidgets('详情页海报：有地址摆播放键，没地址不摆', (tester) async {
      // 详情页是 ListView 懒加载：“正片”行在首屏外，不建出来；
      // 把视口拉高，整页一次建完再断言。
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = MemoryActressDatabase();
      final service = _FakeFilmService(database: db);
      final repository = _LocalOnlyRepository();
      const playable = FilmLibraryEntry(
        vodId: 'qj-001',
        title: '测试作品甲',
        code: 'QJ-001',
        playUrl: 'https://example.test/qj001.m3u8',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: FilmDetailPage(
            entry: playable,
            database: db,
            repository: repository,
            store: LocalStore(),
            service: service,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(PosterPlayBadge), findsOneWidget);
      expect(find.text('正片'), findsOneWidget);
      expect(find.text('直链播放（parse=0）'), findsOneWidget);

      const unplayable = FilmLibraryEntry(
        vodId: 'qj-002',
        title: '测试作品乙',
        code: 'QJ-002',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: FilmDetailPage(
            entry: unplayable,
            database: db,
            repository: repository,
            store: LocalStore(),
            service: service,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(PosterPlayBadge), findsNothing);
      expect(find.text('暂无可播地址'), findsOneWidget);
    });

    testWidgets('文件夹卡：点播放键只调 onPlay，不进详情', (tester) async {
      var tappedCard = false;
      var tappedPlay = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: Scaffold(
            body: ActressFolderVideoCard(
              entry: const FilmLibraryEntry(
                vodId: 'qj-001',
                title: '测试作品甲',
                code: 'QJ-001',
                playUrl: 'https://example.test/qj001.m3u8',
              ),
              onTap: () => tappedCard = true,
              onPlay: () => tappedPlay = true,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(PosterPlayBadge), findsOneWidget);
      await tester.tap(find.byType(PosterPlayBadge));
      await tester.pump();
      expect(tappedPlay, isTrue);
      expect(tappedCard, isFalse);
    });

    testWidgets('文件夹卡：不传 onPlay 时不摆播放键', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: const Scaffold(
            body: ActressFolderVideoCard(
              entry: FilmLibraryEntry(
                vodId: 'qj-001',
                title: '测试作品甲',
                code: 'QJ-001',
                playUrl: 'https://example.test/qj001.m3u8',
              ),
              onTap: _noop,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(PosterPlayBadge), findsNothing);
    });
  });
}

void _noop() {}
