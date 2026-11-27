import 'dart:async';
import 'dart:io';

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

/// 站点库批（2026-11-27）适配：直播 26 源（3 平台＋23 清单）已改由站点库
/// 供数（LiveSources.sqlSources），未导入时 builtin 只剩原生 2 源。
/// 本文件验的是「导入后」的完整源表行为，故在 setUp 注入与生产站点库
/// 等值的 26 源夹具（id/名/协议与生成器 ACCOUNT 对账一致），tearDown 清空。
void injectSqlLiveFixture() {
  LiveSources.sqlSources = <LiveSource>[
    const LiveSource(
      id: 'xiuguo',
      name: '秀果',
      description: '主播直播 · 实时开播',
      protocol: LiveProtocol.pingtai,
      endpoints: ['http://api.vipmisss.com:81/xcdsw', 'http://api.hclyz.com:81/mf'],
      adult: true,
    ),
    const LiveSource(
      id: 'maiyoux',
      name: '欲火聚合',
      description: '欲火移植 · 平台动态聚合 · 实时开播',
      protocol: LiveProtocol.pingtai,
      endpoints: ['http://api.maiyoux.com:81/mf', 'http://api.vipmisss.com:81/xcdsw'],
      adult: true,
    ),
    const LiveSource(
      id: 'bnzb',
      name: '百年直播',
      description: '百年直播 · 多平台聚合 · 实时开播',
      protocol: LiveProtocol.pingtai,
      endpoints: ['http://api.vipmisss.com:81/xcdsw'],
      adult: true,
    ),
    for (final e in <String, String>{
      'user_m3u': '成人点播',
      'm3u_zhubo': '主播网红',
      'm3u_luanlun': '乱伦精品',
      'm3u_huayu': '华语精品',
      'm3u_guochan': '国产精品',
      'm3u_xuesheng': '学生合集',
      'm3u_tanhua': '探花约炮',
      'm3u_riben': '日本有码',
      'm3u_oumei': '欧美大屌',
      'm3u_heilian': '黑料吃瓜',
      'm3u_community10': '社区合集10',
      'm3u_community11': '社区合集11',
      'm3u_wuma': '無碼專區',
      'm3u_wanghong': '網紅頭條',
      'm3u_xingba': '杏吧原創',
      'm3u_chengtou': '成人頭條',
      'm3u_zhifu': '制服絲襪',
      'm3u_qunjiao': '群交淫亂',
      'm3u_mingxing': '明星換臉',
      'm3u_zipai': '自拍偷拍',
      'm3u_avxiongdi': 'AV兄弟无码',
      'm3u_guochanse': '国产色情',
      'm3u_riben2': '日本有码2',
    }.entries)
      LiveSource(
        id: e.key,
        name: e.value,
        description: '',
        protocol: LiveProtocol.list,
        endpoints: ['sql://${e.key}'],
        adult: true,
      ),
  ];
}

void main() {
  late StreamController<dynamic> playerEvents;
  var nextPlayerId = 0;

  setUp(() async {
    injectSqlLiveFixture();
    // 「点日本有码」用例要真加载播放列表：生产端点是站点库落盘后的
    // 本地文件路径，测试里现写一份 65 频道的同格式 m3u 顶替。
    final m3uDir = await Directory.systemTemp.createTemp('live_fixture');
    final m3uFile = File('${m3uDir.path}/riben.m3u');
    final buf = StringBuffer('#EXTM3U\n');
    for (var i = 1; i <= 65; i++) {
      buf.writeln('#EXTINF:-1 group-title="日本有码",频道$i');
      buf.writeln('http://example.test/riben/$i.m3u8');
    }
    await m3uFile.writeAsString(buf.toString());
    LiveSources.sqlSources = [
      for (final src in LiveSources.sqlSources)
        if (src.id == 'm3u_riben')
          LiveSource(
            id: src.id,
            name: src.name,
            description: src.description,
            protocol: src.protocol,
            endpoints: [m3uFile.path],
            adult: src.adult,
          )
        else
          src,
    ];
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
    LiveSources.sqlSources = <LiveSource>[];
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

  // 站点库批（2026-11-27）适配：日本有码的播放列表已不随包（资产
  // 删除），生产端点是站点库导入后落盘的本地文件。widget 测试的
  // FakeAsync 区里 dart:io 文件读永远不完成（AGENTS 既有教训），
  // 页面级「出频道」断言在本环境无从验起，改为：切源动作与加载态
  // 在此验，文件加载＋解析全链由下方普通 test 在真实时钟区验。
  testWidgets('点日本有码：切源成功、进入加载态（文件链见普通用例）', (tester) async {
    whosLibTestLibrary = libraryOf(5);
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 弹窗已关、页面已切源：旧源（内置片库）的频道列表消失，
    // 新源（本地文件 m3u）进入加载态（转圈）——文件读在 FakeAsync
    // 区不完成，加载态就是本环境能验到的最远状态。
    expect(find.byKey(const ValueKey('site-picker-row-m3u_riben')),
        findsNothing);
    expect(find.byKey(const ValueKey('live-channel-list')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    await drainRetireTimer(tester);
  });

  test('本地文件 m3u 加载＋解析全链（站点库落盘端点形态）', () async {
    final dir = Directory.systemTemp.createTempSync('live_file_chain');
    final file = File('${dir.path}/riben.m3u');
    final buf = StringBuffer('#EXTM3U x-tvg-url=""\n');
    buf.writeln(
        '#EXTINF:-1 tvg-id="" tvg-name="CAWD-969 探针" group-title="日本有码",CAWD-969 探针');
    buf.writeln('http://example.test/riben/1.m3u8');
    for (var i = 2; i <= 65; i++) {
      buf.writeln('#EXTINF:-1 group-title="日本有码",频道$i');
      buf.writeln('http://example.test/riben/$i.m3u8');
    }
    file.writeAsStringSync(buf.toString());
    const source = LiveSource(
      id: 'm3u_riben',
      name: '日本有码',
      description: '',
      protocol: LiveProtocol.list,
      endpoints: [],
      adult: true,
    );
    final local = LiveSource(
      id: source.id,
      name: source.name,
      description: '',
      protocol: LiveProtocol.list,
      endpoints: [file.path],
      adult: true,
    );
    final channels = await LiveSources.loadBuiltinListChannels(local);
    expect(channels.length, 65);
    expect(channels.first.title, contains('CAWD-969'));
    expect(channels.first.group, '日本有码');
    expect(channels.first.url, 'http://example.test/riben/1.m3u8');
    expect(channels.every((c) => c.sourceId == 'm3u_riben'), isTrue);
    dir.deleteSync(recursive: true);
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
