// 首页全局搜索演员库段（2026-11-27 用户令）：
// - 库层 globalSearch op：分段、各自上限与 hasMore、番号精
//   确（主键）优先、包含兜底只在没填满且词够长时跑、硬线
//   排除在每条作品查询里都在、同名演员显示合并；
// - 服务层：没库回 null（静默不出段）；
// - 搜索页：综合页签出演员/作品两段、卡片与「更多」跳转落
//   点、未解锁不查库不出段、非综合页签不出段。
// 库层不碰真 sqlite（flutter test 无桌面实现）：注入假查询
// 函数，按 SQL 特征回脚本行并记录调用，与
// actress_library_db_test 同款。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/actress/actress_global_search.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/search_page.dart';

Map<String, Object?> _videoRow(String id) => {
  'vodId': id,
  'title': '作品$id',
  'pic': '',
  'play': 'https://v.test/$id.m3u8',
  'playAlt': '',
  'date': '2024-01-01',
  'typeName': '成人影片',
  'actress': '演员甲',
};

class _FakeGlobalDb {
  _FakeGlobalDb({Set<String>? tables})
    : tables =
          tables ??
          {
            'videos',
            'video_play_urls',
            'video_actress',
            'actresses',
            'video_tag',
            'index_categories',
          };

  final Set<String> tables;
  final calls = <(String, List<Object?>?)>[];
  var actressRows = <Map<String, Object?>>[];
  var exactRows = <Map<String, Object?>>[];
  var prefixRows = <Map<String, Object?>>[];
  var containsRows = <Map<String, Object?>>[];

  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? args,
  ]) async {
    calls.add((sql, args));
    if (sql.contains('sqlite_master')) {
      return [for (final t in tables) {'name': t}];
    }
    if (sql.contains('FROM actresses a')) {
      final limit = (args?.last as num?)?.toInt() ?? actressRows.length;
      return actressRows.take(limit).toList();
    }
    if (sql.contains('FROM video_play_urls')) return const [];
    // _videoRows 的 LIMIT/OFFSET 恒在参数尾两格。
    List<Map<String, Object?>> take(List<Map<String, Object?>> rows) {
      final limit = (args?[args.length - 2] as num?)?.toInt() ?? rows.length;
      return rows.take(limit).toList();
    }

    if (sql.contains('v.vod_id IN (')) return take(exactRows);
    if (sql.contains('OR v.title LIKE')) return take(containsRows);
    if (sql.contains('v.vod_id LIKE')) return take(prefixRows);
    return const [];
  }

  ActressLibraryDbFallback get fallback => ActressLibraryDbFallback(
    pathResolver: () async => '/fake.db',
    opener: (_) async => query,
  );

  bool get calledContains =>
      calls.any((c) => c.$1.contains('OR v.title LIKE'));
}

void main() {
  group('库层 globalSearch op', () {
    test('分段上限与 hasMore：精确段在前、填满后不跑包含兜底', () async {
      final db = _FakeGlobalDb();
      db.actressRows = [
        for (var i = 0; i < 20; i++)
          {'name': '演员$i', 'avatar': '', 'cnt': 100 - i},
      ];
      db.exactRows = [_videoRow('ssis-001'), _videoRow('ssis-002')];
      db.prefixRows = [
        for (var i = 0; i < 20; i++) _videoRow('ssis-1${'$i'.padLeft(2, '0')}'),
      ];
      db.containsRows = [_videoRow('ssis-999')];
      final result = await db.fallback.handle({'op': 'globalSearch', 'q': 'ssis'});
      expect(result['ok'], isTrue);
      final actresses = result['actresses'] as List;
      final works = result['works'] as List;
      expect(actresses, hasLength(actressGlobalActressCap));
      expect(result['actressesHasMore'], isTrue);
      expect(works, hasLength(actressGlobalWorkCap));
      expect(result['worksHasMore'], isTrue);
      // 精确命中的两部排在最前。
      expect((works.first as Map)['vodId'], 'ssis-001');
      expect((works[1] as Map)['vodId'], 'ssis-002');
      // 作品段已被精确+前缀填满：包含兜底（全表扫）不许跑。
      expect(db.calledContains, isFalse);
    });

    test('没填满才跑包含兜底，且每条作品查询都带硬线排除', () async {
      final db = _FakeGlobalDb();
      db.exactRows = [_videoRow('hmn-001')];
      db.containsRows = [_videoRow('hmn-777'), _videoRow('hmn-888')];
      final result = await db.fallback.handle({'op': 'globalSearch', 'q': 'hmn'});
      expect(result['ok'], isTrue);
      final works = result['works'] as List;
      expect(works, hasLength(3));
      expect((works.first as Map)['vodId'], 'hmn-001');
      expect(result['worksHasMore'], isFalse);
      expect(db.calledContains, isTrue);
      final workCalls = db.calls.where((c) => c.$1.contains('FROM videos v'));
      expect(workCalls, isNotEmpty);
      for (final call in workCalls) {
        expect(call.$2, contains('少女萝莉'), reason: call.$1);
      }
    });

    test('同名演员显示合并：计数取大、头像取首个非空', () async {
      final db = _FakeGlobalDb();
      db.actressRows = [
        {'name': '演员甲', 'avatar': '', 'cnt': 5},
        {'name': '演员甲', 'avatar': 'https://a.test/x.jpg', 'cnt': 9},
        {'name': '演员乙', 'avatar': '', 'cnt': 3},
      ];
      final result = await db.fallback.handle({'op': 'globalSearch', 'q': '演员'});
      final actresses = result['actresses'] as List;
      expect(actresses, hasLength(2));
      final first = actresses.first as Map;
      expect(first['name'], '演员甲');
      expect(first['count'], 9);
      expect(first['avatar'], 'https://a.test/x.jpg');
      expect(result['actressesHasMore'], isFalse);
    });

    test('短词（1 字）不跑包含兜底', () async {
      final db = _FakeGlobalDb();
      db.prefixRows = [_videoRow('a-001')];
      db.containsRows = [_videoRow('a-999')];
      final result = await db.fallback.handle({'op': 'globalSearch', 'q': 'a'});
      final works = result['works'] as List;
      expect(works, hasLength(1));
      expect(db.calledContains, isFalse);
    });

    test('actresses 表缺失：演员段回空、作品段照常', () async {
      final db = _FakeGlobalDb(
        tables: {'videos', 'video_play_urls', 'video_actress', 'video_tag'},
      );
      db.exactRows = [_videoRow('abc-001')];
      final result = await db.fallback.handle({'op': 'globalSearch', 'q': 'abc'});
      expect(result['ok'], isTrue);
      expect(result['actresses'], isEmpty);
      expect(result['works'] as List, hasLength(1));
    });
  });

  group('服务层 loadActressGlobalSearch', () {
    test('没库回 null（静默不出段）', () async {
      final noDb = ActressLibraryDbFallback(
        pathResolver: () async => null,
        opener: (_) async => null,
      );
      expect(await loadActressGlobalSearch('ssis', fallback: noDb), isNull);
    });

    test('有库时解析两段与 hasMore', () async {
      final db = _FakeGlobalDb();
      db.actressRows = [
        {'name': '演员甲', 'avatar': '', 'cnt': 42},
      ];
      db.exactRows = [_videoRow('ssis-001')];
      final result = await loadActressGlobalSearch(
        'ssis',
        fallback: db.fallback,
      );
      expect(result, isNotNull);
      expect(result!.actresses, hasLength(1));
      expect(result.works, hasLength(1));
      expect(result.actressesHasMore, isFalse);
      expect(result.worksHasMore, isFalse);
    });
  });

  group('搜索页演员库段', () {
    setUp(
      () => SharedPreferences.setMockInitialValues({'search_list_view': false}),
    );

    Future<List<SearchTab>> fanqieLoader(
      String query, {
      required int tabType,
      required int offset,
    }) async => [
      SearchTab(
        title: tabType == 11 ? '短剧' : '综合',
        items: [
          MediaItem(
            id: 'fx-1',
            title: '番茄结果一',
            cover: '',
            author: '',
            badge: '',
            ep: '',
            kind: tabType == 11 ? 'video' : 'book',
          ),
        ],
        hasMore: false,
      ),
    ];

    ActressGlobalSearchResult fakeResult({
      bool actressesHasMore = true,
      bool worksHasMore = true,
    }) => ActressGlobalSearchResult(
      actresses: [
        {'name': '三上悠亚', 'avatar': '', 'count': 128},
        {'name': '三上二号', 'avatar': '', 'count': 12},
      ],
      works: [
        {
          'vodId': 'ssis-001',
          'title': '作品一',
          'pic': '',
          'code': 'ssis-001',
          'date': '2024-05-01',
          'actress': '三上悠亚',
        },
        {
          'vodId': 'ssis-002',
          'title': '作品二',
          'pic': '',
          'code': 'ssis-002',
          'date': '2024-06-01',
          'actress': '三上悠亚',
        },
      ],
      actressesHasMore: actressesHasMore,
      worksHasMore: worksHasMore,
    );

    Widget page({
      required ActressGlobalSearchLoader? actressLoader,
      bool? enabled = true,
      SearchCategory category = SearchCategory.general,
    }) {
      return MaterialApp(
        home: SearchPage(
          initialQuery: '三上',
          initialCategory: category,
          searchLoader: fanqieLoader,
          actressSearchLoader: actressLoader,
          actressSearchEnabled: enabled,
          actressPageBuilder: (_, name) =>
              Scaffold(appBar: AppBar(), body: Text('演员页：$name')),
          actressWorkPageBuilder: (_, vodId) =>
              Scaffold(appBar: AppBar(), body: Text('作品页：$vodId')),
          actressMoreActressesBuilder: (_, query) =>
              Scaffold(appBar: AppBar(), body: Text('演员更多：$query')),
          actressMoreWorksBuilder: (_, query) =>
              Scaffold(appBar: AppBar(), body: Text('作品更多：$query')),
        ),
      );
    }

    testWidgets('综合页签出两段，卡片与更多跳转落点对', (tester) async {
      // 拉高视口让两段一屏装下：sliver 懒建，折线外的段头/卡
      // 不在树里，滚动博弈会让用例脆（点位随滚动偏移漂移）。
      tester.view.physicalSize = const Size(800, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(page(actressLoader: (_) async => fakeResult()));
      await tester.pumpAndSettle();
      expect(find.text('演员库 · 演员'), findsOneWidget);
      expect(find.text('演员库 · 作品'), findsOneWidget);
      expect(find.byKey(const ValueKey('global-actress-三上悠亚')), findsOneWidget);
      expect(find.byKey(const ValueKey('global-work-ssis-001')), findsOneWidget);
      // 番茄结果照常在。
      expect(find.text('番茄结果一'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('global-actress-三上悠亚')));
      await tester.pumpAndSettle();
      expect(find.text('演员页：三上悠亚'), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('global-actress-more')));
      await tester.pumpAndSettle();
      expect(find.text('演员更多：三上'), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('global-work-ssis-001')));
      await tester.pumpAndSettle();
      expect(find.text('作品页：ssis-001'), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('global-work-more')));
      await tester.pumpAndSettle();
      expect(find.text('作品更多：三上'), findsOneWidget);
    });

    testWidgets('hasMore 为假时不出更多按钮', (tester) async {
      await tester.pumpWidget(
        page(
          actressLoader: (_) async =>
              fakeResult(actressesHasMore: false, worksHasMore: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('演员库 · 演员'), findsOneWidget);
      expect(find.byKey(const ValueKey('global-actress-more')), findsNothing);
      expect(find.byKey(const ValueKey('global-work-more')), findsNothing);
    });

    testWidgets('未解锁：不查库、不出段，其余结果照常', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        page(
          actressLoader: (_) async {
            calls++;
            return fakeResult();
          },
          enabled: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(find.text('演员库 · 演员'), findsNothing);
      expect(find.text('演员库 · 作品'), findsNothing);
      expect(find.text('番茄结果一'), findsOneWidget);
    });

    testWidgets('没库（取数回 null）：段静默不出，不报错', (tester) async {
      await tester.pumpWidget(page(actressLoader: (_) async => null));
      await tester.pumpAndSettle();
      expect(find.text('演员库 · 演员'), findsNothing);
      expect(find.text('演员库 · 作品'), findsNothing);
      expect(find.text('番茄结果一'), findsOneWidget);
    });

    testWidgets('非综合页签不出演员库段', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        page(
          actressLoader: (_) async {
            calls++;
            return fakeResult();
          },
          category: SearchCategory.video,
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(find.text('演员库 · 演员'), findsNothing);
      expect(find.text('番茄结果一'), findsOneWidget);
    });
  });
}
