// 磁力分类库（修仙版移植）界面预览截图：一测一张，输出 PNG 到
// ~/workspace/xiuxian_magnet_library_20261127/previews/。
// 三张：演员库磁力分类栏、磁力分类作品卡三态徽标、管理页磁力
// 分类库区。数据是假库 + 假解析器（任务/已提交表注入），不走
// 真网、不开真 sqflite（与仓内既有预览同口径）。
// 跑法：单独跑本文件、--no-pub，不要与功能测试混链。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_db_manage_page.dart';
import 'package:fqapp/actress/actress_db_source.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_library_native_page.dart';
import 'package:fqapp/actress/actress_magnet_library.dart';
import 'package:fqapp/actress/actress_magnet_state.dart';
import 'package:fqapp/cloud_drive/cloud_115_offline.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'actress_fixtures.dart';
import 'preview_test_support.dart';

const _previewDir =
    '/home/hatch/workspace/xiuxian_magnet_library_20261127/previews';
const _coverUrl = 'https://v.hersav.me/images/av/preview-magnet.jpg';

const _hashA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _hashB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _hashC = 'cccccccccccccccccccccccccccccccccccccccc';

String _magnet(String hash) => 'magnet:?xt=urn:btih:$hash';

/// 假库：三部作品各带一条磁力线路，另登记一个磁力分类
/// 「4K原版」（并集计数 3 部）。
class _FakeDb {
  final tables = {
    'videos',
    'video_play_urls',
    'video_actress',
    'actresses',
    'video_tag',
    'video_ranking',
    'index_categories',
    'video_category',
    'magnet_libraries',
    'magnet_library_works',
  };

  Map<String, Object?> _videoRow(String id, String title) => {
    'vodId': id,
    'title': title,
    'pic': _coverUrl,
    'play': '',
    'playAlt': '',
    'date': '2024-01-01',
    'typeName': '成人影片',
    'actress': '演员甲',
  };

  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? args,
  ]) async {
    if (sql.contains('sqlite_master')) {
      return [for (final t in tables) {'name': t}];
    }
    if (sql.contains('PRAGMA table_info')) {
      return [
        {'name': 'vod_id'},
        {'name': 'play_url'},
        {'name': 'play_from'},
      ];
    }
    if (sql.contains('FROM magnet_libraries')) {
      return [
        {'name': '4K原版'},
      ];
    }
    if (sql.contains('COUNT(DISTINCT vod_id)')) {
      return [
        {'c': 3},
      ];
    }
    if (sql.contains('FROM video_play_urls')) {
      return [
        {'vod_id': 'ssis-001', 'play_url': _magnet(_hashA)},
        {'vod_id': 'mida-002', 'play_url': _magnet(_hashB)},
        {'vod_id': 'ipx-003', 'play_url': _magnet(_hashC)},
      ];
    }
    if (sql.contains('FROM videos v')) {
      return [
        _videoRow('ssis-001', 'SSIS-001 磁力作品一'),
        _videoRow('mida-002', 'MIDA-002 磁力作品二'),
        _videoRow('ipx-003', 'IPX-003 磁力作品三'),
      ];
    }
    return [];
  }
}

/// 假三态：SSIS-001 有已完成任务（网盘可播）、MIDA-002 的
/// 哈希在已提交表里（离线中）、IPX-003 什么都没有（未下载）。
MagnetDriveStateResolver _fakeResolver() => MagnetDriveStateResolver(
  listTasks: () async => const [
    Pan115OfflineTask(
      infoHash: '',
      name: 'SSIS-001 磁力作品一.mp4',
      percent: 1,
      done: true,
    ),
  ],
  submittedHashes: () async => {_hashB},
  confirmInDrive: (_) async => false,
);

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 25; i++) {
      try {
        await Future.delayed(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 100));
      } catch (_) {}
    }
  });
}

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
  late LocalStore store;

  setUp(() {
    store = LocalStore();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => store.dispose());

  Future<void> pumpNative(WidgetTester tester) async {
    await loadPreviewFonts(tester);
    final png = await tester.runAsync(
      () => fakeComicPagePng(const Color(0xFF5B3A8E)),
    );
    final sample = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(png!);
      final frame = await codec.getNextFrame();
      return frame.image;
    });
    PaintingBinding.instance.imageCache.putIfAbsent(
      NetworkImage(_coverUrl),
      () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: sample!))),
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = _FakeDb();
    await tester.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'NotoSansCJK',
            ),
          ),
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'NotoSansCJK'),
            child: ActressLibraryNativePage(
              repository: FixtureRepository(),
              store: store,
              fallback: ActressLibraryDbFallback(
                pathResolver: () async => '/fake/女优库.db',
                opener: (path) async => db.query,
              ),
              magnetStateResolver: _fakeResolver(),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
  }

  testWidgets('preview magnet category bar', (tester) async {
    await pumpNative(tester);
    // 磁力分类组出现：组行 + 「4K原版 · 3」一颗。
    expect(find.byKey(const ValueKey('native-magnet-group')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('native-magnet-cat-4K原版')),
      findsOneWidget,
    );
    expect(find.text('4K原版 · 3'), findsOneWidget);
    await _savePng(tester, 'preview_magnet_category_bar.png');
  });

  testWidgets('preview magnet card states', (tester) async {
    await pumpNative(tester);
    await tester.tap(find.byKey(const ValueKey('native-magnet-cat-4K原版')));
    await _settle(tester);
    // 进磁力分类：回退 chip 在、三部作品三态徽标齐。
    expect(find.byKey(const ValueKey('native-magnet-back')), findsOneWidget);
    expect(find.text('115 · 网盘可播'), findsOneWidget);
    expect(find.text('115 · 离线中'), findsOneWidget);
    expect(find.text('115 · 未下载'), findsOneWidget);
    await _savePng(tester, 'preview_magnet_card_states.png');
  });

  testWidgets('preview manage magnet section', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('magnet_preview_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final externalDb = '${tempDir.path}/external.db';
    final importedDb = '${tempDir.path}/actress/imported.db';
    Directory('${tempDir.path}/actress').createSync(recursive: true);
    File(externalDb).writeAsStringSync('EXTDB');
    File(importedDb).writeAsStringSync('IMPDB');
    final source = ActressDbSource(
      externalPath: () async => externalDb,
      importedPath: () async => importedDb,
      worksCounter: (_) async => 42,
      isIOS: () => false,
    );
    await loadPreviewFonts(tester);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'NotoSansCJK',
            ),
          ),
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'NotoSansCJK'),
            child: ActressDbManagePage(
              source: source,
              onLibraryChanged: () async {},
              magnetLibrariesLoader: () async => const [
                MagnetLibraryRecord(
                  id: 1,
                  name: '4K原版',
                  category: '4K原版',
                  sourceName: '磁力库.sql',
                  importedAtMillis: 1764331200000,
                  works: 96364,
                  playUrls: 99301,
                ),
                MagnetLibraryRecord(
                  id: 2,
                  name: '国产原创',
                  category: '国产原创',
                  sourceName: '国产原创.sql',
                  importedAtMillis: 1764331200000,
                  works: 128,
                  playUrls: 130,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('magnet-library-section')),
      240,
    );
    await _settle(tester);
    expect(find.text('磁力分类库'), findsOneWidget);
    expect(find.text('4K原版'), findsOneWidget);
    expect(find.text('96364 部 · 来源 磁力库.sql'), findsOneWidget);
    expect(find.text('国产原创'), findsOneWidget);
    await _savePng(tester, 'preview_manage_magnet_section.png');
  });
}
