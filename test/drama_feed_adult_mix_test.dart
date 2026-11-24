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

/// 测试里直通映射：不断言本地代理，只验「可播地址」本身。
Future<DramaPlaySource> _passThrough(
  DramaSiteContentClient client,
  DramaPlaySource source,
) async => source;

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
      // 两次合并必须用同一批实例：MediaItem 无 == 重载，身份比较下两次
      // _drama() 生成的不同实例恒不相等，旧写法恒失败，与被测代码无关。
      final dramas = [for (var i = 0; i < 9; i++) _drama('d$i')];
      final short = interleaveAdultMix(dramas.sublist(0, 5), mixed);
      final grown = interleaveAdultMix(dramas, mixed);
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
              DramaSiteItem(id: 'cap-v$i', title: '片$i', cover: 'c$i'),
          ],
          onCatalog: (categoryId) => seenCategories[id] = categoryId,
        ),
        random: Random(1),
        mapSource: _passThrough,
      );
      // 首个可用分类（不是 'all'），每站最多留 2 条；前 4 条里随机验活，
      // 两条都是已验活的真地址。
      expect(seenCategories, {'mjv011': 'c1'});
      expect(entries.length, adultMixItemsPerSite);
      expect(
        {for (final e in entries) e.siteItem.id},
        hasLength(adultMixItemsPerSite),
      );
      for (final entry in entries) {
        expect(entry.siteId, 'mjv011');
        expect(entry.item.kind, 'film');
        expect(entry.item.ep, '');
        expect(entry.item.categories, ['MJ站']);
        expect(entry.item.id, 'adultmix:mjv011:${entry.siteItem.id}');
        expect(entry.playUrl, 'https://example.invalid/cap-play.mp4');
        expect(entry.keyHex, '');
      }
    });

    test(
      'a throwing client resolver yields no entries, never throws',
      () async {
        final entries = await fetchAdultMix(
          xp: 30000,
          sites: const [(id: 'mjv011', name: 'MJ站', kind: 'video')],
          clientForSite: (_) async => throw StateError('模拟取客户端失败'),
          random: Random(6),
          mapSource: _passThrough,
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
            items: const [DramaSiteItem(id: 'skip-v1', title: '片', cover: '')],
          );
        },
        random: Random(2),
        mapSource: _passThrough,
      );
      expect([for (final e in entries) e.siteId], ['missav']);
      expect(entries.single.playUrl, 'https://example.invalid/skip-play.mp4');
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
        mapSource: _passThrough,
      );
      expect(entries, isEmpty);
    });

    test('dead sites fall through to the next wave, bounded', () async {
      final picked = <String>{};
      final entries = await fetchAdultMix(
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
          // 全部空目录：首波 3 站不够数，第二波把剩下的站也试了；
          // 站再多一轮也只试 adultMixSiteAttempts 站。
          return _FakeMixClient(emptyCatalog: true);
        },
        random: Random(4),
        mapSource: _passThrough,
      );
      expect(entries, isEmpty);
      expect(picked.length, 5);
      expect(picked.length, lessThanOrEqualTo(adultMixSiteAttempts));
    });

    test('categories failure falls back to all', () async {
      var catalogCategory = '';
      final entries = await fetchAdultMix(
        xp: 30000,
        sites: const [(id: 'mjv011', name: 'MJ站', kind: 'video')],
        clientForSite: (_) async => _FakeMixClient(
          throwCategories: true,
          items: const [DramaSiteItem(id: 'fb-v1', title: '片', cover: '')],
          onCatalog: (categoryId) => catalogCategory = categoryId,
        ),
        random: Random(5),
        mapSource: _passThrough,
      );
      expect(catalogCategory, 'all');
      expect(entries.length, 1);
      expect(entries.single.playUrl, 'https://example.invalid/fb-play.mp4');
    });

    test('a video that fails verification is skipped for the next one', () async {
      final entries = await fetchAdultMix(
        xp: 30000,
        sites: const [(id: 'mjv011', name: 'MJ站', kind: 'video')],
        clientForSite: (_) async => _FakeMixClient(
          items: const [
            DramaSiteItem(id: 'dead-v0', title: '死片', cover: ''),
            DramaSiteItem(id: 'live-v1', title: '活片一', cover: ''),
            DramaSiteItem(id: 'live-v2', title: '活片二', cover: ''),
          ],
          deadVideoIds: const {'dead-v0'},
        ),
        random: Random(7),
        mapSource: _passThrough,
      );
      // 死片（详情无集）被换掉，两条活片都进卡，死片绝不进 feed。
      expect(
        {for (final e in entries) e.siteItem.id},
        {'live-v1', 'live-v2'},
      );
      expect(
        {for (final e in entries) e.playUrl},
        {'https://example.invalid/live-play.mp4'},
      );
    });

    test('a non-video play url is not a playable mix entry', () async {
      final entries = await fetchAdultMix(
        xp: 30000,
        sites: const [(id: 'mjv011', name: 'MJ站', kind: 'video')],
        clientForSite: (_) async => _FakeMixClient(
          items: const [
            DramaSiteItem(id: 'novel-v0', title: '小说', cover: ''),
            DramaSiteItem(id: 'novel-v1', title: '视频', cover: ''),
          ],
          playUrlFor: (videoId) => videoId == 'novel-v0'
              ? 'novel://{"title":"小说","content":"正文"}'
              : 'https://example.invalid/novel-play.mp4',
        ),
        random: Random(8),
        mapSource: _passThrough,
      );
      expect(
        [for (final e in entries) e.siteItem.id],
        ['novel-v1'],
      );
    });

    test('a dead first wave falls through to a live site', () async {
      final entries = await fetchAdultMix(
        xp: 30000,
        sites: const [
          (id: 'mjv011', name: '死站一', kind: 'video'),
          (id: 'missav', name: '死站二', kind: 'video'),
          (id: 'javrate', name: '死站三', kind: 'video'),
          (id: 'sex8', name: '活站', kind: 'video'),
        ],
        clientForSite: (id) async {
          if (id == 'sex8') {
            return _FakeMixClient(
              items: const [
                DramaSiteItem(id: 'wave-v0', title: '活片', cover: ''),
              ],
            );
          }
          return _FakeMixClient(throwCatalog: true);
        },
        random: Random(9),
        mapSource: _passThrough,
      );
      // 首波 3 个死站全灭，第二波活站兜底进卡。
      expect([for (final e in entries) e.siteId], ['sex8']);
      expect(entries.single.playUrl, 'https://example.invalid/wave-play.mp4');
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
    this.deadVideoIds = const {},
    this.playUrlFor,
  });

  final List<DramaSiteCategory> categoryList;
  final List<DramaSiteItem> items;
  final bool throwCatalog;
  final bool throwCategories;
  final bool emptyCatalog;
  final void Function(String categoryId)? onCatalog;

  /// 这些视频详情无集（验活失败），其余视频正常可播。
  final Set<String> deadVideoIds;

  /// 按视频 id 定取流地址；不传时全站同一条 mp4（地址按测试名前缀区分，
  /// 避免取流缓存跨用例串味）。
  final String Function(String videoId)? playUrlFor;

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
  Future<DramaSiteDetail> detail(String seriesId) async {
    if (deadVideoIds.contains(seriesId)) {
      return const DramaSiteDetail(id: '', title: '', cover: '', episodes: []);
    }
    return DramaSiteDetail(
      id: seriesId,
      title: seriesId,
      cover: '',
      episodes: [
        DramaSiteEpisode(videoId: 'ep-$seriesId', title: '第1集'),
      ],
    );
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    // videoId 是 'ep-<视频id>'，剥掉前缀按视频 id 定地址。
    final videoId = episode.videoId.startsWith('ep-')
        ? episode.videoId.substring(3)
        : episode.videoId;
    final url =
        playUrlFor?.call(videoId) ??
        'https://example.invalid/${videoId.split('-').first}-play.mp4';
    return DramaPlaySource(url: url);
  }
}
