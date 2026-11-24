// 女优库标签筛选测试（2026-11-24 用户令）：
// - 内存库的标签筛选语义：人物列表只留有该标签作品的人；作品列表
//   只留带该标签的作品；与分类是 AND 关系；dbTags 按作品数倒序。
// - ActressTagSheet：点标签回传标签名，点“全部”回传 ''，没有标签
//   时如实显示“暂无标签”。
// 严格库的 SQL 本体在 flutter test 里打不开真库（sqflite 未初始化），
// 用 Python 对真库副本重放（见工作目录 verify/ 下的 replay 脚本）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_database.dart';
import 'package:fqapp/actress/actress_models.dart';
import 'package:fqapp/actress/actress_tag_sheet.dart';

Future<MemoryActressDatabase> _seedDb() async {
  final db = MemoryActressDatabase();
  final a = await db.upsertRosterPerson(
    const RosterPerson(
      source: ActressRosterSourceId.chaoliu,
      sourceId: 'a1',
      name: '八木奈奈',
      sex: 'female',
    ),
  );
  await db.upsertWorks(a!.localId, [
    const RosterFilm(code: 'MIDA-619', title: '测试作品一', category: '有码'),
    const RosterFilm(code: 'SSIS-123', title: '测试作品二', category: '有码'),
  ]);
  final b = await db.upsertRosterPerson(
    const RosterPerson(
      source: ActressRosterSourceId.whos,
      sourceId: 'b1',
      name: '测试二号',
      sex: 'female',
    ),
  );
  await db.upsertWorks(b!.localId, [
    const RosterFilm(code: 'IPX-707', title: '测试作品三', category: '无码'),
  ]);
  db.setWorkTagsForCode('mida-619', ['中文字幕', 'ハイビジョン']);
  db.setWorkTagsForCode('ssis-123', ['ハイビジョン']);
  db.setWorkTagsForCode('ipx-707', ['中文字幕']);
  return db;
}

void main() {
  group('内存库标签筛选', () {
    test('dbTags：按作品数倒序', () async {
      final db = await _seedDb();
      final tags = await db.dbTags();
      expect(tags, [('ハイビジョン', 2), ('中文字幕', 2)]);
    });

    test('listPersons(videoTag)：只留有该标签作品的人', () async {
      final db = await _seedDb();
      final hi = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.worksDesc,
        query: '',
        offset: 0,
        limit: 60,
        videoTag: 'ハイビジョン',
      );
      expect([for (final p in hi) p.displayName], ['八木奈奈']);
      final cn = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.worksDesc,
        query: '',
        offset: 0,
        limit: 60,
        videoTag: '中文字幕',
      );
      expect(
        [for (final p in cn) p.displayName],
        ['八木奈奈', '测试二号'],
      );
      final none = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.worksDesc,
        query: '',
        offset: 0,
        limit: 60,
        videoTag: '不存在的标签',
      );
      expect(none, isEmpty);
    });

    test('listPersons(videoTag + category)：AND 关系', () async {
      final db = await _seedDb();
      final both = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.worksDesc,
        query: '',
        offset: 0,
        limit: 60,
        category: '有码',
        videoTag: 'ハイビジョン',
      );
      expect([for (final p in both) p.displayName], ['八木奈奈']);
      final mismatch = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.worksDesc,
        query: '',
        offset: 0,
        limit: 60,
        category: '无码',
        videoTag: 'ハイビジョン',
      );
      expect(mismatch, isEmpty);
    });

    test('countPersons(videoTag) 与列表同一口径', () async {
      final db = await _seedDb();
      expect(
        await db.countPersons(
          sex: ActressSexFilter.all,
          query: '',
          videoTag: 'ハイビジョン',
        ),
        1,
      );
      expect(
        await db.countPersons(
          sex: ActressSexFilter.all,
          query: '',
          videoTag: '中文字幕',
        ),
        2,
      );
    });

    test('worksForPerson / countWorks(videoTag)：只留带标签的作品', () async {
      final db = await _seedDb();
      final a = (await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.nameAsc,
        query: '八木奈奈',
        offset: 0,
        limit: 1,
      )).first;
      final works = await db.worksForPerson(
        a.localId,
        offset: 0,
        limit: 60,
        videoTag: '中文字幕',
      );
      expect([for (final w in works) w.codeKey], ['MIDA619']);
      expect(
        await db.countWorks(a.localId, videoTag: 'ハイビジョン'),
        2,
      );
      expect(
        await db.countWorks(
          a.localId,
          category: '有码',
          videoTag: '中文字幕',
        ),
        1,
      );
      expect(
        await db.countWorks(
          a.localId,
          category: '无码',
          videoTag: 'ハイビジョン',
        ),
        0,
      );
    });
  });

  group('ActressTagSheet', () {
    const tags = [
      ('ハイビジョン', 183579),
      ('単体作品', 178032),
      ('中文字幕', 34906),
    ];

    Future<void> pumpSheet(
      WidgetTester tester, {
      List<(String, int)> sheetTags = tags,
      String selected = '',
      required ValueChanged<String> onSelected,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ActressTagSheet(
              tags: sheetTags,
              selected: selected,
              onSelected: onSelected,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('点标签回传标签名，点“全部”回传空串', (tester) async {
      var picked = '<none>';
      await pumpSheet(
        tester,
        selected: '中文字幕',
        onSelected: (tag) => picked = tag,
      );
      expect(find.text('标签'), findsOneWidget);
      expect(find.text('3 个'), findsOneWidget);
      await tester.tap(find.text('ハイビジョン（183579）'));
      expect(picked, 'ハイビジョン');
      await tester.tap(find.text('全部'));
      expect(picked, '');
    });

    testWidgets('没有标签时如实显示“暂无标签”，不编', (tester) async {
      await pumpSheet(
        tester,
        sheetTags: const [],
        onSelected: (_) {},
      );
      expect(find.text('暂无标签'), findsOneWidget);
      expect(find.text('这个数据库里没有标签数据'), findsOneWidget);
      expect(find.text('全部'), findsNothing);
    });
  });
}
