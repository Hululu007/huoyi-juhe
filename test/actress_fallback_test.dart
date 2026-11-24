import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_database.dart';
import 'package:fqapp/actress/actress_models.dart';
import 'package:fqapp/actress/actress_roster_sources.dart';
import 'package:fqapp/actress/actress_sync.dart';

Future<ActressHttpResponse> _neverFetch(
  String url, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 20),
}) async => throw StateError('fetch must not be called for $url');

/// Encodes [url] the way whos obfuscates covers: XOR with [key], key last.
String _xorEncode(String url, int key) {
  final bytes = [
    for (final byte in utf8.encode(url)) byte ^ key,
    key,
  ];
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

void main() {
  group('decodeWhosCover', () {
    test('round-trips an https url', () {
      const url = 'https://v.hersav.me/actress/abc.jpg';
      expect(decodeWhosCover(_xorEncode(url, 0x5a)), url);
      expect(
        decodeWhosCover(_xorEncode('http://cdn.example.com/x.jpg', 0x01)),
        'http://cdn.example.com/x.jpg',
      );
    });

    test('rejects invalid input without throwing', () {
      expect(decodeWhosCover(null), isNull);
      expect(decodeWhosCover(''), isNull);
      expect(decodeWhosCover('abcd'), isNull);
      expect(decodeWhosCover('abc'), isNull);
      expect(decodeWhosCover('zzzzzz'), isNull);
      expect(decodeWhosCover('00'), isNull);
    });

    test('rejects decodes that are not urls', () {
      expect(decodeWhosCover(_xorEncode('not a url', 0x5a)), isNull);
    });
  });

  group('parseWhosRoster enrichment', () {
    const fixture = '''
<div class="card">
  <a href="/actresses/aoi-tsubasa">
    <img src="https://cdn.example.com/decoy.jpg" alt="苍井翼">
    <img src="https://v.hersav.me/actress/aoi.jpg" alt="">
  </a>
  <div class="mt-0.5">翼酱</div>
  <span aria-label="评分 8.6">star</span>
  <span>1,234 部作品</span>
</div>
<div class="card">
  <a href="/actresses/suren"><img src="https://v.hersav.me/actress/x.jpg" alt="素人"></a>
</div>
<div class="card">
  <a href="/actresses/amber-girl"><img src="https://v.hersav.me/actress/b.jpg" alt="琥珀"></a>
  <span class="text-amber-400">9.1</span>
  <span>56 部作品</span>
</div>
<div class="card">
  <a href="/actresses/bad-rating"><img src="https://v.hersav.me/actress/c.jpg" alt="离谱"></a>
  <span aria-label="评分 99">star</span>
</div>
<a href="/actresses/page-2">next</a>
''';

    test('parses rating, works, alias and prefers the hersav avatar', () {
      final persons = parseWhosRoster(fixture);
      expect(persons.map((p) => p.sourceId), [
        'aoi-tsubasa',
        'suren',
        'amber-girl',
        'bad-rating',
      ]);
      final aoi = persons.first;
      expect(aoi.name, '苍井翼');
      expect(aoi.avatarUrl, 'https://v.hersav.me/actress/aoi.jpg');
      expect(aoi.rating, 8.6);
      expect(aoi.exactWorks, 1234);
      expect(aoi.aliases, ['翼酱']);
    });

    test('keeps the 素人 actor and drops pagination links', () {
      // 2026-11-21 用户纠正：素人是有番号的正常演员，不再过滤；
      // 分页链接仍丢弃。
      final persons = parseWhosRoster(fixture);
      expect(persons.any((p) => p.name == '素人'), isTrue);
      expect(persons.any((p) => p.sourceId.startsWith('page-')), isFalse);
    });

    test('amber-class rating is a fallback, out-of-range is null', () {
      final persons = parseWhosRoster(fixture);
      // 素人保留后下标后移一位：[1] 是素人（无评分），[2] 是琥珀。
      expect(persons[1].name, '素人');
      expect(persons[2].rating, 9.1);
      expect(persons[2].exactWorks, 56);
      expect(persons[3].rating, isNull);
    });
  });

  group('parseWhosPersonAbout', () {
    test('reads key-value pairs and skips oversized keys', () {
      final about = parseWhosPersonAbout('''
<div>
  <p class="text-sm text-muted-foreground">生日</p>
  <p class="font-medium text-white">1998-01-01</p>
  <p class="text-sm text-muted-foreground">身高</p>
  <p class="font-medium text-white">165cm</p>
  <p class="text-sm text-muted-foreground">这是一个超过八个字的键名</p>
  <p class="font-medium text-white">must be skipped</p>
</div>
''');
      expect(about, {'生日': '1998-01-01', '身高': '165cm'});
    });

    test('empty page yields an empty map', () {
      expect(parseWhosPersonAbout('<html></html>'), isEmpty);
    });
  });

  group('parseWhosFilms', () {
    test('cover fields stay empty when the XOR switch is off', () {
      final films = parseWhosFilms(
        '<a href="/videos/miad-854"><h3>MIAD-854 标题</h3>'
        '<img data-cover-src="${_xorEncode('https://cdn.example.com/c.jpg', 0x5a)}" '
        'src="https://cdn.example.com/fallback.jpg"></a>',
      );
      expect(films, hasLength(1));
      expect(films.single.code, 'MIAD-854');
      expect(films.single.coverUrl, isEmpty);
      expect(films.single.detailUrl, isEmpty);
    });

    test('decodes the cover and detail url when the switch is on', () {
      final films = parseWhosFilms(
        '<a href="/videos/miad-854"><h3>MIAD-854 标题</h3>'
        '<img data-cover-src="${_xorEncode('https://cdn.example.com/c.jpg', 0x5a)}" '
        'src="https://cdn.example.com/fallback.jpg"></a>',
        decodeCover: true,
      );
      expect(films.single.coverUrl, 'https://cdn.example.com/c.jpg');
      expect(films.single.detailUrl, '/videos/miad-854');
    });

    test('undecodable covers fall back to the img src', () {
      final films = parseWhosFilms(
        '<a href="/videos/miad-854"><h3>MIAD-854 标题</h3>'
        '<img data-cover-src="zzzzzz" src="https://cdn.example.com/fallback.jpg"></a>',
        decodeCover: true,
      );
      expect(films.single.coverUrl, 'https://cdn.example.com/fallback.jpg');
    });
  });

  group('WhosRosterSource gates', () {
    test('ranking and name search stay empty while the switches are off', () async {
      final source = WhosRosterSource();
      expect(
        (await source.fetchRankingPage(1, fetch: _neverFetch)).persons,
        isEmpty,
      );
      expect(
        (await source.fetchSearchByName('x', fetch: _neverFetch)).persons,
        isEmpty,
      );
    });

    test('ranking fetches only page 1 with the configured period', () async {
      final requested = <String>[];
      Future<ActressHttpResponse> fetch(
        String url, {
        Map<String, String> headers = const {},
        Duration timeout = const Duration(seconds: 20),
      }) async {
        requested.add(url);
        return const ActressHttpResponse(
          statusCode: 200,
          body: '<a href="/actresses/aoi"><img alt="苍井翼"></a>',
        );
      }

      final source = WhosRosterSource(
        enableRanking: true,
        rankingPeriod: '7d',
      );
      final page = await source.fetchRankingPage(1, fetch: fetch);
      expect(page.persons, hasLength(1));
      expect(requested.single, contains('/ranking/actress?period=7d'));
      final page2 = await source.fetchRankingPage(2, fetch: fetch);
      expect(page2.persons, isEmpty);
      expect(requested, hasLength(1));
    });

    test('name search uses the name query', () async {
      final requested = <String>[];
      Future<ActressHttpResponse> fetch(
        String url, {
        Map<String, String> headers = const {},
        Duration timeout = const Duration(seconds: 20),
      }) async {
        requested.add(url);
        return const ActressHttpResponse(statusCode: 200, body: '');
      }

      final source = WhosRosterSource(enableNameSearch: true);
      await source.fetchSearchByName('苍井翼', fetch: fetch);
      expect(requested.single, contains('/actresses?name='));
    });
  });

  group('merge new fields', () {
    test('rating takes the first non-null, exact works take the max', () {
      final first = mergeRosterIntoPerson(
        null,
        const RosterPerson(
          source: ActressRosterSourceId.whos,
          sourceId: 'aoi',
          name: '苍井翼',
          rating: 8.6,
          exactWorks: 100,
          aliases: ['翼酱'],
        ),
      );
      expect(first.rating, 8.6);
      expect(first.exactWorks, 100);
      expect(first.aliases, ['翼酱']);
      final merged = mergeRosterIntoPerson(
        first,
        const RosterPerson(
          source: ActressRosterSourceId.whos,
          sourceId: 'aoi',
          name: '苍井翼',
          rating: 9.0,
          exactWorks: 80,
        ),
      );
      expect(merged.rating, 8.6);
      expect(merged.exactWorks, 100);
      expect(merged.aliases, ['翼酱']);
    });

    test('about unions with existing keys winning', () {
      final first = mergeRosterIntoPerson(
        null,
        const RosterPerson(
          source: ActressRosterSourceId.whos,
          sourceId: 'aoi',
          name: '苍井翼',
          about: {'生日': '1998-01-01'},
        ),
      );
      final merged = mergeRosterIntoPerson(
        first,
        const RosterPerson(
          source: ActressRosterSourceId.whos,
          sourceId: 'aoi',
          name: '苍井翼',
          about: {'生日': '2000-01-01', '身高': '165cm'},
        ),
      );
      expect(merged.about, {'生日': '1998-01-01', '身高': '165cm'});
    });

    test('merge never touches whosRank', () {
      const existing = ActressPerson(displayName: '苍井翼', whosRank: 5);
      final merged = mergeRosterIntoPerson(
        existing,
        const RosterPerson(
          source: ActressRosterSourceId.whos,
          sourceId: 'aoi',
          name: '苍井翼',
        ),
      );
      expect(merged.whosRank, 5);
    });
  });

  group('rank fallback', () {
    test('missav rank wins, whos rank is the fallback on the same scale', () {
      expect(
        actressRankScore(const ActressPerson(
          displayName: 'A',
          missavRank: 1,
          whosRank: 50,
        )),
        1000,
      );
      expect(
        actressRankScore(const ActressPerson(displayName: 'B', whosRank: 1)),
        1000,
      );
      expect(
        actressRankScore(const ActressPerson(displayName: 'C', whosRank: 50)),
        951,
      );
      expect(
        actressRankScore(const ActressPerson(displayName: 'D')),
        0,
      );
      expect(
        actressRankScore(
          const ActressPerson(displayName: 'E', whosRank: 1001),
        ),
        0,
      );
    });
  });

  group('MemoryActressDatabase new fields', () {
    late MemoryActressDatabase db;

    setUp(() {
      db = MemoryActressDatabase();
    });

    test('setWhosRank keeps the best rank', () async {
      final person = await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.whos,
          sourceId: 'aoi',
          name: '苍井翼',
        ),
      );
      final id = person!.localId;
      await db.setWhosRank(id, 50);
      await db.setWhosRank(id, 80);
      expect((await db.personById(id))!.whosRank, 50);
      await db.setWhosRank(id, 3);
      expect((await db.personById(id))!.whosRank, 3);
      expect((await db.personById(id))!.missavRank, isNull);
    });

    test('setPersonAbout merges with existing keys winning', () async {
      final person = await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.whos,
          sourceId: 'aoi',
          name: '苍井翼',
          about: {'生日': '1998-01-01'},
        ),
      );
      final id = person!.localId;
      await db.setPersonAbout(id, {'生日': '2000-01-01', '身高': '165cm'});
      expect((await db.personById(id))!.about, {
        '生日': '1998-01-01',
        '身高': '165cm',
      });
    });

    test('upsertWorks writes whos cover fields only when present', () async {
      final person = await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.whos,
          sourceId: 'aoi',
          name: '苍井翼',
        ),
      );
      final id = person!.localId;
      await db.upsertWorks(id, [
        const RosterFilm(
          code: 'MIAD-854',
          coverUrl: 'https://cdn.example.com/c.jpg',
          detailUrl: '/videos/miad-854',
        ),
        const RosterFilm(code: 'MIAD-855'),
      ]);
      final works = await db.worksForPerson(id, offset: 0, limit: 100);
      expect(works, hasLength(2));
      final covered = works.firstWhere((w) => w.codeDisplay == 'MIAD-854');
      expect(covered.coverSource, 'whos');
      expect(covered.coverUrl, 'https://cdn.example.com/c.jpg');
      expect(covered.coverDramaId, '/videos/miad-854');
      final plain = works.firstWhere((w) => w.codeDisplay == 'MIAD-855');
      expect(plain.coverUrl, isEmpty);
      expect(plain.coverSource, isEmpty);
    });

    test('hard-line words in aliases or about drop the whole person', () async {
      // Uses the shared blocklist through the same public filter; the
      // concrete word comes from the list the implementation consults.
      final blockedAlias = await db.upsertRosterPerson(
        RosterPerson(
          source: ActressRosterSourceId.whos,
          sourceId: 'blocked1',
          name: '正常名字',
          aliases: [actressBlockedWords.first],
        ),
      );
      expect(blockedAlias, isNull);
      final blockedAbout = await db.upsertRosterPerson(
        RosterPerson(
          source: ActressRosterSourceId.whos,
          sourceId: 'blocked2',
          name: '正常名字',
          about: {'备注': actressBlockedWords.first},
        ),
      );
      expect(blockedAbout, isNull);
    });

    test('setPersonAbout drops blocked entries but keeps clean ones', () async {
      final person = await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.whos,
          sourceId: 'aoi',
          name: '苍井翼',
        ),
      );
      final id = person!.localId;
      await db.setPersonAbout(id, {
        '身高': '165cm',
        '备注': actressBlockedWords.first,
      });
      expect((await db.personById(id))!.about, {'身高': '165cm'});
    });
  });

  group('sync ranking dispatch', () {
    test('whos ranking writes whos_rank, missav ranking writes missav_rank',
        () async {
      final db = MemoryActressDatabase();
      final whos = FakeRosterSource(
        sourceId: ActressRosterSourceId.whos,
        rosterPages: [
          [
            const RosterPerson(
              source: ActressRosterSourceId.whos,
              sourceId: 'aoi',
              name: '苍井翼',
            ),
          ],
        ],
        rankingPages: [
          [
            const RosterPerson(
              source: ActressRosterSourceId.whos,
              sourceId: 'aoi',
              name: '苍井翼',
            ),
          ],
        ],
      );
      final missav = FakeRosterSource(
        sourceId: ActressRosterSourceId.missav,
        rosterPages: [
          [
            const RosterPerson(
              source: ActressRosterSourceId.missav,
              sourceId: 'm/aoi',
              name: '苍井翼',
            ),
          ],
        ],
        rankingPages: [
          [
            const RosterPerson(
              source: ActressRosterSourceId.missav,
              sourceId: 'm/aoi',
              name: '苍井翼',
            ),
          ],
        ],
      );
      final sync = ActressSyncService(
        db: db,
        sources: [whos, missav],
        fetch: _neverFetch,
      );
      addTearDown(sync.dispose);
      final result = await sync.run();
      expect(result.hasFailures, isFalse);
      final persons = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.nameAsc,
        query: '',
        offset: 0,
        limit: 10,
      );
      expect(persons, hasLength(1));
      expect(persons.single.whosRank, 1);
      expect(persons.single.missavRank, 1);
    });
  });
}
