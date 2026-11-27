// 演员库全屏修复预览（内嵌态一张）：
//   preview_inline_fullscreen_button.png 详情页内嵌播放态，
//     底部控制行右端有全屏按钮（本次修复新增）。
// 全屏态预览单独在 actress_fullscreen_player_preview_test
// （同进程连着导航出第二张会撞上本环境预览收尾卡死的既有
// 脆弱性，分开跑两张都稳）。
// 假件与 actress_fullscreen_test 同源（假库/假仓储/假
// JavDB/受控播放器），图片走 actress_fixtures 的色块种子。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/actress/actress_adapter_http.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_javdb_api.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_work_detail_page.dart';

import 'actress_fixtures.dart';
import 'preview_test_support.dart';
import 'support/controlled_player.dart';

const _previewDir = '/home/hatch/workspace/xiuxian_actress_fullscreen_20261127/previews';

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

Future<void> _savePng(WidgetTester tester, String name) async {
  final boundary = tester
      .element(find.byType(RepaintBoundary).first)
      .findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes = data!.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  );
  Directory(_previewDir).createSync(recursive: true);
  File('$_previewDir/$name').writeAsBytesSync(bytes);
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

  testWidgets('预览：内嵌播放带全屏按钮', (tester) async {
    await loadPreviewFonts(tester);
    const colors = <String, Color>{
      'https://img.test/poster.jpg': Color(0xFF5B3A8E),
      'https://img.test/av-a.jpg': Color(0xFF2B91AF),
      'https://img.test/jdb-still.jpg': Color(0xFF6C3483),
    };
    for (final entry in colors.entries) {
      final png = await tester.runAsync(() => fakeComicPagePng(entry.value));
      final sample = await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(png!);
        final frame = await codec.getNextFrame();
        return frame.image;
      });
      PaintingBinding.instance.imageCache.putIfAbsent(
        NetworkImage(entry.key),
        () => OneFrameImageStreamCompleter(
          Future.value(ImageInfo(image: sample!)),
        ),
      );
    }
    tester.view.physicalSize = const Size(390, 844);
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
      RepaintBoundary(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'NotoSansCJK',
            ),
          ),
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
    players[0].emitDuration(const Duration(minutes: 118));
    players[0].emitPosition(const Duration(minutes: 6, seconds: 12));
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('inline-player-fullscreen'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 300));
    await _savePng(tester, 'preview_inline_fullscreen_button.png');
    expect(
      find.byKey(const ValueKey('inline-player-fullscreen')),
      findsOneWidget,
    );
  });
}
