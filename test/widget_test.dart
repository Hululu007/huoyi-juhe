// Basic smoke test: the app boots to the backend-starting screen.
//
// Wrapped in ProviderScope to mirror main() — HomePage is a ConsumerWidget,
// so any future test that reaches it needs the provider scope present.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/main.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/game_service.dart';

/// 硬门槛：RootShell 未建档时只显示全屏创建人物界面。壳层用例要看到
/// 主界面/后端启动屏，得先建一个道友档案（直接调服务，不走创建页）。
Future<void> _createTestProfile(WidgetTester tester) async {
  // 没设 mock 时 SharedPreferences.getInstance() 在测试里等不到平台回包、
  // 一直挂住（CultivationService._load 的第一行就是它），测试 10 分钟超时。
  // 其他用 CultivationService 的测试都先设了 mock，这里补上。
  SharedPreferences.setMockInitialValues({});
  // 只设 mock 还不够：createProfile 末尾的 _persist 是链式 Future
  // （_persistChain.then 回调里再取 SharedPreferences），在 testWidgets
  // 的 FakeAsync 区里挂住、永不返回（真机与普通 test 里正常）；必须
  // 用 tester.runAsync 走真异步区才能跑完。
  await tester.runAsync(
    () => CultivationService.instance.createProfile(
      gender: CultivationGender.male,
      sect: cultivationSects.first,
      profession: defaultCultivationProfession,
    ),
  );
}

void main() {
  // RootShell 一挂就起 GameService 的 5 秒挂机计时器：测试结束时表还
  // 挂着会报 “A Timer is still pending”；long-startup 用例的
  // pumpAndSettle 也会被它拖住永远等不到安静，收尾统一停表。
  tearDown(() => GameService.instance.stopTimerForTest());

  testWidgets('long startup failures stay scrollable and retryable', (
    tester,
  ) async {
    await _createTestProfile(tester);
    await tester.binding.setSurfaceSize(const Size(320, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RootShell(
          backendStarter: () async {
            attempts++;
            throw StateError(List.filled(80, '本地服务启动失败的详细信息').join('\n'));
          },
        ),
      ),
    );
    // 有界 pump，不用 pumpAndSettle：GameService 的 5 秒计时器一起表，
    // pumpAndSettle 会被它拖住永远等不到安静；启动失败屏本身没有无限
    // 动画，几帧 pump 足够让异步的 backendStarter 抛错并画出错屏。
    // 另：RootShell 的 _checkProfile 在 FakeAsync 区里等不到
    // ensureInitialized 的 continuation，pump 刷不掉加载屏，须先从
    // 真异步区再推一次（cultivation_gate 同款）。
    await tester.runAsync(
      () async => CultivationService.instance.ensureInitialized(),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    GameService.instance.stopTimerForTest();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('App boots', (WidgetTester tester) async {
    await _createTestProfile(tester);
    await tester.pumpWidget(const ProviderScope(child: FqApp()));
    await tester.pump();
    // The app should show the backend startup screen or the main shell.
    expect(find.byType(FqApp), findsOneWidget);
  });
}
