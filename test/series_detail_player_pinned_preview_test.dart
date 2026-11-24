import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'preview_test_support.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/shelf_store.dart';

import 'support/fakes.dart';
import 'support/series_detail_fixtures.dart';

/// 详情页播放器固定预览图：测试渲染出 PNG，不构建整包。
///
/// 竖屏手机面（390x844）上截两张：滑动前（顶部）与把详情内容往上滑
/// 800 之后——两张里播放器都应在顶部同一位置，只有下面的详情内容变了。
/// 注：原 390x1600 下详情内容总高（约 1280）小于滚动区（约 1380），
/// 拖不动、两张图逐字节相同，证不出固定；改 390x844 后内容可滚，
/// 第二张才真正是滑后的样子。封面与剧照留空（黑底播放器 + 播放钮），
/// 只证布局固定，不证图片加载。
Future<void> _capture(
  WidgetTester tester,
  ValueKey<String> boundaryKey,
  String path,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(boundaryKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'series-detail-player-pinned-preview-test-',
    );
    Hive.init(directory.path);
    await ShelfStore.instance.init();
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });
  setUp(() async => ShelfStore.instance.clear());

  testWidgets('预览：详情页上下滑，播放器固定在顶部', (tester) async {
    await loadPreviewFonts(tester, lucide: true);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    final chapters = <Chapter>[for (var i = 0; i < 8; i++) chapterAt(i)];
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: 'NotoSansCJK',
          ),
          home: RepaintBoundary(
            key: const ValueKey<String>('player-pinned-preview'),
            child: SeriesDetailPage(
              seriesId: 'film-1',
              historyStore: MemoryReaderStore(),
              title: '抽象三国第一季',
              cover: '',
              episodes: chapters,
              seriesLoader: (_) async => seriesDetailFixture(
                episodeCount: chapters.length,
                episodeLabel: '共${chapters.length}集',
              ),
              siteDetailLoader: (_) async => const FilmSiteDetail(
                synopsis:
                    '东汉末年分三国，烽火连天不休。刘备、关羽、张飞桃园结义，'
                    '立志匡扶汉室；曹操挟天子以令诸侯，孙权坐断东南。'
                    '这是一段用搞笑口吻重讲的三国故事。',
                extra: {'play_from': 'MissAV'},
                stills: [],
              ),
              commentLoader: (_) async => const PlayletCommentPage(),
              contentLoader: (_, _) async =>
                  throw Exception('test-no-stream'),
              relatedLoader: (_) async => const [
                DramaSiteItem(id: 'rel-1', title: '推荐一', cover: ''),
                DramaSiteItem(id: 'rel-2', title: '推荐二', cover: ''),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
    });

    final player = find.byKey(const ValueKey('film-inline-player'));
    expect(player, findsOneWidget);
    final topBefore = tester.getTopLeft(player);
    await _capture(
      tester,
      const ValueKey<String>('player-pinned-preview'),
      previewOutPath('player_pinned_top.png'),
    );

    // 把详情内容往上滑 800：播放器不动，标题往上走。
    await tester.drag(
      find.byKey(const ValueKey('series-detail-content')),
      const Offset(0, -800),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.getTopLeft(player), topBefore);
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('film-detail-title')))
          .dy,
      lessThan(400),
    );
    await _capture(
      tester,
      const ValueKey<String>('player-pinned-preview'),
      previewOutPath('player_pinned_scrolled.png'),
    );
    expect(tester.takeException(), isNull);
  });
}
