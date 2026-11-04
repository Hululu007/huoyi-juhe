import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/m3u_export.dart';
import 'package:fqapp/services/m3u_export_db.dart';
import 'package:fqapp/services/one_click_py.dart';

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

class _FakeM3uSink implements OneClickDownloadSink {
  String savedText = '';

  @override
  Future<String> saveText({
    required String fileName,
    required String text,
  }) async {
    savedText = text;
    return '/storage/emulated/0/Download/$fileName';
  }
}

int countOccurrences(String text, String needle) {
  var count = 0;
  var start = 0;
  while (true) {
    final at = text.indexOf(needle, start);
    if (at < 0) return count;
    count++;
    start = at + needle.length;
  }
}

void main() {
  test('同链不同条目：不同分类的两条都保留，m3u 与库里各两份', () async {
    final db = MemoryM3uExportDb();
    final sink = _FakeM3uSink();
    final result = await exportSiteM3u(
      siteId: 'test_site',
      siteName: '测试站',
      client: _SharedLinkClient(),
      downloadSink: sink,
      dbSink: db,
      gateOpen: true,
    );
    expect(result.successCount, 2);
    expect(result.duplicateCount, 0);
    expect(
      countOccurrences(sink.savedText, 'https://cdn.example.com/shared.m3u8'),
      2,
    );
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
    final sink = _FakeM3uSink();
    await exportSiteM3u(
      siteId: 'site_a',
      siteName: '甲站',
      client: _SharedLinkClient(),
      downloadSink: sink,
      dbSink: db,
      gateOpen: true,
    );
    await exportSiteM3u(
      siteId: 'site_b',
      siteName: '乙站',
      client: _SharedLinkClient(),
      downloadSink: sink,
      dbSink: db,
      gateOpen: true,
    );
    expect((await db.listVideos(gateOpen: true)).length, 4);
    expect((await db.listVideos(gateOpen: true, siteId: 'site_a')).length, 2);
    expect((await db.listVideos(gateOpen: true, siteId: 'site_b')).length, 2);
  });

  test('编号去重仍在：同一编号重复列出只留一份，不记成链接合并', () async {
    final db = MemoryM3uExportDb();
    final sink = _FakeM3uSink();
    final result = await exportSiteM3u(
      siteId: 'test_site',
      siteName: '测试站',
      client: _DuplicatedIdClient(),
      downloadSink: sink,
      dbSink: db,
      gateOpen: true,
    );
    expect(result.successCount, 1);
    expect(result.duplicateCount, 1);
    expect((await db.listVideos(gateOpen: true)).length, 1);
  });
}
