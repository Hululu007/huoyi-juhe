// 作品详情页第二棒预览截图：一测一张，输出到
// ~/workspace/xiuxian_actress_ui2_20261127/previews/：
//   preview2_detail.png        详情页（播放键居中、无线路
//                              列表、剧照行有图）
//   preview3_stills_sources.png 剧照补全效果（JavDB 来源与
//                              截帧来源分别标明）
//   preview4_full.png          补齐后详情页全貌（翻译切换/
//                              评分缎带/下载链接区都在）
// 数据全假（假库 + 假 123AV 取数 + 假 JavDB 取数 v4 形状），
// 图片是按地址预埋进图片缓存的合成色块图，不是真封面/真剧照。
// 跑法：单独跑本文件、--no-pub，不要与功能测试混链。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_javdb_api.dart';
import 'package:fqapp/actress/actress_javdb_image.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_neon.dart';
import 'package:fqapp/actress/actress_online_parse.dart';
import 'package:fqapp/actress/actress_online_sources.dart';
import 'package:fqapp/actress/actress_work_detail_page.dart';

import 'actress_fixtures.dart';
import 'preview_test_support.dart';

const _previewDir = '/home/hatch/workspace/xiuxian_actress_ui2_20261127/previews';
const _posterUrl = 'https://img.test/p1.jpg';
const _avatarUrl = 'https://img.test/av-a.jpg';

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
    'pic': _posterUrl,
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
        {'name': '演员甲', 'avatar': _avatarUrl},
        {'name': '男演员乙', 'avatar': ''},
      ];
    }
    if (sql.contains('content AS content')) {
      return [
        {'content': '这是 SIGL-020 的简介内容。预览用假文案，只为看版面。'},
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
      return [
        _row('mida-002', 'MIDA-002 相关作品'),
        _row('sone-003', 'SONE-003 相关作品'),
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

Future<String> _fakeAv123Fetch(
  String url,
  Map<String, String> headers,
) async {
  if (url.contains('/stream')) {
    return '{"media":{"stream":"https://cdn.test/sigl-020.m3u8"}}';
  }
  if (url.contains('/cn/v/')) {
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
  <a class="card__cover" href="/cn/v/sigl-020"><img class="card__img" data-src="$_posterUrl" alt=""></a>
  <div class="card__title">SIGL-020 在线标题</div>
</div>
''';
}

/// JavDB 假取数（v4 形状）：原名/评分/系列/制作商/标签/剧
/// 照/磁力全给，预览里各区形态与真数据一致。
Future<String> _fakeJavdbFetch(String url) async {
  if (url.contains('/magnets')) {
    return jsonEncode({
      'success': true,
      'data': {
        'magnets': [
          {
            'hash': 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
            'name': 'SIGL-020 高清版',
            'size': 5390,
            'created_at': '2026-11-26',
            'hd': true,
            'cnsub': true,
            'seeders': 10,
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
          'origin_title': '原名タイトル（预览假数据）',
          'score': '8.6',
          'score_count': 321,
          'maker_name': '制作商甲',
          'series_name': '系列甲',
          'tags': [
            {'name': '巨乳'},
            {'name': '单体作品'},
          ],
          'actors': [
            {'name': '演员甲', 'avatar_url': _avatarUrl},
          ],
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
          'cover_url': _posterUrl,
          'duration': 118,
          'release_date': '2024-05-06',
          'score': '8.6',
        },
      ],
    },
  });
}

Future<void> _seedImages(WidgetTester tester) async {
  const colors = <String, Color>{
    _posterUrl: Color(0xFF5B3A8E),
    _avatarUrl: Color(0xFF2B91AF),
    'https://img.test/still1.jpg': Color(0xFF8E3A5B),
    'https://img.test/still2.jpg': Color(0xFF3A8E5B),
    'https://img.test/still3.jpg': Color(0xFF8E7A3A),
    'https://img.test/still4.jpg': Color(0xFF3A5B8E),
    'https://img.test/jdb-still.jpg': Color(0xFF6C3483),
    'https://img.test/jdb-still2.jpg': Color(0xFF1F618D),
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
      () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: sample!))),
    );
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 18; i++) {
      try {
        await Future.delayed(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 100));
      } catch (_) {}
    }
  });
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

Widget _wrap(Widget home) {
  return RepaintBoundary(
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        textTheme: ThemeData.dark().textTheme.apply(
          fontFamily: 'NotoSansCJK',
        ),
      ),
      home: DefaultTextStyle(
        style: const TextStyle(fontFamily: 'NotoSansCJK'),
        child: home,
      ),
    ),
  );
}

void main() {
  late LocalStore store;

  setUp(() {
    store = LocalStore();
  });
  tearDown(() => store.dispose());

  testWidgets('preview2 detail: centered play, no lines, stills row', (
    tester,
  ) async {
    await loadPreviewFonts(tester);
    await _seedImages(tester);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = _FakeDb();
    await tester.pumpWidget(
      _wrap(
        ActressWorkDetailPage.online(
          source: const Av123ActressSource(),
          card: const OnlineVideoCard(
            pageUrl: 'https://123av.com/cn/v/sigl-020',
            title: 'SIGL-020 在线标题',
            cover: _posterUrl,
          ),
          fallback: ActressLibraryDbFallback(
            pathResolver: () async => '/fake/女优库.db',
            opener: (path) async => db.query,
          ),
          repository: _FakeRepository(),
          onlineFetch: _fakeAv123Fetch,
          javdbClient: JavdbApiClient(fetch: _fakeJavdbFetch),
        ),
      ),
    );
    await _settle(tester);
    await tester.drag(
      find.byKey(const ValueKey('work-detail-scroll')),
      const Offset(0, -650),
    );
    await _settle(tester);
    expect(find.text('剧照'), findsOneWidget);
    expect(find.text('播放线路'), findsNothing);
    await _savePng(tester, 'preview2_detail.png');
  });

  testWidgets('preview4 full: translate toggle, ribbon, downloads', (
    tester,
  ) async {
    await loadPreviewFonts(tester);
    await _seedImages(tester);
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = _FakeDb();
    await tester.pumpWidget(
      _wrap(
        ActressWorkDetailPage.local(
          vodId: 'sigl-020',
          fallback: ActressLibraryDbFallback(
            pathResolver: () async => '/fake/女优库.db',
            opener: (path) async => db.query,
          ),
          repository: _FakeRepository(),
          javdbClient: JavdbApiClient(fetch: _fakeJavdbFetch),
        ),
      ),
    );
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('work-detail-translate-toggle')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('work-detail-score-ribbon')),
      findsOneWidget,
    );
    expect(find.text('下载链接'), findsOneWidget);
    await _savePng(tester, 'preview4_full.png');
  });

  testWidgets('preview3 stills sources: javdb vs captured frames', (
    tester,
  ) async {
    await loadPreviewFonts(tester);
    await _seedImages(tester);
    // 截帧来源：把三张合成帧图落到临时目录，走 Image.file。
    final frameDir = Directory.systemTemp.createTempSync('preview_frames_');
    addTearDown(() => frameDir.deleteSync(recursive: true));
    final framePaths = <String>[];
    for (final (i, color) in const [
      Color(0xFF7D3C98),
      Color(0xFF117A65),
      Color(0xFF935116),
    ].indexed) {
      final png = await tester.runAsync(
        () => fakeComicPagePng(color, width: 480, height: 300),
      );
      final path = '${frameDir.path}/frame_$i.jpg';
      File(path).writeAsBytesSync(png!);
      framePaths.add(path);
    }
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Widget label(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 18, 0, 8),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    Widget shot(Widget child) => Container(
      width: 168,
      height: 108,
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
    await tester.pumpWidget(
      _wrap(
        Scaffold(
          backgroundColor: Neon.bg,
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '剧照补全效果（预览假数据）',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                label('来源一 · JavDB 预览图'),
                Row(
                  children: [
                    shot(
                      const ActressNetImage(
                        url: 'https://img.test/jdb-still.jpg',
                      ),
                    ),
                    shot(
                      const ActressNetImage(
                        url: 'https://img.test/jdb-still2.jpg',
                      ),
                    ),
                  ],
                ),
                label('来源二 · 在线流截帧（本地缓存）'),
                // 三帧横排超画布宽：套横向滚动（与 App 剧照行
                // 同形态），不触发溢出条纹。
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final path in framePaths)
                        shot(Image.file(File(path), fit: BoxFit.cover)),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'JavDB 有剧照用 JavDB 的；没有才截帧，截到的帧存本地缓存，重开不重截。',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    await _savePng(tester, 'preview3_stills_sources.png');
  });
}
