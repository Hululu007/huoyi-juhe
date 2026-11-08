import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/mine_page.dart';
import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 影视区境界门禁：未到元婴期（3000 修为）时整页上锁，只显示与直播区
/// 同款的锁页（大锁图标 + 「影视源需要元婴期」+ 还差多少修为约几集
/// 短剧 + 去我的页看进度），不露任何站名与内容；修为到了自动显示
/// 影视源。站列表只留已解锁的站：统一站表走现有的
/// [visibleVideoZoneSites]（见 video_page_tier_test），用户自导站
/// 走新增的 [visibleVideoPagePlayableSites]（同一种可见性逻辑）。
void main() {
  late Directory hiveDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // 门禁开关：生产默认值 true（测试期临时关闭）会放行全部档位，
    // 分档断言须先关掉，用完恢复（与 video_page_tier_test 同款）。
    cultivationAdultTierGateDisabledForTesting = false;
    await CultivationService.instance.resetForTest();
    await CultivationService.instance.ensureInitialized();
    // 「去我的页看进度」会推 MinePage，它的 initState 要读
    // LibraryStore：测试里先开箱（与 mine_page_test 同款）。
    hiveDir = await Directory.systemTemp.createTemp('fqapp-video-lock-');
    Hive.init(hiveDir.path);
    await LibraryStore.instance.init();
  });

  tearDown(() async {
    cultivationAdultTierGateDisabledForTesting = true;
    await CultivationService.instance.resetForTest();
    await Hive.close();
    await hiveDir.delete(recursive: true);
  });

  Future<void> pumpVideo(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: VideoPage()));
    // 上锁态不显示转圈动画；多推几帧让 _load 的 Future 完成并把
    // _loading 置 false，免得还停在转圈上（与 live_page_test 同款）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
  }

  testWidgets('未到元婴期：只显示上锁页，不露任何站名与内容', (tester) async {
    await pumpVideo(tester);

    expect(find.text('影视源需要元婴期'), findsOneWidget);
    expect(find.textContaining('还差 3000 修为'), findsOneWidget);
    expect(find.textContaining('约 10 集短剧'), findsOneWidget);
    expect(find.text('去我的页看进度'), findsOneWidget);
    // 锁页不露站名与分区名：午夜区标题、切换器、用户自导站都不出现。
    expect(find.text('午夜区'), findsNothing);
    expect(find.text('分类'), findsNothing);
  });

  testWidgets('到了元婴期：锁页消失，正常显示影视区', (tester) async {
    // 先按上锁态把页搭起来，再把修为快照换成 3000 修为
    // （6000 秒小说 ×0.5/秒），让页面的修为监听自己重建出内容
    // （与 live_page_test 同款做法）。
    await pumpVideo(tester);
    expect(find.text('影视源需要元婴期'), findsOneWidget);

    CultivationService.instance.snapshotNotifier.value =
        const CultivationSnapshot(
      seconds: {CultivationCategory.novel: 6000.0},
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    expect(find.text('影视源需要元婴期'), findsNothing);
    expect(find.text('午夜区'), findsOneWidget);
  });

  testWidgets('锁页按钮：点「去我的页看进度」跳到我的页', (tester) async {
    await pumpVideo(tester);

    await tester.tap(find.text('去我的页看进度'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    // 我的页已推到最上层（锁页仍在下层路由里，不再可见——
    // Navigator 的下层路由仍在树里，findsNothing 断言不适用）。
    expect(find.byType(MinePage), findsOneWidget);
    expect(find.text('我的'), findsWidgets);
  });

  SourceEntry entry({
    required String id,
    required String name,
    required SourceKind kind,
  }) {
    return SourceEntry(
      id: id,
      name: name,
      kind: kind,
      address: '$id.addr',
      detail: '',
    );
  }

  // 用户自导站（jar 行 id 能归一化到分档表里，py/采集站不在表里）。
  List<SourceEntry> playableEntries() => [
        entry(
          id: 'jar:user_jar:ZakaMjv011',
          name: '用户导入的 jar 站（第 1 档）',
          kind: SourceKind.jarImport,
        ),
        entry(
          id: 'jar:user_jar:ZakaJavrate',
          name: '用户导入的 jar 站（第 4 档末尾）',
          kind: SourceKind.jarImport,
        ),
        entry(
          id: 'import_adult',
          name: '🔞成人站',
          kind: SourceKind.pyImport,
        ),
        entry(
          id: 'import_user_maccms',
          name: '用户添加的采集站',
          kind: SourceKind.customMaccms,
        ),
      ];

  test('用户自导站：修为 0 时分档站一个都不露，不分档站原样保留', () {
    final visible = visibleVideoPagePlayableSites(playableEntries(), 0);
    final ids = visible.map((site) => site.id).toSet();
    expect(ids.contains('jar:user_jar:ZakaMjv011'), isFalse);
    expect(ids.contains('jar:user_jar:ZakaJavrate'), isFalse);
    expect(ids.contains('import_adult'), isTrue);
    expect(ids.contains('import_user_maccms'), isTrue);
  });

  test('用户自导站：元婴 3000 时第 1 档出现，第 4 档还不出现', () {
    final visible = visibleVideoPagePlayableSites(playableEntries(), 3000);
    final ids = visible.map((site) => site.id).toSet();
    expect(ids.contains('jar:user_jar:ZakaMjv011'), isTrue);
    expect(ids.contains('jar:user_jar:ZakaJavrate'), isFalse);
  });

  test('用户自导站：合体 30000 时全部开完', () {
    final visible = visibleVideoPagePlayableSites(playableEntries(), 30000);
    final ids = visible.map((site) => site.id).toSet();
    expect(ids.contains('jar:user_jar:ZakaMjv011'), isTrue);
    expect(ids.contains('jar:user_jar:ZakaJavrate'), isTrue);
    expect(ids.length, playableEntries().length);
  });

  test('用户自导站：门禁开关开时修为 0 也全可见', () {
    cultivationAdultTierGateDisabledForTesting = true;
    final visible = visibleVideoPagePlayableSites(playableEntries(), 0);
    expect(visible.length, playableEntries().length);
  });
}
