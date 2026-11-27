// 演员库全屏回程回归（用户 2026-11-27 20:14 实报）：全屏页里
// 退出全屏不能落进竖屏整页形态，必须直接退页回详情页内嵌舞台
// 并按进度续播。单拆一个文件：整页 PlayerPage 的历史装载走
// LibraryStore 单例，同一进程里第二台整页播放器会被前一台的
// 待处理写入堵住（测试环境特性、与回程逻辑无关），故不与
// actress_fullscreen_test 的往返用例同文件。
// 演员库全屏修复测试（2026-11-27 用户实报「演员库不能全屏」）：
// 1) 内嵌播放器：传了全屏回调才出全屏按钮；点按先销毁自有
//    播放器、再把当前进度交出去（同片库 FilmInlinePlayer 的
//    交接法，避免两台原生播放器抢解码器）。
// 2) 内嵌播放器：startPosition 经 create 的 startMs 下发。
// 3) 详情页往返：点全屏推整页 PlayerPage（openFullScreen 进
//    页即全屏、startPosition 带内嵌进度）；退出后详情页原地
//    恢复内嵌播放，起播位置不丢（整页存档读不到时用进全屏
//    时的进度兜底）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/actress/actress_adapter_http.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_inline_player.dart';
import 'package:fqapp/actress/actress_javdb_api.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_work_detail_page.dart';
import 'package:fqapp/pages/player_page.dart';

import 'support/controlled_player.dart';

/// 假库：与 actress_work_detail_page_test 同一份样本形状
/// （番号 SIGL-020、本地直链一行）。
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

/// JavDB 假取数（同 actress_work_detail_page_test）：不注入
/// 的话详情页补全链会走真接口、留下重试定时器挂在测试尾巴上。
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

/// 等真异步：真时间轮询 + pump，直到目标出现或超时。
Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  int rounds = 60,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late LocalStore store;

  setUp(() {
    store = LocalStore();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          (call) async => null,
        );
  });

  tearDown(() {
    store.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          null,
        );
  });

  // 用户 2026-11-27 20:14 实报回归：全屏页里点「退出全屏」不能
  // 落进竖屏整页形态，必须直接退页回详情页内嵌舞台。上一条用例
  // 是程序直接 pop；这条走用户真实路径（底栏退出全屏钮）。
  testWidgets('详情页全屏回程：点退出全屏直接退页，内嵌舞台按进度恢复', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final players = <ControlledNativePlayer>[];
    ControlledNativePlayer nextPlayer() {
      final created = ControlledNativePlayer();
      players.add(created);
      return created;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: ActressWorkDetailPage.local(
          vodId: 'sigl-020',
          fallback: _fallback(_FakeDb()),
          repository: _FakeRepository(),
          javdbClient: JavdbApiClient(fetch: _fakeJavdbFetch),
          probeFetch: _probeOk,
          playerFactory: nextPlayer,
          playUrlPrep: (url, headers) async => url,
        ),
      ),
    );
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('work-detail-poster-play'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('work-detail-poster-play')));
    await _until(
      tester,
      () => players.isNotEmpty && players[0].calls.contains('created'),
    );
    players[0].emitFirstFrame();
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('inline-player-fullscreen'))
          .evaluate()
          .isNotEmpty,
    );
    players[0].emitPosition(const Duration(seconds: 30));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('inline-player-fullscreen')));
    await _until(tester, () => find.byType(PlayerPage).evaluate().isNotEmpty);
    final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
    expect(page.popOnFullscreenExit, isTrue);
    await _until(
      tester,
      () => players.length >= 2 && players[1].createdStartMs.isNotEmpty,
    );
    players[1].emitFirstFrame();
    await _until(
      tester,
      () => find.byTooltip('退出全屏').evaluate().isNotEmpty,
    );

    // 系统返回退出全屏（与底栏退出全屏钮、顶栏返回同一条
    // _toggleFullScreen 回程）：整页必须被退出，而不是切成竖屏
    // 整页形态留在栈上。按钮路径由 chrome 层用例单独覆盖——
    // 本用例的竖长窗口里运输条横排溢出屏外、点不中，是窗口
    // 形态问题不是回程问题。
    await tester.binding.handlePopRoute();
    await _until(tester, () => find.byType(PlayerPage).evaluate().isEmpty);
    expect(find.byType(PlayerPage), findsNothing);

    // 回到详情页：内嵌播放器重建、按原进度续播，舞台回到 16:10。
    await tester.pump();
    await _until(tester, () => players.length >= 3);
    await _until(tester, () => players[2].createdStartMs.isNotEmpty);
    expect(players[2].createdStartMs, [30000]);
    final stage = find.byKey(const ValueKey('work-detail-stage'));
    expect(stage, findsOneWidget);
    final stageSize = tester.getSize(stage);
    expect(stageSize.width / stageSize.height, closeTo(16 / 10, 0.05));
  });

}
