import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_site_search.dart';
import 'package:fqapp/services/local_db_site_content.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:fqapp/services/m3u_export_db.dart';
import 'package:fqapp/services/midnight_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

MemoryM3uExportDb seededDb() {
  final db = MemoryM3uExportDb();
  db.categories['cat:py_site|1'] = const M3uExportCategoryInfo(
    siteId: 'py_site',
    siteName: 'py 站',
    categoryId: '1',
    categoryName: '电影',
    categoryPath: '电影',
    updatedAt: 3,
  );
  db.categories['cat:py_site|2'] = const M3uExportCategoryInfo(
    siteId: 'py_site',
    siteName: 'py 站',
    categoryId: '2',
    categoryName: '剧集',
    categoryPath: '剧集',
    updatedAt: 2,
  );
  db.categories['cat:adult_site|1'] = const M3uExportCategoryInfo(
    siteId: 'adult_site',
    siteName: '🔞成人站',
    categoryId: '1',
    categoryName: '电影',
    categoryPath: '电影',
    updatedAt: 1,
  );
  M3uExportVideoRecord video({
    required String siteId,
    required String siteName,
    required String categoryId,
    required String categoryName,
    required String videoId,
    required String title,
    String url = 'https://cdn.example.com/v.m3u8',
    String localPath = '',
    int episodeCount = 0,
  }) {
    return M3uExportVideoRecord(
      siteId: siteId,
      siteName: siteName,
      categoryId: categoryId,
      categoryName: categoryName,
      categoryPath: categoryName,
      videoId: videoId,
      title: title,
      url: url,
      localPath: localPath,
      cover: 'cover.jpg',
      synopsis: '简介',
      extra: const {'vod_actor': '演员A'},
      episodeCount: episodeCount,
      updatedAt: 1,
    );
  }

  db.videos['video:py_site|v1'] = video(
    siteId: 'py_site',
    siteName: 'py 站',
    categoryId: '1',
    categoryName: '电影',
    videoId: 'v1',
    title: '片一',
    episodeCount: 3,
  );
  db.videos['video:py_site|v2'] = video(
    siteId: 'py_site',
    siteName: 'py 站',
    categoryId: '1',
    categoryName: '电影',
    videoId: 'v2',
    title: '片二',
  );
  db.videos['video:py_site|v3'] = video(
    siteId: 'py_site',
    siteName: 'py 站',
    categoryId: '2',
    categoryName: '剧集',
    videoId: 'v3',
    title: '剧一',
  );
  db.videos['video:adult_site|a1'] = video(
    siteId: 'adult_site',
    siteName: '🔞成人站',
    categoryId: '1',
    categoryName: '电影',
    videoId: 'a1',
    title: '成人片',
  );
  return db;
}

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    MidnightGate.activated.value = false;
  });

  group('本地库客户端', () {
    test('分类与分页列表走 db，备注带集数', () async {
      MidnightGate.activated.value = true;
      final client = LocalDbContentClient(
        dbSiteId: 'py_site',
        dbSink: seededDb(),
      );
      final categories = await client.categories();
      expect(
        categories.map((c) => c.name).toList(),
        ['电影', '剧集'],
      );
      final page = await client.catalog('1', 1);
      expect(page.items.map((i) => i.id).toList(), ['v1', 'v2']);
      expect(page.hasMore, isFalse);
      expect(page.items.first.remark, '共3集');
      expect((await client.catalog('1', 2)).items, isEmpty);
    });

    test('详情走库里字段，单集，扩展字段齐全', () async {
      MidnightGate.activated.value = true;
      final client = LocalDbContentClient(
        dbSiteId: 'py_site',
        dbSink: seededDb(),
      );
      final detail = await client.detail('v1');
      expect(detail.title, '片一');
      expect(detail.cover, 'cover.jpg');
      expect(detail.synopsis, '简介');
      expect(detail.extra['vod_actor'], '演员A');
      expect(detail.episodes.length, 1);
      expect(detail.episodes.first.videoId, 'v1');
      await expectLater(client.detail('nope'), throwsStateError);
    });

    test('取流双轨：本地文件在走本地，本地没了走线上，两处都没有抛错', () async {
      MidnightGate.activated.value = true;
      final temp = await Directory.systemTemp.createTemp('localdb_');
      try {
        final localFile = File('${temp.path}/v1.m3u8');
        await localFile.writeAsString('#EXTM3U');
        final db = seededDb();
        db.videos['video:py_site|v1'] = M3uExportVideoRecord(
          siteId: 'py_site',
          siteName: 'py 站',
          categoryId: '1',
          categoryName: '电影',
          videoId: 'v1',
          title: '片一',
          url: 'https://cdn.example.com/v1.m3u8',
          localPath: localFile.path,
          cover: '',
          synopsis: '',
          updatedAt: 1,
        );
        final client = LocalDbContentClient(dbSiteId: 'py_site', dbSink: db);
        final local = await client.playSource(
          const DramaSiteEpisode(videoId: 'v1', title: '片一', seriesId: 'v1'),
        );
        expect(local.url, localFile.path);
        final online = await client.playSource(
          const DramaSiteEpisode(videoId: 'v2', title: '片二', seriesId: 'v2'),
        );
        expect(online.url, 'https://cdn.example.com/v.m3u8');
        db.videos['video:py_site|v2'] = M3uExportVideoRecord(
          siteId: 'py_site',
          siteName: 'py 站',
          categoryId: '1',
          categoryName: '电影',
          videoId: 'v2',
          title: '片二',
          url: '',
          cover: '',
          synopsis: '',
          updatedAt: 1,
        );
        await expectLater(
          client.playSource(
            const DramaSiteEpisode(
              videoId: 'v2',
              title: '片二',
              seriesId: 'v2',
            ),
          ),
          throwsStateError,
        );
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    });

    test('搜索按标题子串，午夜未开成人站不露', () async {
      final db = seededDb();
      final client = LocalDbContentClient(dbSiteId: 'py_site', dbSink: db);
      MidnightGate.activated.value = true;
      expect(
        (await client.search('片')).map((i) => i.id).toList(),
        ['v1', 'v2'],
      );
      expect(await client.search('不存在'), isEmpty);
      final adult = LocalDbContentClient(dbSiteId: 'adult_site', dbSink: db);
      MidnightGate.activated.value = false;
      expect(await adult.categories(), isEmpty);
      expect(await adult.search('成人'), isEmpty);
    });
  });

  group('接线', () {
    test('clientFor 的 localdb: 前缀回本地库客户端，不走登记表', () async {
      final client =
          await SourceRegistry.instance.clientFor('localdb:py_site');
      expect(client, isA<LocalDbContentClient>());
      expect(
        (client as LocalDbContentClient).dbSiteId,
        'py_site',
      );
    });
  });

  group('统一搜索', () {
    test('本地库按站成组，站名挂本地库标识，不替线上站结果', () async {
      MidnightGate.activated.value = true;
      final groups = await searchLocalDbSites(
        '片',
        dbSink: seededDb(),
        gateOpen: true,
      );
      expect(
        groups.map((g) => g.siteId).toList(),
        ['localdb:py_site', 'localdb:adult_site'],
      );
      expect(groups.first.siteName, 'py 站·本地库');
      expect(groups.last.siteName, '🔞成人站·本地库');
      expect(
        groups.first.items.map((i) => i.id).toList(),
        ['v1', 'v2'],
      );
      expect(
        groups.last.items.map((i) => i.id).toList(),
        ['a1'],
      );
      final closed = await searchLocalDbSites(
        '成人',
        dbSink: seededDb(),
        gateOpen: false,
      );
      expect(closed, isEmpty);
    });
  });
}
