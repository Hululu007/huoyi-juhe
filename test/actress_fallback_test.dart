import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_database.dart';
import 'package:fqapp/actress/actress_models.dart';

void main() {
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

}
