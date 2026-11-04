import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/site_browse_page.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/m3u_export_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeBrowseClient implements DramaSiteContentClient {
  @override
  Future<List<DramaSiteCategory>> categories() async {
    return const [DramaSiteCategory('1', '电影')];
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    if (page != 1) return const DramaSiteCatalogPage(items: [], hasMore: false);
    return const DramaSiteCatalogPage(
      items: [
        DramaSiteItem(id: 'v1', title: '片一', cover: ''),
        DramaSiteItem(id: 'v2', title: '片二', cover: ''),
      ],
      hasMore: false,
    );
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    return DramaSiteDetail(
      id: seriesId,
      title: seriesId == 'v1' ? '片一' : '片二',
      cover: '',
      synopsis: '',
      episodes: [
        DramaSiteEpisode(
          videoId: 'flag\u0001ep1',
          title: '第1集',
          seriesId: seriesId,
        ),
      ],
    );
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    return DramaPlaySource(
      url: 'https://cdn.example.com/${episode.seriesId}.m3u8',
    );
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async => const [];
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpUntilDbHas(
    WidgetTester tester,
    MemoryM3uExportDb db,
    int count,
  ) async {
    for (var i = 0; i < 30; i++) {
      final rows = await db.listVideos(gateOpen: true);
      if (rows.length >= count) return;
      await tester.pump(const Duration(milliseconds: 100));
    }
    fail('库里条数未达到 $count');
  }

  testWidgets('浏览分类列表自动存库：只有元数据、没有地址', (tester) async {
    final db = MemoryM3uExportDb();
    await tester.pumpWidget(
      MaterialApp(
        home: SiteBrowsePage(
          siteId: 'test_site',
          siteName: '测试站',
          client: _FakeBrowseClient(),
          dbSink: db,
        ),
      ),
    );
    await pumpUntilDbHas(tester, db, 2);
    final rows = await db.listVideos(gateOpen: true);
    expect(rows.map((row) => row.videoId).toSet(), {'v1', 'v2'});
    expect(rows.every((row) => row.url.isEmpty), isTrue);
  });

  testWidgets('预爬取按钮一键爬本站进库：地址齐全', (tester) async {
    final db = MemoryM3uExportDb();
    await tester.pumpWidget(
      MaterialApp(
        home: SiteBrowsePage(
          siteId: 'test_site',
          siteName: '测试站',
          client: _FakeBrowseClient(),
          dbSink: db,
        ),
      ),
    );
    await pumpUntilDbHas(tester, db, 2);
    await tester.tap(find.byKey(const Key('precrawl-button')));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.textContaining('已写入本地库').evaluate().isNotEmpty) break;
    }
    expect(find.textContaining('已写入本地库 2 条'), findsOneWidget);
    final rows = await db.listVideos(gateOpen: true);
    expect(
      rows.map((row) => row.url).toSet(),
      {
        'https://cdn.example.com/v1.m3u8',
        'https://cdn.example.com/v2.m3u8',
      },
    );
  });
}
