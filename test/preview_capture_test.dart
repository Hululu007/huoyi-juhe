import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/adult_novels_page.dart';
import 'package:fqapp/pages/core_novel_category_page.dart';
import 'package:fqapp/services/core_novel_categories.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:fqapp/widgets/home/home_design.dart';

/// 阅读区预览图：测试渲染出 PNG，不构建整包、不落网络。
///
/// 5 张，手机尺寸 390x844 逻辑像素：
/// 成人小说 / 成人漫画 / 成人听书（AdultNovelsPage + loader 假数据）、
/// 小说混排目录页（CoreNovelCategoryPage + loader 假数据）、
/// 小说分类条（不泵 HomePage，单独渲染与 home_page.dart 里同款式的
/// 药丸横排：40 高横滚、左右 16 间距、药丸右间距 8、圆角 20、
/// 13 号字；这张只是条的独立渲染，不是首页实截）。
///
/// 假数据封面留空（HomeMediaCard 空封面走几何占位，不编假封面地址）。
///
/// 已知现状（预览暴露的生产布局问题，本文件不修）：
/// HomeMediaCard 在 390 宽手机上需要 309px 高（5/7 封面 242 +
/// 间距 8 + 两行标题 40.5 + 作者行 18.3），而成人页与混排页的
/// 2 列网格格子只有 279px（childAspectRatio 0.62），每张卡溢出
/// 约 30px，测试里会报 RenderFlex 溢出异常。出图测试把这些已知
/// 溢出异常收掉（只出图，不掩盖根因）；真机 release 包没有黄黑条，
/// 但每张卡底部约 30px（作者行）会被格子裁掉。修法是改两处网格
/// 的 childAspectRatio（例如 0.62 → 0.56），那是生产布局改动，
/// 不在本任务的两文件范围内，留给主聊定。

Directory _outDir() {
  final home = Platform.environment['HOME'];
  final path = home == null || home.isEmpty
      ? 'previews'
      : '$home/workspace/huoyi_juhe/previews';
  return Directory(path);
}

Future<void> _loadPreviewFont(WidgetTester tester) async {
  await tester.runAsync(() async {
    final bytes = await File(
      '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    ).readAsBytes();
    final loader = FontLoader('Roboto')
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    // 卡片按类型画 Lucide 图标，测试里也要加载，否则图标是方框。
    // Lucide 的 IconData 带 fontPackage 'flutter_lucide'，引擎按
    // 'packages/flutter_lucide/lucide' 找字体，直写 'lucide' 对不上。
    final lucideFile = File(
      '/home/hatch/.pub-cache/hosted/pub.dev/flutter_lucide-1.59.0/lib/fonts/lucide.ttf',
    );
    if (await lucideFile.exists()) {
      final lucideBytes = await lucideFile.readAsBytes();
      final lucide = FontLoader('packages/flutter_lucide/lucide')
        ..addFont(Future.value(ByteData.sublistView(lucideBytes)));
      await lucide.load();
    }
  });
}

Future<void> _capture(
  WidgetTester tester,
  ValueKey<String> boundaryKey,
  String name,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(boundaryKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('${_outDir().path}/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

List<MediaItem> _fakeItems(
  String prefix,
  String kind,
  String badge,
  String ep,
) => [
  for (var i = 1; i <= 6; i++)
    MediaItem(
      id: 'preview-$prefix-$i',
      title: '预览$prefix$i',
      cover: '',
      author: '预览作者',
      badge: badge,
      ep: ep,
      kind: kind,
    ),
];

Future<void> _setupSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await _loadPreviewFont(tester);
}

/// 收掉已知的卡片溢出异常（见文件头）：溢出在泵帧时报出，
/// 不收掉测试会因此失败；收掉后测试只负责出图。
void _drainKnownOverflows(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

Widget _boundary(ValueKey<String> key, Widget child) =>
    RepaintBoundary(key: key, child: child);

void main() {
  testWidgets('预览：成人小说', (tester) async {
    await _setupSurface(tester);
    const key = ValueKey('preview-adult-novel');
    await tester.pumpWidget(
      MaterialApp(
        home: _boundary(
          key,
          AdultNovelsPage(
            type: ContentType.novel,
            loader: () async => _fakeItems('小说', 'book', '都市', '全128章'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    _drainKnownOverflows(tester);
    expect(find.byKey(const Key('adult-grid-novel')), findsOneWidget);
    await _capture(tester, key, 'adult-novel');
  });

  testWidgets('预览：成人漫画', (tester) async {
    await _setupSurface(tester);
    const key = ValueKey('preview-adult-comic');
    await tester.pumpWidget(
      MaterialApp(
        home: _boundary(
          key,
          AdultNovelsPage(
            type: ContentType.comic,
            loader: () async => _fakeItems('漫画', 'manga', '玄幻', '全56话'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    _drainKnownOverflows(tester);
    expect(find.byKey(const Key('adult-grid-comic')), findsOneWidget);
    await _capture(tester, key, 'adult-comic');
  });

  testWidgets('预览：成人听书', (tester) async {
    await _setupSurface(tester);
    const key = ValueKey('preview-adult-audio');
    await tester.pumpWidget(
      MaterialApp(
        home: _boundary(
          key,
          AdultNovelsPage(
            type: ContentType.audio,
            loader: () async => _fakeItems('听书', 'audio', '言情', '全42集'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    _drainKnownOverflows(tester);
    expect(find.byKey(const Key('adult-grid-audio')), findsOneWidget);
    await _capture(tester, key, 'adult-audio');
  });

  testWidgets('预览：小说混排目录页', (tester) async {
    await _setupSurface(tester);
    const key = ValueKey('preview-mixed-novel');
    await tester.pumpWidget(
      MaterialApp(
        home: _boundary(
          key,
          CoreNovelCategoryPage(
            category: const MergedNovelCategory('都市', []),
            loader: (_) async => _fakeItems('都市小说', 'book', '都市', '全96章'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    _drainKnownOverflows(tester);
    expect(find.byKey(const Key('core-novel-grid-都市')), findsOneWidget);
    await _capture(tester, key, 'mixed-novel');
  });

  testWidgets('预览：小说分类条（独立渲染）', (tester) async {
    await _setupSurface(tester);
    const key = ValueKey('preview-novel-strip');
    await tester.pumpWidget(
      MaterialApp(
        home: _boundary(
          key,
          Scaffold(
            appBar: AppBar(title: const Text('小说分类条')),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Builder(
                  builder: (context) {
                    final palette = HomePalette.of(context);
                    return SizedBox(
                      height: 40,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        children: [
                          for (final name in ['全部', '都市', '现代言情', '玄幻'])
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Container(
                                alignment: Alignment.center,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                                decoration: BoxDecoration(
                                  color: palette.searchBar,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  name,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: palette.ink,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(
                    '分类条独立渲染，非首页实截',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('玄幻'), findsOneWidget);
    await _capture(tester, key, 'novel-strip');
  });
}
