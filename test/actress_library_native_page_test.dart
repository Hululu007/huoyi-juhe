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
        // 同名异写（尾随空格）：显示层应合并、作品数取大不相加。
        {'name': '演员甲 ', 'avatar': '', 'cnt': 30},
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

/// 真时间等待：详情页的后台补充链（JavDB/番号元数据）是真
/// 异步，假时钟里等不到回包、超时定时器会挂到测试收尾。
Future<void> _settleReal(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 25; i++) {
      try {
        await Future.delayed(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 100));
      } catch (_) {}
    }
  });
}

/// 123AV / PH 的 Dart 直连假取数：按域名回一段能解析出 1 张
/// 卡的页面（结构照两站真页），不碰真网络。
Future<String> _fakeOnlineFetch(
  String url,
  Map<String, String> headers,
) async {
  final text = url;
  if (text.contains('123av.com')) {
    return '''
<div class="card">
  <a class="card__cover" href="/cn/v/ssis-001"><img class="card__img" data-src="https://icdn.123av.com/p1.jpg" alt=""></a>
  <div class="card__title">搜索结果-123av</div>
  <span class="card__dur">120分钟</span>
</div>
''';
  }
  if (text.contains('pornhub.com')) {
    return '''
<div class="wrap">
  <a href="/view_video.php?viewkey=abc123"><img src="https://ci.phncdn.com/t1.jpg" alt="搜索结果-ph"></a>
  <span class="duration">12:34</span>
</div>
''';
  }
  return '';
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
        onlineFetch: _fakeOnlineFetch,
      ),
    );
  }

  testWidgets('默认停在本地源且出卡片，顶部源条六段、在线五段带未验标', (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    expect(find.text('演员库'), findsOneWidget);
    expect(find.byKey(const ValueKey('native-work-ssis-001')), findsOneWidget);
    expect(find.byKey(const ValueKey('native-work-mida-002')), findsOneWidget);
    expect(find.byKey(const ValueKey('native-source-local')), findsOneWidget);
    // who's 已按令从演员库删除：源条无此段、全文无 who's 字样。
    expect(find.byKey(const ValueKey('native-source-whos')), findsNothing);
    expect(find.text("who's"), findsNothing);
    expect(find.byKey(const ValueKey('native-source-123av')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('native-source-pornhub')),
      findsOneWidget,
    );
    // 在线段（123AV/PH/MissAV/潮流/18AV＋2026-11-27 桥接
    // 批平铺的 110 个桥接站）都带未验标；桥接段在横滑源条
    // 尾段、懒建数量随布局变，断言至少五段在位。段集合与
    // 横滑另见 actress_four_sites_widget_test.dart。
    expect(find.text('未验'), findsAtLeastNWidgets(5));
    // 源条在顶部：源条底边在搜索框上方（不在页面底部）。
    final barRect = tester.getRect(
      find.byKey(const ValueKey('native-source-bar')),
    );
    final searchRect = tester.getRect(
      find.byKey(const ValueKey('native-search-field')),
    );
    expect(barRect.bottom <= searchRect.top, isTrue);
    expect(barRect.top < 120, isTrue);
    // 本地一级页签四维齐全。
    expect(find.text('最新'), findsOneWidget);
    expect(find.text('排行榜'), findsOneWidget);
    expect(find.text('演员'), findsOneWidget);
    expect(find.text('标签'), findsOneWidget);
    // 厂牌二级条有 FC2。
    expect(find.text('FC2'), findsOneWidget);
  });

  testWidgets('统一搜索出分段结果且带来源徽标（无 who\'s 段）', (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('native-search-field')),
      'SSIS',
    );
    await tester.tap(find.byKey(const ValueKey('native-search-button')));
    await _settle(tester);
    expect(find.text('女优库 · 2条'), findsOneWidget);
    expect(find.text("who's · 1条"), findsNothing);
    expect(find.text('搜索结果-whos'), findsNothing);
    // 来源徽标：本地段卡片上带「女优库」徽标（顶部源条之外另有）。
    expect(find.text('女优库'), findsNWidgets(3));
    // 搜索分段一次性建出（页面用整列滚动），三段都在树里可直接断言。
    expect(find.text('123AV · 1条'), findsOneWidget);
    expect(find.text('搜索结果-123av'), findsOneWidget);
    expect(find.text('PH · 1条'), findsOneWidget);
    // 退出搜索回浏览态。
    expect(find.byKey(const ValueKey('native-exit-search')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('native-exit-search')));
    await _settle(tester);
    expect(find.text('女优库 · 2条'), findsNothing);
  });

  testWidgets('切到 123AV 出 Dart 卡与栏目页签，点卡进作品详情页', (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('native-source-123av')));
    await _settle(tester);
    // 栏目页签（Dart 直连源）与卡片都出来。
    expect(
      find.byKey(const ValueKey('native-dart-primary-recent')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('native-work-123av-https://123av.com/cn/v/ssis-001'),
      ),
      findsOneWidget,
    );
    expect(find.text('搜索结果-123av'), findsOneWidget);
    // 点卡进作品详情页（页内起播形态），不再直进播放器。
    await tester.tap(
      find.byKey(
        const ValueKey('native-work-123av-https://123av.com/cn/v/ssis-001'),
      ),
    );
    await _settleReal(tester);
    expect(
      find.byKey(const ValueKey('work-detail-poster-play')),
      findsOneWidget,
    );
    expect(find.text('SSIS-001'), findsWidgets);
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

  testWidgets('演员页签三列网格卡、同名合并取大值，点卡进该女优作品', (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('native-local-tab-2')));
    await _settle(tester);
    // 三列网格。
    final grid = tester.widget<GridView>(
      find.byKey(const ValueKey('native-actress-grid')),
    );
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 3);
    // 同名合并：「演员甲」与「演员甲 」合并成一张卡，作品数取
    // 大值 42（不相加成 72、不出 30）。
    expect(find.byKey(const ValueKey('native-actress-演员甲')), findsOneWidget);
    expect(find.byKey(const ValueKey('native-actress-演员甲 ')), findsNothing);
    expect(find.text('作品 42 部'), findsOneWidget);
    expect(find.text('作品 30 部'), findsNothing);
    expect(find.text('作品 72 部'), findsNothing);
    expect(find.byKey(const ValueKey('native-actress-演员乙')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('native-actress-演员甲')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('native-works-back')), findsOneWidget);
    expect(find.text('女优：演员甲 ✕'), findsOneWidget);
    expect(find.byKey(const ValueKey('native-work-ssis-001')), findsOneWidget);
  });

  testWidgets('库层抛英文异常时界面只出中文人话、不露原文', (tester) async {
    final throwing = ActressLibraryDbFallback(
      pathResolver: () async => '/fake/女优库.db',
      opener: (path) async => (
        String sql, [
        List<Object?>? args,
      ]) async => throw StateError('Bad state: 详情为空'),
    );
    await tester.pumpWidget(app(fallback: throwing));
    await _settle(tester);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.textContaining('本地女优库不可用'), findsOneWidget);
  });
}
