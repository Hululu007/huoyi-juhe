// 类型文件夹视图测试（2026-11-24 文件夹视图）。
// - GenericDbReader.typeNameFacet 分组计数 + 标签过滤（测试构造器）；
// - 文件夹网格 widget 渲染与点开；
// - 文件夹卡片封面（2026-11-24 13:42 令）：每卡用该类型视频列表
//   第一条视频的 pic_url，没封面的回落文件夹图标；
//   2026-11-25 起真服务不再逐条复用 listFilms(limit: 1)，改一次
//   GROUP BY 取每类型最小 vod_id + 一次 IN 批量取封面（见
//   actress_film_library.dart typeFolderCovers），假服务仍按旧
//   形状回固定封面，不影响本文件断言。
// - nvku 页首页/分类文件夹流（假影视库服务，不碰真库）；
// - 女优 tab 不动：演员列表原样渲染，文件夹区不在女优 tab 里。
// 真库 SQL（typeFolders/listFilms/countFilms 的严格结构原文 +
// typeNameFacet 通用结构原文）见 verify/replay_folder_sql.py，
// 用 Python sqlite3 对女优库.db 副本重放（flutter test 里
// sqflite 打不开真库）。封面取数 2026-11-25 起改一次聚合 +
// 一次批量取（replay_folder_cover_sql.py 是旧形状，仅供对照）。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_database.dart';
import 'package:fqapp/actress/actress_film_library.dart';
import 'package:fqapp/actress/actress_generic_db.dart';
import 'package:fqapp/actress/actress_mytv_bind.dart';
import 'package:fqapp/actress/actress_nvku_cache.dart';
import 'package:fqapp/actress/actress_nvku_page.dart';
import 'package:fqapp/actress/actress_type_folders.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'actress_fixtures.dart';

/// 假影视库服务：不碰真库、不走绑定。文件夹 3 个（成人影片 3 部、
// 国产精品 2 部、无码专区 1 部）；标签“中文字幕”只挂在
// MIDA-619/SSIS-123（成人影片）、GUO-001（国产精品）上，所以带
// 标签的文件夹计数是成人影片 2、国产精品 1，无码专区掉出（0 部）。
// 注意：这份假数据是让“标签横跨多个文件夹”的组合逻辑可测；
// 真库里标签只覆盖成人影片类作品（2026-11-24 实查：272,994 部
// 带标签作品全是成人影片），所以真机上选了标签文件夹网格只会剩
// 成人影片一个文件夹——那是数据事实，不是 UI 缺了文件夹。
class _FakeFilmService extends FilmLibraryService {
  _FakeFilmService({required super.database});

  var folders = <(String, int)>[
    ('成人影片', 3),
    ('国产精品', 2),
    ('无码专区', 1),
  ];

  var tagFolders = <(String, int)>[
    ('成人影片', 2),
    ('国产精品', 1),
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
      const FilmLibraryEntry(
        vodId: 'ssis-123',
        title: '测试作品二',
        code: 'SSIS-123',
        playUrl: 'https://example.test/ssis123.m3u8',
        typeName: '成人影片',
      ),
      const FilmLibraryEntry(
        vodId: 'ipx-707',
        title: '测试作品三',
        code: 'IPX-707',
        playUrl: 'https://example.test/ipx707.m3u8',
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
      const FilmLibraryEntry(
        vodId: 'guo-002',
        title: '国产测试二',
        code: 'GUO-002',
        playUrl: 'https://example.test/guo002.m3u8',
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

  /// 带“中文字幕”标签的番号：MIDA-619/SSIS-123（成人影片）、
  /// GUO-001（国产精品）；IPX-707 与 GUO-002、WUMA-001 不带。
  final taggedCodes = <String>{'MIDA-619', 'SSIS-123', 'GUO-001'};

  String? lastVideoTag;
  String? lastFolder;

  @override
  Future<FilmLibraryOpenResult> open() async {
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
  Future<List<(String, int)>> typeFolders({
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) async {
    lastVideoTag = videoTag;
    return videoTag.isEmpty ? folders : tagFolders;
  }

  /// 文件夹封面：与真实现同一口径——每类型取该类型第一条视频
  /// （ORDER BY vod_id 首行）的封面；第一行没封面、或该类型没
  /// 视频时回 ''。假服务仍按旧形状逐条取，真服务已改一次聚合 +
  /// 一次批量取（结果同一口径）。
  @override
  Future<Map<String, String>> typeFolderCovers({
    required List<String> typeNames,
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) async {
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
  Future<({String key, List<(String, int)> values})> tags() async {
    return (key: 'video_tag.tag_name', values: tagList);
  }

  List<FilmLibraryEntry> _filtered(String folder, String videoTag) {
    lastFolder = folder;
    lastVideoTag = videoTag;
    var list = works[folder] ?? const [];
    if (videoTag.isNotEmpty) {
      list = list.where((e) => taggedCodes.contains(e.code)).toList();
    }
    return list;
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
    required int offset,
    required int limit,
  }) async {
    final list = _filtered(typeName, videoTag);
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
    return _filtered(typeName, videoTag).length;
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
  for (var i = 0; i < 10; i++) {
    try {
      await tester.pump(const Duration(milliseconds: 100));
    } catch (_) {}
  }
}

/// 把一张真实封面样本（preview/cover_sample.jpg：成人影片第一条
/// 视频 003t28-262 的真实 pic_url 下回来的）预埋进图片缓存，
/// 让 Image.network 在测试环境里不用走网络就能画出来。测试环境
/// 的 mock 网络解不出图，没预埋的 URL 会进 errorBuilder 回落
/// 图标——那正是要测的回落路径。每个需要封面的测试在 pump 前调。
Future<void> _seedCoverCache(WidgetTester tester, String url) async {
  final bytes = File(
    '/home/hatch/workspace/xiuxian_actress_port_20261124/preview/cover_sample.jpg',
  ).readAsBytesSync();
  final image = await tester.runAsync(() async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  });
  PaintingBinding.instance.imageCache.putIfAbsent(
    NetworkImage(url),
    () => OneFrameImageStreamCompleter(
      Future.value(ImageInfo(image: image!)),
    ),
  );
}

void main() {
  group('GenericDbReader.typeNameFacet', () {
    test('按 category 分组、从多到少', () async {
      final reader = GenericDbReader.test(
        works: [
          const GenericDbWork(
            id: 1,
            title: '一',
            category: '成人影片',
            code: 'MIDA-619',
          ),
          const GenericDbWork(
            id: 2,
            title: '二',
            category: '成人影片',
            code: 'SSIS-123',
          ),
          const GenericDbWork(
            id: 3,
            title: '三',
            category: '国产精品',
            code: 'GUO-001',
          ),
          const GenericDbWork(id: 4, title: '四', category: '', code: 'X-1'),
        ],
      );
      expect(await reader.typeNameFacet(), [
        ('成人影片', 2),
        ('国产精品', 1),
      ]);
    });

    test('标签过滤只算带该标签的作品', () async {
      final reader = GenericDbReader.test(
        works: [
          const GenericDbWork(
            id: 1,
            title: '一',
            category: '成人影片',
            code: 'MIDA-619',
          ),
          const GenericDbWork(
            id: 2,
            title: '二',
            category: '成人影片',
            code: 'SSIS-123',
          ),
          const GenericDbWork(
            id: 3,
            title: '三',
            category: '国产精品',
            code: 'GUO-001',
          ),
        ],
        workTags: {
          'MIDA-619': {'中文字幕'},
          'GUO-001': {'中文字幕'},
        },
      );
      expect(
        await reader.typeNameFacet(
          tagKey: 'video_tag.tag_name',
          tag: '中文字幕',
        ),
        [
          ('成人影片', 1),
          ('国产精品', 1),
        ],
      );
      // 没给 workTags 时带标签的作品一条都筛不出来（不是不过滤）。
      final noTags = GenericDbReader.test(
        works: [
          const GenericDbWork(
            id: 1,
            title: '一',
            category: '成人影片',
            code: 'MIDA-619',
          ),
        ],
      );
      expect(
        await noTags.typeNameFacet(
          tagKey: 'video_tag.tag_name',
          tag: '中文字幕',
        ),
        isEmpty,
      );
    });
  });

  group('ActressTypeFolderGrid', () {
    testWidgets('三列文件夹卡：名 + 共N条，点卡回传类型名', (tester) async {
      var opened = '';
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: Scaffold(
            body: ActressTypeFolderGrid(
              folders: const [
                ('成人影片', 339840),
                ('国产精品', 31555),
                ('无码专区', 11847),
              ],
              onOpen: (name) => opened = name,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('成人影片'), findsOneWidget);
      expect(find.text('共339840条'), findsOneWidget);
      expect(find.text('国产精品'), findsOneWidget);
      expect(find.byIcon(Icons.folder_rounded), findsNWidgets(3));
      await tester.tap(find.text('国产精品'));
      expect(opened, '国产精品');
    });

    testWidgets('文件夹里的视频卡：没封面显示番号占位', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 130,
              height: 220,
              child: ActressFolderVideoCard(
                entry: const FilmLibraryEntry(
                  vodId: 'mida-619',
                  title: '测试作品一',
                  code: 'MIDA-619',
                  playUrl: 'https://example.test/mida619.m3u8',
                  typeName: '成人影片',
                ),
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('测试作品一'), findsOneWidget);
      expect(find.text('MIDA-619'), findsOneWidget);
    });

    testWidgets('文件夹卡：有封面的显示封面图，没封面的回落文件夹图标', (
      tester,
    ) async {
      await _seedCoverCache(tester, 'https://example.test/mida619.jpg');
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: Scaffold(
            body: ActressTypeFolderGrid(
              folders: const [
                ('成人影片', 339840),
                ('国产精品', 31555),
                ('无码专区', 11847),
              ],
              covers: const {
                '成人影片': 'https://example.test/mida619.jpg',
              },
              onOpen: (_) {},
            ),
          ),
        ),
      );
      await _settle(tester);
      // 有封面的卡画 Image（缓存里已预埋，加载成功，不回落）；
      // 没封面的两张回落文件夹图标；名 + 共N条都在。
      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.folder_rounded), findsNWidgets(2));
      expect(find.text('成人影片'), findsOneWidget);
      expect(find.text('共339840条'), findsOneWidget);
      expect(find.text('国产精品'), findsOneWidget);
      expect(find.text('无码专区'), findsOneWidget);
    });

    testWidgets('文件夹卡：封面加载失败也回落图标，不崩', (tester) async {
      // 这个 URL 没预埋进缓存：测试环境的 mock 网络解不出图，
      // 走 errorBuilder 回落图标，卡本身照常显示。
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: Scaffold(
            body: ActressTypeFolderGrid(
              folders: const [('成人影片', 339840)],
              covers: const {
                '成人影片': 'https://example.test/broken.jpg',
              },
              onOpen: (_) {},
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.folder_rounded), findsOneWidget);
      expect(find.text('成人影片'), findsOneWidget);
      expect(find.text('共339840条'), findsOneWidget);
    });
  });

  group('ActressNvkuPage 文件夹流', () {
    late LocalStore store;
    late MemoryActressDatabase db;
    late _FakeFilmService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      // 静态会话缓存跨测试串味：每个用例开始前清掉，否则前一个
      // 用例的假数据会让本用例的服务一次都不被调到。
      NvkuEntryCache.clearForTest();
      store = LocalStore();
      db = MemoryActressDatabase();
      service = _FakeFilmService(database: db);
      await ActressMytvBind.instance.ensureBound();
    });

    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: ActressNvkuPage(
            repository: FixtureRepository(),
            store: store,
            database: db,
            filmService: service,
          ),
        ),
      );
      await _settle(tester);
    }

    testWidgets('首页：顶栏是库名，文件夹网格在最顶', (tester) async {
      await pumpPage(tester);
      expect(find.text('女优库.db'), findsOneWidget);
      expect(find.text('类型文件夹'), findsOneWidget);
      expect(find.text('成人影片'), findsOneWidget);
      expect(find.text('共3条'), findsOneWidget);
      expect(find.text('国产精品'), findsOneWidget);
      expect(find.text('无码专区'), findsOneWidget);
      expect(find.text('3 个类型 · 共 6 部'), findsOneWidget);
      // 首页原来的最新上架作品还在（假站源 3 条合成剧）。
      expect(find.text('最新上架'), findsOneWidget);
    });

    testWidgets('文件夹卡用第一条视频的封面，没封面的回落图标', (tester) async {
      await _seedCoverCache(tester, 'https://example.test/mida619.jpg');
      await _seedCoverCache(tester, 'https://example.test/guo001.jpg');
      await pumpPage(tester);
      // 成人影片第一条 MIDA-619 有封面 → 卡里是图；
      // 国产精品第一条 GUO-001 有封面 → 卡里是图；
      // 无码专区第一条 WUMA-001 没封面 → 回落图标。
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('type-folder-成人影片')),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('type-folder-国产精品')),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('type-folder-无码专区')),
          matching: find.byIcon(Icons.folder_rounded),
        ),
        findsOneWidget,
      );
    });

    testWidgets('换标签后封面跟着重算（第一条带标签视频的封面）', (
      tester,
    ) async {
      await _seedCoverCache(tester, 'https://example.test/mida619.jpg');
      await _seedCoverCache(tester, 'https://example.test/guo001.jpg');
      await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('nvku-tag-open')));
      await _settle(tester);
      await tester.tap(find.text('中文字幕（3）'));
      await _settle(tester);
      // 第一部带标签的成人影片还是 MIDA-619（有封面），国产精品是
      // GUO-001（有封面）；无码专区没带标签的作品，掉出网格。
      expect(find.text('无码专区'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('type-folder-成人影片')),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('type-folder-国产精品')),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
    });

    testWidgets('点文件夹进分类 tab 看该类型视频，‹ 全部类型退回', (
      tester,
    ) async {
      await pumpPage(tester);
      await tester.tap(find.text('国产精品'));
      await _settle(tester);
      expect(find.text('国产测试一'), findsOneWidget);
      expect(find.text('国产测试二'), findsOneWidget);
      expect(find.text('测试作品一'), findsNothing);
      expect(find.text('国产精品 · 共2条'), findsOneWidget);
      expect(service.lastFolder, '国产精品');
      await tester.tap(find.text('‹ 全部类型'));
      await _settle(tester);
      expect(find.text('国产测试一'), findsNothing);
      // 修仙版结构与魔蚁不同：关文件夹后分类 tab 回站点作品网格
      // （不是文件夹网格），文件夹网格只在首页；回首页再看文件夹。
      await tester.tap(find.text('首页'));
      await _settle(tester);
      expect(find.text('成人影片'), findsOneWidget);
      expect(find.text('无码专区'), findsOneWidget);
    });

    testWidgets('标签筛：文件夹计数按标签重算，文件夹里同样能筛', (
      tester,
    ) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('nvku-tag-open')));
      await _settle(tester);
      expect(find.text('中文字幕（3）'), findsOneWidget);
      await tester.tap(find.text('中文字幕（3）'));
      await _settle(tester);
      expect(find.text('标签：中文字幕'), findsOneWidget);
      // 文件夹计数只算带标签的作品：无码专区掉出（0 部）。
      expect(find.text('成人影片'), findsOneWidget);
      expect(find.text('国产精品'), findsOneWidget);
      expect(find.text('无码专区'), findsNothing);
      expect(service.lastVideoTag, '中文字幕');
      // 进文件夹：列表里只剩带标签的作品。
      await tester.tap(find.text('成人影片'));
      await _settle(tester);
      expect(find.text('测试作品一'), findsOneWidget);
      expect(find.text('测试作品二'), findsOneWidget);
      expect(find.text('测试作品三'), findsNothing);
      // 清除回全部。
      await tester.tap(find.byKey(const ValueKey('nvku-tag-clear')));
      await _settle(tester);
      expect(find.text('标签：中文字幕'), findsNothing);
      expect(find.text('测试作品三'), findsOneWidget);
    });

    testWidgets('没有文件夹：首页如实显示暂无文件夹，分类 tab 仍是站点作品网格', (tester) async {
      // 修仙版结构与魔蚁不同：分类 tab 仍是站点分类 + 作品网格
      // （不是文件夹网格页），所以空文件夹只在首页如实显示；
      // 切到分类 tab 看到的是作品视图骨架，不是“去首页看作品”。
      // 注意：这里不断言假站源作品名——作品网格要等 _boot 走完
      // _loadCategories → WhosLocalLibrary.ensureLoaded → _loadFromDb，
      // 它在 flutter_test 里调未 mock 的 sqflite 平台通道，永不返回，
      // 真作品只能手机终验；断言作品视图骨架（空态文案）已足够证明
      // 切到的是作品视图而不是文件夹页。
      service.folders = [];
      service.tagFolders = [];
      await pumpPage(tester);
      expect(find.text('暂无文件夹：这个数据库没有 type_name 分类'), findsOneWidget);
      await tester.tap(find.text('分类'));
      await _settle(tester);
      expect(find.text('暂无文件夹：这个数据库没有 type_name 分类'), findsNothing);
      expect(find.text('去首页看作品'), findsNothing);
      expect(find.text('这个分类暂时取不到作品'), findsOneWidget);
    });

    testWidgets('女优 tab 不动：演员列表原样，文件夹区不在里面', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('女优'));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('nvku-actress-list')),
        findsOneWidget,
      );
      expect(find.text('类型文件夹'), findsNothing);
      expect(find.text('成人影片'), findsNothing);
      // 演员列表自己的筛选行还在（全部/有码/无码/欧美）。
      expect(find.text('全部'), findsWidgets);
    });
  });
}
