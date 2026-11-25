import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_database.dart';
import 'package:fqapp/actress/actress_detail_page.dart';
import 'package:fqapp/actress/actress_list_page.dart';
import 'package:fqapp/actress/actress_models.dart';
import 'package:fqapp/actress/actress_play.dart';
import 'package:fqapp/actress/actress_ranking_page.dart';
import 'package:fqapp/actress/actress_widgets.dart';
import 'package:fqapp/actress/actress_crosssite_probe.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/actress/actress_adapter_http.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_widgets.dart';

import 'actress_fixtures.dart';

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

Future<LocalStore> _makeStore() async {
  final store = LocalStore();
  addTearDown(store.dispose);
  return store;
}

const _testSiteA = SourceSite(
  'test-site-a',
  '🔞测试站A',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _testSiteB = SourceSite(
  'test-site-b',
  '测试站B',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _testSiteC = SourceSite(
  'test-site-c',
  '测试站C',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _lazySite = SourceSite(
  // 2026-11-21：MissAV 主站已从懒查波提到单独的 MissAV 波（修
  // UMSO-660），不再是懒查代表；这里改用仍在懒查波的 Jable，
  // 本测试继续验“eager 无果才探懒查”这一条不变的口径。
  'jar:zakatv:ZakaJable',
  '🔞懒查站',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);

void _registerTestSites() {
  for (final site in [_testSiteA, _testSiteB, _testSiteC, _lazySite]) {
    SourceSite.importedSites[site.id] = site;
  }
}

void _unregisterTestSites() {
  for (final site in [_testSiteA, _testSiteB, _testSiteC, _lazySite]) {
    SourceSite.importedSites.remove(site.id);
  }
}

DramaDetail _detailFor(String dramaId, String source) =>
    DramaDetail(Drama(id: dramaId, source: source, title: dramaId), [
      Episode({'id': '1', 'title': '正片', 'flag': '线路1'}, 1),
    ]);

class _ScriptedProbeService extends CrossSiteProbeService {
  _ScriptedProbeService({required super.repository, required this.results});

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

CrossSiteProbeResult _foundResult(
  CrossSiteProvider provider,
  String siteId,
  String dramaId,
) => CrossSiteProbeResult(
  provider: provider,
  siteId: siteId,
  status: CrossSiteProbeStatus.found,
  versions: [
    CrossSiteVersion(
      label: dramaId,
      detail: _detailFor(dramaId, siteId),
      lines: const [CrossSiteLine(label: '线路1', episodeIndex: 0)],
    ),
  ],
);

class _ScriptedRepository extends FixtureRepository {
  Map<String, List<Drama>> searchByQuery = {};
  Map<String, DramaDetail> detailsById = {};
  Set<String> failingResolveIds = {};
  final resolveCalls = <String>[];
  final searchQueries = <String>[];

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    searchQueries.add(query);
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
    return const PlaybackPlan(url: 'https://example.test/synthetic.mp4');
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

void main() {
  group('番号与名字归一化', () {
    test('normalizeAvCode 移植 py _code_key', () {
      expect(normalizeAvCode('SSIS-00123'), 'SSIS123');
      expect(normalizeAvCode('SSIS-123'), 'SSIS123');
      expect(normalizeAvCode('hmn-927'), 'HMN927');
      expect(normalizeAvCode('FC2-PPV-1234567'), 'FC2PPV1234567');
      expect(normalizeAvCode('1PONDO-102726'), '1PONDO102726');
      expect(normalizeAvCode(''), '');
    });

    test('actressNameKey 去空白小写', () {
      expect(actressNameKey('葵　司 '), '葵司');
      expect(actressNameKey('Aoi Tsukasa'), 'aoitsukasa');
    });

    test('actressNameVariants 切别名去重', () {
      expect(actressNameVariants('葵司,葵つかさ、葵司'), ['葵司', '葵つかさ']);
      expect(actressNameVariants('  '), isEmpty);
    });

    test('actressTitleKey 去空白标点', () {
      expect(actressTitleKey('SSIS-00123 测试·标题！'), 'ssis00123测试标题');
    });

    test('硬线过滤大小写不敏感', () {
      expect(actressTextBlocked('LOLI 合集'), isTrue);
      expect(actressTextBlocked('含萝莉的标题'), isTrue);
      expect(actressTextBlocked('普通标题 SSIS-123'), isFalse);
      expect(actressTextBlocked(''), isFalse);
    });
  });

  group('人物合并', () {
    test('新人物落库字段齐全', () {
      final merged = mergeRosterIntoPerson(
        null,
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'X1',
          name: '葵司,葵つかさ',
          sex: 'female',
          avatarUrl: 'https://a/x.jpg',
          tags: ['有码'],
          worksHint: 120,
          recommended: true,
        ),
      );
      expect(merged.displayName, '葵司');
      expect(merged.aliases, ['葵つかさ']);
      expect(merged.sex, 'female');
      expect(merged.rosterWorks, 120);
      expect(merged.fromChaoliu, isTrue);
      expect(merged.chaoliuId, 'X1');
      expect(merged.recommended, isTrue);
    });

    test('共享别名即合并，显示名取高优先级源', () {
      const missav = RosterPerson(
        source: ActressRosterSourceId.missav,
        sourceId: '/dm16/cn/actresses/aoi',
        name: 'Missav 名',
      );
      final first = mergeRosterIntoPerson(null, missav);
      const chaoliu = RosterPerson(
        source: ActressRosterSourceId.chaoliu,
        sourceId: 'X1',
        name: '潮流名,Missav 名',
        sex: 'female',
        worksHint: 50,
      );
      final merged = mergeRosterIntoPerson(first, chaoliu);
      expect(merged.displayName, '潮流名');
      expect(merged.aliases, contains('Missav 名'));
      expect(merged.fromChaoliu, isTrue);
      expect(merged.fromMissav, isTrue);
      expect(merged.missavPath, '/dm16/cn/actresses/aoi');
      expect(merged.sex, 'female');
    });

    test('低优先级源不覆盖高优先级显示名，别名标签取并集', () {
      const chaoliu = RosterPerson(
        source: ActressRosterSourceId.chaoliu,
        sourceId: 'X1',
        name: '潮流名',
        tags: ['有码'],
        worksHint: 50,
      );
      final first = mergeRosterIntoPerson(null, chaoliu);
      const whos = RosterPerson(
        source: ActressRosterSourceId.whos,
        sourceId: 'chao-liu-ming',
        name: '潮流名',
        tags: ['无码'],
        worksHint: 80,
      );
      final merged = mergeRosterIntoPerson(first, whos);
      expect(merged.displayName, '潮流名');
      expect(merged.tags, containsAll(['有码', '无码']));
      expect(merged.rosterWorks, 80);
    });
  });

  group('排行榜分数', () {
    test('名气为主作品数为辅，作品分封顶', () {
      const rank1 = ActressPerson(
        displayName: '甲',
        missavRank: 1,
        worksCount: 100,
      );
      const rank500 = ActressPerson(
        displayName: '乙',
        missavRank: 500,
        worksCount: 500,
      );
      const prolific = ActressPerson(displayName: '丙', worksCount: 2000);
      expect(actressRankScore(rank1), 1100);
      expect(actressRankScore(rank500), 1001);
      expect(actressRankScore(prolific), 500);
      expect(compareActressRank(rank1, rank500), lessThan(0));
      expect(compareActressRank(rank500, prolific), lessThan(0));
    });

    test('推荐加分，同分按作品数再按名字', () {
      const recommended = ActressPerson(
        displayName: '甲',
        recommended: true,
        worksCount: 10,
      );
      const plain = ActressPerson(displayName: '乙', worksCount: 10);
      expect(actressRankScore(recommended), actressRankScore(plain) + 50);
      const more = ActressPerson(displayName: '乙', worksCount: 20);
      const fewer = ActressPerson(displayName: '甲', worksCount: 10);
      expect(compareActressRank(more, fewer), lessThan(0));
      const a = ActressPerson(displayName: 'Ann', worksCount: 10);
      const b = ActressPerson(displayName: 'Bob', worksCount: 10);
      expect(compareActressRank(a, b), lessThan(0));
    });
  });

  group('内存库', () {
    late MemoryActressDatabase db;

    setUp(() {
      db = MemoryActressDatabase();
    });

    test('upsert 按别名合并，硬线名字整人剔除', () async {
      final first = await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.missav,
          sourceId: '/p1',
          name: '测试演员',
        ),
      );
      final second = await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'X1',
          name: '测试演员',
          sex: 'female',
        ),
      );
      expect(first!.localId, second!.localId);
      expect(second.fromChaoliu, isTrue);
      expect(second.fromMissav, isTrue);
      final blocked = await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'X9',
          name: '含萝莉的名字',
        ),
      );
      expect(blocked, isNull);
      expect(await db.countPersons(sex: ActressSexFilter.all, query: ''), 1);
    });

    test('标签筛选：多标签两边都进，无标签只进全部', () async {
      await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'T1',
          name: '双册人',
          sex: 'female',
          tags: ['有码', '无码'],
        ),
      );
      await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.whos,
          sourceId: 'slug-x',
          name: '无标签人',
        ),
      );
      Future<List<String>> names(String tag) async => (await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.nameAsc,
        query: '',
        tag: tag,
        offset: 0,
        limit: 10,
      )).map((p) => p.displayName).toList();
      expect(await names('有码'), ['双册人']);
      expect(await names('无码'), ['双册人']);
      expect(await names('欧美'), isEmpty);
      expect(await names(''), containsAll(['双册人', '无标签人']));
      expect(
        await db.countPersons(sex: ActressSexFilter.all, query: '', tag: '有码'),
        1,
      );
    });

    test('筛选排序分页搜索', () async {
      // “要入库才算”（2026-11-20）：排序只看入库作品数，名册宣称数
      // 不算——这里直接写真实作品行，男演员乙 3 部、女演员甲 2 部、
      // 未知性别丙 0 部。
      final female = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'F1',
          name: '女演员甲',
          sex: 'female',
          worksHint: 30,
        ),
      ))!;
      await db.upsertWorks(female.localId, const [
        RosterFilm(code: 'AAA-001'),
        RosterFilm(code: 'AAA-002'),
      ]);
      final male = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'M1',
          name: '男演员乙',
          sex: 'male',
          worksHint: 100,
        ),
      ))!;
      await db.upsertWorks(male.localId, const [
        RosterFilm(code: 'BBB-001'),
        RosterFilm(code: 'BBB-002'),
        RosterFilm(code: 'BBB-003'),
      ]);
      await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.whos,
          sourceId: 'u1',
          name: '未知性别丙',
        ),
      );
      final females = await db.listPersons(
        sex: ActressSexFilter.female,
        sort: ActressSort.worksDesc,
        query: '',
        offset: 0,
        limit: 10,
      );
      expect(females.map((p) => p.displayName), ['女演员甲']);
      final all = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.worksDesc,
        query: '',
        offset: 0,
        limit: 10,
      );
      expect(all.map((p) => p.displayName), ['男演员乙', '女演员甲', '未知性别丙']);
      final byName = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.nameAsc,
        query: '',
        offset: 0,
        limit: 2,
      );
      expect(byName, hasLength(2));
      final searched = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.worksDesc,
        query: '男演员',
        offset: 0,
        limit: 10,
      );
      expect(searched.map((p) => p.displayName), ['男演员乙']);
      expect(await db.countPersons(sex: ActressSexFilter.all, query: '演员'), 2);
    });

    test('排行只保留最好名次', () async {
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.missav,
          sourceId: '/p1',
          name: '测试演员',
        ),
      ))!;
      await db.setMissavRank(person.localId, 50);
      await db.setMissavRank(person.localId, 80);
      expect((await db.personById(person.localId))!.missavRank, 50);
      await db.setMissavRank(person.localId, 3);
      expect((await db.personById(person.localId))!.missavRank, 3);
    });

    test('作品番号去重与无番号标题去重', () async {
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'X1',
          name: '测试演员',
        ),
      ))!;
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-00123', date: '2024-01-01'),
        RosterFilm(code: 'SSIS-123', date: '2024-01-01'),
        RosterFilm(code: '', title: '无番号 标题'),
        RosterFilm(code: '', title: '无番号标题'),
        RosterFilm(code: '含萝莉的番号', title: '坏条目'),
      ]);
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(works, hasLength(2));
      expect(works[0].codeKey, 'SSIS123');
      expect(works[1].codeKey, '');
      expect((await db.personById(person.localId))!.worksCount, 2);
    });

    test('attachCover 补封面不覆盖已有封面', () async {
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'X1',
          name: '测试演员',
        ),
      ))!;
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-00123'),
      ]);
      await db.attachCover(
        personId: person.localId,
        codeKey: 'SSIS123',
        titleKey: 'ssis00123',
        coverSource: 'site-a',
        coverDramaId: 'd1',
        coverUrl: 'https://cover/1.jpg',
      );
      await db.attachCover(
        personId: person.localId,
        codeKey: 'SSIS123',
        titleKey: 'ssis00123',
        coverSource: 'site-b',
        coverDramaId: 'd2',
        coverUrl: 'https://cover/2.jpg',
      );
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(works, hasLength(1));
      expect(works[0].coverUrl, 'https://cover/1.jpg');
      expect(works[0].coverSource, 'site-a');
    });

    test('attachCover 新增跨站行与 insertIfMissing', () async {
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'X1',
          name: '测试演员',
        ),
      ))!;
      await db.attachCover(
        personId: person.localId,
        codeKey: 'ABW999',
        titleKey: 'abw999',
        codeDisplay: 'ABW-999',
        title: 'ABW-999 新发现',
        coverSource: 'site-a',
        coverDramaId: 'd9',
        coverUrl: 'https://cover/9.jpg',
      );
      await db.attachCover(
        personId: person.localId,
        codeKey: 'HMN927',
        titleKey: 'hmn927',
        coverSource: 'site-a',
        coverDramaId: 'd8',
        coverUrl: 'https://cover/8.jpg',
        insertIfMissing: false,
      );
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(works, hasLength(1));
      expect(works[0].fromCrossSite, isTrue);
      expect(works[0].codeDisplay, 'ABW-999');
    });

    test('films 断点状态与进度', () async {
      final a = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'A',
          name: '甲',
        ),
      ))!;
      await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'B',
          name: '乙',
        ),
      );
      await db.markFilmsState(
        a.localId,
        ActressRosterSourceId.chaoliu,
        ok: true,
      );
      final pending = await db.personsPendingFilms(
        ActressRosterSourceId.chaoliu,
      );
      expect(pending.map((p) => p.displayName), ['乙']);
      final progress = await db.filmsProgress(ActressRosterSourceId.chaoliu);
      expect((progress.done, progress.total), (1, 2));
    });

    test('断点存取', () async {
      await db.saveCheckpoint(
        const ActressSyncCheckpoint(
          source: 'chaoliu',
          phase: 'roster',
          cursor: '3',
          total: 10,
        ),
      );
      final checkpoint = await db.checkpoint(
        ActressRosterSourceId.chaoliu,
        'roster',
      );
      expect(checkpoint!.cursor, '3');
      expect(checkpoint.finished, isFalse);
    });
  });

  group('静默换线播放链', () {
    late _ScriptedRepository repository;
    late LocalStore store;

    setUp(() async {
      _registerTestSites();
      addTearDown(_unregisterTestSites);
      repository = _ScriptedRepository();
      store = await _makeStore();
    });

    ActressPlayChain chainWith({
      required Map<String, CrossSiteProbeResult> results,
      List<SourceSite>? sites,
    }) {
      final probe = _ScriptedProbeService(
        repository: repository,
        results: results,
      );
      return ActressPlayChain(
        repository: repository,
        store: store,
        avId: 'SSIS-00123',
        candidateSites: sites ?? [_testSiteA, _testSiteB, _testSiteC],
        probeService: probe,
        verifyFetch: _alwaysPlayable,
      );
    }

    test('按计划顺序试，预检失败自动换下一个', () async {
      CrossSiteProbeResult found(String siteId, String dramaId) => _foundResult(
        CrossSiteProvider(
          id: siteId,
          name: siteId,
          siteIds: [siteId],
          lazy: false,
        ),
        siteId,
        dramaId,
      );
      final chain = chainWith(
        results: {
          'test-site-a': found('test-site-a', 'drama-a'),
          'test-site-b': found('test-site-b', 'drama-b'),
          'test-site-c': found('test-site-c', 'drama-c'),
        },
      );
      // 计划顺序：🔞站 A 在前，其次 B、C。
      repository.failingResolveIds = {'drama-a'};
      final first = await chain.nextPlayable(profileEpoch: store.profileEpoch);
      expect(first!.detail.drama.id, 'drama-b');
      expect(repository.resolveCalls, ['drama-a', 'drama-b']);
      final second = await chain.nextPlayable(profileEpoch: store.profileEpoch);
      expect(second!.detail.drama.id, 'drama-c');
      final third = await chain.nextPlayable(profileEpoch: store.profileEpoch);
      expect(third, isNull);
      expect(chain.hasMore, isFalse);
    });

    test('eager 无果才探懒查', () async {
      final probe = _ScriptedProbeService(
        repository: repository,
        results: {
          'jar:zakatv:ZakaJable': _foundResult(
            const CrossSiteProvider(
              id: 'jar:zakatv:ZakaJable',
              name: 'lazy',
              siteIds: ['jar:zakatv:ZakaJable'],
              lazy: true,
            ),
            'jar:zakatv:ZakaJable',
            'drama-lazy',
          ),
        },
      );
      final chain = ActressPlayChain(
        repository: repository,
        store: store,
        avId: 'SSIS-00123',
        candidateSites: [_testSiteB, _lazySite],
        probeService: probe,
        verifyFetch: _alwaysPlayable,
      );
      final candidate = await chain.nextPlayable(
        profileEpoch: store.profileEpoch,
      );
      expect(candidate!.detail.drama.id, 'drama-lazy');
      expect(probe.probed, ['test-site-b', 'jar:zakatv:ZakaJable']);
    });

    test('全部失败返回空', () async {
      final chain = chainWith(results: {});
      expect(
        await chain.nextPlayable(profileEpoch: store.profileEpoch),
        isNull,
      );
    });

    test('不允许的站源直接跳过不预检', () async {
      final probe = _ScriptedProbeService(
        repository: repository,
        results: {
          'test-site-a': CrossSiteProbeResult(
            provider: const CrossSiteProvider(
              id: 'test-site-a',
              name: 'a',
              siteIds: ['test-site-a'],
              lazy: false,
            ),
            siteId: 'test-site-a',
            status: CrossSiteProbeStatus.found,
            versions: [
              CrossSiteVersion(
                label: 'v',
                detail: _detailFor('drama-a', 'unknown-x'),
                lines: const [CrossSiteLine(label: '线路1', episodeIndex: 0)],
              ),
            ],
          ),
        },
      );
      final blocked = ActressPlayChain(
        repository: repository,
        store: store,
        avId: 'SSIS-00123',
        candidateSites: [_testSiteA],
        probeService: probe,
        verifyFetch: _alwaysPlayable,
      );
      expect(
        await blocked.nextPlayable(profileEpoch: store.profileEpoch),
        isNull,
      );
      expect(repository.resolveCalls, isEmpty);
    });

    test('标题模式按标题搜并换线', () async {
      repository.searchByQuery = {
        '测试标题': [
          const Drama(id: 't1', source: 'test-site-a', title: '测试标题 HD'),
          const Drama(id: 't2', source: 'test-site-b', title: '测试标题'),
          const Drama(id: 't3', source: 'test-site-a', title: '测试标题 2'),
        ],
      };
      repository.detailsById = {
        't1': _detailFor('t1', 'test-site-a'),
        't2': _detailFor('t2', 'test-site-b'),
      };
      repository.failingResolveIds = {'t1'};
      final chain = ActressPlayChain(
        repository: repository,
        store: store,
        avId: '',
        titleQuery: '测试标题',
        candidateSites: [_testSiteA, _testSiteB],
        verifyFetch: _alwaysPlayable,
      );
      final candidate = await chain.nextPlayable(
        profileEpoch: store.profileEpoch,
      );
      expect(candidate!.detail.drama.id, 't2');
    });

    test('actressPlayAvId 保留原始前导零', () {
      const work = ActressWork(
        personId: 1,
        codeKey: 'SSIS123',
        titleKey: 'ssis123',
        codeDisplay: 'SSIS-00123',
      );
      expect(actressPlayAvId(work), 'SSIS-00123');
      const titled = ActressWork(
        personId: 1,
        codeKey: '',
        titleKey: 'hmn927',
        title: 'HMN-927 标题',
      );
      expect(actressPlayAvId(titled), 'HMN-927');
      const none = ActressWork(
        personId: 1,
        codeKey: '',
        titleKey: 'plain',
        title: '普通标题',
      );
      expect(actressPlayAvId(none), '');
    });
  });

  group('界面', () {
    late MemoryActressDatabase db;
    late _ScriptedRepository repository;
    late LocalStore store;

    setUp(() async {
      _registerTestSites();
      addTearDown(_unregisterTestSites);
      db = MemoryActressDatabase();
      repository = _ScriptedRepository();
      store = await _makeStore();
    });

    Future<ActressPerson> seedPerson(
      String name, {
      String sex = 'female',
      int works = 0,
      int? rank,
      List<String> tags = const [],
    }) async {
      final person = (await db.upsertRosterPerson(
        RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'id-$name',
          name: name,
          sex: sex,
          worksHint: works,
          tags: tags,
        ),
      ))!;
      if (rank != null) await db.setMissavRank(person.localId, rank);
      // “要入库才算”：works 参数写真实作品行，不只写名册宣称数
      // （displayWorks 与头顶人数都只算入库的，宣称数不算）。
      if (works > 0) {
        await db.upsertWorks(person.localId, [
          for (var i = 0; i < works; i++) RosterFilm(code: 'TST-${i + 1}'),
        ], site: ActressRosterSourceId.chaoliu.name);
      }
      return (await db.personById(person.localId))!;
    }

    testWidgets('列表页显示人物，搜索与性别筛选生效', (tester) async {
      await seedPerson('女演员甲', works: 30);
      await seedPerson('男演员乙', sex: 'male', works: 100);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressListPage(
            repository: repository,
            store: store,
            database: db,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('演员库 2 位演员'), findsOneWidget);
      expect(find.text('女演员甲'), findsOneWidget);
      expect(find.text('男演员乙'), findsOneWidget);
      expect(find.text('约 30 部'), findsOneWidget);
      expect(find.byType(GridView), findsOneWidget);
      await tester.tap(find.text('男优'));
      await tester.pumpAndSettle();
      expect(find.text('女演员甲'), findsNothing);
      expect(find.text('男演员乙'), findsOneWidget);
      // 性别“全部” chip：不用 find.text('全部')，顶栏站点筛选当前
      // 项也是“全部”文本，会歧义。
      await tester.tap(find.widgetWithText(ChoiceChip, '全部'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('actress-search')),
        '女演员',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('女演员甲'), findsOneWidget);
      expect(find.text('男演员乙'), findsNothing);
    });

    testWidgets('内嵌模式顶栏不重复女优库标题、只留人数', (tester) async {
      await seedPerson('女演员甲', works: 30);
      await seedPerson('男演员乙', sex: 'male', works: 100);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressListPage(
            repository: repository,
            store: store,
            database: db,
            showTitle: false,
          ),
        ),
      );
      // 顶栏有输入框（光标动画一直动），用定步 pump 代替 settle：
      // 20 × 100ms 足够把名册/人数那几次异步查询跑完。
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.byKey(const ValueKey('actress-embedded-toolbar')),
        findsOneWidget,
      );
      // 内嵌时人数/占位文案在置顶工具栏里，不再另起一条标题栏。
      expect(find.text('演员库'), findsWidgets);
      expect(find.text('演员库 2 位演员'), findsNothing);
      expect(find.text('女优库'), findsNothing);
    });

    testWidgets('列表页第二排按册别标签筛选', (tester) async {
      await seedPerson('有码女', tags: ['有码']);
      await seedPerson('无码男', sex: 'male', tags: ['无码']);
      await seedPerson('欧美女', tags: ['欧美']);
      await seedPerson('无标签者', tags: []);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressListPage(
            repository: repository,
            store: store,
            database: db,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('无标签者'), findsOneWidget);
      await tester.tap(find.text('有码'));
      await tester.pumpAndSettle();
      expect(find.text('有码女'), findsOneWidget);
      expect(find.text('无码男'), findsNothing);
      expect(find.text('无标签者'), findsNothing);
      await tester.tap(find.text('无码'));
      await tester.pumpAndSettle();
      expect(find.text('无码男'), findsOneWidget);
      expect(find.text('有码女'), findsNothing);
      await tester.tap(find.text('欧美'));
      await tester.pumpAndSettle();
      expect(find.text('欧美女'), findsOneWidget);
      expect(find.text('无码男'), findsNothing);
      await tester.tap(find.text('三册全部'));
      await tester.pumpAndSettle();
      expect(find.text('无标签者'), findsOneWidget);
      expect(find.text('有码女'), findsOneWidget);
    });

    testWidgets('头像占位显示姓氏大字', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ActressAvatar(avatarUrl: '', name: '安倍亚沙美'),
          ),
        ),
      );
      expect(find.text('安'), findsOneWidget);
      expect(find.byIcon(Icons.person_rounded), findsNothing);
    });

    testWidgets('列表页奖杯钮进排行榜', (tester) async {
      await seedPerson('女演员甲', works: 30);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressListPage(
            repository: repository,
            store: store,
            database: db,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-actress-ranking')));
      await tester.pumpAndSettle();
      expect(find.text('演员排行榜'), findsOneWidget);
    });

    testWidgets('详情页作品按卡片网格展示', (tester) async {
      final person = await seedPerson('女演员甲', works: 0);
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-00123', date: '2024-01-01'),
        RosterFilm(code: 'HMN-927'),
        RosterFilm(code: '', title: '无番号作品标题'),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressDetailPage(
            localId: person.localId,
            repository: repository,
            store: store,
            database: db,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DramaTile), findsNWidgets(3));
      expect(find.text('SSIS-00123'), findsOneWidget);
      expect(find.text('无番号作品标题'), findsOneWidget);
    });

    testWidgets('详情页点卡库里无地址报库里暂无播放地址', (tester) async {
      final person = await seedPerson('女演员甲', works: 1);
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-00123'),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressDetailPage(
            localId: person.localId,
            repository: repository,
            store: store,
            database: db,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DramaTile).first);
      // 点卡后最多等 2 秒池子建好：pumpAndSettle 不等长 Timer，显式
      // 推进假时钟（同文件 advanceAutoChain 的做法）。
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      // 2026-11-22 只走数据库：这部只有番号、库里没有播放地址，
      // 不跨站探活、不报站数，只报库里暂无播放地址、不进详情页。
      expect(find.text('库里暂无播放地址'), findsOneWidget);
      expect(find.byType(PlayerPage), findsNothing);
    });

    testWidgets('排行榜按综合分排序', (tester) async {
      await seedPerson('演员甲', works: 500, rank: 500);
      await seedPerson('演员乙', works: 100, rank: 1);
      await seedPerson('演员丙', works: 10);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressRankingPage(
            repository: repository,
            store: store,
            database: db,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('actress-rank-1')),
          matching: find.text('演员乙'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('actress-rank-2')),
          matching: find.text('演员甲'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('actress-rank-3')),
          matching: find.text('演员丙'),
        ),
        findsOneWidget,
      );
    });

  });
}
