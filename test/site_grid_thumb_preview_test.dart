import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/site_health.dart';
import 'package:fqapp/services/site_thumb_cache.dart';
import 'package:fqapp/widgets/site_grid_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_test_support.dart';

/// 同步批第一批预览图：选站弹窗站卡透视（16:9 封面 + 站名）+
/// 健康点（绿/红）+ 无封面回落首字块。出图到同步批工作目录，
/// 给用户看版式用，不进发布物。接缝与 site_grid_thumb_test 同款。
const _entries = <SiteGridEntry>[
  (id: 'good', name: '红果短剧', zone: SiteGridZone.builtin, group: SiteGridGroup.shortDrama),
  (id: 'bad', name: '河马影视', zone: SiteGridZone.builtin, group: SiteGridGroup.video),
  (id: 's3', name: '柚子影视', zone: SiteGridZone.builtin, group: SiteGridGroup.video),
  (id: 's4', name: '星辰影院', zone: SiteGridZone.builtin, group: SiteGridGroup.video),
  (id: 's5', name: '蓝光影院', zone: SiteGridZone.builtin, group: SiteGridGroup.video),
  (id: 's6', name: '飞鱼影视', zone: SiteGridZone.builtin, group: SiteGridGroup.video),
];

Widget _fakeImage(String url) {
  final hue = (url.hashCode % 360).abs().toDouble();
  return Container(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: [
          HSLColor.fromAHSL(1, hue, 0.55, 0.42).toColor(),
          HSLColor.fromAHSL(1, (hue + 40) % 360, 0.6, 0.26).toColor(),
        ],
      ),
    ),
    child: const Center(
      child: Icon(Icons.play_arrow, color: Colors.white54, size: 34),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('预览：站卡透视 + 健康点', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SiteHealthStore.instance.resetForTest();
    SiteHealthStore.instance.markLoadedForTest();
    SiteHealthPrefs.instance.resetForTest();
    final store = SiteHealthStore.instance;
    for (var i = 0; i < 4; i++) {
      store.recordSearch('good', ok: true, items: 5);
      store.recordDetail('good', ok: true);
      store.recordPlay('good', ok: true);
      store.recordPlay('bad', ok: false);
    }
    final tempDir = Directory.systemTemp.createTempSync('sync_preview');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final cache = SiteThumbCache(directoryProvider: () async => tempDir);
    // 除「河马影视」外都预置封面；它取不到图，演示回落首字块 + 红点。
    // put 带落盘 IO，必须在 runAsync 真异步区里做（假时钟区会挂死）。
    await tester.runAsync(() async {
      for (final entry in _entries) {
        if (entry.id == 'bad') continue;
        await cache.put(entry.id, 'https://img.example.test/${entry.id}.jpg');
      }
    });

    await loadPreviewFonts(tester);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey<String>('sync-preview'),
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: 'NotoSansCJK',
            brightness: Brightness.dark,
          ),
          home: Scaffold(
            backgroundColor: const Color(0xFF0F0F14),
            body: Center(
              child: Builder(
                builder: (buttonContext) => TextButton(
                  onPressed: () {
                    showSiteGridDialog(
                      context: buttonContext,
                      sites: _entries,
                      selectedId: 'good',
                      thumbCache: cache,
                      thumbFetcher: (_) async => null,
                      thumbImageBuilder: _fakeImage,
                    );
                  },
                  child: const Text('打开选站弹窗'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开选站弹窗'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey<String>('sync-preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          '/home/hatch/workspace/xiuxian_moyi_sync_20261126/preview_site_grid.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
    // 收尾：清健康存储的防抖落盘定时器，否则测试框架报 pending timer。
    SiteHealthStore.instance.resetForTest();
    SiteHealthPrefs.instance.resetForTest();
    cache.resetForTest();
  });
}
