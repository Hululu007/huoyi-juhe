import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/local_library_page.dart';
import 'package:fqapp/services/m3u_export_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

M3uExportVideoRecord _video({
  required String siteId,
  required String siteName,
  required String videoId,
  int updatedAt = 10,
}) {
  return M3uExportVideoRecord(
    siteId: siteId,
    siteName: siteName,
    categoryId: 'all',
    categoryName: '全部',
    videoId: videoId,
    title: '片 $videoId',
    url: 'https://cdn.example.com/$videoId.m3u8',
    cover: '',
    synopsis: '',
    episodeCount: 1,
    updatedAt: updatedAt,
  );
}

Future<MemoryM3uExportDb> _seededDb() async {
  final db = MemoryM3uExportDb();
  await db.saveExport(
    siteId: 'testsite',
    siteName: '测试站',
    categories: const [],
    videos: [
      _video(siteId: 'testsite', siteName: '测试站', videoId: 'v1'),
      _video(
        siteId: 'testsite',
        siteName: '测试站',
        videoId: 'v2',
        updatedAt: 20,
      ),
    ],
  );
  await db.saveExport(
    siteId: 'adultsite',
    siteName: '🔞成人站',
    categories: const [],
    videos: [_video(siteId: 'adultsite', siteName: '🔞成人站', videoId: 'a1')],
  );
  return db;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('列站点：按视频汇总条数，午夜未开时成人站不列', () async {
    final db = await _seededDb();
    final closed = await db.listSites(gateOpen: false);
    expect(closed.map((s) => s.siteName), ['测试站']);
    expect(closed.single.videoCount, 2);
    final open = await db.listSites(gateOpen: true);
    expect(open.map((s) => s.siteName), ['测试站', '🔞成人站']);
    expect(open.last.videoCount, 1);
  });

  testWidgets('播库页：列站点与条数，点站名进浏览页且无预爬取按钮', (tester) async {
    final db = await _seededDb();
    await tester.pumpWidget(
      MaterialApp(home: LocalLibraryPage(dbSink: db)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('测试站'), findsOneWidget);
    expect(find.text('2 条'), findsOneWidget);
    // 门已移除：成人站不再隐藏，直接列出。
    expect(find.text('🔞成人站'), findsOneWidget);
    await tester.tap(find.text('测试站'));
    // 不用 pumpAndSettle：浏览页走注册表解析本地库站，真实 Hive
    // 的平台通道在 widget 测试里不返回，手动 pump 只等 AppBar 出现。
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    // 浏览页已打开（标题为站名），本地库站不显示预爬取按钮。
    expect(find.text('测试站'), findsWidgets);
    expect(find.byKey(const Key('precrawl-button')), findsNothing);
  });

  testWidgets('播库页空态：没有记录时显示空提示', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: LocalLibraryPage(dbSink: MemoryM3uExportDb())),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('本地库还是空的'), findsOneWidget);
  });
}
