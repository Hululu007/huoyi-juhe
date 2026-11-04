import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/m3u_export.dart';
import 'package:fqapp/services/m3u_export_db.dart';

/// 共链假客户端：两个分类下的不同条目取流到同一个播放链接。
class _SharedLinkClient extends DramaSiteContentClient {
  @override
  Future<List<DramaSiteCategory>> categories() async => const [
    DramaSiteCategory('1', '电影'),
    DramaSiteCategory('2', '剧集'),
  ];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    if (page > 1) return const DramaSiteCatalogPage(items: [], hasMore: false);
    return DramaSiteCatalogPage(
      items: [
        DramaSiteItem(
          id: categoryId == '1' ? 'v1' : 'v2',
          title: categoryId == '1' ? '片一' : '片二',
          cover: '',
        ),
      ],
      hasMore: false,
    );
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    return DramaSiteDetail(
      id: seriesId,
      title: '片$seriesId',
      cover: '',
      synopsis: '',
      episodes: [
        DramaSiteEpisode(videoId: seriesId, title: '第1集', seriesId: seriesId),
      ],
    );
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    return const DramaPlaySource(
      url: 'https://cdn.example.com/shared.m3u8',
    );
  }
}

/// 同一页内同一条目编号出现两次：编号去重的对照。
class _DuplicatedIdClient extends DramaSiteContentClient {
  @override
  Future<List<DramaSiteCategory>> categories() async => const [
    DramaSiteCategory('1', '电影'),
  ];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    if (page > 1) return const DramaSiteCatalogPage(items: [], hasMore: false);
    return const DramaSiteCatalogPage(
      items: [
        DramaSiteItem(id: 'v1', title: '片一', cover: ''),
        DramaSiteItem(id: 'v1', title: '片一', cover: ''),
      ],
      hasMore: false,
    );
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    return DramaSiteDetail(
      id: seriesId,
      title: '片$seriesId',
      cover: '',
      synopsis: '',
      episodes: [
        DramaSiteEpisode(videoId: seriesId, title: '第1集', seriesId: seriesId),
      ],
    );
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    return const DramaPlaySource(
      url: 'https://cdn.example.com/shared.m3u8',
    );
  }
}

void main() {
  test('同链不同条目：不同分类的两条都保留，库里各两份', () async {
    final db = MemoryM3uExportDb();
    final result = await exportSiteToLocalDb(
      siteId: 'test_site',
      siteName: '测试站',
      client: _SharedLinkClient(),
      dbSink: db,
      gateOpen: true,
    );
    expect(result.successCount, 2);
    expect(result.duplicateCount, 0);
    final rows = await db.listVideos(gateOpen: true);
    expect(rows.map((row) => row.videoId).toSet(), {'v1', 'v2'});
    expect(rows.map((row) => row.title).toSet(), {'片一', '片二'});
    expect(rows.map((row) => row.categoryName).toSet(), {'电影', '剧集'});
    expect(
      rows.map((row) => row.url).toSet(),
      {'https://cdn.example.com/shared.m3u8'},
    );
  });

  test('同链不同站点：两站各存各的，不按链接合并', () async {
    final db = MemoryM3uExportDb();
    await exportSiteToLocalDb(
      siteId: 'site_a',
      siteName: '甲站',
      client: _SharedLinkClient(),
      dbSink: db,
      gateOpen: true,
    );
    await exportSiteToLocalDb(
      siteId: 'site_b',
      siteName: '乙站',
      client: _SharedLinkClient(),
      dbSink: db,
      gateOpen: true,
    );
    expect((await db.listVideos(gateOpen: true)).length, 4);
    expect((await db.listVideos(gateOpen: true, siteId: 'site_a')).length, 2);
    expect((await db.listVideos(gateOpen: true, siteId: 'site_b')).length, 2);
  });

  test('编号去重仍在：同一编号重复列出只留一份，不记成链接合并', () async {
    final db = MemoryM3uExportDb();
    final result = await exportSiteToLocalDb(
      siteId: 'test_site',
      siteName: '测试站',
      client: _DuplicatedIdClient(),
      dbSink: db,
      gateOpen: true,
    );
    expect(result.successCount, 1);
    expect(result.duplicateCount, 1);
    expect((await db.listVideos(gateOpen: true)).length, 1);
  });
}
