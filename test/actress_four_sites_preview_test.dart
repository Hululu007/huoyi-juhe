// 演员库四站接入（工人 D）预览⑤：顶部源条接完后的主页
// （六段页签：女优库 / 123AV / PH / MissAV / 潮流 / 18AV，
// 在线段带未验小标；420 宽下后段溢出、横滑可见）。
// 输出两张：preview5_source_bar.png（初始态）、
// preview5_source_bar_scrolled.png（横滑后露出 18AV）。
// 数据是假库 + 假仓储，不走真网。单独跑本文件、--no-pub。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_library_native_page.dart';

import 'preview_test_support.dart';

const _previewDir = '/home/hatch/workspace/xiuxian_actress_ui2_20261127/previews';
const _coverUrl = 'https://v.hersav.me/images/av/preview-sample.jpg';

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

  Map<String, Object?> _videoRow(String id, String title) => {
    'vodId': id,
    'title': title,
    'pic': _coverUrl,
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
      return [_videoRow('rank-001', '排行榜作品')];
    }
    if (sql.contains('category_name AS name')) {
      return [
        {'name': '中文字幕', 'cnt': 3631},
      ];
    }
    if (sql.contains('FROM actresses a')) {
      return [
        {'name': '演员甲', 'avatar': '', 'cnt': 42},
        {'name': '演员乙', 'avatar': '', 'cnt': 7},
      ];
    }
    if (sql.contains('FROM videos v')) {
      return [
        _videoRow('ssis-001', 'SSIS-001 预览作品一'),
        _videoRow('mida-002', 'MIDA-002 预览作品二'),
        _videoRow('ipx-003', 'IPX-003 预览作品三'),
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
  }) async => CatalogPage([
    for (var i = 1; i <= 6; i++)
      Drama(
        id: '$source-$i',
        source: source,
        title: '$source 在线作品 $i',
        cover: _coverUrl,
      ),
  ], page: page);

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async =>
      CatalogPage(const []);

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
  testWidgets('预览⑤：顶部源条六段页签 + 横滑形态', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await loadPreviewFonts(tester);
    final store = LocalStore();
    addTearDown(store.dispose);
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
            child: ActressLibraryNativePage(
              repository: _FakeRepository(),
              store: store,
              fallback: ActressLibraryDbFallback(
                pathResolver: () async => '/fake/女优库.db',
                opener: (path) async => db.query,
              ),
              onlineFetch: (url, headers) async => '',
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      for (var i = 0; i < 15; i++) {
        await Future.delayed(const Duration(milliseconds: 150));
        await tester.pump(const Duration(milliseconds: 80));
      }
    });
    await _savePng(tester, 'preview5_source_bar.png');
    // 横滑形态由图里后段页签被右缘截断体现；横滑可达性
    // （滑后 18AV 可见可点）由 actress_four_sites_widget_test
    // 的源条用例断言（预览里再拖一次截图曾挂死在捕获上，
    // 按预览单跑教训不在预览文件里做拖动截图）。
  });
}
