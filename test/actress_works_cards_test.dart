// 女优作品卡片列表修复（2026-11-19）：
// ① 同步时取 MissAV 封面 + 按来源站写 coverSource；
// ② 补封面流式 + 番号路墙钟上限；
// ③ 点作品卡快路径直取详情进页；
// ④ 探活链总预算内收敛；
// ⑤ MissAV 女优 folder 详情画作品卡片网格（多部与单部都不退回选集）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_database.dart';
import 'package:fqapp/actress/actress_detail_page.dart';
import 'package:fqapp/actress/actress_json_fallback.dart';
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

const _missavSite = SourceSite(
  'jar:missav30:ZakaMissav',
  '🔞MissAV',
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
const _coverSite = SourceSite(
  'test-cover-a',
  '🔞测试站A',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);

void _registerCardsTestSites() {
  for (final site in [_missavSite, _otherSite, _coverSite]) {
    SourceSite.importedSites[site.id] = site;
  }
}

void _unregisterCardsTestSites() {
  for (final site in [_missavSite, _otherSite, _coverSite]) {
    SourceSite.importedSites.remove(site.id);
  }
}

Future<LocalStore> _makeCardsStore() async {
  final store = LocalStore();
  addTearDown(store.dispose);
  return store;
}

/// 本批测试共用的假仓：详情/目录/搜索均可脚本化；封面返回空
/// （卡片形态不断言真图，只断言卡片与网格本身）。
class _CardsRepository extends FixtureRepository {
  Map<String, DramaDetail> detailsById = {};
  final detailIds = <String>[];
  Map<String, List<Drama>> catalogByCategory = {};
  var catalogFail = false;
  final catalogCategories = <String>[];
  Map<String, List<Drama>> searchByQuery = {};
  final searchQueries = <String>[];
  Duration searchDelay = Duration.zero;
  Set<String> delayedQueries = {};

  /// 流式搜索注入：不设时走默认实现（批回 searchAcross 再按站拆开）。
  Future<void> Function(
    List<String> sources,
    String query, {
    required void Function(String source, List<Drama> items) onSite,
    bool Function()? shouldStop,
  })?
  progressiveHandler;

  @override
  Future<void> searchAcrossProgressive(
    List<String> sources,
    String query, {
    required void Function(String source, List<Drama> items) onSite,
    bool Function()? shouldStop,
  }) async {
    final handler = progressiveHandler;
    if (handler != null) {
      return handler(sources, query, onSite: onSite, shouldStop: shouldStop);
    }
    return super.searchAcrossProgressive(
      sources,
      query,
      onSite: onSite,
      shouldStop: shouldStop,
    );
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    detailIds.add(drama.id);
    return detailsById[drama.id] ?? super.detail(drama);
  }

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    catalogCategories.add(category);
    if (catalogFail) throw AppFailure('合成目录失败');
    final items = catalogByCategory[category] ?? const [];
    return CatalogPage(items, hasMore: false, page: page);
  }

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    searchQueries.add(query);
    if (delayedQueries.contains(query)) {
      await Future.delayed(searchDelay);
    }
    return CatalogPage(searchByQuery[query] ?? const []);
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

DramaDetail _cardsDetailFor(String dramaId, String source, String title) =>
    DramaDetail(Drama(id: dramaId, source: source, title: title), [
      Episode({'id': '1', 'title': 'Full', 'flag': '线路1'}, 1),
    ]);

/// 假影视库 db：按番号回库里行（2026-11-22 只走数据库：点卡只试
/// 这些行，不再走封面站记下的详情 id、也不跨站探活）。
class _CardsFilmDb implements FilmDbFallbackProvider {
  _CardsFilmDb(this.rowsByCode);

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

void main() {
  group('同步时取 MissAV 封面', () {
    test('upsertWorks 按来源站写封面：MissAV 有封面、whos 语义不变', () async {
      final db = MemoryActressDatabase();
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.missav,
          sourceId: '/dm16/cn/actresses/x',
          name: '测试女优',
        ),
      ))!;
      final id = person.localId;
      await db.upsertWorks(id, const [
        RosterFilm(
          code: 'SSIS-00123',
          coverUrl: 'https://cdn.example.com/c1.jpg',
          detailUrl: '/dm16/cn/ssis00123',
        ),
        RosterFilm(code: 'SSIS-00124'),
      ], coverSource: actressRosterCoverSource(ActressRosterSourceId.missav));
      var works = await db.worksForPerson(id, offset: 0, limit: 100);
      final missav = works.firstWhere((w) => w.codeDisplay == 'SSIS-00123');
      expect(missav.hasCover, isTrue);
      expect(missav.coverSource, 'jar:missav30:ZakaMissav');
      expect(missav.coverDramaId, '/dm16/cn/ssis00123');
      expect(missav.coverUrl, 'https://cdn.example.com/c1.jpg');
      // whos 默认：不传来源参数仍记 whos；无封面的仍全空。
      await db.upsertWorks(id, const [
        RosterFilm(
          code: 'MIAD-854',
          coverUrl: 'https://cdn.example.com/c.jpg',
          detailUrl: '/videos/miad-854',
        ),
        RosterFilm(code: 'MIAD-855'),
      ]);
      works = await db.worksForPerson(id, offset: 0, limit: 100);
      final whos = works.firstWhere((w) => w.codeDisplay == 'MIAD-854');
      expect(whos.coverSource, 'whos');
      expect(whos.hasCover, isTrue);
      final plain = works.firstWhere((w) => w.codeDisplay == 'MIAD-855');
      expect(plain.hasCover, isFalse);
      // 来源站为空：有封面地址也不认站源、不写封面。
      await db.upsertWorks(id, const [
        RosterFilm(
          code: 'ABC-999',
          coverUrl: 'https://cdn.example.com/c9.jpg',
          detailUrl: '/x',
        ),
      ], coverSource: '');
      works = await db.worksForPerson(id, offset: 0, limit: 100);
      final dropped = works.firstWhere((w) => w.codeDisplay == 'ABC-999');
      expect(dropped.hasCover, isFalse);
      expect(dropped.coverSource, isEmpty);
    });
  });

  group('点作品卡快路径', () {
    late MemoryActressDatabase db;
    late _CardsRepository repository;
    late LocalStore store;

    setUp(() async {
      _registerCardsTestSites();
      addTearDown(_unregisterCardsTestSites);
      db = MemoryActressDatabase();
      repository = _CardsRepository();
      store = await _makeCardsStore();
    });

    testWidgets('有封面的作品点卡走库里地址进详情页播，不弹找片遮罩', (tester) async {
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'X1',
          name: '女演员甲',
          sex: 'female',
        ),
      ))!;
      await db.upsertWorks(person.localId, const [
        RosterFilm(
          code: 'SSIS-00123',
          coverUrl: 'https://cover/x.jpg',
          detailUrl: 'other-drama',
        ),
      ], coverSource: 'test-site-other');
      // 2026-11-22 只走数据库：点卡只试库里这行（番号 SSIS-00123
      // 的直链），不再走封面站记下的详情 id、也不建探活链；库里
      // 行的剧 id 是 toDramaDetail 拼出的 'json:站:vodId'，详情
      // 仓按这个 id 备好详情。
      repository.detailsById['json:test-site-other:other-drama'] =
          _cardsDetailFor(
            'json:test-site-other:other-drama',
            'test-site-other',
            'SSIS-00123 其他标题',
          );
      await tester.pumpWidget(
        MaterialApp(
          home: ActressDetailPage(
            localId: person.localId,
            repository: repository,
            store: store,
            database: db,
            filmDb: _CardsFilmDb({
              'SSIS123': [
                ActressJsonEntry(
                  site: 'test-site-other',
                  vodId: 'other-drama',
                  vodName: 'SSIS-00123 其他标题',
                  vodPic: '',
                  vodActor: '女演员甲',
                  vodDirector: '',
                  vodRemarks: '',
                  vodPubdate: '',
                  vodArea: '',
                  vodYear: '',
                  vodContent: '',
                  vodPlayFrom: 'test-site-other',
                  vodPlayUrl: '正片\$https://example.test/other.mp4',
                  typeName: '',
                  vodCode: 'SSIS-00123',
                  vodActressPic: '',
                ),
              ],
            }),
            verifyFetch: _alwaysPlayable,
            // 修仙版没有 DetailScreen：点卡进修仙版 PlayerPage，
            // 用假播放器（真 NativePlayer 在测试里建不起来）。
            playerFactory: () => ControlledNativePlayer(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DramaTile).first);
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(PlayerPage).evaluate().isNotEmpty) break;
      }
      expect(find.byType(PlayerPage), findsOneWidget);
      // 修仙版 PlayerPage 标题不在常驻文本里：直接断言标题属性。
      expect(
        tester.widget<PlayerPage>(find.byType(PlayerPage)).title,
        'SSIS-00123 其他标题',
      );
      expect(find.text('正在找可播片源…'), findsNothing);
      expect(find.text('暂无可播片源'), findsNothing);
      // 点卡走的是库里那行：进播放页的标题就是库里那行的标题
      // （上面已断言）。修仙版 PlayerPage 不调 repository.detail
      //（集表就是库里行的集，contentLoader 直接按集 resolve），
      // 所以魔蚁那条 detailIds 断言在这里没有对应物，不再断言。
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

  group('探活链总预算', () {
    late _CardsRepository repository;
    late LocalStore store;

    setUp(() async {
      _registerCardsTestSites();
      addTearDown(_unregisterCardsTestSites);
      repository = _CardsRepository();
      store = await _makeCardsStore();
    });

    test('慢站不拖过总预算：预算耗尽即判无源，剩下站不再起跑', () async {
      final sites = [
        for (var i = 0; i < 18; i++)
          SourceSite(
            'test-site-$i',
            '🔞测试站$i',
            '测试站',
            section: SourceSite.sectionVideo,
            origin: SourceSite.originImport,
          ),
      ];
      for (final site in sites) {
        SourceSite.importedSites[site.id] = site;
      }
      addTearDown(() {
        for (final site in sites) {
          SourceSite.importedSites.remove(site.id);
        }
      });
      final probe = _SlowProbeService(
        repository: repository,
        delay: const Duration(milliseconds: 300),
      );
      final chain = ActressPlayChain(
        repository: repository,
        store: store,
        avId: 'SSIS-00123',
        candidateSites: sites,
        probeService: probe,
        probeConcurrency: 6,
        totalBudget: const Duration(milliseconds: 400),
        verifyFetch: _alwaysPlayable,
      );
      final stopwatch = Stopwatch()..start();
      final candidate = await chain.nextPlayable(
        profileEpoch: store.profileEpoch,
      );
      stopwatch.stop();
      expect(candidate, isNull);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      // 18 站没探完：预算耗尽后剩下的站不再起跑。
      expect(probe.probed.length, lessThan(18));
      expect(probe.probed.length, greaterThan(0));
    });
  });

  // 暂缓：'MissAV folder 详情画作品卡片网格' 组（3 个 testWidgets）
  // 未移植——它们直接 pump 魔蚁的 DetailScreen（folder 详情画
  // 作品卡片网格是 DetailScreen 的行为）；修仙版没有 DetailScreen
  // 等价物，女优库详情页是 ActressDetailPage（只读库、点卡直进
  // PlayerPage），folder 形态不在本次合并范围内。
}

/// 慢探活假服务：每站固定延迟后回空（无源），记录起跑过的站。
/// （原在已暂缓的 folder 组之后定义，移回文件末尾。）
class _SlowProbeService extends CrossSiteProbeService {
  _SlowProbeService({required super.repository, required this.delay});

  final Duration delay;
  final probed = <String>[];

  @override
  Future<CrossSiteProbeResult> probeProvider(
    CrossSiteProvider provider,
    String siteId,
    String avId,
  ) async {
    probed.add(siteId);
    await Future.delayed(delay);
    return CrossSiteProbeResult(
      provider: provider,
      siteId: siteId,
      status: CrossSiteProbeStatus.empty,
    );
  }
}
