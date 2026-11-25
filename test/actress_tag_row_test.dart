// 女优 tab 第二排分类 + 第三排删除（2026-11-24 用户令）：
// - 第二排是视频分类：三册全部/有码/无码/欧美/国产/4K/动漫/三级/其他，
//   接在欧美后面同一排平铺（横向滚动），不另起一排；值取自数据库
//   video_category.main_category 在重合并库里的 DISTINCT 值。
// - 第三排（数据库名分类，东瀛合集/综合合集那种库名 + 作品数）整排
//   删除，含它管的筛选状态；女优 tab 只剩性别排 + 分类排。
// - 男优：性别筛选接线不变（名册库上点男优只留 sex=male 的人）；
//   男优头像走 ActressAvatar + 库里 avatarUrl，有就显示照片。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_database.dart';
import 'package:fqapp/actress/actress_list_page.dart';
import 'package:fqapp/actress/actress_models.dart';
import 'package:fqapp/actress/actress_widgets.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'actress_fixtures.dart';

Future<LocalStore> _makeStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore();
  addTearDown(store.dispose);
  return store;
}

/// 首屏 _bootstrap 里有真异步文件 IO（绑目录/读库选择/叠加断点），
/// FakeAsync 里定步 pump 永远等不到它完成（见 AGENTS.md 2026-11-18
/// 条：testWidgets 里 async dart:io 会挂住）；必须在 runAsync 里
/// 用真时间轮询、块内 pump。点胶囊后的重载是纯内存库查询，假
/// 时间 pump 就够，见 _waitFor。顶栏有输入框（光标动画一直动），
/// 不能用 pumpAndSettle。
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 30; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}

/// 首屏链路（_bootstrap → 概览 → 列表）要跑好几轮异步查询，定步
/// 20 次有时不够：在上限内一直 pump 到目标出现为止。
Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 60; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// _waitFor 的反向：一直 pump 到目标消失为止。点“男优”后不能等
/// 男优出现（首屏全部里他本来就在），要等女演员卡片被新列表换掉。
Future<void> _waitForGone(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 60; i++) {
    if (finder.evaluate().isEmpty) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('ActressTagFilter 第二排分类', () {
    test('顺序：全部/有码/无码/欧美/国产/4K/动漫/三级/其他', () {
      expect(
        ActressTagFilter.values.map((f) => f.label).toList(),
        ['三册全部', '有码', '无码', '欧美', '国产', '4K', '动漫', '三级', '其他'],
      );
    });

    test('tagValue 与数据库主分类名一致', () {
      expect(ActressTagFilter.domestic.tagValue, '国产');
      expect(ActressTagFilter.fourK.tagValue, '4K');
      expect(ActressTagFilter.anime.tagValue, '动漫');
      expect(ActressTagFilter.sanji.tagValue, '三级');
      expect(ActressTagFilter.other.tagValue, '其他');
      expect(ActressTagFilter.all.tagValue, '');
    });

    test('覆盖重合并库的全部非空主分类', () {
      // 2026-11-24 对 ~/workspace/roster_remrge_20261124/女优库.db
      // 实查：video_category.main_category DISTINCT 非空值就是这 8 个
      //（有码 251867、无码 86936、国产 35365、4K 24456、动漫 11110、
      // 三级 10418、欧美 4950、其他 4501；空值 18187 + NULL 1278 不
      // 单独成类，2026-11-23 已定：空着就算全部）。
      const dbCategories = {
        '有码',
        '无码',
        '国产',
        '4K',
        '动漫',
        '三级',
        '欧美',
        '其他',
      };
      final enumValues = {
        for (final f in ActressTagFilter.values)
          if (f.tagValue.isNotEmpty) f.tagValue,
      };
      expect(enumValues, dbCategories);
    });
  });

  group('女优 tab 两排筛选', () {
    late MemoryActressDatabase db;
    late LocalStore store;

    setUp(() async {
      db = MemoryActressDatabase();
      store = await _makeStore();
    });

    Future<ActressPerson> seedPerson(
      String name, {
      String sex = 'female',
      int works = 0,
      List<String> tags = const [],
      String avatarUrl = '',
    }) async {
      final person = (await db.upsertRosterPerson(
        RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'id-$name',
          name: name,
          sex: sex,
          avatarUrl: avatarUrl,
          worksHint: works,
          tags: tags,
        ),
      ))!;
      if (works > 0) {
        await db.upsertWorks(person.localId, [
          for (var i = 0; i < works; i++) RosterFilm(code: 'TST-${i + 1}'),
        ], site: ActressRosterSourceId.chaoliu.name);
      }
      return (await db.personById(person.localId))!;
    }

    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ActressListPage(
            repository: FixtureRepository(),
            store: store,
            database: db,
          ),
        ),
      );
      await _settle(tester);
    }

    testWidgets('第二排 9 个胶囊都在，第三排库名行已删', (tester) async {
      await seedPerson('有码女', tags: ['有码'], works: 3);
      await pumpPage(tester);
      await _waitFor(tester, find.text('有码女'));
      for (final label in ['三册全部', '有码', '无码', '欧美', '国产', '4K', '动漫', '三级', '其他']) {
        expect(find.text(label), findsOneWidget, reason: '第二排缺 $label');
      }
      expect(find.byKey(const ValueKey('actress-category-all')), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key as ValueKey<String>).value.startsWith('actress-category-'),
        ),
        findsNothing,
      );
      expect(find.text('有码女'), findsOneWidget);
    });

    testWidgets('点国产：名册库没这个标签，如实空列表、不崩', (tester) async {
      await seedPerson('有码女', tags: ['有码'], works: 3);
      await seedPerson('无码男', sex: 'male', tags: ['无码'], works: 2);
      await pumpPage(tester);
      await tester.tap(find.text('国产'));
      await _waitFor(tester, find.text('暂无人物'));
      // 名册里没有“国产”这个标签（roster 0 人），筛出空列表是诚实的，
      // 不是 bug；视频库上国产走主分类筛（见 SQL 重放脚本）。
      expect(find.text('暂无人物'), findsOneWidget);
      expect(find.text('有码女'), findsNothing);
      await tester.tap(find.text('三册全部'));
      await _settle(tester);
      expect(find.text('有码女'), findsOneWidget);
      expect(find.text('无码男'), findsOneWidget);
    });

    testWidgets('点男优只留男优，头像走库里的 avatarUrl', (tester) async {
      const maleAvatar =
          'https://c0.jdbstatic.com/avatars/mm/MmXaX.jpg';
      await seedPerson(
        '黒田悠斗',
        sex: 'male',
        works: 5,
        avatarUrl: maleAvatar,
      );
      await seedPerson('女演员甲', works: 30);
      await pumpPage(tester);
      await tester.tap(find.text('男优'));
      await _waitForGone(tester, find.text('女演员甲'));
      expect(find.text('黒田悠斗'), findsOneWidget);
      expect(find.text('女演员甲'), findsNothing);
      // 卡片里有一张 Image，用的就是库里的头像地址（测试环境没网，
      // 图本身加载失败会回落占位，但 Image 节点必须带着这个地址）。
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Image &&
              w.image is NetworkImage &&
              (w.image as NetworkImage).url == maleAvatar,
        ),
        findsOneWidget,
      );
    });

    testWidgets('无头像时回落名字首字圆圈', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ActressAvatar(avatarUrl: '', name: '黒田悠斗'),
          ),
        ),
      );
      expect(find.text('黒'), findsOneWidget);
    });
  });
}
