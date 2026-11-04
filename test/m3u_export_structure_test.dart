import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/local_db_site_content.dart';
import 'package:fqapp/services/m3u_export.dart';
import 'package:fqapp/services/m3u_export_db.dart';
import 'package:fqapp/services/one_click_py.dart';

/// 层级假客户端：父分类电影下挂子分类动作，子分类带扩展字段。
class _HierarchicalClient extends DramaSiteContentClient {
  @override
  Future<List<DramaSiteCategory>> categories() async => const [
    DramaSiteCategory('m', '电影'),
    DramaSiteCategory(
      'a',
      '动作',
      parentId: 'm',
      path: '电影/动作',
      extra: {'icon': 'act'},
    ),
  ];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    if (categoryId != 'a' || page > 1) {
      return const DramaSiteCatalogPage(items: [], hasMore: false);
    }
    return const DramaSiteCatalogPage(
      items: [DramaSiteItem(id: 'v1', title: '片一', cover: '')],
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
    return DramaPlaySource(
      url: 'https://cdn.example.com/${episode.videoId}.m3u8',
    );
  }
}

class _FakeM3uSink implements OneClickDownloadSink {
  @override
  Future<String> saveText({
    required String fileName,
    required String text,
  }) async =>
      '/storage/emulated/0/Download/$fileName';
}

void main() {
  test('层级与字段往返：导出不压平，本地库读回原样', () async {
    final db = MemoryM3uExportDb();
    final result = await exportSiteM3u(
      siteId: 'test_site',
      siteName: '测试站',
      client: _HierarchicalClient(),
      downloadSink: _FakeM3uSink(),
      dbSink: db,
      gateOpen: true,
    );
    expect(result.successCount, 1);

    final stored = await db.listCategories(gateOpen: true);
    expect(stored.length, 2);
    final parent = stored.firstWhere((c) => c.categoryId == 'm');
    expect(parent.parentId, isEmpty);
    expect(parent.categoryPath, '电影');
    final child = stored.firstWhere((c) => c.categoryId == 'a');
    expect(child.parentId, 'm');
    expect(child.categoryPath, '电影/动作');
    expect(child.extra['icon'], 'act');

    final rows = await db.listVideos(gateOpen: true);
    expect(rows.length, 1);
    expect(rows.first.categoryPath, '电影/动作');

    final client = LocalDbContentClient(dbSiteId: 'test_site', dbSink: db);
    final back = await client.categories();
    final backChild = back.firstWhere((c) => c.id == 'a');
    expect(backChild.parentId, 'm');
    expect(backChild.path, '电影/动作');
    expect(backChild.extra['icon'], 'act');
    expect(backChild.displayName, '电影/动作');
    final backParent = back.firstWhere((c) => c.id == 'm');
    expect(backParent.displayName, '电影');
  });

  test('平铺分类展示名不变', () {
    expect(const DramaSiteCategory('1', '电影').displayName, '电影');
    expect(
      const DramaSiteCategory('a', '动作', path: '电影/动作').displayName,
      '动作',
    );
  });
}
