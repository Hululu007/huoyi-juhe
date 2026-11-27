// 首页全局搜索的演员库落点（ActressLibraryNativePage 新入口
// 参数）：initialActress 进页直达作品下钻、initialActressQuery
// 进页停演员页签带名筛选、initialSearchQuery 进页直接出统一
// 搜索结果。假仓储 + 假库注入，不碰真库真网（照
// actress_library_native_page_test 的搭法）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_library_native_page.dart';

class _RecordingDb {
  final tables = {
    'videos',
    'video_play_urls',
    'video_actress',
    'actresses',
    'video_tag',
    'video_ranking',
    'index_categories',
  };
  final calls = <(String, List<Object?>?)>[];

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
    calls.add((sql, args));
    if (sql.contains('sqlite_master')) {
      return [for (final t in tables) {'name': t}];
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
    if (sql.contains('FROM videos v')) {
      return [_videoRow('ssis-001'), _videoRow('mida-002')];
    }
    return const [];
  }
}

class _FakeRepository extends AppRepository {
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory('all', '全部')];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async => CatalogPage(const [], page: page);

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async =>
      CatalogPage(const []);

  @override
  Future<void> searchAcrossProgressive(
    List<String> sources,
    String query, {
    required void Function(String source, List<Drama> items) onSite,
    bool Function()? shouldStop,
  }) async {}

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

Future<String> _fakeOnlineFetch(String url, Map<String, String> headers) async =>
    '';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late LocalStore store;
  late _RecordingDb db;

  setUp(() {
    store = LocalStore();
    db = _RecordingDb();
  });
  tearDown(() => store.dispose());

  Widget app({
    String? initialActress,
    String? initialActressQuery,
    String? initialSearchQuery,
  }) {
    return MaterialApp(
      home: ActressLibraryNativePage(
        repository: _FakeRepository(),
        store: store,
        fallback: ActressLibraryDbFallback(
          pathResolver: () async => '/fake.db',
          opener: (_) async => db.query,
        ),
        onlineFetch: _fakeOnlineFetch,
        initialActress: initialActress,
        initialActressQuery: initialActressQuery,
        initialSearchQuery: initialSearchQuery,
      ),
    );
  }

  testWidgets('initialActress：进页直达她的作品下钻', (tester) async {
    await tester.pumpWidget(app(initialActress: '演员甲'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('native-works-back')), findsOneWidget);
    expect(find.text('女优：演员甲 ✕'), findsOneWidget);
    expect(find.byKey(const ValueKey('native-work-ssis-001')), findsOneWidget);
    // works op 带 actress 参数落库。
    expect(
      db.calls.any(
        (c) => c.$1.contains('FROM video_actress') && c.$2!.contains('演员甲'),
      ),
      isTrue,
    );
  });

  testWidgets('initialActressQuery：停演员页签带名筛选，chip 可清', (tester) async {
    await tester.pumpWidget(app(initialActressQuery: '演员'));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('native-actress-query-clear')),
      findsOneWidget,
    );
    expect(find.text('演员名：演员 ✕'), findsOneWidget);
    expect(find.byKey(const ValueKey('native-actress-演员甲')), findsOneWidget);
    // actresses op 带 q 参数落库。
    expect(
      db.calls.any(
        (c) => c.$1.contains('FROM actresses a') && c.$2!.contains('%演员%'),
      ),
      isTrue,
    );
    // 清筛选后回到全量演员。
    await tester.tap(find.byKey(const ValueKey('native-actress-query-clear')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('native-actress-query-clear')),
      findsNothing,
    );
  });

  testWidgets('initialSearchQuery：进页直接出统一搜索结果', (tester) async {
    await tester.pumpWidget(app(initialSearchQuery: 'ssis'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('native-exit-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('native-work-ssis-001')), findsOneWidget);
  });
}
