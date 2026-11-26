import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/game_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/game_data.dart';
import 'package:fqapp/services/game_service.dart';
import 'package:fqapp/widgets/game_battle_stage.dart';

/// 修仙版游戏 UI 回归：战斗剑光 / BOSS 血条 / 技能新名。
///
/// 游戏页已删主页 hub：打开直接在战场（没有「进入战斗」钮、
/// 没有技能圆盘 / 主线竖牌 / 队伍招募条，顶栏也没有「主页」钮）；
/// 战场顶部有 BOSS 血条（名 + 红条 + 真实血量），技能栏四技能
/// 按用户原型定名（剑影分光 / 雷法 / 大庚剑阵 / 万剑归宗）。
/// 注意：本文件只断言界面与接线，不跑数值；剑光本身是纯视觉特效，
/// 手机上看效果。收尾照 test/game_battle_minions_test.dart：
/// 换页 + 推 3 秒假时间清掉寻路 / 出招 / 剑光那类没法取消的
/// Future.delayed，不然 fake_async 在测试结束时报 Pending timers。
Future<void> _pumpGamePage(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: GamePage(
          active: false,
          onExit: () {},
          onOpenFilmTab: () {},
          onOpenDramaTab: () {},
          onSwitchToVideo: () {},
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _pumpStage(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: GameBattleStage(
          monster: gameMonsterById('zi_dian_mo_yi'),
          heroPower: 60,
          heroMaxHp: 1000,
          profession: '天道',
          heroName: '道友',
          heroRealm: '炼气中期',
          heroIsFemale: false,
          heroXp: 0,
          dungeonName: '血色禁地',
          xpLabel: '炼气中期 0/300',
          xpRatio: 0,
          // active 关掉：不跑自动战斗，断言才稳定（自动放招会把
          // 大招名打上横幅，和技能栏的菱形名撞成两个）。
          active: false,
          onMonsterKilled: () {},
          onMinionKilled: (_) {},
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

Future<void> _tearDown(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: SizedBox())),
  );
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CultivationService.instance.resetForTest();
    await GameService.instance.resetForTest();
    await GameService.instance.ensureInitialized();
  });

  group('删主页 hub：打开直达战场', () {
    testWidgets('打开直接在战场：无主页元素，BOSS 血条与四技能名都在',
        (tester) async {
      await _pumpGamePage(tester);
      // 主页 hub 元素全不在。
      expect(find.text('进入战斗'), findsNothing);
      expect(find.text('队伍招募：组队刷副本'), findsNothing);
      expect(find.text('御剑'), findsNothing);
      expect(find.text('归元'), findsNothing);
      expect(find.text('冰心'), findsNothing);
      expect(find.text('新月'), findsNothing);
      // 战场顶栏常驻：有「离开」与「观影」，没有「主页」钮。
      expect(find.text('离开'), findsOneWidget);
      expect(find.text('观影'), findsOneWidget);
      expect(find.text('主页'), findsNothing);
      // 开局 BOSS（紫电魔蚁）血条：名 + 真实血量。
      expect(find.text('紫电魔蚁 · BOSS'), findsOneWidget);
      expect(find.text('180/180'), findsOneWidget);
      // 战场技能栏四技能名。
      expect(find.text('剑影分光'), findsOneWidget);
      expect(find.text('雷法'), findsOneWidget);
      expect(find.text('大庚剑阵'), findsOneWidget);
      expect(find.text('万剑归宗'), findsOneWidget);
      await _tearDown(tester);
    });
  });

  group('32 轮战斗：BOSS 血条与技能新名', () {
    testWidgets('顶部有 BOSS 血条（名 + 真实血量），技能栏是四个新名',
        (tester) async {
      await _pumpStage(tester);
      expect(find.text('紫电魔蚁 · BOSS'), findsOneWidget);
      expect(find.text('180/180'), findsOneWidget);
      expect(find.text('剑影分光'), findsOneWidget);
      expect(find.text('雷法'), findsOneWidget);
      expect(find.text('大庚剑阵'), findsOneWidget);
      expect(find.text('万剑归宗'), findsOneWidget);
      expect(find.text('普攻'), findsNothing);
      expect(find.text('惊蛰'), findsNothing);
      await _tearDown(tester);
    });
  });
}
