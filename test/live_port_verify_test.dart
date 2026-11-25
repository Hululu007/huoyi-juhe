import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/whos_local_library.dart';
import 'package:fqapp/pages/live_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/live_sources.dart';
import 'package:fqapp/services/platform_channel.dart';
import 'package:fqapp/services/whos_live_bridge.dart';
import 'package:fqapp/source_picker_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 直播列表移植收尾验证（2026-11-25）：上一任工人留下的
/// live_picker_whoslib_test.dart 里有两项在测试环境里跑不过——
/// ① 4.4MB m3u 资产加载是普通 Future，假时钟 pump 推不动，
/// 必须 runAsync 给真时间（AGENTS.md 索引加载同款教训）；
/// ② 3200 高屏下首屏 60 行一次放得下、列表滑不动，_loadMore
/// 的滚动触发走不到，续载断言取不到深行。
/// 本文件用假播放器 + 真时间等待 + 手机尺寸滚动重新验同一批
/// 行为，旧文件不动（只作对照，见 REPORT.md）。
void main() {
  late StreamController<dynamic> playerEvents;
  var nextPlayerId = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CultivationService.instance.resetForTest();
    await CultivationService.instance.ensureInitialized();
    // 假原生播放器：create 回 playerId，事件流补 created /
    // videoSize / firstFrame，起播不再挂 MissingPluginException，
    // 也不留 10 秒超时 FakeTimer。
    playerEvents = StreamController<dynamic>.broadcast();
    PlatformChannels.invoke = (channel, method, args) async {
      if (method == 'create') {
        final id = ++nextPlayerId;
        scheduleMicrotask(() {
          playerEvents.add({
            'playerId': id,
            'type': 'created',
            'value': 1,
          });
          playerEvents.add({
            'playerId': id,
            'type': 'videoSize',
            'width': 1280,
            'height': 720,
          });
          playerEvents.add({'playerId': id, 'type': 'firstFrame'});
        });
        return <String, dynamic>{'playerId': id};
      }
      return null;
    };
    PlatformChannels.events = (_) => playerEvents.stream;
  });

  tearDown(() async {
    await playerEvents.close();
    PlatformChannels.invoke = null;
    PlatformChannels.events = null;
    whosLibTestLibrary = null;
    await CultivationService.instance.resetForTest();
  });

  WhosLocalLibrary libraryOf(int count) {
    return WhosLocalLibrary.fromWorks([
      for (var i = 1; i <= count; i++)
        WhosLocalWork(
          id: 'ssis-${i.toString().padLeft(3, '0')}',
          title: '标题$i',
          cover: 'https://example.test/ssis-$i.jpg',
          playUrl: 'https://example.test/ssis-$i.m3u8',
          code: 'SSIS-${i.toString().padLeft(3, '0')}',
          brand: 'ssis',
        ),
    ]);
  }

  Future<bool> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    int maxPumps = 120,
  }) async {
    for (var i = 0; i < maxPumps; i++) {
      if (finder.evaluate().isNotEmpty) return true;
      await tester.pump(const Duration(milliseconds: 100));
    }
    return finder.evaluate().isNotEmpty;
  }

  Future<void> pumpUnlocked(
    WidgetTester tester, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: LivePage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    CultivationService.instance.snapshotNotifier.value =
        const CultivationSnapshot(
      seconds: {CultivationCategory.novel: 6000.0},
    );
  }

  Finder pickerTiles() => find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        (widget.key as ValueKey<String>).value.startsWith('site-picker-row-'),
  );

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(find.byTooltip('切换直播源'));
    expect(
      await pumpUntil(tester, find.text('切换直播源')),
      true,
    );
  }

  Future<void> scrollPickerIntoView(
    WidgetTester tester,
    Finder finder,
  ) async {
    for (var i = 0; i < 20; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.drag(
        find.byKey(const ValueKey('site-picker-list')),
        const Offset(0, -300),
      );
      await tester.pump();
    }
  }

  /// 默认源已改成秀果（不再压内置片库大库）：要验片库的用例先从
  /// 弹窗里点选内置片库，再等第一页频道出来。
  Future<void> pickWhosLib(WidgetTester tester) async {
    // 先等解锁帧建出来（切源按钮进树），再开弹窗。
    expect(
      await pumpUntil(tester, find.byTooltip('切换直播源')),
      true,
    );
    await openPicker(tester);
    await scrollPickerIntoView(
      tester,
      find.byKey(const ValueKey('site-picker-row-whos_lib')),
    );
    await tester.tap(
      find.byKey(const ValueKey('site-picker-row-whos_lib')),
    );
    expect(
      await pumpUntil(
        tester,
        find.byKey(const ValueKey('live-channel-0')),
      ),
      true,
    );
  }

  /// 收尾：把页面从树上摘掉（dispose 建 30 秒 retire 计时器），
  /// 再推 31 秒假时间让它走完；否则框架报 pending timer。
  Future<void> drainRetireTimer(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 31));
  }

  List<String> rowTexts(WidgetTester tester, String key) {
    final row = find.byKey(ValueKey<String>(key));
    if (row.evaluate().isEmpty) return const [];
    return tester
        .widgetList<Text>(
          find.descendant(of: row, matching: find.byType(Text)),
        )
        .map((text) => text.data ?? '')
        .toList();
  }

  testWidgets('弹窗源数 = 28，首项内置片库、末项哔哩哔哩', (tester) async {
    expect(LiveSources.builtin.length, 28);
    expect(LiveSources.builtin.first.id, whosLibSourceId);
    expect(LiveSources.builtin.first.endpoint, 'whoslib://all');
    expect(LiveSources.builtin.last.id, 'bilibili');

    whosLibTestLibrary = libraryOf(5);
    await pumpUnlocked(tester);
    await pickWhosLib(tester);
    await openPicker(tester);
    await scrollPickerIntoView(
      tester,
      find.byKey(const ValueKey('site-picker-row-bilibili')),
    );
    expect(pickerTiles(), findsNWidgets(28));
    expect(find.text('内置片库'), findsOneWidget);
    expect(find.text('日本有码'), findsOneWidget);
    expect(find.text('哔哩哔哩'), findsOneWidget);
    await drainRetireTimer(tester);
  });

  testWidgets('有导入源时分平台源 / 导入源两组，点 tile 回 id', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  await showSitePickerDialog(
                    context,
                    sectionName: '直播',
                    currentId: 'whos_lib',
                    groups: [
                      SourcePickerGroup(
                        title: '平台源',
                        entries: [
                          for (final source in LiveSources.builtin)
                            SourcePickerEntry(
                              id: source.id,
                              name: source.name,
                            ),
                        ],
                      ),
                      const SourcePickerGroup(
                        title: '导入源',
                        entries: [
                          SourcePickerEntry(
                            id: 'imported',
                            name: '导入的频道',
                          ),
                        ],
                      ),
                    ],
                  );
                },
                child: const Text('开弹窗'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开弹窗'));
    expect(await pumpUntil(tester, find.text('切换直播源')), true);
    expect(find.text('平台源 28'), findsOneWidget);
    await scrollPickerIntoView(
      tester,
      find.byKey(const ValueKey('site-picker-row-imported')),
    );
    expect(find.text('导入源 1'), findsOneWidget);
    expect(pickerTiles(), findsNWidgets(29));
  });

  testWidgets('whoslib 桥出频道：分类、分页、字段', (tester) async {
    whosLibTestLibrary = libraryOf(130);
    final platforms = await fetchWhosLibPlatforms();
    expect(platforms.map((p) => p.id), contains('new'));
    expect(platforms.map((p) => p.id), contains('rank'));

    final page1 = await fetchWhosLibChannels(
      platforms.firstWhere((p) => p.id == 'new'),
      page: 1,
    );
    expect(page1.length, 120);
    expect(page1.first.title, 'SSIS-001 标题1');
    // 库里 playUrl 按番号归一（ssis-001 → ssis-1），只验形态。
    expect(page1.first.url, startsWith('https://example.test/ssis-'));
    expect(page1.first.url, endsWith('.m3u8'));
    expect(page1.first.sourceId, whosLibSourceId);
    expect(page1.first.number, 'SSIS-001');

    final page2 = await fetchWhosLibChannels(
      platforms.firstWhere((p) => p.id == 'new'),
      page: 2,
    );
    expect(page2.length, 10);
    expect(page2.last.title, 'SSIS-130 标题130');
    expect(
      page1.map((c) => c.title).toSet().intersection(
        page2.map((c) => c.title).toSet(),
      ),
      isEmpty,
    );
  });

  testWidgets('点内置片库出频道，行里无源名列', (tester) async {
    whosLibTestLibrary = libraryOf(5);
    await pumpUnlocked(tester);
    await pickWhosLib(tester);
    expect(find.text('最新作品 · 5'), findsOneWidget);
    expect(find.text('SSIS-001 标题1'), findsWidgets);
    // 列表里不再有源名：弹窗关着，页内任何地方都没有“内置片库”。
    expect(find.text('内置片库'), findsNothing);
    // 频道行只有一个 Text（频道名），没有源名列。
    expect(rowTexts(tester, 'live-channel-0').length, 1);
    expect(rowTexts(tester, 'live-channel-0').first, 'SSIS-001 标题1');
    await drainRetireTimer(tester);
  });

  testWidgets('点日本有码：m3u 资产出频道，行里无源名列', (tester) async {
    whosLibTestLibrary = libraryOf(5);
    // 高屏：首屏 60 行一次建出来，深行不用滚动才存在。
    await pumpUnlocked(tester, size: const Size(390, 3200));
    await pickWhosLib(tester);
    await openPicker(tester);
    await scrollPickerIntoView(
      tester,
      find.byKey(const ValueKey('site-picker-row-m3u_riben')),
    );
    await tester.tap(
      find.byKey(const ValueKey('site-picker-row-m3u_riben')),
    );
    // 4.4MB 资产加载 + 解析是普通 Future，假时钟推不动，
    // 先给真时间再轮询。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 8));
    });
    // 改口径（第 3 包三列网格）：格行高 54、列表区比旧频道列矮，
    // 3200 高屏首屏也一次建不出 60 行——改成拖动网格直到第 60
    // 行建出来，再拖回顶部验首行（断言本身不变）。
    final grid = find.byKey(const ValueKey('live-channel-list'));
    for (var i = 0; i < 16; i++) {
      if (find
          .byKey(const ValueKey('live-channel-59'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
      await tester.drag(grid, const Offset(0, -800));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('live-channel-59')), findsOneWidget);
    for (var i = 0; i < 16; i++) {
      if (find
          .byKey(const ValueKey('live-channel-0'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
      await tester.drag(grid, const Offset(0, 800));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('日本有码'), findsNothing);
    expect(rowTexts(tester, 'live-channel-0').length, 1);
    // 首行是 m3u 真数据（番号标题），不是旧源残留。
    expect(rowTexts(tester, 'live-channel-0').first, contains('CAWD-969'));
    await drainRetireTimer(tester);
  });

  testWidgets('内置片库手机尺寸滑到底续载：本地翻页 + 远端下一页', (tester) async {
    whosLibTestLibrary = libraryOf(130);
    await pumpUnlocked(tester);
    await pickWhosLib(tester);
    final list = find.byKey(const ValueKey('live-channel-list'));
    // 改口径（第 3 包三列网格）：续载触发点随列表迁到三列网格
    // ListView（key 不变），格行高 54 比旧频道行高，一次 -3000
    // 拖动滚过的行数变少——改成反复拖动直到目标行建出来
    // （断言本身不变：60 → 本地翻页、119 → 本地末尾、129 → 远端续页）。
    Future<void> dragUntil(Finder finder) async {
      // 步幅 500 小于列表构建窗口（视口 + 前后缓存约 18 行），
      // 大步幅会把目标行整段跳过去、永远建不出来。
      for (var i = 0; i < 30; i++) {
        if (finder.evaluate().isNotEmpty) return;
        await tester.drag(list, const Offset(0, -500));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // 滑到底翻本地第 2 页（120 条）：先等 60 号行建出来确认翻页。
    await dragUntil(find.byKey(const ValueKey('live-channel-60')));
    expect(
      await pumpUntil(
        tester,
        find.byKey(const ValueKey('live-channel-60')),
      ),
      true,
    );
    // 再滑到底见到 119 号行（本地 120 条的末尾）。
    await dragUntil(find.byKey(const ValueKey('live-channel-119')));
    expect(
      await pumpUntil(
        tester,
        find.byKey(const ValueKey('live-channel-119')),
      ),
      true,
    );
    // 再滑到底：本地表见底，远端续载第 2 页（130 条）。
    await dragUntil(find.byKey(const ValueKey('live-channel-129')));
    expect(
      await pumpUntil(
        tester,
        find.byKey(const ValueKey('live-channel-129')),
      ),
      true,
    );
    expect(find.text('SSIS-130 标题130'), findsOneWidget);
    await drainRetireTimer(tester);
  });

  testWidgets('四个公开名字都在，直播调用能编译', (tester) async {
    // 编译期已验：SourcePickerEntry / SourcePickerGroup /
    // showSitePickerDialog / SitePickerDialog 四个名字在本文件
    // 与 live_page.dart 里都被引用；这里再跑一遍弹窗冒烟。
    const entry = SourcePickerEntry(id: 'whos_lib', name: '内置片库');
    const group = SourcePickerGroup(title: '', entries: [entry]);
    expect(group.entries.first.id, 'whos_lib');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  await showSitePickerDialog(
                    context,
                    sectionName: '直播',
                    currentId: 'whos_lib',
                    groups: const [group],
                  );
                },
                child: const Text('开弹窗'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开弹窗'));
    expect(await pumpUntil(tester, find.text('切换直播源')), true);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SitePickerDialog &&
            widget.sectionName == '直播',
      ),
      findsOneWidget,
    );
  });
}
