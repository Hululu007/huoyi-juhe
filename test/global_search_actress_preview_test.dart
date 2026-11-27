// 首页全局搜索演员库段预览（2026-11-27）：一测一张，输出
// PNG 到 ~/workspace/xiuxian_global_search_20261127/previews/。
// 数据全假件（假番茄 loader + 假演员库取数），封面/头像留
// 空走占位，只证版式。跑法：单独跑本文件、--no-pub，不与
// 功能测试混链。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/actress/actress_global_search.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/search_page.dart';

import 'preview_test_support.dart';

const _previewDir =
    '/home/hatch/workspace/xiuxian_global_search_20261127/previews';

Future<List<SearchTab>> _fanqieLoader(
  String query, {
  required int tabType,
  required int offset,
}) async => [
  SearchTab(
    title: '综合',
    items: [
      for (var i = 1; i <= 2; i++)
        MediaItem(
          id: 'fx-$i',
          title: '站内结果 $i',
          cover: '',
          author: '',
          badge: '',
          ep: '',
          kind: 'video',
        ),
    ],
    hasMore: false,
  ),
];

ActressGlobalSearchResult _fakeResult() => ActressGlobalSearchResult(
  actresses: [
    {'name': '三上悠亚', 'avatar': '', 'count': 128},
    {'name': '河北彩花', 'avatar': '', 'count': 96},
    {'name': '枫可怜', 'avatar': '', 'count': 54},
    {'name': '美谷朱里', 'avatar': '', 'count': 41},
  ],
  works: [
    for (var i = 1; i <= 3; i++)
      {
        'vodId': 'ssis-00$i',
        'title': '预览作品 $i（封面占位）',
        'pic': '',
        'code': 'ssis-00$i',
        'date': '2024-0$i-01',
        'actress': '三上悠亚',
      },
  ],
  actressesHasMore: true,
  worksHasMore: true,
);

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
  setUp(
    () => SharedPreferences.setMockInitialValues({'search_list_view': false}),
  );

  Future<void> pumpPage(WidgetTester tester, {required bool enabled}) async {
    // 逻辑高 1100：三段（站点/演员/作品）一屏装下同框。
    tester.view.physicalSize = const Size(780, 2200);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await loadPreviewFonts(tester);
    await tester.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          home: SearchPage(
            initialQuery: '三上',
            searchLoader: _fanqieLoader,
            actressSearchLoader: (_) async => _fakeResult(),
            actressSearchEnabled: enabled,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('全局搜索：站点段＋演员段＋作品段同屏', (tester) async {
    await pumpPage(tester, enabled: true);
    expect(find.text('演员库 · 演员'), findsOneWidget);
    expect(find.text('演员库 · 作品'), findsOneWidget);
    await _savePng(tester, 'search_global_sections.png');
  });

  testWidgets('未解锁：无演员库段', (tester) async {
    await pumpPage(tester, enabled: false);
    expect(find.text('演员库 · 演员'), findsNothing);
    expect(find.text('演员库 · 作品'), findsNothing);
    await _savePng(tester, 'search_global_locked.png');
  });
}
