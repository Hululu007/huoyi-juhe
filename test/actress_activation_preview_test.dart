// 演员库激活批预览（2026-11-27）：一测一张，输出 PNG 到
// ~/workspace/xiuxian_actress_activation_20261127/previews/。
// 两张：①数据库管理页未激活引导态；②点外置「导入激活」被
// 版本门拒后的中文原因提示态。注入假来源/假校验，不碰真库。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_db_import.dart';
import 'package:fqapp/actress/actress_db_manage_page.dart';
import 'package:fqapp/actress/actress_db_source.dart';
import 'package:fqapp/actress/actress_library_version.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _previewDir =
    '/home/hatch/workspace/xiuxian_actress_activation_20261127/previews';

Future<void> _savePng(WidgetTester tester, String name) async {
  final boundary = tester
      .element(find.byType(RepaintBoundary).first)
      .findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  Directory(_previewDir).createSync(recursive: true);
  File('$_previewDir/$name').writeAsBytesSync(data!.buffer.asUint8List());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String externalDb;
  late String importedDb;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('activation_preview_');
    externalDb = '${tempDir.path}/external.db';
    importedDb = '${tempDir.path}/actress/imported.db';
    Directory('${tempDir.path}/actress').createSync(recursive: true);
    File(externalDb).writeAsStringSync('EXTDB');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> pumpManage(
    WidgetTester tester, {
    required ActressDbVersionChecker versionChecker,
  }) async {
    final source = ActressDbSource(
      externalPath: () async => externalDb,
      importedPath: () async => importedDb,
      worksCounter: (_) async => 449339,
      isIOS: () => false,
    );
    final service = ActressDbImportService(
      source: source,
      dbValidator: (_) async =>
          const ActressDbValidation(ok: true, works: 449339),
      dbVersionChecker: versionChecker,
    );
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          child: ActressDbManagePage(
            source: source,
            importService: service,
            onLibraryChanged: () async {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('预览1：未激活引导页', (tester) async {
    await pumpManage(
      tester,
      versionChecker: (_) async => (
        info: const ActressLibraryVersionInfo(
          format: 'actress_library',
          formatVersion: '1',
          coreVersion: '2026.11.27',
          libraryVersion: '20261127v5',
        ),
        error: null,
      ),
    );
    expect(find.byKey(const ValueKey('activation-guide')), findsOneWidget);
    await _savePng(tester, 'preview_unactivated_guide.png');
  });

  testWidgets('预览2：版本不符提示', (tester) async {
    await pumpManage(
      tester,
      versionChecker: (_) async => (
        info: const ActressLibraryVersionInfo(
          format: 'actress_library',
          formatVersion: '1',
          coreVersion: '2027.01.01',
          libraryVersion: '20270101',
        ),
        error: actressLibraryVersionError(
          const ActressLibraryVersionInfo(
            format: 'actress_library',
            formatVersion: '1',
            coreVersion: '2027.01.01',
            libraryVersion: '20270101',
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('dual-import-external')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    expect(find.byKey(const ValueKey('dual-error')), findsOneWidget);
    expect(find.textContaining('要求核心版本 2027.01.01'), findsWidgets);
    await _savePng(tester, 'preview_version_mismatch.png');
  });
}
