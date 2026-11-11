import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/game_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/game_data.dart';
import 'package:fqapp/services/game_service.dart';
import 'package:fqapp/widgets/game_battle_stage.dart';

/// 修仙版第 32 轮游戏 UI 回归：主页 + 战斗剑光 / BOSS 血条 / 技能新名。
///
/// 主页：打开先是主页（白发女剑仙 + 云海仙宫），点「进入战斗」切战场，
/// 技能圆盘点技能进战场并放那一招；战场顶部有 BOSS 血条（名 + 红条 +
/// 真实血量），技能栏四技能按用户原型定名（剑影分光 / 雷法 / 大庚剑阵 /
/// 万剑归宗）。
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
          monster: gameMonsterById('ye_lang'),
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

  group('32 轮游戏主页', () {
    testWidgets('打开先是主页：进入战斗钮、四技能、主线竖牌、队伍条都在',
        (tester) async {
      await _pumpGamePage(tester);
      expect(find.text('进入战斗'), findsOneWidget);
      expect(find.text('御剑'), findsOneWidget);
      expect(find.text('归元'), findsOneWidget);
      expect(find.text('冰心'), findsOneWidget);
      expect(find.text('新月'), findsOneWidget);
      // 主线竖牌是逐字竖排：只断言首尾两字（主 / 草）。
      expect(find.text('主'), findsOneWidget);
      expect(find.text('草'), findsOneWidget);
      expect(find.text('队伍招募：组队刷副本'), findsOneWidget);
      // 没建档时名字显示通用称呼“道友”，不是写死的“凌雪瑶”。
      expect(find.text('道友'), findsOneWidget);
      expect(find.text('凌雪瑶'), findsNothing);
      await _tearDown(tester);
    });

    testWidgets('点御剑进战场并放招，点主页钮切回主页', (tester) async {
      await _pumpGamePage(tester);
      await tester.tap(find.text('御剑'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('进入战斗'), findsNothing);
      expect(find.text('主页'), findsOneWidget);
      expect(find.text('剑影分光'), findsOneWidget);
      await tester.tap(find.text('主页'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('进入战斗'), findsOneWidget);
      await _tearDown(tester);
    });

    testWidgets('点前往/活动只提示待开放，点地图开主线推图', (tester) async {
      await _pumpGamePage(tester);
      await tester.tap(find.text('前往'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('前往待开放'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      // 「前往待开放」是 2 秒提示：fake 计时下一次 pump(3 秒)
      // 只启动退出动画、提示还留在树里，此时点「活动」新提示
      // 会被排在它后面出不来；等它彻底消失再点。
      // （断言与视口未动；重叠本身已修好，单独点「活动」即通。）
      for (var i = 0;
          i < 10 && find.text('前往待开放').evaluate().isNotEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.tap(find.text('活动'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('活动待开放'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.text('地图'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('任务 · 主线推图'), findsOneWidget);
      await _tearDown(tester);
    });
  });

  group('32 轮战斗：BOSS 血条与技能新名', () {
    testWidgets('顶部有 BOSS 血条（名 + 真实血量），技能栏是四个新名',
        (tester) async {
      await _pumpStage(tester);
      expect(find.text('野狼 · BOSS'), findsOneWidget);
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
