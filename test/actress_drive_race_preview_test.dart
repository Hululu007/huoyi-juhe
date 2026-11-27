// 预览图（2026-11-27 两活）：
// 1) 开页自动离线后：下载区状态小字「已自动提交到 115 离线
//    下载」+ 交的那行「已提交」标；
// 2) 网盘池命中起播：本地线死、网盘直链赢下竞速，海报区变
//    页内播放器。
// 全部假件（假库/假 JavDB/假自动离线/假找片器/假播放器）。
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
import 'package:fqapp/cloud_drive/cloud_drive_types.dart';
import 'package:fqapp/cloud_drive/cloud_providers.dart';
import 'package:fqapp/cloud_drive/drive_code_play.dart';

import 'support/controlled_player.dart';

const _previewDir =
    '/home/hatch/workspace/xiuxian_actress_drive_race_20261127/previews';
const _boundaryKey = ValueKey<String>('drive-race-preview-boundary');

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
      ];
    }
    if (sql.contains('content AS content')) {
      return [
        {'content': '简介内容。'},
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
      ];
    }
    if (sql.contains('SELECT tag_name AS name FROM video_tag')) {
      return [
        {'name': '剧情'},
      ];
    }
    if (sql.contains('FROM videos v')) {
      if (sql.contains('WHERE v.vod_id = ?')) {
        return [
          {
            'vodId': 'sigl-020',
            'title': 'SIGL-020 样本标题',
            'pic': 'https://img.test/poster.jpg',
            'play': 'https://v.hersav.me/abc/abc.m3u8',
            'playAlt': '',
            'date': '2024-05-06',
            'typeName': '剧情',
            'actress': '演员甲',
          },
        ];
      }
      return [
        {
          'vodId': 'mida-002',
          'title': 'MIDA-002 相关作品',
          'pic': 'https://img.test/poster.jpg',
          'play': '',
          'playAlt': '',
          'date': '',
          'typeName': '',
          'actress': '演员甲',
        },
      ];
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

Future<String> _javdbFetch(String url) async {
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

Future<FeedProbeResponse> _probeDriveOnly(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async {
  if (url.contains('cdn115.test')) {
    return FeedProbeResponse(
      statusCode: 200,
      headers: const {},
      headBytes: utf8.encode('#EXTM3U\n#EXT-X-VERSION:3\n'),
    );
  }
  return const FeedProbeResponse(statusCode: 404, headers: {}, headBytes: []);
}

Future<String> _fetchDead(String url, Map<String, String> headers) async =>
    throw StateError('no network in preview');

void main() {
  late LocalStore store;
  late Directory cacheDir;

  setUp(() {
    store = LocalStore();
    cacheDir = Directory.systemTemp.createTempSync('actress_race_prev_');
  });
  tearDown(() {
    store.dispose();
    if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
  });

  ActressWorkDetailPage page({
    ActressAutoOffline? autoOffline,
    DriveCodePlayFinder? drivePlayFinder,
    ControlledNativePlayer? player,
  }) {
    return ActressWorkDetailPage.local(
      vodId: 'sigl-020',
      fallback: ActressLibraryDbFallback(
        pathResolver: () async => '/fake/女优库.db',
        opener: (path) async => _FakeDb().query,
      ),
      repository: _FakeRepository(),
      javdbClient: JavdbApiClient(fetch: _javdbFetch),
      onlineFetch: _fetchDead,
      autoOffline: autoOffline,
      drivePlayFinder: drivePlayFinder,
      stillCache: ActressStillCache(directoryOf: () async => cacheDir),
      probeFetch: _probeDriveOnly,
      playerFactory: () => player ?? ControlledNativePlayer(),
      playUrlPrep: (url, headers) async => url,
    );
  }

  testWidgets('预览1：开页自动离线后的下载区状态', (tester) async {
    tester.view.physicalSize = const Size(420, 2300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final autoOffline = ActressAutoOffline(
      isEnabled: () async => true,
      isLoggedIn: () async => true,
      wasSubmitted: (fp) async => false,
      markSubmitted: (fp) async {},
      taskExists: (code, hash) async => false,
      driveHasFile: (code) async => false,
      submit: (url) async => const Pan115SubmitResult(ok: true),
    );
    await tester.pumpWidget(_scene(page(autoOffline: autoOffline)));
    await _until(
      tester,
      () => find.text('已自动提交到 115 离线下载').evaluate().isNotEmpty,
    );
    expect(find.text('已自动提交到 115 离线下载'), findsOneWidget);
    expect(find.text('已提交'), findsOneWidget);
    await _capture(tester, 'preview_auto_offline_status');
  });

  testWidgets('预览2：网盘池命中起播（海报区变播放器）', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final player = ControlledNativePlayer();
    final driveFinder = DriveCodePlayFinder(
      isLoggedIn: () async => true,
      search: (keyword) async => [
        const CloudDriveFile(
          id: 'f1',
          name: 'SIGL-020.mp4',
          isFolder: false,
          kind: CloudFileKind.video,
        ),
      ],
      directLink: (file) async =>
          const CloudDirectLink(url: 'https://cdn115.test/sigl-020.m3u8'),
    );
    await tester.pumpWidget(
      _scene(page(drivePlayFinder: driveFinder, player: player)),
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
      () => player.calls.any(
        (c) => c == 'create:https://cdn115.test/sigl-020.m3u8',
      ),
    );
    player.emitFirstFrame();
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('inline-player-toggle'))
          .evaluate()
          .isNotEmpty,
    );
    await _capture(tester, 'preview_drive_pool_playing');
  });
}
