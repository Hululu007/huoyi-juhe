import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_database.dart';
import 'package:fqapp/actress/actress_detail_page.dart';
import 'package:fqapp/actress/actress_list_page.dart';
import 'package:fqapp/actress/actress_models.dart';
import 'package:fqapp/actress/actress_play.dart';
import 'package:fqapp/actress/actress_ranking_page.dart';
import 'package:fqapp/actress/actress_roster_sources.dart';
import 'package:fqapp/actress/actress_search.dart';
import 'package:fqapp/actress/actress_sync.dart';
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

Future<ActressHttpResponse> _unusedFetch(
  String url, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 20),
}) async => throw UnimplementedError('fake source must not fetch');

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

    test('extractLeadingAvCode 只认标题开头', () {
      expect(extractLeadingAvCode('SSIS-123 测试标题'), 'SSIS-123');
      expect(extractLeadingAvCode('FC2-PPV-1234567 标题'), 'FC2-PPV-1234567');
      expect(extractLeadingAvCode('1PONDO-102726 标题'), '1PONDO-102726');
      expect(extractLeadingAvCode('SSIS123 标题'), 'SSIS123');
      expect(extractLeadingAvCode('2024-123456 标题'), '');
      expect(extractLeadingAvCode('标题里有 SSIS-123'), '');
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

  group('名册解析', () {
    test('parseChaoliuRoster 字段与推荐', () {
      const body =
          '{"actors":['
          '{"id":"X1","n":"测试演员，别名一","s":"female","t":120,"e":120,'
          '"c":"有码,推荐","a":"https://c0.jdbstatic.com/avatars/x/X1.jpg"},'
          '{"id":"X2","n":"男演员","s":"male","t":5,"e":5}]}';
      final persons = parseChaoliuRoster(body);
      expect(persons, hasLength(2));
      expect(persons[0].name, '测试演员，别名一');
      expect(persons[0].tags, ['有码', '推荐']);
      expect(persons[0].recommended, isTrue);
      expect(persons[0].worksHint, 120);
      expect(
        persons[1].avatarUrl,
        'https://chaoliu-av-tk8m.web.zaka.live/jp/av/X2.jpg',
      );
    });

    test('parseChaoliuFilms 全量取回跳过空项', () {
      const body =
          '[[1,"SSIS-00123","2024-01-01"],[2,"HMN-927","2024-02-02"],'
          '[3,"",""],[4]]';
      final films = parseChaoliuFilms(body);
      expect(films, hasLength(2));
      expect(films[0].code, 'SSIS-00123');
      expect(films[0].date, '2024-01-01');
      expect(films[1].codeKey, 'HMN927');
    });

    test('parseWhosRoster 切块与分页排除', () {
      const body =
          '<a href="/actresses/aoi-tsukasa">'
          '<img alt="葵司" src="/img/aoi.jpg"></a>'
          '<a href="/actresses/page-2">下一页</a>'
          '<a href="/actresses/yua-mikami">'
          '<img alt="三上悠亚" src="https://x.test/y.jpg"></a>';
      final persons = parseWhosRoster(body);
      expect(persons, hasLength(2));
      expect(persons[0].sourceId, 'aoi-tsukasa');
      expect(persons[0].name, '葵司');
      expect(persons[0].avatarUrl, 'https://whos.tv/img/aoi.jpg');
      expect(persons[0].sex, '');
      expect(persons[1].sourceId, 'yua-mikami');
    });

    test('parseWhosFilms 标题与番号', () {
      const body =
          '<a href="/videos/123"><h3>SSIS-001 测试标题</h3></a>'
          '<a href="/videos/124"><img alt="HMN-927 另一部"></a>'
          '<a href="/videos/123"><h3>SSIS-001 测试标题</h3></a>';
      final films = parseWhosFilms(body);
      expect(films, hasLength(2));
      expect(films[0].code, 'SSIS-001');
      expect(films[1].code, 'HMN-927');
    });

    test('parseMissavRoster 选择器与相对路径', () {
      const body =
          '<div class="max-w-full"><ul>'
          '<li><a href="/dm16/cn/actresses/aoi">'
          '<img src="https://m.test/a.jpg"><h4>葵司</h4></a></li>'
          '<li><a href="https://missav.live/dm16/cn/actresses/yua">'
          '<img src="https://m.test/y.jpg"><h4>三上悠亚</h4></a></li>'
          '</ul></div>';
      final persons = parseMissavRoster(body);
      expect(persons, hasLength(2));
      expect(persons[0].sourceId, '/dm16/cn/actresses/aoi');
      expect(persons[0].name, '葵司');
      expect(persons[1].sourceId, '/dm16/cn/actresses/yua');
      expect(persons[1].sex, '');
    });

    test('parseMissavFilms lozad alt', () {
      const body =
          '<div class="grid relative"><a href="/dm16/cn/a">'
          '<img class="lozad" alt="SSIS-001 标题"></a></div>'
          '<div class="grid relative"><a href="/dm16/cn/b">'
          '<img class="lozad" alt="无番号标题"></a></div>';
      final films = parseMissavFilms(body);
      expect(films, hasLength(2));
      expect(films[0].code, 'SSIS-001');
      expect(films[1].code, '');
      expect(films[1].title, '无番号标题');
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

  group('同步服务', () {
    late MemoryActressDatabase db;

    setUp(() {
      db = MemoryActressDatabase();
    });

    RosterPerson person(String id, String name) => RosterPerson(
      source: ActressRosterSourceId.chaoliu,
      sourceId: id,
      name: name,
      sex: 'female',
    );

    test('全量同步合并三家并记排行', () async {
      final chaoliu = FakeRosterSource(
        sourceId: ActressRosterSourceId.chaoliu,
        rosterPages: [
          [person('A', '演员甲'), person('B', '演员乙')],
        ],
        filmsBySourceId: {
          'A': const [RosterFilm(code: 'SSIS-00123')],
          'B': const [RosterFilm(code: 'HMN-927')],
        },
      );
      final missav = FakeRosterSource(
        sourceId: ActressRosterSourceId.missav,
        rosterPages: [
          [
            const RosterPerson(
              source: ActressRosterSourceId.missav,
              sourceId: '/p-a',
              name: '演员甲',
            ),
          ],
        ],
        filmsBySourceId: {
          '/p-a': const [RosterFilm(code: 'SSIS-123')],
        },
        rankingPages: [
          [
            const RosterPerson(
              source: ActressRosterSourceId.missav,
              sourceId: '/p-a',
              name: '演员甲',
            ),
            const RosterPerson(
              source: ActressRosterSourceId.missav,
              sourceId: '/p-b',
              name: '演员乙',
            ),
          ],
        ],
      );
      final sync = ActressSyncService(
        db: db,
        sources: [chaoliu, missav],
        fetch: _unusedFetch,
      );
      addTearDown(sync.dispose);
      final result = await sync.run();
      expect(result.hasFailures, isFalse);
      expect(result.persons, 2);
      // SSIS-00123 与 SSIS-123 归一化后同一部，但来自潮流与 MissAV
      // 两家名册，按（站，番号）各留一条；加演员乙的 HMN-927 共 3 行。
      expect(result.works, 3);
      final persons = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.nameAsc,
        query: '',
        offset: 0,
        limit: 10,
      );
      final a = persons.firstWhere((p) => p.displayName == '演员甲');
      expect(a.fromChaoliu, isTrue);
      expect(a.fromMissav, isTrue);
      expect(a.missavRank, 1);
      expect(a.worksCount, 2);
      final b = persons.firstWhere((p) => p.displayName == '演员乙');
      expect(b.missavRank, 2);
      final checkpoint = await db.checkpoint(
        ActressRosterSourceId.chaoliu,
        'roster',
      );
      expect(checkpoint!.finished, isTrue);
    });

    test('名册断点续跑不重复拉已完成页', () async {
      final failing = FakeRosterSource(
        sourceId: ActressRosterSourceId.chaoliu,
        rosterPages: [
          [person('A', '演员甲')],
          [person('B', '演员乙')],
        ],
        failRosterPages: {2},
      );
      final sync1 = ActressSyncService(
        db: db,
        sources: [failing],
        fetch: _unusedFetch,
      );
      addTearDown(sync1.dispose);
      final result1 = await sync1.run();
      expect(result1.hasFailures, isTrue);
      // 3 个取页工人并行：页 1、2、3 同时领走；页 2 失败重试 3 次，
      // 页 3 是超前取到的空页（无更多时停）；断点留在最早缺口第 2 页。
      expect(failing.fetchedRosterPages.toSet(), {1, 2, 3});
      expect(failing.fetchedRosterPages.where((p) => p == 2).length, 3);
      final checkpoint = await db.checkpoint(
        ActressRosterSourceId.chaoliu,
        'roster',
      );
      expect(checkpoint!.finished, isFalse);
      expect(checkpoint.cursor, '2');

      final resumed = FakeRosterSource(
        sourceId: ActressRosterSourceId.chaoliu,
        rosterPages: [
          [person('A', '演员甲')],
          [person('B', '演员乙')],
        ],
      );
      final sync2 = ActressSyncService(
        db: db,
        sources: [resumed],
        fetch: _unusedFetch,
      );
      addTearDown(sync2.dispose);
      await sync2.run();
      // 续跑从最早缺口第 2 页续爬，第 1 页不再拉（超前取到的空页
      // 3、4 不影响断言，只认第 1 页没再拉、第 2 页拉了）。
      expect(resumed.fetchedRosterPages.contains(1), isFalse);
      expect(resumed.fetchedRosterPages.contains(2), isTrue);
      expect(await db.countPersons(sex: ActressSexFilter.all, query: ''), 2);
    });

    test('作品断点续跑只补失败的人', () async {
      final failing = FakeRosterSource(
        sourceId: ActressRosterSourceId.chaoliu,
        rosterPages: [
          [person('A', '演员甲'), person('B', '演员乙')],
        ],
        filmsBySourceId: {
          'A': const [RosterFilm(code: 'SSIS-00123')],
          'B': const [RosterFilm(code: 'HMN-927')],
        },
        failFilmsFor: {'B'},
      );
      final sync1 = ActressSyncService(
        db: db,
        sources: [failing],
        fetch: _unusedFetch,
      );
      addTearDown(sync1.dispose);
      await sync1.run();
      final filmsCheckpoint = await db.checkpoint(
        ActressRosterSourceId.chaoliu,
        'films',
      );
      expect(filmsCheckpoint!.finished, isFalse);

      final resumed = FakeRosterSource(
        sourceId: ActressRosterSourceId.chaoliu,
        rosterPages: [
          [person('A', '演员甲'), person('B', '演员乙')],
        ],
        filmsBySourceId: {
          'A': const [RosterFilm(code: 'SSIS-00123')],
          'B': const [RosterFilm(code: 'HMN-927')],
        },
      );
      final sync2 = ActressSyncService(
        db: db,
        sources: [resumed],
        fetch: _unusedFetch,
      );
      addTearDown(sync2.dispose);
      await sync2.run();
      expect(resumed.fetchedFilmsFor, ['B']);
      final done = await db.checkpoint(ActressRosterSourceId.chaoliu, 'films');
      expect(done!.finished, isTrue);
    });

    test('单源失败不拖垮其余源', () async {
      final failing = FakeRosterSource(
        sourceId: ActressRosterSourceId.chaoliu,
        rosterPages: [
          [person('A', '演员甲')],
        ],
        failRosterPages: {1},
      );
      final ok = FakeRosterSource(
        sourceId: ActressRosterSourceId.whos,
        rosterPages: [
          [
            const RosterPerson(
              source: ActressRosterSourceId.whos,
              sourceId: 'w1',
              name: '演员丙',
            ),
          ],
        ],
      );
      final sync = ActressSyncService(
        db: db,
        sources: [failing, ok],
        fetch: _unusedFetch,
      );
      addTearDown(sync.dispose);
      final result = await sync.run();
      expect(result.failedSources, [ActressRosterSourceId.chaoliu]);
      expect(await db.countPersons(sex: ActressSexFilter.all, query: ''), 1);
    });

    test('取消后断点保留', () async {
      final persons = [for (var i = 0; i < 20; i++) person('P$i', '演员$i')];
      final slow = _SlowFilmsSource(
        sourceId: ActressRosterSourceId.chaoliu,
        rosterPages: [persons],
        filmsBySourceId: {
          for (final p in persons)
            p.sourceId: const [RosterFilm(code: 'SSIS-00123')],
        },
      );
      final sync = ActressSyncService(
        db: db,
        sources: [slow],
        fetch: _unusedFetch,
        filmsConcurrency: 1,
      );
      addTearDown(sync.dispose);
      final running = sync.run();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      sync.cancel();
      final result = await running;
      expect(result.cancelled, isTrue);
      final pending = await db.personsPendingFilms(
        ActressRosterSourceId.chaoliu,
      );
      expect(pending, isNotEmpty);
    });
  });

  group('双键合流补全', () {
    late MemoryActressDatabase db;
    late _ScriptedRepository repository;
    late LocalStore store;

    setUp(() async {
      _registerTestSites();
      addTearDown(_unregisterTestSites);
      db = MemoryActressDatabase();
      repository = _ScriptedRepository();
      store = await _makeStore();
      // 列表页顶栏有搜索输入框，光标闪烁是无限动画：测试里定死光标，
      // 否则 pumpAndSettle 永远等不到静止（2026-11-21）。
      EditableText.debugDeterministicCursor = true;
      addTearDown(() => EditableText.debugDeterministicCursor = false);
    });

    Future<ActressPerson> seedPerson() async {
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'X1',
          name: '测试演员',
          sex: 'female',
        ),
      ))!;
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-00123', date: '2024-01-01'),
        RosterFilm(code: 'HMN-927'),
        RosterFilm(code: '', title: '无番号作品标题'),
      ]);
      return (await db.personById(person.localId))!;
    }

    test('名字路附封面并新增带番号发现', () async {
      final person = await seedPerson();
      repository.searchByQuery = {
        '测试演员': [
          const Drama(
            id: 'd1',
            source: 'test-site-a',
            title: 'SSIS-00123 测试标题',
            cover: 'https://cover/1.jpg',
          ),
          const Drama(
            id: 'd2',
            source: 'test-site-a',
            title: 'ABW-999 新发现',
            cover: 'https://cover/2.jpg',
          ),
          const Drama(
            id: 'd3',
            source: 'test-site-a',
            title: '另一部无番号',
            cover: 'https://cover/3.jpg',
          ),
        ],
      };
      final enrichment = ActressEnrichment(
        repository: repository,
        store: store,
        db: db,
      );
      final completed = await enrichment.enrichPerson(person);
      expect(completed, isTrue);
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      // 原 3 部 + 新增 ABW-999；无番号命中不新增。
      expect(works, hasLength(4));
      final ssis = works.firstWhere((w) => w.codeKey == 'SSIS123');
      expect(ssis.coverUrl, 'https://cover/1.jpg');
      expect(ssis.title, 'SSIS-00123 测试标题');
      final discovered = works.firstWhere((w) => w.codeKey == 'ABW999');
      expect(discovered.fromCrossSite, isTrue);
      expect(discovered.coverUrl, 'https://cover/2.jpg');
    });

    test('番号路补封面，全部有封面后缓存优先不再搜', () async {
      final person = await seedPerson();
      repository.searchByQuery = {
        // 名字路：无番号命中按标题键附到已有行，补上无番号作品。
        '测试演员': [
          const Drama(
            id: 'd0',
            source: 'test-site-a',
            title: '无番号作品标题',
            cover: 'https://cover/0.jpg',
          ),
        ],
        'SSIS-00123': [
          const Drama(
            id: 'd8',
            source: 'test-site-b',
            title: 'SSIS-00123 标题',
            cover: 'https://cover/8.jpg',
          ),
        ],
        'HMN-927': [
          const Drama(
            id: 'd9',
            source: 'test-site-b',
            title: 'HMN-927 标题',
            cover: 'https://cover/9.jpg',
          ),
        ],
      };
      final enrichment = ActressEnrichment(
        repository: repository,
        store: store,
        db: db,
      );
      final completed = await enrichment.enrichPerson(person);
      expect(completed, isTrue);
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      final hmn = works.firstWhere((w) => w.codeKey == 'HMN927');
      expect(hmn.coverUrl, 'https://cover/9.jpg');
      // 三部作品全部补上封面后，记 enriched 再打开才跳过。
      expect(works.every((w) => w.hasCover), isTrue);
      final queriesAfterFirst = repository.searchQueries.length;
      expect(queriesAfterFirst, greaterThan(0));
      await db.markEnriched(person.localId);
      final fresh = (await db.personById(person.localId))!;
      await enrichment.enrichPerson(fresh);
      expect(repository.searchQueries.length, queriesAfterFirst);
    });

    test('番号路触上限返回未完成', () async {
      final person = await seedPerson();
      final enrichment = ActressEnrichment(
        repository: repository,
        store: store,
        db: db,
        codeSearchCap: 1,
      );
      final completed = await enrichment.enrichPerson(person);
      expect(completed, isFalse);
    });

    test('硬线标题命中跳过', () async {
      final person = await seedPerson();
      repository.searchByQuery = {
        '测试演员': [
          const Drama(
            id: 'bad1',
            source: 'test-site-a',
            title: 'ABW-111 含萝莉的标题',
            cover: 'https://cover/bad.jpg',
          ),
        ],
      };
      final enrichment = ActressEnrichment(
        repository: repository,
        store: store,
        db: db,
      );
      await enrichment.enrichPerson(person);
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(works, hasLength(3));
      expect(works.any((w) => w.codeKey == 'ABW111'), isFalse);
    });

    test('无作品不算完成但照常按名搜索（不中毒）', () async {
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'X0',
          name: '空演员',
        ),
      ))!;
      final enrichment = ActressEnrichment(
        repository: repository,
        store: store,
        db: db,
      );
      // 返回 false：调用方不得记 enrichedAt，作品同步进来后下次打开再补。
      // 2026-11-20 新规：零作品的人也按名搜全站（没有也要爬取新增），
      // 搜不到保持为空、不造假数据。
      expect(await enrichment.enrichPerson(person), isFalse);
      expect(repository.searchQueries, contains('空演员'));
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
      final sync = ActressSyncService(
        db: db,
        sources: const [],
        fetch: _unusedFetch,
      );
      addTearDown(sync.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressListPage(
            repository: repository,
            store: store,
            database: db,
            syncService: sync,
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
      final sync = ActressSyncService(
        db: db,
        sources: const [],
        fetch: _unusedFetch,
      );
      addTearDown(sync.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressListPage(
            repository: repository,
            store: store,
            database: db,
            syncService: sync,
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
      final sync = ActressSyncService(
        db: db,
        sources: const [],
        fetch: _unusedFetch,
      );
      addTearDown(sync.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressListPage(
            repository: repository,
            store: store,
            database: db,
            syncService: sync,
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
      final sync = ActressSyncService(
        db: db,
        sources: const [],
        fetch: _unusedFetch,
      );
      addTearDown(sync.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressListPage(
            repository: repository,
            store: store,
            database: db,
            syncService: sync,
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

    Future<void> markAllDone() async {
      for (final source in ActressRosterSourceId.values) {
        for (final phase in ['roster', 'films']) {
          await db.saveCheckpoint(
            ActressSyncCheckpoint(
              source: source.name,
              phase: phase,
              finished: true,
            ),
          );
        }
      }
    }

    // 自动续跑链靠 2 秒 Timer：pumpAndSettle 不等长 Timer，显式推进假时钟。
    Future<void> advanceAutoChain(WidgetTester tester) async {
      for (var i = 0; i < 2; i++) {
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
      }
    }

    Future<void> pumpListPage(
      WidgetTester tester,
      ActressSyncService sync,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ActressListPage(
            repository: repository,
            store: store,
            database: db,
            syncService: sync,
          ),
        ),
      );
    }

    // 不自动爬取（2026-11-20 用户令）：进页不再自动起爬、自动续跑
    // 已废除；同步只在用户手动点刷新/继续/开始时跑一次，跑完或
    // 取消后都不自动再续。
    testWidgets('没同步完进页不自动跑，手动点继续同步才跑一次', (tester) async {
      await seedPerson('女演员甲', works: 30);
      final sync = _CountingSync(db: db);
      addTearDown(sync.dispose);
      await pumpListPage(tester, sync);
      await tester.pumpAndSettle();
      await advanceAutoChain(tester);
      expect(sync.runs, 0);
      await tester.tap(find.text('继续同步'));
      await tester.pumpAndSettle();
      expect(sync.runs, 1);
      expect(sync.refreshArgs, [false]);
      await advanceAutoChain(tester);
      expect(sync.runs, 1);
    });

    testWidgets('已同步完进页不自动跑', (tester) async {
      await seedPerson('女演员甲', works: 30);
      await markAllDone();
      final sync = _CountingSync(db: db);
      addTearDown(sync.dispose);
      await pumpListPage(tester, sync);
      await tester.pumpAndSettle();
      await advanceAutoChain(tester);
      expect(sync.runs, 0);
    });

    testWidgets('库空进页不自动跑，点开始同步才跑一次', (tester) async {
      final sync = _CountingSync(db: db);
      addTearDown(sync.dispose);
      await pumpListPage(tester, sync);
      await tester.pumpAndSettle();
      await advanceAutoChain(tester);
      expect(sync.runs, 0);
      expect(find.text('还没有数据，点刷新开始同步演员库。'), findsOneWidget);
      await tester.tap(find.text('开始同步'));
      await tester.pumpAndSettle();
      expect(sync.runs, 1);
      expect(sync.refreshArgs, [false]);
    });

    testWidgets('手动点刷新跑一次，跑完不自动再续', (tester) async {
      await seedPerson('女演员甲', works: 30);
      final sync = _CountingSync(db: db);
      addTearDown(sync.dispose);
      await pumpListPage(tester, sync);
      await tester.pumpAndSettle();
      await advanceAutoChain(tester);
      expect(sync.runs, 0);
      await tester.tap(find.byKey(const ValueKey('refresh-actress-library')));
      await tester.pumpAndSettle();
      expect(sync.runs, 1);
      await advanceAutoChain(tester);
      expect(sync.runs, 1);
    });

    testWidgets('取消后不自动续跑', (tester) async {
      await seedPerson('女演员甲', works: 30);
      final sync = _CountingSync(db: db)..nextCancelled = true;
      addTearDown(sync.dispose);
      await pumpListPage(tester, sync);
      await tester.pumpAndSettle();
      await advanceAutoChain(tester);
      expect(sync.runs, 0);
      await tester.tap(find.text('继续同步'));
      await tester.pumpAndSettle();
      expect(sync.runs, 1);
      await advanceAutoChain(tester);
      expect(sync.runs, 1);
    });
  });
}

class _CountingSync extends ActressSyncService {
  _CountingSync({required super.db})
    : super(sources: const [], fetch: _unusedFetch);

  var runs = 0;
  final refreshArgs = <bool>[];
  var nextCancelled = false;

  @override
  Future<ActressSyncResult> run({bool refresh = false}) {
    runs++;
    refreshArgs.add(refresh);
    return Future.value(
      ActressSyncResult(
        persons: 0,
        works: 0,
        failedSources: const [],
        cancelled: nextCancelled,
      ),
    );
  }
}

class _SlowFilmsSource extends FakeRosterSource {
  _SlowFilmsSource({
    required super.sourceId,
    required super.rosterPages,
    required super.filmsBySourceId,
  });

  @override
  Future<List<RosterFilm>> fetchFilms(
    String sourceId, {
    required ActressHttpFetch fetch,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return super.fetchFilms(sourceId, fetch: fetch);
  }
}
