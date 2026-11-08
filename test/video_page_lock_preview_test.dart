import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/cultivation.dart';

/// 影视区锁页预览图：测试渲染出 PNG，不构建整包。
///
/// 真实 VideoPage 在 0 修为（凡人境界）下的上锁态：顶栏「影视」+
/// 大锁图标 + 「影视源需要元婴期」+ 还差 3000 修为（约 10 集短剧）
/// + 「去我的页看进度」按钮。修为快照默认是空（0 修为），不用另设。
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
  });
}

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
  testWidgets('预览：影视区锁页（凡人境界，未到元婴期）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    await CultivationService.instance.resetForTest();
    await CultivationService.instance.ensureInitialized();
    addTearDown(() => CultivationService.instance.resetForTest());
    await _loadPreviewFont(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: const ValueKey('video-lock-preview-boundary'),
          child: const VideoPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.text('影视源需要元婴期'), findsOneWidget);
    expect(find.textContaining('还差 3000 修为'), findsOneWidget);
    expect(find.textContaining('约 10 集短剧'), findsOneWidget);
    expect(find.text('去我的页看进度'), findsOneWidget);
    expect(find.text('午夜区'), findsNothing);
    await _capture(
      tester,
      const ValueKey('video-lock-preview-boundary'),
      'previews/film_zone_locked.png',
    );
  });
}
