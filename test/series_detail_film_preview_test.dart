import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/services/shelf_store.dart';

import 'support/fakes.dart';
import 'support/series_detail_fixtures.dart';

/// 一次性预览截图生成器：把影视区新版式详情页渲染成两张 PNG（顶部播放器 +
/// 毛玻璃详情、滚到底的选集 + 简介），供手机上看版式。跑完即删，不进常
/// 规测试集（写文件、不做断言）。
void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'series-detail-film-preview-',
    );
    Hive.init(directory.path);
    await ShelfStore.instance.init();
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });
  setUp(() async => ShelfStore.instance.clear());

  Future<void> capture(
    WidgetTester tester,
    GlobalKey boundaryKey,
    String path,
  ) async {
    final boundary =
        boundaryKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final data = bytes!.buffer.asUint8List();
    // ignore: avoid_print
    print('preview bytes: ${data.length} -> $path');
    await File(path).writeAsBytes(data);
  }

  testWidgets('preview: film detail top', (tester) async {
    // 不改测试窗口尺寸（默认 800x600），只截顶部真实渲染。

    final boundaryKey = GlobalKey();
    final episodes = [for (var i = 0; i < 3; i++) chapterAt(i)];
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: boundaryKey,
          child: SeriesDetailPage(
            seriesId: 'film-1',
            historyStore: MemoryReaderStore(),
            title: '抽象三国第一季',
            cover: '',
            episodes: episodes,
            seriesLoader: (_) async => seriesDetailFixture(
              episodeCount: episodes.length,
              episodeLabel: '共${episodes.length}集',
            ),
            siteDetailLoader: (_) async => const FilmSiteDetail(
              synopsis: '这是一段影视简介，用于预览毛玻璃详情区的简介行。',
              extra: {'play_from': 'MissAV'},
              stills: [],
            ),
            commentLoader: (_) async => const PlayletCommentPage(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    await capture(
      tester,
      boundaryKey,
      '/home/hatch/workspace/film_detail_preview_top.png',
    );
  });
}
