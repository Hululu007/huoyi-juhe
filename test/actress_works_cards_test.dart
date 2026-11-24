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
import 'package:fqapp/actress/actress_roster_sources.dart';
import 'package:fqapp/actress/actress_search.dart';
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
    test('parseMissavFilms 取出封面与详情地址', () {
      const html = '''
<div class="grid relative">
  <a href="/dm16/cn/ssis00123"><img class="lozad" alt="SSIS-00123 测试标题" data-src="https://cdn.example.com/cover1.jpg"></a>
</div>
<div class="grid relative">
  <a href="/dm16/cn/abw00456"><img class="lozad" alt="ABW-456 另一部" src="https://cdn.example.com/cover2.jpg"></a>
</div>
<div class="grid relative">
  <a href="/dm16/cn/fc2ppv7890123"><img class="lozad" alt="FC2-PPV-7890123 第三部" data-srcset="https://cdn.example.com/cover3.jpg 100w, https://cdn.example.com/cover3b.jpg 200w"></a>
</div>
<div class="grid relative">
  <a href="/dm16/cn/nocover"><img class="lozad" alt="SSIS-00999 无图的一部"></a>
</div>
''';
      final films = parseMissavFilms(html);
      expect(films, hasLength(4));
      expect(films[0].code, 'SSIS-00123');
      expect(films[0].coverUrl, 'https://cdn.example.com/cover1.jpg');
      expect(films[0].detailUrl, '/dm16/cn/ssis00123');
      // src 回落。
      expect(films[1].coverUrl, 'https://cdn.example.com/cover2.jpg');
      expect(films[1].detailUrl, '/dm16/cn/abw00456');
      // data-srcset 只取首个地址。
      expect(films[2].coverUrl, 'https://cdn.example.com/cover3.jpg');
      expect(films[2].detailUrl, '/dm16/cn/fc2ppv7890123');
      // 无图地址时两字段为空，不影响标题与番号。
      expect(films[3].code, 'SSIS-00999');
      expect(films[3].coverUrl, isEmpty);
      expect(films[3].detailUrl, '/dm16/cn/nocover');
    });

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

  group('补封面提速', () {
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

    Future<ActressPerson> seedPersonWithWorks(List<RosterFilm> films) async {
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'X1',
          name: '测试女优',
          sex: 'female',
        ),
      ))!;
      await db.upsertWorks(person.localId, films);
      return (await db.personById(person.localId))!;
    }

    test('名字路流式：首站结果一到就贴封面，不等整轮', () async {
      final person = await seedPersonWithWorks(const [
        RosterFilm(code: 'SSIS-00123', date: '2024-01-01'),
        RosterFilm(code: 'ABW-00456', date: '2024-01-02'),
      ]);
      // 假流式：先报 A 站命中，停 50ms 后再报 B 站；断言 A 站
      // 的封面在 B 站到达前已经落库。
      var attachedAfterFirstSite = false;
      repository.progressiveHandler =
          (sources, query, {required onSite, shouldStop}) async {
            onSite('test-cover-a', [
              const Drama(
                id: 'a-ssis',
                source: 'test-cover-a',
                title: 'SSIS-00123 测试标题',
                cover: 'https://cover/a.jpg',
              ),
            ]);
            await Future.delayed(const Duration(milliseconds: 50));
            final works = await db.worksForPerson(
              person.localId,
              offset: 0,
              limit: 100,
            );
            attachedAfterFirstSite = works
                .firstWhere((w) => w.codeDisplay == 'SSIS-00123')
                .hasCover;
            onSite('test-cover-a', [
              const Drama(
                id: 'a-abw',
                source: 'test-cover-a',
                title: 'ABW-00456 测试标题',
                cover: 'https://cover/b.jpg',
              ),
            ]);
          };
      final completed = await ActressEnrichment(
        repository: repository,
        store: store,
        db: db,
      ).enrichPerson(person);
      expect(completed, isTrue);
      expect(attachedAfterFirstSite, isTrue);
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 100,
      );
      expect(
        works.firstWhere((w) => w.codeDisplay == 'ABW-00456').hasCover,
        isTrue,
      );
    });

    test('番号路墙钟上限：超时不再起跑新作品，本轮记未完成', () async {
      final films = [
        for (var i = 0; i < 12; i++)
          RosterFilm(code: 'SSIS-00${100 + i}', date: '2024-01-01'),
      ];
      final person = await seedPersonWithWorks(films);
      // 名字路无命中（搜不到），番号路每部作品搜一次、每次 2 秒
      // （兜底站一段 + 全站一段）；并发 6、墙钟上限 500ms：
      // 第一批 6 部跑完即停，剩下 6 部不再起跑，本轮返回未完成。
      repository.searchDelay = const Duration(seconds: 2);
      repository.delayedQueries = {for (final film in films) film.code};
      final enrichment = ActressEnrichment(
        repository: repository,
        store: store,
        db: db,
        codeRoundBudget: const Duration(milliseconds: 500),
      );
      final stopwatch = Stopwatch()..start();
      final completed = await enrichment.enrichPerson(person);
      stopwatch.stop();
      expect(completed, isFalse);
      // 12 部里只起跑了第一批 6 部（去重后的番号查询数）；
      // 兜底站与全站两段搜索会让同一番号出现两次，不按调用次数计。
      final codeQueries = repository.searchQueries
          .where((q) => q.startsWith('SSIS-'))
          .toSet();
      expect(codeQueries.length, 6);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
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
