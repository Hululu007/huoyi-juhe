import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/game_data.dart';
import 'package:fqapp/widgets/game_battle_stage.dart';
import 'package:fqapp/widgets/game_monster_art.dart';

/// 小怪战场回归：50 个托机器人已删，换成 14 只小怪。
///
/// 注意：本文件依赖另一路在 lib/services/game_sound.dart 里
/// 加的 GameSoundService.playSwordClash（播 sword_clash.mp3），
/// 那方法落盘前本文件连同 game_battle_stage.dart 一起编不过，
/// 等两路合到一起再跑。
Future<void> _pumpStage(
  WidgetTester tester, {
  required GameMonster monster,
  required int heroPower,
  required List<GameMonster> minionKills,
  required List<void Function()> bossKills,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: GameBattleStage(
          monster: monster,
          heroPower: heroPower,
          heroMaxHp: 1000,
          profession: '天道',
          heroName: '道友',
          heroRealm: '炼气中期',
          heroIsFemale: false,
          heroXp: 0,
          dungeonName: '血色禁地',
          xpLabel: '炼气中期 0/300',
          xpRatio: 0,
          onMonsterKilled: () => bossKills.add(() {}),
          onMinionKilled: minionKills.add,
          onHeroStrike: (_) {},
          onOpenShop: () {},
          onOpenTasks: () {},
          onOpenProfile: () {},
          onOpenFunctions: () {},
          onOpenAnnounce: () {},
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 收尾：把战场换掉（dispose 里停掉心跳定时器与小怪重刷
/// 定时器），再推 3 秒假时间，让寻路 1.4 秒、出招 280ms、
/// 死亡 680ms 这类没法取消的 Future.delayed 都跑完——
/// 不然 fake_async 在测试结束时报 Pending timers。
/// 回调里都有 mounted 检查，跑完只是空转，不会再 setState。
Future<void> _tearDownStage(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: SizedBox())),
  );
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  group('小怪战场（托机器人已删，换成小怪）', () {
    testWidgets('场上是 14 只小怪 + 1 只章节怪，四种野兽图全在，没有托机器人',
        (tester) async {
      final minionKills = <GameMonster>[];
      final bossKills = <void Function()>[];
      await _pumpStage(
        tester,
        monster: gameMonsterById('ye_lang'),
        heroPower: 60,
        minionKills: minionKills,
        bossKills: bossKills,
      );
      // 1 只章节怪 + 14 只小怪。
      expect(find.byType(GameMonsterArt), findsNWidgets(15));
      // 小怪的图按槽位轮着用四张：金光蟒 / 紫电妖狼 /
      // 赤焰火虎 / 金刚巨猿，四种都在场上。
      final overrides = tester
          .widgetList<GameMonsterArt>(find.byType(GameMonsterArt))
          .map((widget) => widget.artOverride)
          .whereType<String>()
          .toSet();
      expect(overrides, gameMonsterCommonArts.toSet());
      // 托机器人不在了：名字、喊话气泡一个都没有。
      expect(find.text('南宫婉'), findsNothing);
      expect(find.text('韩跑跑'), findsNothing);
      expect(find.text('老大！你一定能赢！'), findsNothing);
      await _tearDownStage(tester);
    });

    testWidgets('主角挂机打小怪：打死结算一只，重刷后场上还是 14 只',
        (tester) async {
      final minionKills = <GameMonster>[];
      final bossKills = <void Function()>[];
      await _pumpStage(
        tester,
        monster: gameMonsterById('ye_lang'),
        heroPower: 8000,
        minionKills: minionKills,
        bossKills: bossKills,
      );
      // 寻路 1.4 秒 + 普攻 1.6 秒一剑：推 10 秒假时间，
      // 主角一定打死过小怪（高战力一剑一只）。
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(minionKills, isNotEmpty);
      // 死掉的槽位 1.2 秒重刷，场上一直 14 只小怪 + 1 只章节怪。
      expect(find.byType(GameMonsterArt), findsNWidgets(15));
      await _tearDownStage(tester);
    });
  });
}
