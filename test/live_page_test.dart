import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/live_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 直播页的数据走修仙境界：未到元婴期（3000 修为）时只显示上锁提示，
/// 不露源名与频道；到了元婴期正常显示四个内置源（按火蚁TV：源名在
/// 当前卡「切换直播源」框里，不再是横向源 chips）。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CultivationService.instance.resetForTest();
    await CultivationService.instance.ensureInitialized();
  });

  tearDown(() async {
    await CultivationService.instance.resetForTest();
  });

  Future<void> pumpLive(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LivePage()));
    // 上锁态不显示转圈动画；多推几帧让 loadImportedChannels 的
    // Future 完成并把 _loading 置 false，免得解锁后还停在转圈上。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
  }

  testWidgets('未到元婴期：只显示上锁提示，不露源名与频道', (tester) async {
    await pumpLive(tester);

    expect(find.text('直播源需要元婴期'), findsOneWidget);
    expect(find.textContaining('还差 3000 修为'), findsOneWidget);
    expect(find.text('去我的页看进度'), findsOneWidget);
    expect(find.text('秀果'), findsNothing);
    expect(find.text('欲火聚合'), findsNothing);
    expect(find.text('百年直播'), findsNothing);
    expect(find.text('成人点播'), findsNothing);
    expect(find.text('内置直播源'), findsNothing);
    expect(find.text('导入的 m3u 频道'), findsNothing);
  });

  testWidgets('到了元婴期：正常显示四个内置源', (tester) async {
    // 先按上锁态把页搭起来（与旧口令版测试同一结构：先锁后解），
    // 再把修为快照换成 3000 修为（6000 秒小说 ×0.5/秒），让页面的
    // 修为监听自己重建出列表。修为累计本身由 cultivation_test 覆盖，
    // 这里只验页面对境界的反应；直接换快照可避开 testWidgets 里调
    // 异步服务方法会挂起的问题。
    await pumpLive(tester);
    expect(find.text('直播源需要元婴期'), findsOneWidget);

    CultivationService.instance.snapshotNotifier.value =
        const CultivationSnapshot(
      seconds: {CultivationCategory.novel: 6000.0},
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    expect(find.text('直播源需要元婴期'), findsNothing);
    // 源 chips 已按火蚁TV去掉：源名只在当前卡 caption 与「切换直播源」框里，
    // 不再以独立 Text 出现在页上。
    expect(find.text('内置直播源'), findsNothing);
    await tester.tap(find.byTooltip('切换直播源'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('切换直播源'), findsOneWidget);
    expect(find.text('秀果'), findsOneWidget);
    expect(find.text('欲火聚合'), findsOneWidget);
    expect(find.text('百年直播'), findsOneWidget);
    expect(find.text('成人点播'), findsOneWidget);
  });
}
