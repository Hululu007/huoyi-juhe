// 作品详情页（ActressWorkDetailPage）测试：AvPlay 式版面
// （信息卡/演员/剧照/线路）+ 页内起播 + 竞速失败文案。
// 全部注入假件（假库查询/假仓储/假在线取数/假 JavDB 取数/
// 假探活/受控播放器），不碰真库真网。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_http.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_javdb_api.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_online_parse.dart';
import 'package:fqapp/actress/actress_online_sources.dart';
import 'package:fqapp/actress/actress_work_detail_page.dart';

import 'support/controlled_player.dart';

/// 假库：detail op 回一份完整样本（番号 SIGL-020，带
/// actresses.avatar 与 videos.content 两列，走新补查路径）；
/// works op 回一部同演员作品。
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

  Map<String, Object?> _row(String id, String title) => {
    'vodId': id,
    'title': title,
    'pic': 'https://img.test/poster.jpg',
    'play': 'https://v.hersav.me/abc/abc.m3u8',
    'playAlt': '',
    'date': '2024-05-06',
    'typeName': '剧情',
    'actress': '演员甲',
  };

  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? args,
  ]) async {
    if (sql.contains('sqlite_master')) {
      return [for (final t in tables) {'name': t}];
    }
    if (sql.contains('PRAGMA table_info(actresses)')) {
      return [
        {'name': 'name'},
        {'name': 'avatar'},
      ];
    }
    if (sql.contains('PRAGMA table_info(videos)')) {
      return [
        {'name': 'content'},
      ];
    }
    if (sql.contains('PRAGMA')) return [];
    if (sql.contains('a.avatar AS avatar')) {
      return [
        {'name': '演员甲', 'avatar': 'https://img.test/av-a.jpg'},
        {'name': '男演员乙', 'avatar': ''},
      ];
    }
    if (sql.contains('content AS content')) {
      return [
        {'content': '这是 SIGL-020 的简介内容。'},
      ];
    }
    if (sql.contains('FROM video_play_urls')) {
      return [
        {'play_url': 'https://v.hersav.me/abc/abc.m3u8'},
      ];
    }
    if (sql.contains('SELECT a.name AS name FROM video_actress')) {
      return [
        {'name': '演员甲'},
        {'name': '男演员乙'},
      ];
    }
    if (sql.contains('SELECT tag_name AS name FROM video_tag')) {
      return [
        {'name': '中文字幕'},
        {'name': '剧情'},
      ];
    }
    if (sql.contains('FROM videos v')) {
      if (sql.contains('WHERE v.vod_id = ?')) {
        return [_row('sigl-020', 'SIGL-020 样本标题')];
      }
      return [_row('mida-002', 'MIDA-002 相关作品')];
    }
    return [];
  }
}

ActressLibraryDbFallback _fallback(_FakeDb db) {
  return ActressLibraryDbFallback(
    pathResolver: () async => '/fake/女优库.db',
    opener: (path) async => db.query,
  );
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
    Episode({'id': 'https://example.test/whos.m3u8', 'title': '正片'}, 1),
  ]);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async => const PlaybackPlan(url: 'https://example.test/whos.m3u8');
}

/// 123AV 假取数：搜索/列表回 1 张卡；详情页回带内联 player
/// JSON 与 4 张剧照的页面；/stream 回 media.stream。
Future<String> _fakeAv123Fetch(
  String url,
  Map<String, String> headers,
) async {
  final text = url;
  if (text.contains('/stream')) {
    return '{"media":{"stream":"https://cdn.test/sigl-020.m3u8"}}';
  }
  if (text.contains('/cn/v/')) {
    return '<html><body>'
        '<h1>SIGL-020 在线标题</h1>'
        '<div class="preview-images">'
        '<img src="https://img.test/still1.jpg">'
        '<img src="https://img.test/still2.jpg">'
        '<img src="https://img.test/still3.jpg">'
        '<img src="https://img.test/still4.jpg">'
        '</div>'
        '<script>' +
        r'''player(JSON.parse('[{\u0022number\u0022:1,\u0022name\u0022:\u00221\u0022,\u0022url\u0022:\u0022https:\\\/\\\/embed.test\\\/e\\\/XYZ1\u0022}]')''' +
        '</script></body></html>';
  }
  return '''
<div class="card">
  <a class="card__cover" href="/cn/v/sigl-020"><img class="card__img" data-src="https://img.test/p1.jpg" alt=""></a>
  <div class="card__title">SIGL-020 在线标题</div>
</div>
''';
}

/// JavDB 假取数：搜索按番号精确命中，详情回评分/系列/制作
/// 商/剧照/演员头像。
Future<String> _fakeJavdbFetch(String url) async {
  if (url.contains('/movies/')) {
    return jsonEncode({
      'success': true,
      'data': {
        'actors': [
          {'name': '演员甲', 'avatar_url': 'https://img.test/av-a.jpg'},
        ],
        'preview_images': [
          {'large_url': 'https://img.test/jdb-still.jpg'},
        ],
        'maker_name': '制作商甲',
        'series_name': '系列甲',
        'score': '8.6',
        'score_count': 321,
      },
    });
  }
  return jsonEncode({
    'success': true,
    'data': {
      'movies': [
        {
          'id': 'm1',
          'number': 'SIGL-020',
          'title': 'SIGL-020 样本标题',
          'thumb_url': 'https://img.test/thumb.jpg',
          'cover_url': 'https://img.test/poster.jpg',
          'duration': 7080,
          'release_date': '2024-05-06',
          'score': '8.6',
        },
      ],
    },
  });
}

Future<FeedProbeResponse> _probeOk(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async {
  return FeedProbeResponse(
    statusCode: 200,
    headers: const {},
    headBytes: utf8.encode('#EXTM3U\n#EXT-X-VERSION:3\n'),
  );
}

Future<FeedProbeResponse> _probeDead(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async {
  return const FeedProbeResponse(statusCode: 404, headers: {}, headBytes: []);
}

/// 等真异步（详情装配/竞速/起播都是普通 Future）：真时间轮
/// 询 + pump，直到断言目标出现或超时。
Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  int rounds = 40,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (ready()) return;
    await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 100),
        ));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late LocalStore store;

  setUp(() {
    store = LocalStore();
  });
  tearDown(() => store.dispose());

  Widget app(Widget page) => MaterialApp(home: page);

  /// 高视口：一屏内把详情页各区都建出来（列表是懒加载，
  /// 默认 800×600 下半截区块根本不建、断言无从谈起）。
  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(420, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  ActressWorkDetailPage localPage({
    JavdbApiClient? javdbClient,
    FeedProbeFetch? probeFetch,
    ControlledNativePlayer? player,
  }) {
    return ActressWorkDetailPage.local(
      vodId: 'sigl-020',
      fallback: _fallback(_FakeDb()),
      repository: _FakeRepository(),
      javdbClient: javdbClient,
      probeFetch: probeFetch ?? _probeOk,
      playerFactory: () => player ?? ControlledNativePlayer(),
      playUrlPrep: (url, headers) async => url,
    );
  }

  testWidgets('本地详情：信息卡/简介/演员（含男演员）/分类/线路齐，无评分不出缎带', (
    tester,
  ) async {
    tallView(tester);
    await tester.pumpWidget(app(localPage()));
    await _until(tester, () => find.text('这是 SIGL-020 的简介内容。').evaluate().isNotEmpty);
    // 番号按库里存的原样显示（小写 sigl-020，与用户实报截图一致）。
    expect(find.text('sigl-020'), findsWidgets);
    expect(find.text('2024-05-06'), findsOneWidget);
    expect(find.text('这是 SIGL-020 的简介内容。'), findsOneWidget);
    // 演员区两名都在（含男演员），点名断言。
    expect(
      find.byKey(const ValueKey('work-detail-cast-演员甲')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('work-detail-cast-男演员乙')),
      findsOneWidget,
    );
    // 没评分数据：缎带不出现、信息卡无评分行（不编数字）。
    expect(
      find.byKey(const ValueKey('work-detail-score-ribbon')),
      findsNothing,
    );
    expect(find.textContaining('人评分'), findsNothing);
    // 本地线路行在位。
    expect(
      find.byKey(const ValueKey('work-detail-line-local-0')),
      findsOneWidget,
    );
    // 她们还演出过 / 你可能也喜欢都接上本地库结果。
    expect(find.text('她们还演出过'), findsOneWidget);
    expect(find.text('你可能也喜欢'), findsOneWidget);
  });

  testWidgets('JavDB 补充：评分缎带/系列/制作商/剧照补位', (tester) async {
    tallView(tester);
    await tester.pumpWidget(
      app(localPage(javdbClient: JavdbApiClient(fetch: _fakeJavdbFetch))),
    );
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('work-detail-score-ribbon'))
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey('work-detail-score-ribbon')),
      findsOneWidget,
    );
    expect(find.text('8.6（共 321 人评分）'), findsOneWidget);
    expect(find.text('制作商甲'), findsOneWidget);
    expect(find.text('系列甲'), findsOneWidget);
    // 剧照区由 JavDB 补图出 1 张。
    expect(find.byKey(const ValueKey('work-detail-still-0')), findsOneWidget);
  });

  testWidgets('点海报播放键页内起播：海报区变播放器、线路行标播放中', (tester) async {
    tallView(tester);
    final player = ControlledNativePlayer();
    await tester.pumpWidget(app(localPage(player: player)));
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('work-detail-line-local-0'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('work-detail-poster-play')));
    await _until(
      tester,
      () => player.calls.any((c) => c.startsWith('create:')),
    );
    player.emitFirstFrame();
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('inline-player-toggle'))
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey('inline-player-toggle')),
      findsOneWidget,
    );
    expect(find.text('播放中'), findsOneWidget);
  });

  testWidgets('在线详情（123AV）：剧照出画 + 全部入口，点线路页内起播', (tester) async {
    tallView(tester);
    final player = ControlledNativePlayer();
    await tester.pumpWidget(
      app(
        ActressWorkDetailPage.online(
          source: const Av123ActressSource(),
          card: const OnlineVideoCard(
            pageUrl: 'https://123av.com/cn/v/sigl-020',
            title: 'SIGL-020 在线标题',
            cover: 'https://img.test/p1.jpg',
          ),
          fallback: _fallback(_FakeDb()),
          repository: _FakeRepository(),
          onlineFetch: _fakeAv123Fetch,
          probeFetch: _probeOk,
          playerFactory: () => player,
          playUrlPrep: (url, headers) async => url,
        ),
      ),
    );
    // 剧照 4 张 → 「全部 4 >」入口出现。
    await _until(tester, () => find.text('全部 4 >').evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('work-detail-still-0')), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('work-detail-line-dart-123av')),
    );
    await _until(
      tester,
      () => player.calls.any((c) => c.startsWith('create:')),
    );
    player.emitFirstFrame();
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('inline-player-toggle'))
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey('inline-player-toggle')),
      findsOneWidget,
    );
  });

  testWidgets('全部线路验活不过：海报区落「暂无可播线路」不无限转圈', (tester) async {
    tallView(tester);
    await tester.pumpWidget(
      app(
        ActressWorkDetailPage.online(
          source: const Av123ActressSource(),
          card: const OnlineVideoCard(
            pageUrl: 'https://123av.com/cn/v/sigl-020',
            title: 'SIGL-020 在线标题',
            cover: 'https://img.test/p1.jpg',
          ),
          fallback: _fallback(_FakeDb()),
          repository: _FakeRepository(),
          onlineFetch: _fakeAv123Fetch,
          probeFetch: _probeDead,
          playerFactory: () => ControlledNativePlayer(),
          playUrlPrep: (url, headers) async => url,
        ),
      ),
    );
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('work-detail-line-dart-123av'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('work-detail-poster-play')));
    await _until(
      tester,
      () => find.textContaining('暂无可播线路').evaluate().isNotEmpty,
    );
    expect(find.textContaining('暂无可播线路'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('inline-player-toggle')),
      findsNothing,
    );
  });
}
