import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/local_db_site_content.dart';
import 'package:fqapp/services/m3u_export.dart';
import 'package:fqapp/services/m3u_export_db.dart';
import 'package:fqapp/services/one_click_py.dart';
import 'package:fqapp/services/site_identity.dart';

class _FakeClient extends DramaSiteContentClient {
  _FakeClient(this.itemId);

  final String itemId;

  @override
  Future<List<DramaSiteCategory>> categories() async =>
      const [DramaSiteCategory('1', '电影')];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    if (page > 1) return const DramaSiteCatalogPage(items: [], hasMore: false);
    return DramaSiteCatalogPage(
      items: [DramaSiteItem(id: itemId, title: '片$itemId', cover: '')],
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
  group('归一键', () {
    test('内容站地址按主机归一：大小写、www、前缀路径、端口都不另起键', () {
      expect(
        canonicalSiteKey(
          siteId: 'custom_1',
          address: 'https://WWW.HongGuoDuanJu.COM/api.php?ac=videolist',
          addressIsSiteAddress: true,
        ),
        'host:hongguoduanju.com',
      );
      expect(
        canonicalSiteKey(
          siteId: 'custom_2',
          address: 'https://www.zywest263.com:8443/api.php',
          addressIsSiteAddress: true,
        ),
        'host:zywest263.com',
      );
    });

    test('地址不是内容站地址时不按主机合并，退回登记 id', () {
      expect(
        canonicalSiteKey(
          siteId: 'py_1',
          address: 'https://files.example.com/x.jar',
        ),
        'id:py_1',
      );
      expect(
        canonicalSiteKey(siteId: 'py_1', address: 'example.py'),
        'id:py_1',
      );
      expect(canonicalSiteKey(siteId: 'py_1'), 'id:py_1');
    });

    test('内置站已核实主机进表，红果镜像同域也不合并', () {
      expect(canonicalSiteKey(siteId: 'hongguo'), 'host:hongguoduanju.com');
      expect(canonicalSiteKey(siteId: 'huaguo'), 'host:zywest263.com');
      expect(canonicalSiteKey(siteId: 'faguo'), 'host:xzyx168.com');
      expect(canonicalSiteKey(siteId: 'wuguo'), 'host:duanju55.com');
      expect(canonicalSiteKey(siteId: 'wangguo'), 'host:duanju2.com');
      expect(canonicalSiteKey(siteId: 'hgtvmirror'), 'id:hgtvmirror');
    });

    test('已是归一键时透传，不套第二层', () {
      expect(
        canonicalSiteKey(siteId: 'host:hongguoduanju.com'),
        'host:hongguoduanju.com',
      );
      expect(canonicalSiteKey(siteId: 'id:py_site'), 'id:py_site');
    });

    test('地址适用范围：只有采集站与书源站的地址是内容站地址', () {
      expect(addressIsSiteAddressForKind('customMaccms'), isTrue);
      expect(addressIsSiteAddressForKind('legadoImport'), isTrue);
      for (final kind in [
        'pyImport',
        'jarImport',
        'jsImport',
        'xbpqImport',
        'remoteJson',
        'builtinDrama',
      ]) {
        expect(addressIsSiteAddressForKind(kind), isFalse);
      }
    });
  });

  group('选站去重', () {
    test('同站多入口只留第一行，镜像与不同地址不折掉', () {
      final rows = dedupeByCanonicalKey(
        [
          ('hongguo', '', false),
          ('custom_1', 'https://hongguoduanju.com/api.php', true),
          ('hgtvmirror', '', false),
          ('py_9', 'https://files.example.com/a.py', false),
          ('custom_2', 'https://www.zywest263.com/api.php', true),
          ('huaguo', '', false),
        ],
        (row) => canonicalSiteKey(
          siteId: row.$1,
          address: row.$2,
          addressIsSiteAddress: row.$3,
        ),
      );
      expect(
        [for (final row in rows) row.$1],
        ['hongguo', 'hgtvmirror', 'py_9', 'custom_2'],
      );
    });
  });

  group('双入口同站合一', () {
    test('内置红果与采集站同域导出，库里只有一批记录、一组分类', () async {
      final db = MemoryM3uExportDb();
      final sink = _FakeM3uSink();
      await exportSiteM3u(
        siteId: 'hongguo',
        siteName: '红果',
        client: _FakeClient('v1'),
        downloadSink: sink,
        dbSink: db,
        gateOpen: true,
      );
      await exportSiteM3u(
        siteId: 'custom_1',
        siteName: '红果采集',
        client: _FakeClient('v2'),
        downloadSink: sink,
        dbSink: db,
        gateOpen: true,
        siteAddress: 'https://hongguoduanju.com/api.php',
        addressIsSiteAddress: true,
      );
      final rows = await db.listVideos(gateOpen: true, siteId: 'hongguo');
      expect(rows.map((row) => row.videoId).toSet(), {'v1', 'v2'});
      expect(
        rows.map((row) => row.siteId).toSet(),
        {'host:hongguoduanju.com'},
      );
      final categories =
          await db.listCategories(gateOpen: true, siteId: 'hongguo');
      expect(categories.length, 1);
      expect(categories.first.categoryName, '电影');
      final client = LocalDbContentClient(
        dbSiteId: 'host:hongguoduanju.com',
        dbSink: db,
      );
      final page = await client.catalog('1', 1);
      expect(page.items.map((item) => item.id).toSet(), {'v1', 'v2'});
    });

    test('不同主机不合并，镜像不并入红果', () async {
      final db = MemoryM3uExportDb();
      final sink = _FakeM3uSink();
      await exportSiteM3u(
        siteId: 'hongguo',
        siteName: '红果',
        client: _FakeClient('v1'),
        downloadSink: sink,
        dbSink: db,
        gateOpen: true,
      );
      await exportSiteM3u(
        siteId: 'hgtvmirror',
        siteName: '红果镜像',
        client: _FakeClient('v9'),
        downloadSink: sink,
        dbSink: db,
        gateOpen: true,
      );
      expect(
        (await db.listVideos(gateOpen: true, siteId: 'hongguo'))
            .map((row) => row.videoId)
            .toList(),
        ['v1'],
      );
      expect(
        (await db.listVideos(gateOpen: true, siteId: 'hgtvmirror'))
            .map((row) => row.videoId)
            .toList(),
        ['v9'],
      );
    });
  });
}
