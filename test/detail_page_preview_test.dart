import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';

/// 详情页预览图：测试渲染出 PNG，不构建整包。
///
/// 渲染手机版 DetailPage（视频），数据全部注入、不碰网络：
/// 标题/封面/作者来自 MediaItem，简介走 detailLoader，选集走
/// directoryLoader。封面在测试里不加载真实图片，显示占位，版式以
/// 标题、简介、选集、底部操作栏为准。
///
/// 测试环境默认字体没有中文会出方框，这里先把系统里的
/// Noto Sans CJK SC 载进来当主题字体，字才能正常显示。
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
      final file = File('previews/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  testWidgets('预览：详情页（视频）', (tester) async {
    // 载入系统里的 Noto Sans CJK SC（简体中文），否则中文全是方框。
    final regularBytes = File(
      '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    ).readAsBytesSync();
    final boldBytes = File(
      '/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc',
    ).readAsBytesSync();
    final loader = FontLoader('NotoSansCJK')
      ..addFont(Future.value(ByteData.view(regularBytes.buffer)));
    await loader.load();
    final boldLoader = FontLoader('NotoSansCJK')
      ..addFont(Future.value(ByteData.view(boldBytes.buffer)));
    await boldLoader.load();

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    final item = MediaItem(
      id: 'video-1',
      seriesId: 'video-1',
      title: '重生之我在都市修仙',
      cover: '',
      author: '张三',
      badge: '',
      ep: '8',
      kind: 'video',
    );
    final chapters = <Chapter>[
      for (var i = 1; i <= 8; i++)
        Chapter(itemId: 'ep$i', title: '第$i集', volumeName: ''),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'NotoSansCJK'),
        home: RepaintBoundary(
          key: const ValueKey<String>('detail-preview'),
          child: DetailPage(
            item: item,
            detailLoader: (id, {String tab = '小说'}) async {
              return {
                'description':
                    '一代仙尊渡劫失败，重生回到了二十年前的高中时代。'
                    '这一世，他要弥补所有遗憾，守护身边的人，'
                    '以一身修为横扫都市，成就无上仙尊。',
              };
            },
            directoryLoader: (id, {String tab = '小说'}) async {
              return [chapters];
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('重生之我在都市修仙'), findsWidgets);
    expect(find.textContaining('一代仙尊'), findsOneWidget);
    // 详情页目录只预览前 3 集（_previewChapterCount = 3），第 8 集不在预览里。
    expect(find.text('第1集'), findsOneWidget);
    expect(find.text('第3集'), findsOneWidget);

    await _capture(tester, const ValueKey<String>('detail-preview'), 'detail_page');
  });
}
