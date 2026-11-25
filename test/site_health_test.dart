import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/local_media_proxy.dart';
import 'package:fqapp/services/site_health.dart';
import 'package:fqapp/services/site_health_tracking_client.dart';

/// 站点健康学习（A3）测试：计分 / 分档 / 老化 / 保留期 / 落盘往返 /
/// 记录客户端三处打点与 localProxy 透传。

SiteHealthRecord _record({
  int searchOk = 0,
  int searchFail = 0,
  int detailOk = 0,
  int detailFail = 0,
  int playOk = 0,
  int playFail = 0,
  int lastOkAtMs = 0,
  int lastFailAtMs = 0,
  int consecutiveFails = 0,
}) {
  return SiteHealthRecord()
    ..searchOk = searchOk
    ..searchFail = searchFail
    ..detailOk = detailOk
    ..detailFail = detailFail
    ..playOk = playOk
    ..playFail = playFail
    ..lastOkAtMs = lastOkAtMs
    ..lastFailAtMs = lastFailAtMs
    ..consecutiveFails = consecutiveFails;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('计分', () {
    test('无样本时总分中性、档位 unknown', () {
      final record = _record();
      expect(record.score, siteHealthNeutralRate);
      expect(record.tier, SiteHealthTier.unknown);
    });

    test('单类样本不足 3 按中性计，不奖不罚', () {
      // 搜索 2 次全成功也不该把总分拉满：该类仍按 0.5。
      final record = _record(searchOk: 2, lastOkAtMs: 1000);
      expect(record.searchRate, siteHealthNeutralRate);
      expect(record.score, siteHealthNeutralRate);
    });

    test('权重 0.4/0.3/0.3：三类全成功且样本足时总分为 1', () {
      final record = _record(
        searchOk: 3,
        detailOk: 3,
        playOk: 3,
        lastOkAtMs: 1000,
      );
      expect(record.score, closeTo(1.0, 1e-9));
      expect(record.tier, SiteHealthTier.good);
    });

    test('搜索全失败时总分 = 0.4*0 + 0.3*0.5 + 0.3*0.5 = 0.3 判红', () {
      final record = _record(searchFail: 4, lastFailAtMs: 1000);
      expect(record.score, closeTo(0.3, 1e-9));
      expect(record.tier, SiteHealthTier.bad);
    });
  });

  group('分档', () {
    test('连续失败 ≥5 直接判红，优先于分数', () {
      final record = _record(
        searchOk: 10,
        detailOk: 10,
        playOk: 10,
        lastOkAtMs: 500,
        lastFailAtMs: 1000,
        consecutiveFails: 5,
      );
      expect(record.score, closeTo(1.0, 1e-9));
      expect(record.tier, SiteHealthTier.bad);
    });

    test('分数够绿但从没成功过不给绿', () {
      // 样本都不足时分数恒 0.5，进不到绿；构造 detail/play 中性、
      // search 高分但 lastOkAtMs=0 的记录验证绿的第二条件。
      final record = _record(searchOk: 9, searchFail: 1, lastOkAtMs: 0);
      // searchRate=0.9，总分=0.36+0.15+0.15=0.66 < 0.7 本就不是绿；
      // 再把 detail/play 拉到样本足且全成功，总分 0.96，但没成功
      // 时间戳仍不给绿。
      record.detailOk = 3;
      record.playOk = 3;
      expect(record.score, greaterThan(siteHealthGreenThreshold));
      expect(record.tier, SiteHealthTier.fair);
    });

    test('黄档区间：总分在 0.4 与 0.7 之间', () {
      final record = _record(
        searchOk: 3,
        searchFail: 3,
        lastOkAtMs: 100,
        lastFailAtMs: 200,
      );
      expect(record.score, closeTo(0.5, 1e-9));
      expect(record.tier, SiteHealthTier.fair);
    });
  });

  group('老化与保留', () {
    test('aged：超保留期后计数整除减半，时间戳与连败不动', () {
      final now = DateTime.fromMillisecondsSinceEpoch(
        siteHealthRetention.inMilliseconds + 100000,
      );
      final record = _record(
        searchOk: 10,
        searchFail: 4,
        playOk: 6,
        lastOkAtMs: 1000,
        consecutiveFails: 3,
      );
      record.aged(now);
      expect(record.searchOk, 5);
      expect(record.searchFail, 2);
      expect(record.playOk, 3);
      expect(record.consecutiveFails, 3);
      expect(record.lastOkAtMs, 1000);
    });

    test('aged：未超保留期不动', () {
      final record = _record(searchOk: 10, lastOkAtMs: 1000);
      record.aged(DateTime.fromMillisecondsSinceEpoch(2000));
      expect(record.searchOk, 10);
    });

    test('prune：超期整条丢弃，无活动的保留', () {
      final now = DateTime.fromMillisecondsSinceEpoch(
        siteHealthRetention.inMilliseconds + 5000,
      );
      final pruned = pruneExpiredSiteHealth({
        'old': _record(searchOk: 1, lastOkAtMs: 1000),
        'fresh': _record(searchOk: 1, lastOkAtMs: now.millisecondsSinceEpoch),
        'never': _record(),
      }, now);
      expect(pruned.keys, unorderedEquals(['fresh', 'never']));
    });
  });

  group('落盘编码', () {
    test('JSON 往返一致', () {
      final record = _record(
        searchOk: 7,
        searchFail: 1,
        detailOk: 2,
        playOk: 5,
        playFail: 1,
        lastOkAtMs: 123,
        lastFailAtMs: 456,
        consecutiveFails: 1,
      );
      final back = SiteHealthRecord.fromJson(record.toJson());
      expect(back, isNotNull);
      expect(back!.searchOk, 7);
      expect(back.searchFail, 1);
      expect(back.detailOk, 2);
      expect(back.playOk, 5);
      expect(back.playFail, 1);
      expect(back.lastOkAtMs, 123);
      expect(back.consecutiveFails, 1);
    });

    test('坏结构回 null', () {
      expect(SiteHealthRecord.fromJson('nope'), isNull);
      expect(SiteHealthRecord.fromJson(null), isNull);
    });
  });

  group('稳定排序', () {
    test('分数降序、同分保原序', () {
      final scores = {'a': 0.5, 'b': 0.9, 'c': 0.5, 'd': 0.1};
      final sorted = stableHealthSort(['a', 'b', 'c', 'd'], (id) => scores[id]!);
      expect(sorted, ['b', 'a', 'c', 'd']);
    });
  });

  group('SiteHealthStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SiteHealthStore.instance.resetForTest();
      SiteHealthStore.instance.markLoadedForTest();
      SiteHealthPrefs.instance.resetForTest();
    });

    tearDown(() async {
      await SiteHealthStore.instance.flush();
      SiteHealthStore.instance.resetForTest();
    });

    test('打点累计与连败清零', () {
      final store = SiteHealthStore.instance;
      store.recordPlay('s1', ok: false);
      store.recordPlay('s1', ok: false);
      expect(store.recordOf('s1')!.consecutiveFails, 2);
      store.recordPlay('s1', ok: true);
      final record = store.recordOf('s1')!;
      expect(record.playOk, 1);
      expect(record.playFail, 2);
      expect(record.consecutiveFails, 0);
    });

    test('搜索回空不记成功（未实现搜索的站不被教成健康站）', () {
      final store = SiteHealthStore.instance;
      store.recordSearch('s1', ok: true, items: 0);
      expect(store.recordOf('s1'), isNull);
      store.recordSearch('s1', ok: true, items: 3);
      expect(store.recordOf('s1')!.searchOk, 1);
      store.recordSearch('s1', ok: false);
      expect(store.recordOf('s1')!.searchFail, 1);
    });

    test('总开关关时不打点、分数恒中性', () {
      final store = SiteHealthStore.instance;
      store.enabled = false;
      store.recordPlay('s1', ok: true);
      expect(store.recordOf('s1'), isNull);
      expect(store.scoreOf('s1'), siteHealthNeutralRate);
      expect(store.orderIds(['a', 'b']), ['a', 'b']);
    });

    test('orderIds 按分数重排，未知站居中', () {
      final store = SiteHealthStore.instance;
      for (var i = 0; i < 4; i++) {
        store.recordPlay('good', ok: true);
        store.recordPlay('bad', ok: false);
      }
      final ordered = store.orderIds(['bad', 'unknown', 'good']);
      expect(ordered, ['good', 'unknown', 'bad']);
    });

    test('clear 后全表为空', () async {
      final store = SiteHealthStore.instance;
      store.recordPlay('s1', ok: true);
      await store.clear();
      expect(store.recordOf('s1'), isNull);
      expect(store.scoreOf('s1'), siteHealthNeutralRate);
    });

    test('落盘后新一轮 load 读得回', () async {
      final store = SiteHealthStore.instance;
      store.recordDetail('s9', ok: true, elapsedMs: 120);
      await store.flush();
      final encoded = store.encode();
      expect(encoded, contains('s9'));
      store.resetForTest();
      await store.load();
      expect(store.recordOf('s9')!.detailOk, 1);
    });
  });

  group('SiteHealthTrackingClient', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SiteHealthStore.instance.resetForTest();
      SiteHealthStore.instance.markLoadedForTest();
    });

    tearDown(() async {
      await SiteHealthStore.instance.flush();
      SiteHealthStore.instance.resetForTest();
    });

    test('详情成败各记一次，异常原样抛出', () async {
      final client = SiteHealthTrackingClient(
        siteId: 'sx',
        inner: _FakeClient(),
      );
      final detail = await client.detail('v1');
      expect(detail.id, 'v1');
      expect(SiteHealthStore.instance.recordOf('sx')!.detailOk, 1);
      await expectLater(client.detail('boom'), throwsStateError);
      expect(SiteHealthStore.instance.recordOf('sx')!.detailFail, 1);
    });

    test('播放取流成败打点', () async {
      final client = SiteHealthTrackingClient(
        siteId: 'sx',
        inner: _FakeClient(),
      );
      final source = await client.playSource(
        const DramaSiteEpisode(videoId: 'e1', title: '第1集'),
      );
      expect(source.url, contains('example'));
      expect(SiteHealthStore.instance.recordOf('sx')!.playOk, 1);
      final failing = SiteHealthTrackingClient(
        siteId: 'sx',
        inner: _FakeClient(failPlay: true),
      );
      await expectLater(
        failing.playSource(const DramaSiteEpisode(videoId: 'e1', title: 'x')),
        throwsStateError,
      );
      expect(SiteHealthStore.instance.recordOf('sx')!.playFail, 1);
    });

    test('搜索有结果记成功、抛错记失败', () async {
      final client = SiteHealthTrackingClient(
        siteId: 'sx',
        inner: _FakeClient(),
      );
      final items = await client.search('keyword');
      expect(items, hasLength(2));
      expect(SiteHealthStore.instance.recordOf('sx')!.searchOk, 1);
      final failing = SiteHealthTrackingClient(
        siteId: 'sx',
        inner: _FakeClient(failSearch: true),
      );
      await expectLater(failing.search('k'), throwsStateError);
      expect(SiteHealthStore.instance.recordOf('sx')!.searchFail, 1);
    });

    test('localProxy：内层没实现时抛 StateError（诚实失败不回空）', () async {
      final client = SiteHealthTrackingClient(
        siteId: 'sx',
        inner: _FakeClient(),
      );
      await expectLater(
        client.localProxy(Uri.parse('http://127.0.0.1/proxy?x=1')),
        throwsStateError,
      );
    });

    test('localProxy：内层实现了就转发结果', () async {
      final client = SiteHealthTrackingClient(
        siteId: 'sx',
        inner: _FakeProxyClient(),
      );
      final response = await client.localProxy(
        Uri.parse('http://127.0.0.1/proxy?x=1'),
      );
      expect(response, isNotNull);
      expect(response!.status, 200);
    });
  });
}

class _FakeClient extends DramaSiteContentClient {
  _FakeClient({this.failPlay = false, this.failSearch = false});

  final bool failPlay;
  final bool failSearch;

  @override
  Future<List<DramaSiteCategory>> categories() async => const [];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async =>
      const DramaSiteCatalogPage(items: [], hasMore: false);

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    if (seriesId == 'boom') throw StateError('detail failed');
    return DramaSiteDetail(
      id: seriesId,
      title: '片名',
      cover: '',
      episodes: const [DramaSiteEpisode(videoId: 'e1', title: '第1集')],
    );
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    if (failSearch) throw StateError('search failed');
    return const [
      DramaSiteItem(id: 'a', title: '甲', cover: ''),
      DramaSiteItem(id: 'b', title: '乙', cover: ''),
    ];
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    if (failPlay) throw StateError('play failed');
    return const DramaPlaySource(url: 'https://example.com/v.m3u8');
  }
}

class _FakeProxyClient extends _FakeClient implements LocalProxyCapable {
  @override
  Future<LocalProxyResponse?> localProxy(Uri uri) async =>
      const LocalProxyResponse(status: 200, mime: 'text/plain', body: []);
}
