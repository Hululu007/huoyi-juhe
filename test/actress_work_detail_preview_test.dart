// 作品详情页预览截图：一测一张，输出三张 PNG 到
// ~/workspace/xiuxian_actress_playfix_20261127/：
//   preview_detail_top.png    上半（钉顶栏/海报墙/信息卡/分类/演员）
//   preview_detail_bottom.png 下半（剧照/播放线路/还演出过/可能喜欢）
//   preview_stills_viewer.png 剧照全屏浏览
// 数据全假（假库 + 假 123AV 取数 + 假 JavDB 取数），图片是按
// 地址预埋进图片缓存的合成色块图，不是真封面/真剧照；海报区
// 是未起播形态（播放器起播形态见功能测试断言）。
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
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_online_parse.dart';
import 'package:fqapp/actress/actress_online_sources.dart';
import 'package:fqapp/actress/actress_work_detail_page.dart';

import 'actress_fixtures.dart';
import 'preview_test_support.dart';

const _previewDir = '/home/hatch/workspace/xiuxian_actress_playfix_20261127';
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
    if (sql.contains('SELECT content FROM videos')) {
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
        _row('ipx-004', 'IPX-004 相关作品'),
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
  <a class="card__cover" href="/cn/v/sigl-020"><img class="card__img" data-src="$_posterUrl" alt=""></a>
  <div class="card__title">SIGL-020 在线标题</div>
</div>
''';
}

Future<String> _fakeJavdbFetch(String url) async {
  if (url.contains('/movies/')) {
    return jsonEncode({
      'success': true,
      'data': {
        'actors': [
          {'name': '演员甲', 'avatar_url': _avatarUrl},
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
          'cover_url': _posterUrl,
          'duration': 7080,
          'release_date': '2024-05-06',
          'score': '8.6',
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
  });
  tearDown(() => store.dispose());

  Future<void> pumpPage(WidgetTester tester) async {
    await loadPreviewFonts(tester);
    // 图片预埋：每张图一个合成色块，按地址塞进图片缓存。
    const colors = <String, Color>{
      _posterUrl: Color(0xFF5B3A8E),
      _avatarUrl: Color(0xFF2B91AF),
      'https://img.test/still1.jpg': Color(0xFF8E3A5B),
      'https://img.test/still2.jpg': Color(0xFF3A8E5B),
      'https://img.test/still3.jpg': Color(0xFF8E7A3A),
      'https://img.test/still4.jpg': Color(0xFF3A5B8E),
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
    final db = _FakeDb();
    await tester.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'NotoSansCJK',
            ),
          ),
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'NotoSansCJK'),
            child: ActressWorkDetailPage.online(
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
        ),
      ),
    );
    await _settle(tester);
  }

  testWidgets('preview detail top', (tester) async {
    await pumpPage(tester);
    expect(
      find.byKey(const ValueKey('work-detail-poster-play')),
      findsOneWidget,
    );
    await _savePng(tester, 'preview_detail_top.png');
  });

  testWidgets('preview detail bottom', (tester) async {
    await pumpPage(tester);
    // 滚到剧照与线路区。
    await tester.drag(
      find.byKey(const ValueKey('work-detail-scroll')),
      const Offset(0, -650),
    );
    await _settle(tester);
    expect(find.text('剧照'), findsOneWidget);
    await _savePng(tester, 'preview_detail_bottom.png');
  });

  testWidgets('preview stills viewer', (tester) async {
    await pumpPage(tester);
    await tester.drag(
      find.byKey(const ValueKey('work-detail-scroll')),
      const Offset(0, -650),
    );
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('work-detail-still-0')));
    await _settle(tester);
    await _savePng(tester, 'preview_stills_viewer.png');
  });
}
