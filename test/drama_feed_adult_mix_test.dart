import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/drama_feed_adult_mix.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';

MediaItem _drama(String id) => MediaItem(
  id: id,
  title: '剧$id',
  cover: '',
  author: '',
  badge: '',
  ep: '10',
  kind: 'video',
);

MediaItem _mixed(String id) => MediaItem(
  id: id,
  title: '片$id',
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'film',
);

void main() {
  group('adultMixPool', () {
    test('keeps only tiered video sites', () {
      final pool = adultMixPool([
        (id: 'mjv011', name: 'MJ站', kind: 'video'),
        (id: 'missav', name: 'MissAV', kind: 'video'),
        // 不在分档表里的视频站（用户自导/非成人站）不进混入池。
        (id: 'some-user-site', name: '自导站', kind: 'video'),
        // 阅读站不进混入池。
        (id: 'mjv011', name: 'MJ站', kind: 'novel'),
      ]);
      expect(pool, [
        (id: 'mjv011', name: 'MJ站'),
        (id: 'missav', name: 'MissAV'),
      ]);
    });

    test('empty input stays empty', () {
      expect(adultMixPool(const []), isEmpty);
    });
  });

  group('interleaveAdultMix', () {
    test('inserts one mixed item after every stride dramas', () {
      final dramas = [for (var i = 0; i < 10; i++) _drama('d$i')];
      final mixed = [_mixed('m0'), _mixed('m1')];
      final merged = interleaveAdultMix(dramas, mixed);
      expect(
        [for (final item in merged) item.id],
        [
          'd0',
          'd1',
          'd2',
          'd3',
          'm0',
          'd4',
          'd5',
          'd6',
          'd7',
          'm1',
          'd8',
          'd9',
        ],
      );
    });

    test('no mixed items returns the drama list unchanged', () {
      final dramas = [_drama('d0'), _drama('d1')];
      expect(interleaveAdultMix(dramas, const []), same(dramas));
    });

    test('empty drama list stays empty even with mixed items', () {
      expect(interleaveAdultMix(const [], [_mixed('m0')]), isEmpty);
    });

    test('leftover mixed items are not forced onto the tail', () {
      final dramas = [_drama('d0'), _drama('d1'), _drama('d2')];
      final merged = interleaveAdultMix(dramas, [_mixed('m0'), _mixed('m1')]);
      expect([for (final item in merged) item.id], ['d0', 'd1', 'd2']);
    });

    test('appending dramas keeps the merged prefix stable', () {
      final mixed = [_mixed('m0'), _mixed('m1')];
      final short = interleaveAdultMix([
        for (var i = 0; i < 5; i++) _drama('d$i'),
      ], mixed);
      final grown = interleaveAdultMix([
        for (var i = 0; i < 9; i++) _drama('d$i'),
      ], mixed);
      // loadMore 续上后，前 6 个位置（d0..d3、m0、d4）一字不动。
      expect(grown.sublist(0, short.length), short);
    });
  });

  group('fetchAdultMix', () {
    test('empty pool returns empty without touching clients', () async {
      var calls = 0;
      final entries = await fetchAdultMix(
        xp: 0,
        sites: const [],
        clientForSite: (_) async {
          calls++;
          return null;
        },
      );
      expect(entries, isEmpty);
      expect(calls, 0);
    });

    test('fetches first-category page one, capped per site', () async {
      final seenCategories = <String, String>{};
      final entries = await fetchAdultMix(
        xp: 30000,
        sites: const [(id: 'mjv011', name: 'MJ站', kind: 'video')],
        clientForSite: (id) async => _FakeMixClient(
          categoryList: const [
            DramaSiteCategory('all', '全部'),
            DramaSiteCategory('c1', '分类一'),
          ],
          items: [
            for (var i = 0; i < 5; i++)
              DramaSiteItem(id: 'v$i', title: '片$i', cover: 'c$i'),
          ],
          onCatalog: (categoryId) => seenCategories[id] = categoryId,
        ),
        random: Random(1),
      );
      // 首个可用分类（不是 'all'），每站最多留 2 条。
      expect(seenCategories, {'mjv011': 'c1'});
      expect(entries.length, adultMixItemsPerSite);
      final first = entries.first;
      expect(first.siteId, 'mjv011');
      expect(first.siteItem.id, 'v0');
      expect(first.item.kind, 'film');
      expect(first.item.ep, '');
      expect(first.item.title, '片0');
      expect(first.item.categories, ['MJ站']);
      expect(first.item.id, 'adultmix:mjv011:v0');
    });

    test(
      'a throwing client resolver yields no entries, never throws',
      () async {
        final entries = await fetchAdultMix(
          xp: 30000,
          sites: const [(id: 'mjv011', name: 'MJ站', kind: 'video')],
          clientForSite: (_) async => throw StateError('模拟取客户端失败'),
          random: Random(6),
        );
        expect(entries, isEmpty);
      },
    );

    test('a failing site is skipped, the others still land', () async {
      final entries = await fetchAdultMix(
        xp: 30000,
        sites: const [
          (id: 'mjv011', name: 'MJ站', kind: 'video'),
          (id: 'missav', name: 'MissAV', kind: 'video'),
        ],
        clientForSite: (id) async {
          if (id == 'mjv011') return _FakeMixClient(throwCatalog: true);
          return _FakeMixClient(
            items: const [DramaSiteItem(id: 'v1', title: '片', cover: '')],
          );
        },
        random: Random(2),
      );
      expect([for (final e in entries) e.siteId], ['missav']);
    });

    test('empty catalogs and null clients yield no entries', () async {
      final entries = await fetchAdultMix(
        xp: 30000,
        sites: const [
          (id: 'mjv011', name: 'MJ站', kind: 'video'),
          (id: 'missav', name: 'MissAV', kind: 'video'),
        ],
        clientForSite: (id) async {
          if (id == 'mjv011') return null;
          return _FakeMixClient(emptyCatalog: true);
        },
        random: Random(3),
      );
      expect(entries, isEmpty);
    });

    test('at most three sites are picked per round', () async {
      final picked = <String>{};
      await fetchAdultMix(
        xp: 30000,
        sites: const [
          (id: 'mjv011', name: '站1', kind: 'video'),
          (id: 'missav', name: '站2', kind: 'video'),
          (id: 'javrate', name: '站3', kind: 'video'),
          (id: 'huangguo', name: '站4', kind: 'video'),
          (id: 'sex8', name: '站5', kind: 'video'),
        ],
        clientForSite: (id) async {
          picked.add(id);
          return _FakeMixClient(emptyCatalog: true);
        },
        random: Random(4),
      );
      expect(picked.length, adultMixSiteCount);
    });

    test('categories failure falls back to all', () async {
      var catalogCategory = '';
      final entries = await fetchAdultMix(
        xp: 30000,
        sites: const [(id: 'mjv011', name: 'MJ站', kind: 'video')],
        clientForSite: (_) async => _FakeMixClient(
          throwCategories: true,
          items: const [DramaSiteItem(id: 'v1', title: '片', cover: '')],
          onCatalog: (categoryId) => catalogCategory = categoryId,
        ),
        random: Random(5),
      );
      expect(catalogCategory, 'all');
      expect(entries.length, 1);
    });
  });
}

class _FakeMixClient extends DramaSiteContentClient {
  _FakeMixClient({
    this.categoryList = const [DramaSiteCategory('all', '全部')],
    this.items = const [],
    this.throwCatalog = false,
    this.throwCategories = false,
    this.emptyCatalog = false,
    this.onCatalog,
  });

  final List<DramaSiteCategory> categoryList;
  final List<DramaSiteItem> items;
  final bool throwCatalog;
  final bool throwCategories;
  final bool emptyCatalog;
  final void Function(String categoryId)? onCatalog;

  @override
  Future<List<DramaSiteCategory>> categories() async {
    if (throwCategories) throw StateError('模拟分类失败');
    return categoryList;
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    onCatalog?.call(categoryId);
    if (throwCatalog) throw StateError('模拟取数失败');
    if (emptyCatalog) {
      return const DramaSiteCatalogPage(items: [], hasMore: false);
    }
    return DramaSiteCatalogPage(items: items, hasMore: false);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async =>
      const DramaSiteDetail(id: '', title: '', cover: '', episodes: []);

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async =>
      const DramaPlaySource(url: '');
}
