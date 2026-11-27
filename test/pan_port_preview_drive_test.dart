import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/cloud_drive/cloud_drive_screen.dart';

import 'preview_test_support.dart';

// 网盘独立页预览单独成文件：网盘主体的初始化走工厂静态缓存，
// 与首页预览同文件跑时跨测试的假时钟区会把缓存的异步对象留死，
// 分文件跑各自进程状态干净（探针实测）。
const _previewDir = '/home/hatch/workspace/xiuxian_pan_port_20261127/previews';
const _boundaryKey = ValueKey<String>('pan-port-preview-boundary');

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundaryKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$_previewDir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

Widget _scene(Widget child) {
  return RepaintBoundary(
    key: _boundaryKey,
    child: MaterialApp(
      theme: ThemeData(fontFamily: 'NotoSansCJK', brightness: Brightness.dark),
      home: child,
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 600),
      ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('02 网盘页（独立页，五家未登录）', (tester) async {
    await loadPreviewFonts(tester, lucide: true);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_scene(const CloudDriveScreen()));
    await _settle(tester);
    await _capture(tester, '02_drive_screen');
  });

}
