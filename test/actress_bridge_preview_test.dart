// 演员库桥接＋补全批预览（2026-11-27）：一测一张，输出
// PNG 到 ~/workspace/xiuxian_actress_bridge_20261127/
// previews/。数据全假件（假仓储/假库/假 JavDB/活站结构
// 夹具），封面预埋合成图，不走真网。
// 跑法：单独跑本文件、--no-pub，不与功能测试混链。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
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
import 'package:fqapp/actress/actress_library_native_page.dart';
import 'package:fqapp/actress/actress_online_parse.dart';
import 'package:fqapp/actress/actress_py_lines.dart';
import 'package:fqapp/actress/actress_site_bridge.dart';
import 'package:fqapp/actress/actress_still_capture.dart';
import 'package:fqapp/actress/actress_work_detail_page.dart';

import 'actress_fixtures.dart';
import 'preview_test_support.dart';
import 'support/controlled_player.dart';

const _previewDir =
    '/home/hatch/workspace/xiuxian_actress_bridge_20261127/previews';

const _liveListHtml = '''
<div class='post video_9s'>
<figure class='video-preview thumb'>
<a  target="_top"  href="https://18av.nl/zh/chinese_content/344250/HMN-834.html"><img src='https://stimg1.test/426873_HMN-834.jpg' class='thumb'><video loop='true' muted='true' playsinline='true' poster='' data-src='https://gifb.test/426873_HMN-834.mp4' src='' autoplay='true' class='thumb'></video><div class='video-loader' style='visibility: hidden;'><div class='spinner-border text-pink'></div></div></a>
</figure>
<div class='con'>
<h3 itemprop='name headline'><a  target="_top"  href="https://18av.nl/zh/chinese_content/344250/HMN-834.html">[中字]HMN-834 因為性無能而開始使用成人網站的年輕太太</a></h3>
<div class='meta'>2026/11/27</div>
</div>
</div>
<div class='post video_9s'>
<figure class='video-preview thumb'>
<a  target="_top"  href="https://18av.nl/zh/chinese_content/344249/MIAB-662.html"><img src='https://stimg1.test/426687_MIAB-662.jpg' class='thumb'><video loop='true' class='thumb'></video></a>
</figure>
<div class='con'>
<h3 itemprop='name headline'><a  target="_top"  href="https://18av.nl/zh/chinese_content/344249/MIAB-662.html">[中字]MIAB-662 當了紀念裸模代班的我</a></h3>
<div class='meta'>2026/11/27</div>
</div>
</div>
<div class='post video_9s'>
<figure class='video-preview thumb'>
<a  target="_top"  href="https://18av.nl/zh/chinese_content/344248/IPZZ-874.html"><img src='https://stimg1.test/426688_IPZZ-874.jpg' class='thumb'><video loop='true' class='thumb'></video></a>
</figure>
<div class='con'>
<h3 itemprop='name headline'><a  target="_top"  href="https://18av.nl/zh/chinese_content/344248/IPZZ-874.html">[中字]IPZZ-874 通勤時擦肩而過的制服美少女</a></h3>
<div class='meta'>2026/11/27</div>
</div>
</div>
<div class='post video_9s'>
<figure class='video-preview thumb'>
<a  target="_top"  href="https://18av.nl/zh/chinese_content/344247/JUFE-621.html"><img src='https://stimg1.test/426689_JUFE-621.jpg' class='thumb'><video loop='true' class='thumb'></video></a>
</figure>
<div class='con'>
<h3 itemprop='name headline'><a  target="_top"  href="https://18av.nl/zh/chinese_content/344247/JUFE-621.html">[中字]JUFE-621 用著成熟的身體教導著年輕肉棒的巨乳媽媽朋友</a></h3>
<div class='meta'>2026/11/27</div>
</div>
</div>
''';

Future<String> _onlineFetch(String url, Map<String, String> headers) async =>
    _liveListHtml;

/// JavDB 假取数（v4 形状，UMSO-659 满字段）：搜索命中 →
/// 详情（日期/时长/制作商/评分/演员/标签/剧照）→ 磁力。
Future<String> _javdbFetch(String url) async {
  if (url.contains('/magnets')) {
    return jsonEncode({
      'success': true,
      'data': {
        'magnets': [
          {
            'hash': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            'name': 'UMSO-659 高清版',
            'size': 4230,
            'created_at': '2025-09-20',
            'hd': true,
            'cnsub': true,
            'seeders': 42,
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
          'id': 'm9',
          'number': 'UMSO-659',
          'title': 'UMSO-659 光泽绽放的曲线美巨乳若妻出差按摩',
          'release_date': '2025-09-12',
          'duration': 118,
          'maker_name': '样本制作商',
          'score': '7.9',
          'score_count': 456,
          'actors': [
            {'name': '鈴木真夕', 'avatar_url': 'https://img.test/mayu.jpg'},
          ],
          'tags': [
            {'name': '巨乳'},
            {'name': '人妻'},
            {'name': '按摩'},
          ],
          'preview_images': [
            {'large_url': 'https://img.test/still1.jpg'},
            {'large_url': 'https://img.test/still2.jpg'},
            {'large_url': 'https://img.test/still3.jpg'},
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
          'id': 'm9',
          'number': 'UMSO-659',
          'title': 'UMSO-659 光泽绽放的曲线美巨乳若妻出差按摩',
          'cover_url': 'https://img.test/umso.jpg',
        },
      ],
    },
  });
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 25; i++) {
      try {
        await Future.delayed(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 100));
      } catch (_) {}
    }
  });
}

/// 源条是横滑懒建列表：目标段没建出来前先拖条，拖到建出
/// 为止（桥接段在尾段，要多拖几下）。
Future<void> _revealChip(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
    await tester.drag(
      find.byKey(const ValueKey('native-source-bar-scroll')),
      const Offset(-320, 0),
    );
    await tester.pump(const Duration(milliseconds: 120));
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

Future<void> _preloadCovers(WidgetTester tester, List<String> urls) async {
  final png = await tester.runAsync(
    () => fakeComicPagePng(const Color(0xFF5B3A8E)),
  );
  final sample = await tester.runAsync(() async {
    final codec = await ui.instantiateImageCodec(png!);
    final frame = await codec.getNextFrame();
    return frame.image;
  });
  for (final url in urls) {
    PaintingBinding.instance.imageCache.putIfAbsent(
      NetworkImage(url),
      () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: sample!))),
    );
  }
}

class _EmptyCapturer implements ActressStillCapturer {
  @override
  Future<List<Uint8List>> captureFrames({
    required String url,
    Map<String, String> headers = const {},
    int count = 5,
  }) async => const [];
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

/// 假仓储：分类两档；目录按站回四张番号卡。
class _FakeRepository extends AppRepository {
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [
    CatalogCategory('c1', '最新'),
    CatalogCategory('c2', '人妻'),
  ];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async => CatalogPage([
    const Drama(
      id: 'umso-659',
      source: 'fake',
      title: 'UMSO-659 光泽绽放的曲线美巨乳若妻出差按摩',
      cover: 'https://img.test/umso.jpg',
    ),
    const Drama(
      id: 'abf-352',
      source: 'fake',
      title: 'ABF-352 在地的後輩送上來的未婚妻',
      cover: 'https://img.test/abf.jpg',
    ),
    const Drama(
      id: 'hmn-834',
      source: 'fake',
      title: 'HMN-834 年輕太太被勾引',
      cover: 'https://img.test/hmn.jpg',
    ),
    const Drama(
      id: 'ssis-001',
      source: 'fake',
      title: 'SSIS-001 样本标题',
      cover: 'https://img.test/ssis.jpg',
    ),
  ], page: page);

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
    Episode({'id': 'https://example.test/v.m3u8', 'title': '正片'}, 1),
  ]);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async => const PlaybackPlan(url: 'https://example.test/v.m3u8');
}

/// 假库：sameCode 回 UMSO-659 的简介（详情预览用），其余
/// 查询回空；原生页本地段只求不崩。
class _FakeDb {
  _FakeDb();

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
    if (sql.contains('vod_id IN (')) {
      if (sql.contains('content AS content')) {
        return [
          {'content': '若妻在出差地接受按摩服务，曲线与光泽在镜头前绽放。（本地库同番号行简介）'},
        ];
      }
      if (sql.contains('a.avatar AS avatar')) {
        return [
          {'name': '鈴木真夕', 'avatar': 'https://img.test/mayu.jpg'},
        ];
      }
    }
    return [];
  }
}

void main() {
  late LocalStore store;
  late Directory cacheDir;

  setUp(() {
    store = LocalStore();
    cacheDir = Directory.systemTemp.createTempSync('bridge_preview_');
  });
  tearDown(() {
    store.dispose();
    if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
  });

  ThemeData theme() => ThemeData.dark().copyWith(
    textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'NotoSansCJK'),
  );

  void phoneView(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('preview topbar: 桥接站与六段同排平铺', (tester) async {
    await loadPreviewFonts(tester);
    await _preloadCovers(tester, const [
      'https://img.test/umso.jpg',
      'https://img.test/abf.jpg',
      'https://img.test/hmn.jpg',
      'https://img.test/ssis.jpg',
    ]);
    phoneView(tester);
    final db = _FakeDb();
    await tester.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(),
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'NotoSansCJK'),
            child: ActressLibraryNativePage(
              repository: _FakeRepository(),
              store: store,
              onlineFetch: _onlineFetch,
              fallback: ActressLibraryDbFallback(
                pathResolver: () async => '/fake/女优库.db',
                opener: (path) async => db.query,
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    // 点开第一个桥接段（ABJAV），源条里桥接段与既有六段同排。
    await _revealChip(tester, 'native-source-bridge-seed_abjav');
    final chip = find.byKey(const ValueKey('native-source-bridge-seed_abjav'));
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await _settle(tester);
    expect(find.textContaining('UMSO-659'), findsWidgets);
    await _savePng(tester, 'preview_topbar_bridge.png');
  });

  testWidgets('preview 18av list: 活站结构出卡', (tester) async {
    await loadPreviewFonts(tester);
    await _preloadCovers(tester, const [
      'https://stimg1.test/426873_HMN-834.jpg',
      'https://stimg1.test/426687_MIAB-662.jpg',
      'https://stimg1.test/426688_IPZZ-874.jpg',
      'https://stimg1.test/426689_JUFE-621.jpg',
    ]);
    phoneView(tester);
    final db = _FakeDb();
    await tester.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(),
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'NotoSansCJK'),
            child: ActressLibraryNativePage(
              repository: _FakeRepository(),
              store: store,
              onlineFetch: _onlineFetch,
              fallback: ActressLibraryDbFallback(
                pathResolver: () async => '/fake/女优库.db',
                opener: (path) async => db.query,
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    await _revealChip(tester, 'native-source-av18');
    final chip = find.byKey(const ValueKey('native-source-av18'));
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await _settle(tester);
    expect(find.textContaining('HMN-834'), findsWidgets);
    expect(find.textContaining('暂时没有内容'), findsNothing);
    await _savePng(tester, 'preview_av18_list.png');
  });

  testWidgets('preview detail: UMSO-659 在线入口补满', (tester) async {
    await loadPreviewFonts(tester);
    await _preloadCovers(tester, const [
      'https://img.test/umso.jpg',
      'https://img.test/still1.jpg',
      'https://img.test/still2.jpg',
      'https://img.test/still3.jpg',
      'https://img.test/mayu.jpg',
    ]);
    tester.view.physicalSize = const Size(390, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = _FakeDb();
    final source = ActressBridgedSiteSource(
      ActressPyBridge(_FakeRepository()),
      station: kActressBridgedSites[2],
    );
    await tester.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(),
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'NotoSansCJK'),
            child: ActressWorkDetailPage.online(
              source: source,
              card: const OnlineVideoCard(
                pageUrl: 'umso-659',
                title: 'UMSO-659 光泽绽放的曲线美巨乳若妻出差按摩',
                cover: 'https://img.test/umso.jpg',
              ),
              fallback: ActressLibraryDbFallback(
                pathResolver: () async => '/fake/女优库.db',
                opener: (path) async => db.query,
              ),
              repository: _FakeRepository(),
              onlineFetch: (url, headers) async => '',
              javdbClient: JavdbApiClient(fetch: _javdbFetch),
              stillCapturer: _EmptyCapturer(),
              stillCache: ActressStillCache(directoryOf: () async => cacheDir),
              probeFetch: _probeOk,
              playerFactory: () => ControlledNativePlayer(),
              playUrlPrep: (url, headers) async => url,
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('UMSO-659'), findsWidgets);
    expect(find.textContaining('本地库同番号行简介'), findsOneWidget);
    await _savePng(tester, 'preview_detail_umso_filled.png');
  });
}
