import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/source_management_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/site_library.dart';
import 'package:fqapp/services/source_registry.dart';

// 站点库批（2026-11-27）预览：未导入名单态 / 点未激活站的导入提示 /
// 导入后列表三张。数据：名单是随包真名单；导入后场景用注册链测试
// 接缝注入 3 个假站，只验版式与状态，不冒充真导入。
const _previewDir =
    '/home/hatch/workspace/xiuxian_station_sql_build_20261127/previews';
const _boundaryKey = ValueKey<String>('site-library-preview-boundary');

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory supportDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    supportDir = Directory.systemTemp.createTempSync('site_lib_preview');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => supportDir.path,
        );
    CultivationService.instance.snapshotNotifier.value =
        const CultivationSnapshot(bonusXp: 99999);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    CultivationService.instance.snapshotNotifier.value =
        CultivationSnapshot.empty;
    SourceRegistry.instance.debugSqlStationsOverride = null;
    SourceRegistry.instance.debugSqlImportedOverride = null;
    if (supportDir.existsSync()) supportDir.deleteSync(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => SiteLibraryService.instance.roster());
    await tester.runAsync(() => SourceRegistry.instance.load());
    await tester.pumpWidget(_scene(const SourceManagementPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('预览1：未导入名单态', (tester) async {
    SourceRegistry.instance.debugSqlImportedOverride = false;
    await pumpPage(tester);
    await tester.scrollUntilVisible(
      find.text('未激活（站点库未导入）'),
      500,
      maxScrolls: 300,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('未激活（站点库未导入）'), findsOneWidget);
    await _capture(tester, 'preview_1_roster_unimported');
  });

  testWidgets('预览2：点未激活站弹导入提示', (tester) async {
    SourceRegistry.instance.debugSqlImportedOverride = false;
    await pumpPage(tester);
    await tester.scrollUntilVisible(
      find.text('未激活（站点库未导入）'),
      500,
      maxScrolls: 300,
    );
    await tester.pump(const Duration(milliseconds: 300));
    // 点名单组第一行（组标题下面第一站）。
    final rows = find.byWidgetPredicate(
      (w) => w is ListTile && w.subtitle != null,
    );
    await tester.tap(rows.first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('去导入'), findsOneWidget);
    await tester.pumpAndSettle();
    await _capture(tester, 'preview_2_import_prompt');
  });

  testWidgets('预览3：导入后列表（假站注入）', (tester) async {
    // 注册表单例在同文件前序用例里已 loaded，先重置（重置会清接缝，
    // 故接缝在重置之后再设）。
    SourceRegistry.instance.debugResetForTest();
    SourceRegistry.instance.debugSqlImportedOverride = true;
    SourceRegistry.instance.debugSqlStationsOverride = const [
      SiteLibraryStation(
        siteId: 'seed_previewpy',
        canonId: 'previewpy',
        name: '预览影视站',
        kind: 'pyImport',
        zone: 'video',
        contentType: 'video',
        isAdult: false,
        sortOrder: 0,
        fileName: 'previewpy.py',
        codeFilePath: '/tmp/previewpy.py',
      ),
      SiteLibraryStation(
        siteId: 'jar:zakatv:ZakaPreview',
        canonId: 'previewjar',
        name: '🔞预览午夜站',
        kind: 'jarImport',
        zone: 'video',
        contentType: 'video',
        isAdult: true,
        sortOrder: 1,
        className: 'com.github.catvod.spider.ZakaPreview',
        jarAssetId: 'zakatv',
      ),
      SiteLibraryStation(
        siteId: 'seed_previewbook',
        canonId: 'previewbook',
        name: '预览书源站',
        kind: 'legadoImport',
        zone: 'novel',
        contentType: 'novel',
        isAdult: false,
        sortOrder: 2,
        fileName: 'previewbook.json',
        codeFilePath: '/tmp/previewbook.json',
      ),
    ];
    await pumpPage(tester);
    await tester.scrollUntilVisible(find.text('预览影视站'), 500,
        maxScrolls: 300);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('预览影视站'), findsOneWidget);
    await _capture(tester, 'preview_3_imported_list');
  });
}
