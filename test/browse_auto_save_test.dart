import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/local_db_site_content.dart';
import 'package:fqapp/services/m3u_export.dart';
import 'package:fqapp/services/m3u_export_db.dart';
import 'package:fqapp/services/midnight_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  M3uExportVideoRecord seeded({
    String videoId = 'v1',
    String url = '',
  }) {
    return M3uExportVideoRecord(
      siteId: 'id:test_site',
      siteName: '测试站',
      categoryId: '1',
      categoryName: '电影',
      videoId: videoId,
      title: '片一',
      url: url,
      cover: '',
      synopsis: '',
      updatedAt: 1,
    );
  }

  group('浏览自动存库', () {
    test('新条目存进库：只有元数据、没有地址', () async {
      final db = MemoryM3uExportDb();
      await saveBrowsedCatalogToDb(
        siteId: 'test_site',
        siteName: '测试站',
        category: const DramaSiteCategory('1', '电影'),
        items: const [
          DramaSiteItem(id: 'v1', title: '片一', cover: ''),
          DramaSiteItem(id: 'v2', title: '片二', cover: ''),
        ],
        dbSink: db,
      );
      final rows = await db.listVideos(gateOpen: true);
      expect(rows.length, 2);
      expect(rows.every((row) => row.url.isEmpty), isTrue);
      expect(rows.map((row) => row.categoryName).toSet(), {'电影'});
    });

    test('已在库里的条目不动：不重复、不刷地址', () async {
      final db = MemoryM3uExportDb();
      await db.saveExport(
        siteId: 'id:test_site',
        siteName: '测试站',
        categories: const [],
        videos: [seeded(url: 'https://cdn.example.com/v1.m3u8')],
      );
      await saveBrowsedCatalogToDb(
        siteId: 'test_site',
        siteName: '测试站',
        category: const DramaSiteCategory('1', '电影'),
        items: const [
          DramaSiteItem(id: 'v1', title: '片一', cover: ''),
          DramaSiteItem(id: 'v2', title: '片二', cover: ''),
        ],
        dbSink: db,
      );
      final rows = await db.listVideos(gateOpen: true);
      expect(rows.length, 2);
      expect(
        rows.firstWhere((row) => row.videoId == 'v1').url,
        'https://cdn.example.com/v1.m3u8',
      );
      expect(
        rows.firstWhere((row) => row.videoId == 'v2').url,
        isEmpty,
      );
    });

    test('午夜未开时成人站不存', () async {
      MidnightGate.activated.value = false;
      final db = MemoryM3uExportDb();
      await saveBrowsedCatalogToDb(
        siteId: 'test_site',
        siteName: '🔞测试站',
        category: const DramaSiteCategory('1', '电影'),
        items: const [DramaSiteItem(id: 'v1', title: '片一', cover: '')],
        dbSink: db,
      );
      expect(await db.listVideos(gateOpen: true), isEmpty);
    });

    test('本地库自己的列表不回写', () async {
      final db = MemoryM3uExportDb();
      await saveBrowsedCatalogToDb(
        siteId: 'localdb:id:test_site',
        siteName: '测试站',
        category: const DramaSiteCategory('1', '电影'),
        items: const [DramaSiteItem(id: 'v1', title: '片一', cover: '')],
        dbSink: db,
      );
      expect(await db.listVideos(gateOpen: true), isEmpty);
    });
  });

  group('本地库播放现取回写', () {
    test('记录无地址时现取并回写，下次直接走库里地址', () async {
      final db = MemoryM3uExportDb();
      await db.saveExport(
        siteId: 'id:test_site',
        siteName: '测试站',
        categories: const [],
        videos: [seeded()],
      );
      var resolved = 0;
      final client = LocalDbContentClient(
        dbSiteId: 'id:test_site',
        dbSink: db,
        liveResolver: (videoId) async {
          resolved++;
          return DramaPlaySource(url: 'https://cdn.example.com/v1.m3u8');
        },
      );
      const episode = DramaSiteEpisode(videoId: 'v1', title: '片一');
      final source = await client.playSource(episode);
      expect(source.url, 'https://cdn.example.com/v1.m3u8');
      expect(resolved, 1);
      final rows = await db.listVideos(gateOpen: true);
      expect(rows.single.url, 'https://cdn.example.com/v1.m3u8');
      final again = await client.playSource(episode);
      expect(again.url, 'https://cdn.example.com/v1.m3u8');
      expect(resolved, 1);
    });

    test('无解析器时保持旧报错', () async {
      final db = MemoryM3uExportDb();
      await db.saveExport(
        siteId: 'id:test_site',
        siteName: '测试站',
        categories: const [],
        videos: [seeded()],
      );
      final client = LocalDbContentClient(
        dbSiteId: 'id:test_site',
        dbSink: db,
      );
      await expectLater(
        client.playSource(
          const DramaSiteEpisode(videoId: 'v1', title: '片一'),
        ),
        throwsStateError,
      );
    });

    test('解析器回空时保持旧报错、库不动', () async {
      final db = MemoryM3uExportDb();
      await db.saveExport(
        siteId: 'id:test_site',
        siteName: '测试站',
        categories: const [],
        videos: [seeded()],
      );
      final client = LocalDbContentClient(
        dbSiteId: 'id:test_site',
        dbSink: db,
        liveResolver: (_) async => null,
      );
      await expectLater(
        client.playSource(
          const DramaSiteEpisode(videoId: 'v1', title: '片一'),
        ),
        throwsStateError,
      );
      final rows = await db.listVideos(gateOpen: true);
      expect(rows.single.url, isEmpty);
    });
  });
}
