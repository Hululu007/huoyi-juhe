// 演员库原生页（ActressLibraryNativePage）功能测试。
// 假仓储（照 test/ 既有假仓储模式实现 AppRepository 抽象）+
// ActressLibraryDbFallback 注入假查询（照 actress_library_db_test
// 第 36/102 行的 pathResolver/opener 注入模式），不碰真库真网。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_ios_import.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_library_native_page.dart';

class _FakeDb {
  final tables = {
    'videos',
    'video_play_urls',
    'video_actress',
    'actresses',
    'video_tag',
    'video_ranking',
    'index_categories',
  };

  Map<String, Object?> _videoRow(String id) => {
    'vodId': id,
    'title': '作品$id',
    'pic': '',
    'play': 'https://v.hersav.me/h/h.m3u8',
    'playAlt': '',
    'date': '2024-01-01',
    'typeName': '成人影片',
    'actress': '演员甲',
  };

  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? args,
  ]) async {
    if (sql.contains('sqlite_master')) {
      return [for (final t in tables) {'name': t}];
    }
    if (sql.contains('FROM video_ranking')) {
      return [_videoRow('rank-001')];
    }
    if (sql.contains('category_name AS name')) {
      return [
        {'name': '中文字幕', 'cnt': 3631},
      ];
    }
    if (sql.contains('FROM actresses a')) {
      return [
        {'name': '演员甲', 'avatar': '', 'cnt': 42},
        {'name': '演员乙', 'avatar': '', 'cnt': 7},
      ];
    }
    if (sql.contains('FROM video_play_urls')) {
      return [
        {'play_url': 'https://v.hersav.me/h/h.m3u8'},
      ];
    }
    if (sql.contains('SELECT a.name AS name FROM video_actress')) {
      return [
        {'name': '演员甲'},
      ];
    }
    if (sql.contains('SELECT tag_name AS name FROM video_tag')) {
      return [
        {'name': '中文字幕'},
      ];
    }
    if (sql.contains('FROM videos v')) {
      if (sql.contains('WHERE v.vod_id = ?')) {
        final id = args?.first?.toString() ?? '';
        return [_videoRow(id)];
      }
      return [_videoRow('ssis-001'), _videoRow('mida-002')];
    }
    return [];
  }
}

ActressLibraryDbFallback _fallback(_FakeDb db, {bool hasDb = true}) {
  return ActressLibraryDbFallback(
    pathResolver: () async => hasDb ? '/fake/女优库.db' : null,
    opener: (path) async => hasDb ? db.query : null,
  );
}

class _FakeRepository extends AppRepository {
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory('all', '全部'), CatalogCategory('new', '最新')];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    return CatalogPage([
      Drama(
        id: '$source-1',
        source: source,
        title: '$source 作品一',
        tags: const ['CODE-1'],
      ),
    ], page: page);
  }

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async =>
      CatalogPage(const []);

  @override
  Future<void> searchAcrossProgressive(
    List<String> sources,
    String query, {
    required void Function(String source, List<Drama> items) onSite,
    bool Function()? shouldStop,
  }) async {
    for (final source in sources) {
      onSite(source, [
        Drama(id: '$source-s1', source: source, title: '搜索结果-$source'),
      ]);
    }
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => drama.cover;

  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail(drama, [
    Episode({'id': 'https://example.test/a.m3u8', 'title': '正片'}, 1),
  ]);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async => const PlaybackPlan(url: 'https://example.test/a.m3u8');
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late LocalStore store;

  setUp(() {
    store = LocalStore();
  });
  tearDown(() => store.dispose());

  Widget app({ActressLibraryDbFallback? fallback}) {
    return MaterialApp(
      home: ActressLibraryNativePage(
        repository: _FakeRepository(),
        store: store,
        fallback: fallback ?? _fallback(_FakeDb()),
      ),
    );
  }

  testWidgets('默认停在本地源且出卡片，底部四段齐全、123AV/PH 带未验标', (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    expect(find.text('演员库'), findsOneWidget);
    expect(find.byKey(const ValueKey('native-work-ssis-001')), findsOneWidget);
    expect(find.byKey(const ValueKey('native-work-mida-002')), findsOneWidget);
    expect(find.byKey(const ValueKey('native-source-local')), findsOneWidget);
    expect(find.byKey(const ValueKey('native-source-whos')), findsOneWidget);
    expect(find.byKey(const ValueKey('native-source-123av')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('native-source-pornhub')),
      findsOneWidget,
    );
    expect(find.text('未验'), findsNWidgets(2));
    // 本地一级页签四维齐全。
    expect(find.text('最新'), findsOneWidget);
    expect(find.text('排行榜'), findsOneWidget);
    expect(find.text('演员'), findsOneWidget);
    expect(find.text('标签'), findsOneWidget);
    // 厂牌二级条有 FC2。
    expect(find.text('FC2'), findsOneWidget);
  });

  testWidgets('切到 who\'s 出在线卡', (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('native-source-whos')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('native-work-whos-whos-1')),
      findsOneWidget,
    );
    expect(find.text('whos 作品一'), findsOneWidget);
  });

  testWidgets('统一搜索出分段结果且带来源徽标', (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('native-search-field')),
      'SSIS',
    );
    await tester.tap(find.byKey(const ValueKey('native-search-button')));
    await _settle(tester);
    expect(find.text('女优库 · 2条'), findsOneWidget);
    expect(find.text("who's · 1条"), findsOneWidget);
    // 来源徽标：本地段卡片上带「女优库」徽标（底部源条之外另有）。
    expect(find.text('女优库'), findsNWidgets(3));
    expect(find.text('搜索结果-whos'), findsOneWidget);
    // 搜索分段一次性建出（页面用整列滚动），四段都在树里可直接断言。
    expect(find.text('123AV · 1条'), findsOneWidget);
    expect(find.text('搜索结果-123av'), findsOneWidget);
    expect(find.text('PH · 1条'), findsOneWidget);
    // 退出搜索回浏览态。
    expect(find.byKey(const ValueKey('native-exit-search')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('native-exit-search')));
    await _settle(tester);
    expect(find.text('女优库 · 2条'), findsNothing);
  });

  testWidgets('管理弹层入口齐全（按当前平台断言可见项）', (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('native-manage-button')));
    await _settle(tester);
    expect(find.text('数据库管理'), findsOneWidget);
    expect(find.byKey(const ValueKey('native-manage-reload')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('native-manage-list-page')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('native-manage-legacy-page')),
      findsOneWidget,
    );
    if (Platform.isAndroid) {
      expect(
        find.byKey(const ValueKey('native-manage-grant-folder')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('native-manage-grant-file')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('native-manage-permission')),
        findsOneWidget,
      );
    }
    if (Platform.isIOS) {
      expect(find.byType(ActressIosImportTile), findsOneWidget);
    }
  });

  testWidgets('本地无库出状态区不白屏', (tester) async {
    await tester.pumpWidget(app(fallback: _fallback(_FakeDb(), hasDb: false)));
    await _settle(tester);
    expect(find.text('演员库'), findsOneWidget);
    expect(find.textContaining('本地女优库尚未就绪'), findsOneWidget);
    expect(find.byKey(const ValueKey('native-state-manage')), findsOneWidget);
    expect(find.text('去授权 / 打开管理'), findsOneWidget);
  });

  testWidgets('演员页签出行、点行进该女优作品且有回退 chip', (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('native-local-tab-2')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('native-actress-演员甲')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('native-actress-演员甲')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('native-works-back')), findsOneWidget);
    expect(find.text('女优：演员甲 ✕'), findsOneWidget);
    expect(find.byKey(const ValueKey('native-work-ssis-001')), findsOneWidget);
  });
}
