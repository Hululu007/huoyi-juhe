import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_database.dart';
import 'package:fqapp/actress/actress_detail_page.dart';
import 'package:fqapp/actress/actress_json_fallback.dart';
import 'package:fqapp/actress/actress_m3u_index.dart';
import 'package:fqapp/actress/actress_models.dart';
import 'package:fqapp/actress/actress_play.dart';

import 'package:fqapp/actress/actress_crosssite_probe.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/actress/actress_adapter_http.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_widgets.dart';

import 'actress_fixtures.dart';
import 'support/controlled_player.dart';

/// 演员库点卡播放优化（2026-11-18）：兜底 MJV 优先探查、点卡直进
/// 详情页起播、封面按番号先走 MJV。兜底站 key 见
/// [actressFallbackSiteIds]：mjv011（jar）→ chaoliu（py）→
/// v_mjv011（Go 槽）→ 18AV 双生站（av18avmcg、av18av）。

const _mjvJarSite = SourceSite(
  'jar:zakatv:ZakaMjv011',
  '🔞mjv011',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _chaoliuSite = SourceSite(
  'chaoliu',
  '🔞潮流',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _mjvGoSite = SourceSite(
  'v_mjv011',
  '🔞mjv011',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _av18mcgSite = SourceSite(
  'jar:zakatv:av18avmcg',
  '🔞18AV',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _av18Site = SourceSite(
  'jar:zakatv:av18av',
  '🔞18AV',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _otherSite = SourceSite(
  'test-site-other',
  '🔞其他站',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);

const _allFallbackTestSites = [
  _mjvJarSite,
  _chaoliuSite,
  _mjvGoSite,
  _av18mcgSite,
  _av18Site,
  _otherSite,
];

void _registerFallbackTestSites() {
  for (final site in _allFallbackTestSites) {
    SourceSite.importedSites[site.id] = site;
  }
}

/// 验活假探针：永远可播（合成地址 example.test 在测试里没有真服务，
/// 默认探针会判死；链测试只测链逻辑，不测真网络）。
Future<FeedProbeResponse> _alwaysPlayable(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async => const FeedProbeResponse(
  statusCode: 200,
  headers: {'content-type': 'video/mp4'},
  headBytes: [1],
);

/// 按地址判活的假探针：地址含 'dead' 的判死，其余判活。
Future<FeedProbeResponse> _playableUnlessDead(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async => url.contains('dead')
    ? const FeedProbeResponse(statusCode: 404, headers: {}, headBytes: [])
    : const FeedProbeResponse(
        statusCode: 200,
        headers: {'content-type': 'video/mp4'},
        headBytes: [1],
      );

/// 假兜底 json 文档：顶层四键、每行 15 字段同顺序（见
/// validateActressJsonDocument），只给 whos.json 用。
String _fakeFallbackDoc(List<Map<String, dynamic>> rows) => jsonEncode({
  'list': rows,
  'parse': '',
  'jx': '',
  'last_update': '2026-11-20',
});

Map<String, dynamic> _fakeFallbackRow({
  required String vodId,
  required String vodCode,
  required String vodName,
  required String playUrl,
  String vodPic = '',
  String vodActor = '女演员甲',
  String vodPlayFrom = 'whos',
}) => {
  'vod_id': vodId,
  'vod_name': vodName,
  'vod_pic': vodPic,
  'vod_actor': vodActor,
  'vod_director': '',
  'vod_remarks': '',
  'vod_pubdate': '',
  'vod_area': '',
  'vod_year': '',
  'vod_content': '',
  'vod_play_from': vodPlayFrom,
  'vod_play_url': playUrl,
  'type_name': '',
  'vod_code': vodCode,
  'vod_actress_pic': '',
};

/// 假影视库 db（第一档）：按番号回 DB 行；名字路回空。
class _FakeFilmDb implements FilmDbFallbackProvider {
  _FakeFilmDb(this.rowsByCode);

  final Map<String, List<ActressJsonEntry>> rowsByCode;

  @override
  Future<List<ActressJsonEntry>> entriesForActress(
    String name, {
    String? site,
  }) async => const [];

  @override
  Future<List<ActressJsonEntry>> entriesForCode(
    String codeKey, {
    String? site,
  }) async => rowsByCode[codeKey] ?? const [];
}

/// 假 DB 行：直拼 ActressJsonEntry（不走 json 文本）。
ActressJsonEntry _dbEntry({
  required String vodId,
  required String playUrl,
  String site = 'mjv',
  String vodName = 'SSIS-00123 库里标题',
}) => ActressJsonEntry(
  site: site,
  vodId: vodId,
  vodName: vodName,
  vodPic: '',
  vodActor: '女演员甲',
  vodDirector: '',
  vodRemarks: '',
  vodPubdate: '',
  vodArea: '',
  vodYear: '',
  vodContent: '',
  vodPlayFrom: site,
  vodPlayUrl: '正片\$$playUrl',
  typeName: '',
  vodCode: 'SSIS-00123',
  vodActressPic: '',
);

void _unregisterFallbackTestSites() {
  for (final site in _allFallbackTestSites) {
    SourceSite.importedSites.remove(site.id);
  }
}

Future<LocalStore> _makeFallbackStore() async {
  final store = LocalStore();
  addTearDown(store.dispose);
  return store;
}

DramaDetail _fallbackDetailFor(String dramaId, String source, String title) =>
    DramaDetail(Drama(id: dramaId, source: source, title: title), [
      Episode({'id': '1', 'title': 'Full', 'flag': '线路1'}, 1),
    ]);

class _RecordingProbeService extends CrossSiteProbeService {
  _RecordingProbeService({required super.repository, required this.results});

  final Map<String, CrossSiteProbeResult> results;
  final probed = <String>[];

  @override
  Future<CrossSiteProbeResult> probeProvider(
    CrossSiteProvider provider,
    String siteId,
    String avId,
  ) async {
    probed.add(siteId);
    return results[siteId] ??
        CrossSiteProbeResult(
          provider: provider,
          siteId: siteId,
          status: CrossSiteProbeStatus.empty,
        );
  }
}

CrossSiteProbeResult _fallbackFoundResult(
  CrossSiteProvider provider,
  String siteId,
  String dramaId,
  String title,
) => CrossSiteProbeResult(
  provider: provider,
  siteId: siteId,
  status: CrossSiteProbeStatus.found,
  versions: [
    CrossSiteVersion(
      label: dramaId,
      detail: _fallbackDetailFor(dramaId, siteId, title),
      lines: const [CrossSiteLine(label: '线路1', episodeIndex: 0)],
    ),
  ],
);

class _FallbackRepository extends FixtureRepository {
  Map<String, List<Drama>> searchByQuery = {};
  Future<CatalogPage> Function(List<String> sources, String query)?
  searchHandler;
  Map<String, DramaDetail> detailsById = {};
  Set<String> failingResolveIds = {};

  /// 按剧 id 定取流地址：不设时一律回合成地址。
  Map<String, String> resolveUrls = {};

  /// 大于等于 0 时：前 N 次 resolve 成功，之后全部失败（widget 测试
  /// 用：链预检成功一次，播放器起播再解时失败进错误态，不建真
  /// 播放器）。-1 表示永远成功。
  var resolveSuccessBudget = -1;
  final resolveCalls = <String>[];
  final searchCalls = <({List<String> sources, String query})>[];

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    searchCalls.add((sources: List.of(sources), query: query));
    final handler = searchHandler;
    if (handler != null) return handler(sources, query);
    return CatalogPage(searchByQuery[query] ?? const []);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async =>
      detailsById[drama.id] ?? super.detail(drama);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    bool adBlock = true,
    int quality = 0,
    int route = 0,
  }) async {
    resolveCalls.add(drama.id);
    if (failingResolveIds.contains(drama.id)) {
      throw AppFailure('合成解析失败');
    }
    if (resolveSuccessBudget == 0) {
      throw AppFailure('合成解析失败');
    }
    if (resolveSuccessBudget > 0) resolveSuccessBudget--;
    return PlaybackPlan(
      url: resolveUrls[drama.id] ?? 'https://example.test/synthetic.mp4',
    );
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

void main() {
  group('兜底链探查顺序', () {
    late _FallbackRepository repository;
    late LocalStore store;

    setUp(() async {
      _registerFallbackTestSites();
      addTearDown(_unregisterFallbackTestSites);
      repository = _FallbackRepository();
      store = await _makeFallbackStore();
    });

    ActressPlayChain chainWith(
      _RecordingProbeService probe, {
      List<SourceSite>? sites,
      FeedProbeFetch? verifyFetch,
    }) => ActressPlayChain(
      repository: repository,
      store: store,
      avId: 'SSIS-00123',
      candidateSites:
          sites ??
          [
            _otherSite,
            _av18Site,
            _mjvGoSite,
            _chaoliuSite,
            _av18mcgSite,
            _mjvJarSite,
          ],
      probeService: probe,
      probeConcurrency: 1,
      verifyFetch: verifyFetch ?? _alwaysPlayable,
    );

    test('先探 MJV 系再探 18AV 再探其他站', () async {
      final probe = _RecordingProbeService(
        repository: repository,
        results: const {},
      );
      final chain = chainWith(probe);
      expect(
        await chain.nextPlayable(profileEpoch: store.profileEpoch),
        isNull,
      );
      expect(probe.probed, [
        'jar:zakatv:ZakaMjv011',
        'chaoliu',
        'v_mjv011',
        'jar:zakatv:av18avmcg',
        'jar:zakatv:av18av',
        'test-site-other',
      ]);
    });

    test('MJV 命中直接返回，不再探其他站', () async {
      final probe = _RecordingProbeService(
        repository: repository,
        results: {
          'jar:zakatv:ZakaMjv011': _fallbackFoundResult(
            const CrossSiteProvider(
              id: 'jar:zakatv:ZakaMjv011',
              name: '🔞mjv011',
              siteIds: ['jar:zakatv:ZakaMjv011'],
              lazy: false,
            ),
            'jar:zakatv:ZakaMjv011',
            'mjv-drama',
            'SSIS-00123 MJV 标题',
          ),
        },
      );
      final chain = chainWith(probe);
      final candidate = await chain.nextPlayable(
        profileEpoch: store.profileEpoch,
      );
      expect(candidate, isNotNull);
      expect(candidate!.detail.drama.source, 'jar:zakatv:ZakaMjv011');
      expect(probe.probed, ['jar:zakatv:ZakaMjv011']);
    });

    test('MJV 未命中回落全站探查', () async {
      final probe = _RecordingProbeService(
        repository: repository,
        results: {
          'test-site-other': _fallbackFoundResult(
            const CrossSiteProvider(
              id: 'test-site-other',
              name: '🔞其他站',
              siteIds: ['test-site-other'],
              lazy: false,
            ),
            'test-site-other',
            'other-drama',
            'SSIS-00123 其他标题',
          ),
        },
      );
      final chain = chainWith(probe);
      final candidate = await chain.nextPlayable(
        profileEpoch: store.profileEpoch,
      );
      expect(candidate, isNotNull);
      expect(candidate!.detail.drama.source, 'test-site-other');
      expect(probe.probed, [
        'jar:zakatv:ZakaMjv011',
        'chaoliu',
        'v_mjv011',
        'jar:zakatv:av18avmcg',
        'jar:zakatv:av18av',
        'test-site-other',
      ]);
    });

    test('兜底取流失败自动换下一条', () async {
      repository.failingResolveIds = {'mjv-drama'};
      final probe = _RecordingProbeService(
        repository: repository,
        results: {
          'jar:zakatv:ZakaMjv011': _fallbackFoundResult(
            const CrossSiteProvider(
              id: 'jar:zakatv:ZakaMjv011',
              name: '🔞mjv011',
              siteIds: ['jar:zakatv:ZakaMjv011'],
              lazy: false,
            ),
            'jar:zakatv:ZakaMjv011',
            'mjv-drama',
            'SSIS-00123 MJV 标题',
          ),
          'test-site-other': _fallbackFoundResult(
            const CrossSiteProvider(
              id: 'test-site-other',
              name: '🔞其他站',
              siteIds: ['test-site-other'],
              lazy: false,
            ),
            'test-site-other',
            'other-drama',
            'SSIS-00123 其他标题',
          ),
        },
      );
      final chain = chainWith(probe);
      final candidate = await chain.nextPlayable(
        profileEpoch: store.profileEpoch,
      );
      expect(candidate, isNotNull);
      expect(candidate!.detail.drama.source, 'test-site-other');
      expect(repository.resolveCalls, ['mjv-drama', 'other-drama']);
    });

    test('直链验活失败换下一条，不开死地址', () async {
      repository.resolveUrls = {
        'mjv-drama': 'https://example.test/dead-mjv.mp4',
        'other-drama': 'https://example.test/other.mp4',
      };
      final probe = _RecordingProbeService(
        repository: repository,
        results: {
          'jar:zakatv:ZakaMjv011': _fallbackFoundResult(
            const CrossSiteProvider(
              id: 'jar:zakatv:ZakaMjv011',
              name: '🔞mjv011',
              siteIds: ['jar:zakatv:ZakaMjv011'],
              lazy: false,
            ),
            'jar:zakatv:ZakaMjv011',
            'mjv-drama',
            'SSIS-00123 MJV 标题',
          ),
          'test-site-other': _fallbackFoundResult(
            const CrossSiteProvider(
              id: 'test-site-other',
              name: '🔞其他站',
              siteIds: ['test-site-other'],
              lazy: false,
            ),
            'test-site-other',
            'other-drama',
            'SSIS-00123 其他标题',
          ),
        },
      );
      final chain = chainWith(probe, verifyFetch: _playableUnlessDead);
      final candidate = await chain.nextPlayable(
        profileEpoch: store.profileEpoch,
      );
      expect(candidate, isNotNull);
      expect(candidate!.detail.drama.source, 'test-site-other');
      expect(repository.resolveCalls, ['mjv-drama', 'other-drama']);
      // 死地址的站也记进已试：链耗尽时报数有据。
      expect(
        chain.triedSources,
        containsAll(['jar:zakatv:ZakaMjv011', 'test-site-other']),
      );
    });

    test('resetForRetry 后重探同一条，不复用死候选', () async {
      final probe = _RecordingProbeService(
        repository: repository,
        results: {
          'jar:zakatv:ZakaMjv011': _fallbackFoundResult(
            const CrossSiteProvider(
              id: 'jar:zakatv:ZakaMjv011',
              name: '🔞mjv011',
              siteIds: ['jar:zakatv:ZakaMjv011'],
              lazy: false,
            ),
            'jar:zakatv:ZakaMjv011',
            'mjv-drama',
            'SSIS-00123 MJV 标题',
          ),
        },
      );
      final chain = chainWith(probe);
      final first = await chain.nextPlayable(profileEpoch: store.profileEpoch);
      expect(first, isNotNull);
      expect(first!.detail.drama.id, 'mjv-drama');
      expect(probe.probed, ['jar:zakatv:ZakaMjv011']);
      chain.resetForRetry();
      expect(chain.triedSources, isEmpty);
      final second = await chain.nextPlayable(profileEpoch: store.profileEpoch);
      expect(second, isNotNull);
      expect(second!.detail.drama.id, 'mjv-drama');
      expect(probe.probed, ['jar:zakatv:ZakaMjv011', 'jar:zakatv:ZakaMjv011']);
    });

    test('preferSiteId 让作品自己的站先探', () async {
      final probe = _RecordingProbeService(
        repository: repository,
        results: const {},
      );
      final chain = ActressPlayChain(
        repository: repository,
        store: store,
        avId: 'SSIS-00123',
        candidateSites: const [
          _otherSite,
          _av18Site,
          _mjvGoSite,
          _chaoliuSite,
          _av18mcgSite,
          _mjvJarSite,
        ],
        probeService: probe,
        probeConcurrency: 1,
        verifyFetch: _alwaysPlayable,
        preferSiteId: 'chaoliu',
      );
      expect(
        await chain.nextPlayable(profileEpoch: store.profileEpoch),
        isNull,
      );
      expect(probe.probed, [
        'chaoliu',
        'jar:zakatv:ZakaMjv011',
        'v_mjv011',
        'jar:zakatv:av18avmcg',
        'jar:zakatv:av18av',
        'test-site-other',
      ]);
      expect(chain.triedSources, hasLength(6));
    });
  });

  group('点卡直进详情页', () {
    late MemoryActressDatabase db;
    late _FallbackRepository repository;
    late LocalStore store;

    setUp(() async {
      _registerFallbackTestSites();
      addTearDown(_unregisterFallbackTestSites);
      db = MemoryActressDatabase();
      repository = _FallbackRepository();
      store = await _makeFallbackStore();
    });

    Future<ActressPerson> seedPerson() async {
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'X1',
          name: '女演员甲',
          sex: 'female',
        ),
      ))!;
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-00123', date: '2024-01-01'),
      ]);
      return (await db.personById(person.localId))!;
    }

    /// 错误面板渲染会触发一条既有框架断言（StatusPanel 内
    /// ExpansionTile 含 ListTile，见 player_sniff_back_test.dart），
    /// 与本批改动无关，只放行这一条。
    void suppressKnownListTileAssertion() {
      final original = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        if (details.toString().contains(
          'ListTile background color or ink splashes',
        )) {
          return;
        }
        original?.call(details);
      };
      addTearDown(() {
        FlutterError.onError = original;
      });
    }

    Future<void> pumpDetailPage(
      WidgetTester tester, {
      ActressJsonFallback? fallback,
      FilmDbFallbackProvider? filmDb,
      FeedProbeFetch? verifyFetch,
    }) async {
      final person = await seedPerson();
      await tester.pumpWidget(
        MaterialApp(
          home: ActressDetailPage(
            localId: person.localId,
            repository: repository,
            store: store,
            database: db,
            fallback: fallback,
            filmDb: filmDb,
            verifyFetch: verifyFetch ?? _alwaysPlayable,
            // 修仙版没有 DetailScreen：点卡进修仙版 PlayerPage，
            // 用假播放器（真 NativePlayer 在测试里建不起来）。
            playerFactory: () => ControlledNativePlayer(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// 有界等待详情页出现（播放器内有定时器，不用 pumpAndSettle）。
    Future<void> pumpUntilDetail(WidgetTester tester) async {
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(PlayerPage).evaluate().isNotEmpty) break;
      }
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    /// 假兜底：只有 whos.json 里有一条 SSIS-00123 的行（mjv 那份空），
    /// 播放地址由调用方定。2026-11-22 只走数据库后，详情页不再读
    /// 这些 json 行——这里只用来回归“给了 json 行也不进播放池”
    /// （见“第一档本地 db 活的”）。localJsonDir 传空临时目录：
    /// 不传时 load() 会调 getApplicationDocumentsDirectory()，
    /// widget 测试里它永远不返回（见 testWidgets FakeAsync +
    /// async dart:io 挂起）。
    /// mjvPlayUrl 非空时 mjv.json 也补一条同番号行（vod_play_from
    /// 须写 mjv：mjv011.json 是规范文件，站按 vod_play_from 认，
    /// 写 whos 会与 whos 行同键被合并掉）。
    Future<ActressJsonFallback> fakeFallbackWithRow({
      required String playUrl,
      String? mjvPlayUrl,
    }) async {
      final temp = Directory.systemTemp.createTempSync();
      addTearDown(() {
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
      File('${temp.path}/whos.json').writeAsStringSync(
        _fakeFallbackDoc([
          _fakeFallbackRow(
            vodId: 'ssis-row-1',
            vodCode: 'SSIS-00123',
            vodName: 'SSIS-00123 存的标题',
            playUrl: playUrl,
          ),
        ]),
      );
      if (mjvPlayUrl != null) {
        File('${temp.path}/mjv011.json').writeAsStringSync(
          _fakeFallbackDoc([
            _fakeFallbackRow(
              vodId: 'mjv-row-1',
              vodCode: 'SSIS-00123',
              vodName: 'SSIS-00123 MJV 死链标题',
              playUrl: mjvPlayUrl,
              vodPlayFrom: 'mjv',
            ),
          ]),
        );
      }
      final fallback = ActressJsonFallback(
        localJsonDir: temp,
        // m3u 索引给空 manifest：只走数据库后 json/m3u 行都不进池，
        // 这里留空只是不让它干扰。
        m3uIndex: WhosM3uIndex(
          bytesReader: (_) async =>
              Uint8List.fromList(gzip.encode(utf8.encode('{}'))),
        ),
      );
      await fallback.load();
      return fallback;
    }

    testWidgets('存的地址活的：直接播，不探链', (tester) async {
      suppressKnownListTileAssertion();
      // 库里地址 resolve 1 次成功；播放器起播再解时失败进错误态，
      // 不建真播放器。
      repository.resolveSuccessBudget = 1;
      await pumpDetailPage(
        tester,
        // 2026-11-22 只走数据库：存的地址现在指库里（filmDb）的行，
        // 不再是注入的 json 兜底行——_loadFallback 只读 db 行。
        filmDb: _FakeFilmDb({
          'SSIS123': [
            _dbEntry(
              vodId: 'db-row-1',
              playUrl: 'https://example.test/whos-ssis.mp4',
              vodName: 'SSIS-00123 存的标题',
            ),
          ],
        }),
      );
      await tester.tap(find.byType(DramaTile).first);
      await pumpUntilDetail(tester);
      expect(find.byType(PlayerPage), findsOneWidget);
      // 修仙版 PlayerPage 标题不在常驻文本里（顶栏只在控制层可见时
      // 才画标题）：直接断言进播放页那部作品的标题属性。
      expect(
        tester.widget<PlayerPage>(find.byType(PlayerPage)).title,
        'SSIS-00123 存的标题',
      );
      expect(find.text('暂无可播片源'), findsNothing);
      expect(find.text('这条播不了，已试过 6 个站'), findsNothing);
      // 只解过存的地址（链已删、没多解别的站）。
      expect(repository.resolveCalls, contains('json:mjv:db-row-1'));
      expect(
        repository.resolveCalls.every((id) => id == 'json:mjv:db-row-1'),
        isTrue,
      );
            // NativePlayer.setKeepScreenOn 在 PlayerPage 的 initState
      // 与 dispose 各调一次；方法通道在测试里无应答，.timeout
      // (10 秒) 的定时器一直挂着。先拆树（dispose 再建一个），再
      // 把假时钟拨过 10 秒让两个超时定时器都触发（通道报超时异
      // 常，dispose 里已 catch），否则框架在拆树后报“仍有 Timer
      // 待处理”。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
    });

    testWidgets('mjv 死链：存的 mjv 地址死了，落到同番号 whos 行，不探链', (tester) async {
      suppressKnownListTileAssertion();
      // 主会话 2026-11-20 20:27 查实：mjv011.json 里存的 m3u8
      // 已系统性死亡（7 个 streamfastpro 域名抽验全 404），
      // whos.json 5 条全 200——库里 mjv 死、whos 活是常态，
      // 不是偶然。存的地址要按站逐条验活、死的跳过、活的播。
      repository.resolveUrls = {
        'json:mjv:mjv-row-1': 'https://example.test/dead-mjv.mp4',
        'json:whos:ssis-row-1': 'https://example.test/whos-ssis.mp4',
      };
      // mjv resolve 1 次 + whos resolve 1 次成功；播放器起播
      // 再解时失败进错误态，不建真播放器。
      repository.resolveSuccessBudget = 2;
      await pumpDetailPage(
        tester,
        // 2026-11-22 只走数据库：两条存的地址都改由库里（filmDb）
        // 给，不再走注入的 json 兜底行；顺序即 filmDb 回的行序。
        filmDb: _FakeFilmDb({
          'SSIS123': [
            _dbEntry(
              vodId: 'mjv-row-1',
              playUrl: 'https://example.test/dead-mjv.mp4',
              vodName: 'SSIS-00123 MJV 死链标题',
            ),
            _dbEntry(
              vodId: 'ssis-row-1',
              playUrl: 'https://example.test/whos-ssis.mp4',
              site: 'whos',
              vodName: 'SSIS-00123 存的标题',
            ),
          ],
        }),
        verifyFetch: _playableUnlessDead,
      );
      await tester.tap(find.byType(DramaTile).first);
      await pumpUntilDetail(tester);
      expect(find.byType(PlayerPage), findsOneWidget);
      // 进播放页的是 whos 那行（存的标题），不是死的 mjv 那行。
      expect(
        tester.widget<PlayerPage>(find.byType(PlayerPage)).title,
        'SSIS-00123 存的标题',
      );
      // 先解 mjv（死了）、再解 whos（活了播它），不探链。修仙版
      // PlayerPage 播失败会静默重试、每次重试都再调一次 resolve
      //（魔蚁 DetailScreen 只解一次），所以不断言精确列表，只
      // 断言前两条顺序与“只解过这两条”。
      expect(
        repository.resolveCalls.take(2).toList(),
        ['json:mjv:mjv-row-1', 'json:whos:ssis-row-1'],
      );
      expect(
        repository.resolveCalls.every(
          (id) =>
              id == 'json:mjv:mjv-row-1' || id == 'json:whos:ssis-row-1',
        ),
        isTrue,
      );
            // NativePlayer.setKeepScreenOn 在 PlayerPage 的 initState
      // 与 dispose 各调一次；方法通道在测试里无应答，.timeout
      // (10 秒) 的定时器一直挂着。先拆树（dispose 再建一个），再
      // 把假时钟拨过 10 秒让两个超时定时器都触发（通道报超时异
      // 常，dispose 里已 catch），否则框架在拆树后报“仍有 Timer
      // 待处理”。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
    });

    testWidgets('第一档本地 db 活的：播库里的地址，不探链、不走内置', (tester) async {
      suppressKnownListTileAssertion();
      // 库里地址 resolve 1 次成功；播放器起播再解时失败进错误态，
      // 不建真播放器。
      repository.resolveSuccessBudget = 1;
      await pumpDetailPage(
        tester,
        // 2026-11-22 只走数据库：json 兜底行即使给了也不进播放池，
        // 下面断言“存的标题”不出现就是这条回归检查。
        fallback: await fakeFallbackWithRow(
          playUrl: '正片\$https://example.test/whos-ssis.mp4',
        ),
        filmDb: _FakeFilmDb({
          'SSIS123': [
            _dbEntry(
              vodId: 'db-row-1',
              playUrl: 'https://example.test/db-ssis.mp4',
            ),
          ],
        }),
      );
      await tester.tap(find.byType(DramaTile).first);
      await pumpUntilDetail(tester);
      expect(find.byType(PlayerPage), findsOneWidget);
      // 进播放页的是库里那行（库里标题），注入的 json 行不进池。
      expect(
        tester.widget<PlayerPage>(find.byType(PlayerPage)).title,
        'SSIS-00123 库里标题',
      );
      // 只解过库里的地址（内置行没解、不探链）。
      expect(repository.resolveCalls, contains('json:mjv:db-row-1'));
      expect(
        repository.resolveCalls.every((id) => id == 'json:mjv:db-row-1'),
        isTrue,
      );
            // NativePlayer.setKeepScreenOn 在 PlayerPage 的 initState
      // 与 dispose 各调一次；方法通道在测试里无应答，.timeout
      // (10 秒) 的定时器一直挂着。先拆树（dispose 再建一个），再
      // 把假时钟拨过 10 秒让两个超时定时器都触发（通道报超时异
      // 常，dispose 里已 catch），否则框架在拆树后报“仍有 Timer
      // 待处理”。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
    });

  });

  // 暂缓：'嗅探页接受加载失败回调' 未移植——SniffWebViewPage 是
  // 魔蚁 playback_sniffer.dart 的嗅探页，修仙版没有等价物；
  // 女优库点播只走数据库，不走嗅探页。
}
