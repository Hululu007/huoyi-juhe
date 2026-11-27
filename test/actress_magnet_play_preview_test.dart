// 预览图（2026-11-27 磁力播放）：
// 1) 等待态：点「磁力播放」后海报区原地变等待态——状态
//    实显「离线中 45%」+ 进度条 + 取消等待；下载区带
//    「磁力播放」主入口、每行播放钮与「115 网盘 · 会员」标；
// 2) 秒下直接播态：任务首轮即完成，海报区原地换成页内
//    播放器播网盘那一份。
// 全部假件（假库/假 JavDB/假等待器/假播放器）。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_http.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_javdb_api.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_still_capture.dart';
import 'package:fqapp/actress/actress_work_detail_page.dart';
import 'package:fqapp/cloud_drive/auto_offline.dart';
import 'package:fqapp/cloud_drive/cloud_115_offline.dart';
import 'package:fqapp/cloud_drive/magnet_offline.dart';
import 'package:fqapp/cloud_drive/magnet_play.dart';

import 'support/controlled_player.dart';

const _previewDir =
    '/home/hatch/workspace/xiuxian_actress_magnet_play_20261127/previews';
const _boundaryKey = ValueKey<String>('magnet-play-preview-boundary');

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundaryKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$_previewDir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

Widget _scene(Widget child) {
  return RepaintBoundary(
    key: _boundaryKey,
    child: MaterialApp(
      theme: ThemeData(fontFamily: 'NotoSansCJK', brightness: Brightness.dark),
      home: child,
    ),
  );
}

Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  int rounds = 50,
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
  late Directory cacheDir;

  setUp(() {
    store = LocalStore();
    cacheDir = Directory.systemTemp.createTempSync('actress_magnet_prev_');
  });
  tearDown(() {
    store.dispose();
    if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
  });

  ActressWorkDetailPage page({
    required MagnetPlayWaiter magnetPlay,
    ControlledNativePlayer? player,
  }) {
    return ActressWorkDetailPage.local(
      vodId: 'sigl-020',
      fallback: ActressLibraryDbFallback(
        pathResolver: () async => '/fake/女优库.db',
        opener: (path) async => _FakeDb().query,
      ),
      repository: _FakeRepository(),
      javdbClient: JavdbApiClient(fetch: _javdbFetchMagnets),
      onlineFetch: _fetchDead,
      autoOffline: ActressAutoOffline(
        isEnabled: () async => false,
        isLoggedIn: () async => true,
        wasSubmitted: (fp) async => false,
        markSubmitted: (fp) async {},
        taskExists: (code, hash) async => false,
        driveHasFile: (code) async => false,
        submit: (url) async => const Pan115SubmitResult(ok: true),
      ),
      magnetOffline: MagnetOfflineSubmitter(
        isLoggedIn: () async => true,
        submit: (url) async => const Pan115SubmitResult(ok: true),
      ),
      magnetPlay: magnetPlay,
      pan115VipProbe: () async => true,
      stillCache: ActressStillCache(directoryOf: () async => cacheDir),
      probeFetch: _probeOk,
      playerFactory: () => player ?? ControlledNativePlayer(),
      playUrlPrep: (url, headers) async => url,
    );
  }

  MagnetPlayWaiter waiter({
    required List<Pan115OfflineTask> Function(int call) tasksFor,
    int driveHitOnCall = -1,
    Future<void> Function(Duration)? delay,
  }) {
    var findCalls = 0;
    var listCalls = 0;
    return MagnetPlayWaiter(
      isLoggedIn: () async => true,
      findInDrive: (code) async {
        findCalls++;
        if (driveHitOnCall >= 0 && findCalls >= driveHitOnCall) {
          return (
            url: 'https://cdn115.test/sigl-020.m3u8',
            headers: const <String, String>{},
          );
        }
        return null;
      },
      wasSubmitted: (fp) async => false,
      markSubmitted: (fp) async {},
      taskExists: (code, hash) async => false,
      submit: (url) async => const Pan115SubmitResult(ok: true),
      listTasks: () async => tasksFor(++listCalls),
      delay: delay ?? (_) async {},
    );
  }

  testWidgets('预览1：磁力播放等待态（离线中 45%）', (tester) async {
    tester.view.physicalSize = const Size(420, 2300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _scene(
        page(
          magnetPlay: waiter(
            tasksFor: (_) => const [
              Pan115OfflineTask(
                infoHash: '',
                name: 'SIGL-020.mp4',
                percent: 0.45,
                done: false,
              ),
            ],
            delay: (d) => Future<void>.delayed(d),
          ),
        ),
      ),
    );
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('work-detail-magnet-play'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('work-detail-magnet-play')));
    await _until(
      tester,
      () => find.text('离线中 45%').evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await _capture(tester, 'preview_magnet_waiting');
    // 收尾：取消等待并放行挂起的轮询延时。
    await tester.tap(
      find.byKey(const ValueKey('work-detail-magnet-play-cancel')),
    );
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('预览2：秒下直接播态（页内播放器播网盘份）', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final player = ControlledNativePlayer();
    await tester.pumpWidget(
      _scene(
        page(
          magnetPlay: waiter(
            tasksFor: (_) => const [
              Pan115OfflineTask(
                infoHash: '',
                name: 'SIGL-020.mp4',
                percent: 1,
                done: true,
              ),
            ],
            driveHitOnCall: 2,
          ),
          player: player,
        ),
      ),
    );
    // 先等页面加载完（列表出现；_until 带真实异步轮转），
    // 再拖下载区出来点。
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('work-detail-scroll'))
          .evaluate()
          .isNotEmpty,
    );
    for (
      var i = 0;
      i < 20 &&
          find
              .byKey(const ValueKey('work-detail-magnet-play'))
              .evaluate()
              .isEmpty;
      i++
    ) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('work-detail-magnet-play')));
    await _until(
      tester,
      () => player.calls.any(
        (c) => c == 'create:https://cdn115.test/sigl-020.m3u8',
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await _capture(tester, 'preview_magnet_drive_playing');
  });
}

// ---------------------------------------------------------------------------
// 假件（与 actress_magnet_play_test 同形）
// ---------------------------------------------------------------------------

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

Future<String> _javdbFetchMagnets(String url) async {
  if (url.contains('/magnets')) {
    return jsonEncode({
      'success': true,
      'data': {
        'magnets': [
          {
            'hash': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            'name': 'SIGL-020.torrent',
            'size': 5390,
            'created_at': '2026-11-26',
            'hd': true,
          },
          {
            'hash': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            'name': 'SIGL-020.mp4',
            'size': 5390,
            'created_at': '2026-11-26',
            'hd': true,
          },
        ],
      },
    });
  }
  if (url.contains('api/v4/movies/')) {
    return jsonEncode({
      'success': true,
      'data': {
        'movie': {
          'id': 'm1',
          'number': 'SIGL-020',
          'score': '8.6',
          'score_count': 321,
          'preview_images': [
            {'large_url': 'https://img.test/jdb-still.jpg'},
          ],
        },
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
          'cover_url': 'https://img.test/poster.jpg',
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

Future<String> _fetchDead(String url, Map<String, String> headers) async =>
    throw StateError('no network in test');
