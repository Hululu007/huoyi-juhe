// 演员库桥接＋补全批测试（2026-11-27）：
// - 18AV 没数据根因：活站现行列表结构（post 后缀类名 +
//   figure 包裹 + img 后 video 元素 + img 单引号 src）旧
//   两式 0 命中 → 新结构式解析出卡；源真失败（空响应 /
//   模板又变）抛中文原因、不吞成空态；真空结果仍回空表。
// - py 桥（MissAV/潮流同路）失败不吞空。
// - 番号全源统一提取：123AV/18AV 地址、py 桥卡 id、
//   标题扫描、PH viewkey 不误判、FC2 式。
// - 桥接站：注册表盘点（110 站、id 不重、黑名单不在）、
//   分类现取、取卡走仓储通道。
// - 详情页：在线入口（桥接站 UMSO-659 形态）吃同番号互
//   补补上简介；全链补不到时出底线中文说明、不留空白。
// 全部假件（假仓储 / 假取数 / 假库查询），不碰真库真网。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_http.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_av18_source.dart';
import 'package:fqapp/actress/actress_javdb_api.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_mjv_parse.dart';
import 'package:fqapp/actress/actress_online_parse.dart';
import 'package:fqapp/actress/actress_online_sources.dart';
import 'package:fqapp/actress/actress_py_lines.dart';
import 'package:fqapp/actress/actress_site_bridge.dart';
import 'package:fqapp/actress/actress_still_capture.dart';
import 'package:fqapp/actress/actress_work_detail_page.dart';
import 'package:fqapp/cloud_drive/cloud_providers.dart' show CloudDirectLink;
import 'package:fqapp/cloud_drive/drive_code_play.dart';

import 'support/controlled_player.dart';

// ---------------------------------------------------------------------------
// 夹具：18AV 活站现行列表结构（2026-11-27 本机实拉
// chinese_list_1.html 缩样，结构逐字照活页）。
// ---------------------------------------------------------------------------

const _liveListHtml = '''
<div class='post video_9s'>
<figure class='video-preview thumb'>
<a  target="_top"  href="https://18av.nl/zh/chinese_content/344250/HMN-834.html"><img src='https://stimg1.test/426873_HMN-834.jpg' class='thumb'><video loop='true' muted='true' playsinline='true' poster='' data-src='https://gifb.test/426873_HMN-834.mp4' src='' autoplay='true' class='thumb'></video><div class='video-loader' style='visibility: hidden;'><div class='spinner-border text-pink'></div></div></a>
</figure>
<div class='con'>
<h3 itemprop='name headline'><a  target="_top"  href="https://18av.nl/zh/chinese_content/344250/HMN-834.html">[中字]HMN-834 样本标题一</a></h3>
<div class='meta'>2026/11/27</div>
</div>
</div>
<div class='post video_9s'>
<figure class='video-preview thumb'>
<a  target="_top"  href="https://18av.nl/zh/chinese_content/344249/MIAB-662.html"><img src='https://stimg1.test/426687_MIAB-662.jpg' class='thumb'><video loop='true' class='thumb'></video></a>
</figure>
<div class='con'>
<h3 itemprop='name headline'><a  target="_top"  href="https://18av.nl/zh/chinese_content/344249/MIAB-662.html">[中字]MIAB-662 样本标题二</a></h3>
<div class='meta'>2026/11/27</div>
</div>
</div>
''';

/// 模板又变的假页：有作品链接、没有任何已知卡片结构。
const _alienListHtml = '''
<html><body>
<article class="tile"><a href="https://18av.nl/zh/chinese_content/1/ABF-001.html">ABF-001</a></article>
</body></html>
''';

/// 真空搜索页（照活站 search 0 条形态）：整页无作品链接。
const _emptySearchHtml = '''
<html><body><div class="search-info">search UMSO-000 (0)</div></body></html>
''';

Future<String> _liveFetch(String url, Map<String, String> headers) async =>
    _liveListHtml;

void main() {
  group('18AV 活站结构解析', () {
    test('现行结构（figure+video+单引号 src）解析出卡', () {
      final cards = parseMjvCards(_liveListHtml);
      expect(cards, hasLength(2));
      expect(cards[0].ctype, 'chinese');
      expect(cards[0].num, '344250');
      expect(cards[0].slug, 'HMN-834');
      expect(cards[0].title, contains('HMN-834'));
      expect(cards[0].cover, contains('426873_HMN-834.jpg'));
      expect(cards[1].slug, 'MIAB-662');
    });

    test('旧 post 结构仍可解析（兜底式不回归）', () {
      const old = '''
<div class='post'><a href="/zh/chinese_content/255461/SSIS-001.html"><img src='https://img.test/c1.jpg'></a><div class='con'><h3><a href="/zh/chinese_content/255461/SSIS-001.html">SSIS-001 中字版</a></h3></div></div>
''';
      final cards = parseMjvCards(old);
      expect(cards, hasLength(1));
      expect(cards.single.slug, 'SSIS-001');
    });

    test('fetchCards：活站结构回真卡（中文字幕默认分类）', () async {
      const source = Av18ActressSource();
      final cards = await source.fetchCards(
        primaryId: '',
        secondaryId: '',
        query: '',
        page: 1,
        fetch: _liveFetch,
      );
      expect(cards, hasLength(2));
      expect(cards.first.pageUrl, contains('HMN-834.html'));
      expect(cards.first.title, contains('HMN-834'));
    });

    test('fetchCards：模板又变（有链接解析不到）抛中文原因', () async {
      Future<String> alien(String url, Map<String, String> headers) async =>
          _alienListHtml;
      const source = Av18ActressSource();
      await expectLater(
        source.fetchCards(
          primaryId: '',
          secondaryId: '',
          query: '',
          page: 1,
          fetch: alien,
        ),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.message,
            'message',
            contains('页面结构变了'),
          ),
        ),
      );
    });

    test('fetchCards：空响应抛中文原因', () async {
      Future<String> blank(String url, Map<String, String> headers) async =>
          '   ';
      const source = Av18ActressSource();
      await expectLater(
        source.fetchCards(
          primaryId: '',
          secondaryId: '',
          query: '',
          page: 1,
          fetch: blank,
        ),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.message,
            'message',
            contains('没有返回内容'),
          ),
        ),
      );
    });

    test('fetchCards：真空搜索结果回空表（不误报失败）', () async {
      Future<String> empty(String url, Map<String, String> headers) async =>
          _emptySearchHtml;
      const source = Av18ActressSource();
      final cards = await source.fetchCards(
        primaryId: '',
        secondaryId: '',
        query: 'UMSO-000',
        page: 1,
        fetch: empty,
      );
      expect(cards, isEmpty);
    });
  });

  group('py 桥失败不吞空', () {
    test('仓储 AppFailure 原样上抛（界面显真原因）', () async {
      final bridge = ActressPyBridge(
        _FakeRepository(catalogError: AppFailure('该站源当前不可用')),
      );
      await expectLater(
        bridge.browseCards(
          siteId: 'seed_missav',
          category: '',
          query: '',
          page: 1,
        ),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.message,
            'message',
            '该站源当前不可用',
          ),
        ),
      );
    });

    test('仓储其他异常转中文原因（不吞空表）', () async {
      final bridge = ActressPyBridge(
        _FakeRepository(catalogError: StateError('boom')),
      );
      await expectLater(
        bridge.browseCards(siteId: 'seed_chaoliu', category: '', query: '', page: 1),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.message,
            'message',
            contains('暂时取不到内容'),
          ),
        ),
      );
    });

    test('仓储正常回卡', () async {
      final bridge = ActressPyBridge(_FakeRepository());
      final cards = await bridge.browseCards(
        siteId: 'seed_missav',
        category: '',
        query: 'UMSO-659',
        page: 1,
      );
      expect(cards, hasLength(1));
      expect(cards.single.pageUrl, 'umso-659');
      expect(cards.single.title, contains('UMSO-659'));
    });
  });

  group('番号全源统一提取', () {
    OnlineVideoCard card(String url, [String title = '']) =>
        OnlineVideoCard(pageUrl: url, title: title);

    test('123AV 地址提番号', () {
      final source = actressOnlineSourceById('123av')!;
      expect(
        actressOnlineCardCode(
          source,
          card('https://123av.com/en/dm13/v/umso-659'),
        ),
        'UMSO-659',
      );
    });

    test('18AV 地址尾段 slug 即番号', () {
      const source = Av18ActressSource();
      expect(
        actressOnlineCardCode(
          source,
          card('https://18av.nl/zh/chinese_content/343899/UMSO-659.html'),
        ),
        'UMSO-659',
      );
    });

    test('潮流 py 卡 id（ctype#num#slug）提尾段番号', () {
      final source = ChaoliuPySource(ActressPyBridge(_FakeRepository()));
      expect(
        actressOnlineCardCode(
          source,
          card('chinese_content#343899#UMSO-659'),
        ),
        'UMSO-659',
      );
    });

    test('MissAV py 卡 id 即番号', () {
      final source = MissavPySource(ActressPyBridge(_FakeRepository()));
      expect(actressOnlineCardCode(source, card('umso-659')), 'UMSO-659');
    });

    test('PH 只认标题番号、viewkey 不误判', () {
      final source = actressOnlineSourceById('pornhub')!;
      expect(
        actressOnlineCardCode(
          source,
          card(
            'https://www.pornhub.com/view_video.php?viewkey=ph5e8a1b2c3d4e5f',
            '普通标题没有番号',
          ),
        ),
        '',
      );
      expect(
        actressOnlineCardCode(
          source,
          card(
            'https://www.pornhub.com/view_video.php?viewkey=ph5e8a1b2c3d4e5f',
            'ABF-352 搬运标题',
          ),
        ),
        'ABF-352',
      );
    });

    test('标题扫描：FC2 与连写式', () {
      expect(actressExtractCode('FC2-PPV-1234567 标题'), 'FC2-PPV-1234567');
      expect(actressExtractCode('前缀 UMSO659 后缀'), 'UMSO659');
      expect(actressExtractCode('2026/11/27 发布'), isNull);
      expect(actressExtractCode(''), isNull);
    });
  });

  group('桥接站注册与取卡', () {
    test('注册表盘点：110 站、站 id 不重、黑名单不在', () {
      expect(kActressBridgedSites, hasLength(110));
      final ids = [for (final s in kActressBridgedSites) s.stationId];
      expect(ids.toSet(), hasLength(ids.length));
      for (final banned in [
        'seed_whos',
        'seed_missav',
        'seed_chaoliu',
        'seed_nvku',
        'jar:zakatv:ZakaWhos',
        'jar:zakatv:ZakaMjv011',
        'jar:zakatv:zakajavpk',
      ]) {
        expect(ids, isNot(contains(banned)), reason: banned);
      }
    });

    test('桥接源集合：id 唯一、与既有六段不撞', () {
      final sources = actressBridgedLibrarySources(
        ActressPyBridge(_FakeRepository()),
      );
      expect(sources, hasLength(110));
      final ids = [for (final s in sources) s.id];
      expect(ids.toSet(), hasLength(110));
      for (final existing in ['123av', 'pornhub', 'av18', 'missav', 'chaoliu']) {
        expect(ids, isNot(contains(existing)));
      }
    });

    test('ensureTabs 装入仓储分类（全部 + 真实分类）', () async {
      final repo = _FakeRepository();
      final source = ActressBridgedSiteSource(
        ActressPyBridge(repo),
        station: kActressBridgedSites.first,
      );
      expect(source.primaryTabs, hasLength(1));
      await source.ensureTabs(repo);
      expect(source.primaryTabs.map((t) => t.id), ['all', 'c1', 'c2']);
      // 二次调用不重复装（一次性）。
      await source.ensureTabs(repo);
      expect(source.primaryTabs, hasLength(3));
    });

    test('桥接源取卡走仓储通道', () async {
      final repo = _FakeRepository();
      final source = ActressBridgedSiteSource(
        ActressPyBridge(repo),
        station: kActressBridgedSites.first,
      );
      final cards = await source.fetchCards(
        primaryId: 'all',
        secondaryId: '',
        query: 'UMSO-659',
        page: 1,
        fetch: _liveFetch,
      );
      expect(cards, hasLength(1));
      expect(cards.single.title, contains('UMSO-659'));
    });

    test('桥接源仓储失败抛中文原因（不吞空）', () async {
      final repo = _FakeRepository(catalogError: AppFailure('该站源当前不可用'));
      final source = ActressBridgedSiteSource(
        ActressPyBridge(repo),
        station: kActressBridgedSites.first,
      );
      await expectLater(
        source.fetchCards(
          primaryId: 'all',
          secondaryId: '',
          query: '',
          page: 1,
          fetch: _liveFetch,
        ),
        throwsA(isA<AppFailure>()),
      );
    });
  });

  group('详情页全源统一补全', () {
    late LocalStore store;
    late Directory cacheDir;

    setUp(() {
      store = LocalStore();
      cacheDir = Directory.systemTemp.createTempSync('bridge_detail_');
    });
    tearDown(() {
      store.dispose();
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    });

    void tallView(WidgetTester tester) {
      tester.view.physicalSize = const Size(420, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    ActressWorkDetailPage page({
      required ActressOnlineSource source,
      required OnlineVideoCard card,
      required _UmsoFakeDb db,
    }) {
      return ActressWorkDetailPage.online(
        source: source,
        card: card,
        fallback: ActressLibraryDbFallback(
          pathResolver: () async => '/fake/女优库.db',
          opener: (path) async => db.query,
        ),
        repository: _FakeRepository(),
        onlineFetch: _emptyOnlineFetch,
        javdbClient: JavdbApiClient(fetch: _javdbEmptyFetch),
        stillCapturer: _EmptyCapturer(),
        stillCache: ActressStillCache(directoryOf: () async => cacheDir),
        probeFetch: _probeOk,
        // 网盘池与会员探针注入假件：生产实现背后是引擎单例，
        // 其期约在测试假时钟区里跨测试不可靠（会拖住补充链
        // 收账、留下挂起计时器），与同仓其他详情页接缝同口
        // 径（见 actress_work_detail_page_test 的注入说明）。
        drivePlayFinder: DriveCodePlayFinder(
          isLoggedIn: () async => false,
          search: (keyword) async => const [],
          directLink: (file) async =>
              const CloudDirectLink(url: 'https://x.test/none.m3u8'),
        ),
        pan115VipProbe: () async => null,
        playerFactory: () => ControlledNativePlayer(),
        playUrlPrep: (url, headers) async => url,
      );
    }

    testWidgets('桥接站入口 UMSO-659：番号提取到、同番号补上简介', (
      tester,
    ) async {
      tallView(tester);
      final source = ActressBridgedSiteSource(
        ActressPyBridge(_FakeRepository()),
        station: kActressBridgedSites.first,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: page(
            source: source,
            card: const OnlineVideoCard(
              pageUrl: 'umso-659',
              title: 'UMSO-659 光泽绽放的曲线美巨乳若妻出差按摩',
              cover: 'https://img.test/umso.jpg',
            ),
            db: _UmsoFakeDb(withFill: true),
          ),
        ),
      );
      // 番号信息卡在位（补全链的钥匙已提取到）。
      await _until(tester, () => find.text('UMSO-659').evaluate().isNotEmpty);
      expect(find.text('UMSO-659'), findsWidgets);
      // 同番号互补把本地库简介补上（此前在线入口全空白）。
      await _until(
        tester,
        () => find.text('本地库同番号行的简介。').evaluate().isNotEmpty,
      );
      expect(find.text('本地库同番号行的简介。'), findsOneWidget);
      // 有内容了，底线说明不出。
      expect(find.byKey(const ValueKey('work-detail-fill-note')), findsNothing);
    });

    testWidgets('18AV 入口 UMSO-659：地址提番号、同番号补上简介', (
      tester,
    ) async {
      tallView(tester);
      const source = Av18ActressSource();
      await tester.pumpWidget(
        MaterialApp(
          home: page(
            source: source,
            card: const OnlineVideoCard(
              pageUrl:
                  'https://18av.nl/zh/chinese_content/343899/UMSO-659.html',
              title: 'UMSO-659 光泽绽放的曲线美巨乳若妻出差按摩',
              cover: 'https://img.test/umso.jpg',
            ),
            db: _UmsoFakeDb(withFill: true),
          ),
        ),
      );
      await _until(
        tester,
        () => find.text('本地库同番号行的简介。').evaluate().isNotEmpty,
      );
      expect(find.text('本地库同番号行的简介。'), findsOneWidget);
    });

    testWidgets('全链补不到：底线中文说明出现、海报标题以下不留空白', (
      tester,
    ) async {
      tallView(tester);
      final source = ActressBridgedSiteSource(
        ActressPyBridge(_FakeRepository()),
        station: kActressBridgedSites.first,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: page(
            source: source,
            card: const OnlineVideoCard(
              pageUrl: 'zzzz-000',
              title: 'ZZZZ-000 无资料样本',
              cover: '',
            ),
            db: _UmsoFakeDb(withFill: false),
          ),
        ),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('work-detail-fill-note'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.byKey(const ValueKey('work-detail-fill-note')),
        findsOneWidget,
      );
      expect(find.textContaining('详细资料暂时没补到'), findsOneWidget);
    });
  });
}

Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  int rounds = 60,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

class _EmptyCapturer implements ActressStillCapturer {
  @override
  Future<List<Uint8List>> captureFrames({
    required String url,
    Map<String, String> headers = const {},
    int count = 5,
  }) async => const [];
}

Future<String> _emptyOnlineFetch(String url, Map<String, String> headers) async =>
    '';

Future<String> _javdbEmptyFetch(String url) async {
  return jsonEncode({
    'success': true,
    'data': {'movies': <Object?>[]},
  });
}

Future<FeedProbeResponse> _probeOk(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async {
  return FeedProbeResponse(
    statusCode: 200,
    headers: const {},
    headBytes: utf8.encode('#EXTM3U\n#EXT-X-VERSION:3\n'),
  );
}

/// 假仓储：分类两档、目录恒回一张 UMSO-659 卡（或按注入
/// 抛错）、详情给 parse=1 计划（桥接取流回 null 用）。
class _FakeRepository extends AppRepository {
  _FakeRepository({this.catalogError});

  final Object? catalogError;

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [
    CatalogCategory('c1', '分类一'),
    CatalogCategory('c2', '分类二'),
  ];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    final error = catalogError;
    if (error != null) throw error;
    return CatalogPage([
      const Drama(
        id: 'umso-659',
        source: 'fake',
        title: 'UMSO-659 光泽绽放的曲线美巨乳若妻出差按摩',
        cover: 'https://img.test/umso.jpg',
      ),
    ], page: page);
  }

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async =>
      CatalogPage(const []);

  @override
  Future<void> searchAcrossProgressive(
    List<String> sources,
    String query, {
    required void Function(String source, List<Drama> items) onSite,
    bool Function()? shouldStop,
  }) async {}

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => drama.cover;

  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail(drama, [
    Episode({'id': 'x', 'title': '正片', 'parse': 1}, 1),
  ]);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async => const PlaybackPlan(url: '');
}

/// UMSO-659 假库（查询函数形态，同 samecode 批）：withFill
/// 时 sameCode 两查回简介与演员头像，其余查询全空。
class _UmsoFakeDb {
  _UmsoFakeDb({required this.withFill});

  final bool withFill;
  final tables = {
    'videos',
    'video_play_urls',
    'video_actress',
    'actresses',
    'video_tag',
    'video_ranking',
    'index_categories',
  };

  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? args,
  ]) async {
    if (sql.contains('sqlite_master')) {
      return [for (final t in tables) {'name': t}];
    }
    if (sql.contains('PRAGMA table_info(actresses)')) {
      return [
        {'name': 'name'},
        {'name': 'avatar'},
      ];
    }
    if (sql.contains('PRAGMA table_info(videos)')) {
      return [
        {'name': 'content'},
      ];
    }
    if (sql.contains('PRAGMA')) return [];
    if (withFill && sql.contains('vod_id IN (')) {
      if (sql.contains('content AS content')) {
        return [
          {'content': '本地库同番号行的简介。'},
        ];
      }
      if (sql.contains('a.avatar AS avatar')) {
        return [
          {'name': '鈴木真夕', 'avatar': 'https://img.test/mayu.jpg'},
        ];
      }
    }
    return [];
  }
}
