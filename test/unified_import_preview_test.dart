import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/actress/unified_import_page.dart';

// 统一导入口批（2026-11-28）预览：统一入口选文件页——MYTV/db
// 文件列表（名字＋大小）＋页尾「选择其他文件」次要入口。
const _previewDir =
    '/home/hatch/workspace/xiuxian_unified_import_20261128/previews';
const _boundaryKey = ValueKey<String>('unified-import-preview-boundary');

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

void main() {
  testWidgets('统一入口列表页：文件行与次要入口齐全、出图', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      RepaintBoundary(
        key: _boundaryKey,
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: 'NotoSansCJK',
            brightness: Brightness.dark,
          ),
          home: const UnifiedImportListPage(
            files: [
              (
                name: '凡人修仙站点.sql',
                path: '/MYTV/db/凡人修仙站点.sql',
                sizeBytes: 904065322,
              ),
              (name: '女优库.db', path: '/MYTV/db/女优库.db', sizeBytes: 901980160),
              (
                name: '磁力库.sql.gz',
                path: '/MYTV/db/磁力库.sql.gz',
                sizeBytes: 101407408,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('unified-import-file-凡人修仙站点.sql')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('unified-import-file-女优库.db')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('unified-import-file-磁力库.sql.gz')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('unified-import-pick-other')),
      findsOneWidget,
    );
    expect(find.textContaining('自动认出'), findsOneWidget);

    await _capture(tester, 'unified_import_list');
  });

  testWidgets('统一入口列表页：空目录态有中文说明', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: UnifiedImportListPage(files: [])),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('unified-import-empty')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('unified-import-pick-other')),
      findsOneWidget,
    );
  });
}
