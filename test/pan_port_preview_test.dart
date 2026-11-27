import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/actress/actress_db_import.dart';
import 'package:fqapp/actress/actress_db_manage_page.dart';
import 'package:fqapp/actress/actress_db_source.dart';
import 'package:fqapp/cloud_drive/cloud_credential_store.dart';
import 'package:fqapp/cloud_drive/cloud_drive_login.dart';
import 'package:fqapp/cloud_drive/cloud_drive_screen.dart';
import 'package:fqapp/cloud_drive/cloud_drive_stations.dart';
import 'package:fqapp/pages/hongguo_login_page.dart';
import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:fqapp/widgets/home/home_tab_bar.dart';
import 'package:fqapp/widgets/series_detail/moyi_detail_theme.dart';
import 'package:fqapp/widgets/site_grid_dialog.dart';

import 'preview_test_support.dart';

// 本批（xiuxian_pan_port_20261127）预览：真渲染本批控件出图落 previews/。
// 数据是夹具（未登录/假登录态、假库文件），只验版式与落点，不冒充真数据。
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
  // 异步加载链（设置→凭证→列表）要多帧才落定，单 pump 不够。
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('01 首页网盘档：分类行听书后是网盘＋网盘页主体', (tester) async {
    await loadPreviewFonts(tester, lucide: true);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final panIndex = homeCategories.indexWhere((c) => c.label == '网盘');
    expect(panIndex, greaterThan(0));
    await tester.pumpWidget(
      _scene(
        Scaffold(
          backgroundColor: Colors.transparent,
          body: DecoratedBox(
            decoration: const BoxDecoration(gradient: moyiPageGradient),
            child: CustomScrollView(
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: HomeTabBarDelegate(
                      selectedIndex: panIndex,
                      onSelect: (_) {},
                      categories: homeCategories,
                      dark: true,
                      extent: HomeTabBarDelegate.extentFor(1),
                    ),
                  ),
                  const SliverToBoxAdapter(
                    child: CloudDriveBody(embedded: true),
                  ),
                ],
              ),
          ),
        ),
      ),
    );
    await _settle(tester);
    await _capture(tester, '01_home_pan_tab');
  });

  testWidgets('03 登入中心：红果账号卡＋网盘账号区（115 假登录态）', (
    tester,
  ) async {
    await loadPreviewFonts(tester, lucide: true);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = await SharedPreferences.getInstance();
    final store = CloudCredentialStore(prefs);
    await store.save(
      'pan115',
      CloudCredentials(
        fields: const {'cookie': 'a=b'},
        savedAtMs: 1,
        label: '我的115',
      ),
    );
    await tester.pumpWidget(
      _scene(
        DecoratedBox(
          decoration: const BoxDecoration(gradient: moyiPageGradient),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              title: const Text('账号中心'),
            ),
            body: ListView(
              children: [
                const HongguoAccountTile(),
                CloudDriveAccountSection(store: store),
              ],
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    await _capture(tester, '03_login_center');
  });

  testWidgets('04 片库选站弹窗：导入区里 115 网盘站在位', (tester) async {
    await loadPreviewFonts(tester, lucide: true);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = await SharedPreferences.getInstance();
    final store = CloudCredentialStore(prefs);
    await store.save(
      'pan115',
      CloudCredentials(
        fields: const {'cookie': 'a=b'},
        savedAtMs: 1,
        label: '我的115',
      ),
    );
    await CloudDriveStations.refresh(store);
    addTearDown(() {
      SourceRegistry.instance.setCloudDriveEntries(const []);
    });
    final custom = <SourceEntry>[
      const SourceEntry(
        id: 'user_video_1',
        name: '用户导入影视站',
        kind: SourceKind.pyImport,
        extra: {'contentType': 'video'},
      ),
    ];
    final entries = videoZoneSiteEntries(
      withCloudDriveSites(custom),
      999999,
      isBuiltinEnabled: (_) => true,
    );
    expect(entries.any((e) => e.id == 'cloud:pan115'), isTrue);
    await tester.pumpWidget(
      _scene(
        Scaffold(
          backgroundColor: const Color(0xFF0F0F14),
          body: Center(
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  await showSiteGridDialog(
                    context: context,
                    sites: entries,
                    initialZone: SiteGridZone.import,
                  );
                },
                child: const Text('打开选站'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('打开选站'));
    await tester.pump(const Duration(milliseconds: 400));
    await _settle(tester);
    await _capture(tester, '04_video_zone_cloud_station');
  });

  testWidgets('05 数据库管理页：双库卡＋切换＋导入口', (tester) async {
    await loadPreviewFonts(tester, lucide: true);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tempDir = Directory.systemTemp.createTempSync('pan_preview_db_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final externalDb = '${tempDir.path}/external.db';
    final importedDb = '${tempDir.path}/actress/imported.db';
    Directory('${tempDir.path}/actress').createSync(recursive: true);
    File(externalDb).writeAsBytesSync(List<int>.filled(4096, 0));
    File(importedDb).writeAsBytesSync(List<int>.filled(2048, 0));
    final source = ActressDbSource(
      externalPath: () async => externalDb,
      importedPath: () async => importedDb,
      worksCounter: (path) async => path == externalDb ? 449339 : 1204,
      isIOS: () => false,
    );
    await tester.pumpWidget(
      _scene(
        ActressDbManagePage(
          source: source,
          importService: ActressDbImportService(
            source: source,
            dbValidator: (_) async =>
                const ActressDbValidation(ok: true, works: 1),
          ),
          onLibraryChanged: () async {},
        ),
      ),
    );
    await _settle(tester);
    await _capture(tester, '05_db_manage_page');
  });
}
