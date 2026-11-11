import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/main.dart';
import 'package:fqapp/pages/cultivation_create_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/game_service.dart';
import 'package:fqapp/widgets/cultivation_level_up_dialog.dart';

/// 硬门槛与升境弹窗：首次启动未建档时只显示全屏创建人物界面
/// （无跳过、无关闭、返回键绕不过去），建档后进主界面；修为跨过
/// 境界门槛时弹升境庆祝弹窗，列新解锁的内容区与成人站档位。
///
/// 创建页带无限动画（粒子、呼吸），不能用 pumpAndSettle，
/// 改用 pump 推进时长。
/// 壳层测试不启动本地服务：后端就绪立即为真，直接进主界面。
Future<void> _noBackend() async {}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CultivationService.instance.resetForTest();
  });

  testWidgets('未建档时只显示全屏创建人物界面，不进主界面', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: RootShell(backendStarter: _noBackend)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(CultivationCreatePage), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    // RootShell 启动挂机服务 GameService（5 秒周期定时器）：体结束
    // 时若还挂着，_verifyInvariants 报 Timer 仍挂起；tearDown 在
    // invariant 检查之后才跑，来不及，只能在体末显式清掉
    // （resetForTest 开头同步取消定时器）。
    await tester.runAsync(() => GameService.instance.resetForTest());
  });

  testWidgets('建档后进主界面，底部栏正常显示', (tester) async {
    // 裸 await createProfile 会挂死在 FakeAsync 区里
    // （SharedPreferences 系调用等不到回包，本地单跑复现 10 分钟
    // 超时、CI 上同款无异常块失败），改走 runAsync。
    await tester.runAsync(() => CultivationService.instance.createProfile(
          gender: CultivationGender.male,
          sect: cultivationSects.first,
          profession: defaultCultivationProfession,
        ));
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: RootShell(backendStarter: _noBackend)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    // RootShell 的 _checkProfile 在 FakeAsync 区里等不到
    // ensureInitialized 的 continuation：23 次 pump 刷不掉加载屏，
    // 从真异步区再推一次 ensureInitialized、随后 pump 才会进主界面
    // （探针实测；空 runAsync 同样能顶过去，起作用的是 runAsync
    // 本身的排空，这里用 ensureInitialized 是表意更直接的同款）。
    await tester.runAsync(
      () async => CultivationService.instance.ensureInitialized(),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(CultivationCreatePage), findsNothing);
    // 默认进游戏 tab（index 0），底部导航在游戏页是藏掉的；
    // 点顶栏「离开」切到首页 tab 后底部栏才出现。
    await tester.tap(find.text('离开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.runAsync(() => GameService.instance.resetForTest());
  });

  testWidgets('创建页里点开始修仙后落盘进主界面', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: RootShell(backendStarter: _noBackend)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(CultivationCreatePage), findsOneWidget);

    // 「开始修仙」按钮在 800×600 默认画布下位于 y=1192，落在视口外，
    // 直接 tap 点不到（CI/本地同款警告 + 断言失败）；先滚进视口再点。
    await tester.ensureVisible(find.text('开始修仙'));
    await tester.tap(find.text('开始修仙'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(CultivationCreatePage), findsNothing);
    // 同建档后：默认进游戏 tab（index 0），底部导航藏着；
    // 点顶栏「离开」切到首页 tab 后底部栏才出现。
    await tester.tap(find.text('离开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(
      CultivationService.instance.snapshot.hasProfile,
      isTrue,
    );

    await tester.runAsync(() => GameService.instance.resetForTest());
  });

  testWidgets('升境弹窗：跨过元婴期列出影视区第 1 档与直播成人源', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showCultivationLevelUpDialog(
                  context,
                  crossedRealmIndexes: crossedRealmIndexes(2999, 3000),
                  adultRegistryOrder: const [
                    'site_a',
                    'site_b',
                    'site_c',
                    'site_d',
                    'site_e',
                    'site_f',
                    'site_g',
                    'site_h',
                  ],
                  newXp: 3000,
                ),
                child: const Text('弹'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('弹'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('元婴已成，影视区开！'), findsOneWidget);
    expect(find.text('元婴出窍，天地任逍遥。'), findsOneWidget);
    expect(find.textContaining('影视区（第 1 档站）'), findsOneWidget);
    expect(find.textContaining('直播成人源'), findsOneWidget);
    expect(find.textContaining('当前修为 3000'), findsOneWidget);
    expect(
      find.textContaining('下一境化神期，还差 5000 修为'),
      findsOneWidget,
    );

    await tester.tap(find.text('入境一观'));
    await tester.pumpAndSettle();
    expect(find.text('元婴已成，影视区开！'), findsNothing);
  });

  testWidgets('升境弹窗：没跨过境界时不弹', (tester) async {
    var called = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  called = true;
                  await showCultivationLevelUpDialog(
                    context,
                    crossedRealmIndexes: crossedRealmIndexes(100, 200),
                    adultRegistryOrder: const ['site_a'],
                    newXp: 200,
                  );
                },
                child: const Text('弹'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('弹'));
    await tester.pump();

    expect(called, isTrue);
    expect(find.text('元婴已成，影视区开！'), findsNothing);
  });
}
