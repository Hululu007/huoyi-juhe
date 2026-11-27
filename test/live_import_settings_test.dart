import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/live_page.dart';
import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/live_platform.dart';
import 'package:fqapp/services/live_settings.dart';
import 'package:fqapp/services/live_sleep_timer.dart';
import 'package:fqapp/services/live_sources.dart';
import 'package:fqapp/services/live_subscriptions.dart';
import 'package:fqapp/services/platform_channel.dart';
import 'package:fqapp/services/player_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 直播第 4 包（导入 + 设置接线）验证：
/// ① 多槽订阅机件：本地内容导入落盘、远程导入（拉取注入桩）、
///   失败按原因报错、删除落盘同步、远程刷新重拉；
/// ② 老单槽导入迁移成一条订阅、频道不丢；
/// ③ 直播页：左下「+」本地导入成订阅源并自动切源、导入失败
///   显示原因、选源弹窗「导入源」组出现订阅源且长按删除；
/// ④ 直播设置：睡眠默认落盘且直播侧读得到（applyLiveSleepDefault
///   起算）；2026-11-27 起设置页直播分类已摘除，睡眠默认改在
///   直播睡眠定时弹窗的「默认时长」行里改。
const _m3uA = '#EXTM3U\n'
    '#EXTINF:-1 group-title="新闻",导入频道甲\n'
    'https://example.com/a.m3u8\n'
    '#EXTINF:-1 group-title="新闻",导入频道乙\n'
    'https://example.com/b.m3u8\n';

const _txtA = '新闻,#genre#\n'
    '文本频道甲,https://example.com/t1.m3u8\n'
    '文本频道乙,https://example.com/t2.m3u8\n';

void main() {
  late StreamController<dynamic> playerEvents;
  var nextPlayerId = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    LiveSubscriptionStore.instance.resetForTest();
    LiveSettingsStore.instance.resetForTest();
    LiveSleepTimer.instance.cancel();
    liveLocalFilePickerForTest = null;
    await CultivationService.instance.resetForTest();
    await CultivationService.instance.ensureInitialized();
    playerEvents = StreamController<dynamic>.broadcast();
    PlatformChannels.invoke = (channel, method, args) async {
      if (method == 'create') {
        final id = ++nextPlayerId;
        scheduleMicrotask(() {
          playerEvents.add({'playerId': id, 'type': 'created', 'value': 1});
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
    livePlatformsFetcherForTest = (_) async => const [
      LivePlatform(id: 'p1', name: '测试分组', count: 1),
    ];
    liveChannelsFetcherForTest = (_, _) async => [
      LiveChannel(title: '默认源频道', url: 'https://example.com/d.m3u8'),
    ];
  });

  tearDown(() async {
    livePlatformsFetcherForTest = null;
    liveChannelsFetcherForTest = null;
    liveLocalFilePickerForTest = null;
    LiveSubscriptionStore.instance.resetForTest();
    LiveSettingsStore.instance.resetForTest();
    LiveSleepTimer.instance.cancel();
    await playerEvents.close();
    PlatformChannels.invoke = null;
    PlatformChannels.events = null;
    await CultivationService.instance.resetForTest();
  });

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

  Future<void> pumpUnlocked(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: LivePage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    CultivationService.instance.snapshotNotifier.value =
        const CultivationSnapshot(
          seconds: {CultivationCategory.novel: 6000.0},
        );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// 与 live_info_grid 同款收尾：卸掉页面并推 31 秒假时间，
  /// 排掉播放器退役计时器，免得框架报 pending timer。
  Future<void> drainRetireTimer(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 31));
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

  group('订阅机件', () {
    test('本地 m3u 内容导入成订阅源并落盘，txt 按行式解析', () async {
      final store = LiveSubscriptionStore.instance;
      final sub = await store.addLocal(
        name: '本地甲',
        content: _m3uA,
        fileName: 'a.m3u',
      );
      expect(sub.sourceId, startsWith('m3u:'));
      expect(sub.channelCount, 2);
      final channels = store.channelsFor(sub);
      expect(channels.map((c) => c.title), ['导入频道甲', '导入频道乙']);
      expect(channels.first.sourceId, sub.sourceId);

      final txt = await store.addLocal(
        name: '本地乙',
        content: _txtA,
        fileName: 'b.txt',
      );
      expect(store.channelsFor(txt).map((c) => c.title), [
        '文本频道甲',
        '文本频道乙',
      ]);

      // 落盘：重置内存后重新读盘，两条都还在。
      store.resetForTest();
      final reloaded = await store.load();
      expect(reloaded.map((s) => s.name), ['本地甲', '本地乙']);
    });

    test('远程导入走拉取、命名取主机名、刷新重拉更新快照', () async {
      final store = LiveSubscriptionStore.instance;
      var served = _m3uA;
      LiveSubscriptionStore.fetchTextForTest = (_) async => served;
      final sub = await store.addRemote('https://example.com/list.m3u');
      expect(sub.isUrl, isTrue);
      expect(sub.name, 'example.com');
      expect(sub.channelCount, 2);

      served = '#EXTM3U\n'
          '#EXTINF:-1,刷新后频道\n'
          'https://example.com/c.m3u8\n';
      final updated = await store.refreshRemote(sub);
      expect(updated.channelCount, 1);
      expect(store.channelsFor(updated).single.title, '刷新后频道');
    });

    test('导入失败按原因报错：空内容 / 不是播放列表 / 拉不到 / 地址无效', () async {
      final store = LiveSubscriptionStore.instance;
      await expectLater(
        store.addLocal(name: '空', content: '   ', fileName: 'x.m3u'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('内容为空'),
          ),
        ),
      );
      await expectLater(
        store.addLocal(name: '垃圾', content: 'hello world', fileName: 'x.m3u'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('未解析到任何频道'),
          ),
        ),
      );
      LiveSubscriptionStore.fetchTextForTest = (_) async =>
          throw StateError('订阅拉取失败：HTTP 404');
      await expectLater(
        store.addRemote('https://example.com/dead.m3u'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('订阅拉取失败'),
          ),
        ),
      );
      await expectLater(
        store.addRemote('ftp://example.com/x.m3u'),
        throwsA(isA<StateError>()),
      );
      // 失败不落盘：一条订阅都没有。
      expect(store.items, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('juhe_live_subscriptions'), isNull);
    });

    test('删除订阅后落盘同步删', () async {
      final store = LiveSubscriptionStore.instance;
      final sub = await store.addLocal(
        name: '待删',
        content: _m3uA,
        fileName: 'a.m3u',
      );
      await store.remove(sub.id);
      expect(store.items, isEmpty);
      store.resetForTest();
      expect(await store.load(), isEmpty);
    });

    test('老单槽导入迁移成一条订阅，频道不丢、旧键清掉', () async {
      final legacyChannels = [
        LiveChannel(
          title: '老频道甲',
          url: 'https://example.com/old1.m3u8',
          group: '老组',
        ).toJson(),
        LiveChannel(
          title: '老频道乙',
          url: 'https://example.com/old2.m3u8',
          group: '老组',
        ).toJson(),
      ];
      SharedPreferences.setMockInitialValues({
        'juhe_live_m3u_channels': jsonEncode(legacyChannels),
        'juhe_live_m3u_url': 'https://example.com/old.m3u',
      });
      final store = LiveSubscriptionStore.instance;
      final subs = await store.load();
      expect(subs, hasLength(1));
      final sub = subs.single;
      expect(sub.isUrl, isTrue);
      expect(sub.url, 'https://example.com/old.m3u');
      final channels = store.channelsFor(sub);
      expect(channels.map((c) => c.title), ['老频道甲', '老频道乙']);
      expect(channels.first.sourceId, sub.sourceId);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('juhe_live_m3u_channels'), isNull);
      expect(prefs.getString('juhe_live_m3u_url'), isNull);
      // 迁移结果已落盘：重置后读回仍是一条。
      store.resetForTest();
      expect(await store.load(), hasLength(1));
    });
  });

  group('直播页接线', () {
    testWidgets('左下+本地导入成订阅源并自动切源', (tester) async {
      liveLocalFilePickerForTest = () async =>
          (name: '我的源.m3u', content: _m3uA);
      await pumpUnlocked(tester);
      expect(
        find.byKey(const ValueKey('live-import-add')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('live-import-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('live-import-local')));
      expect(await pumpUntil(tester, find.text('导入频道甲')), isTrue);
      expect(find.text('导入频道乙'), findsOneWidget);
      final subs = LiveSubscriptionStore.instance.items;
      expect(subs, hasLength(1));
      expect(subs.single.name, '我的源');
      await drainRetireTimer(tester);
    });

    testWidgets('左下+远程导入（拉取桩）自动切源', (tester) async {
      LiveSubscriptionStore.fetchTextForTest = (_) async => _m3uA;
      await pumpUnlocked(tester);
      await tester.tap(find.byKey(const ValueKey('live-import-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('live-import-remote')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'https://example.com/list.m3u',
      );
      await tester.tap(find.text('导入'));
      expect(await pumpUntil(tester, find.text('导入频道甲')), isTrue);
      expect(LiveSubscriptionStore.instance.items.single.isUrl, isTrue);
      await drainRetireTimer(tester);
    });

    testWidgets('本地导入失败按原因显示报错，不装成功', (tester) async {
      liveLocalFilePickerForTest = () async =>
          (name: '坏文件.m3u', content: '这不是播放列表');
      await pumpUnlocked(tester);
      await tester.tap(find.byKey(const ValueKey('live-import-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('live-import-local')));
      expect(
        await pumpUntil(tester, find.textContaining('未解析到任何频道')),
        isTrue,
      );
      expect(LiveSubscriptionStore.instance.items, isEmpty);
      await drainRetireTimer(tester);
    });

    testWidgets('弹窗导入组出现订阅源，长按删除后落盘同步删', (tester) async {
      final store = LiveSubscriptionStore.instance;
      final sub = await store.addLocal(
        name: '弹窗订阅',
        content: _m3uA,
        fileName: 'a.m3u',
      );
      await pumpUnlocked(tester);
      await tester.tap(find.byTooltip('切换直播源'));
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey('site-picker-row-${sub.sourceId}'));
      await scrollPickerIntoView(tester, row);
      await tester.pumpAndSettle();
      expect(find.text('导入源 1'), findsOneWidget);
      expect(find.text('弹窗订阅'), findsOneWidget);
      await tester.longPress(row);
      await tester.pumpAndSettle();
      expect(find.text('弹窗订阅'), findsNothing);
      expect(store.items, isEmpty);
      store.resetForTest();
      expect(await store.load(), isEmpty);
      await drainRetireTimer(tester);
    });

    testWidgets('删当前订阅源回落默认源', (tester) async {
      liveLocalFilePickerForTest = () async =>
          (name: '当前源.m3u', content: _m3uA);
      await pumpUnlocked(tester);
      await tester.tap(find.byKey(const ValueKey('live-import-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('live-import-local')));
      expect(await pumpUntil(tester, find.text('导入频道甲')), isTrue);
      final sub = LiveSubscriptionStore.instance.items.single;
      await tester.tap(find.byTooltip('切换直播源'));
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey('site-picker-row-${sub.sourceId}'));
      await scrollPickerIntoView(tester, row);
      await tester.pumpAndSettle();
      await tester.longPress(row);
      await tester.pumpAndSettle();
      // 弹窗关掉后页面已回落默认源（测试桩频道）。
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(await pumpUntil(tester, find.text('默认源频道')), isTrue);
      await drainRetireTimer(tester);
    });
  });

  group('直播设置', () {
    test('睡眠默认落盘，直播侧 applyLiveSleepDefault 读得到并起算', () async {
      final store = LiveSettingsStore.instance;
      await store.setSleepDefaultMinutes(30);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('juhe_live_sleep_minutes'), 30);
      store.resetForTest();
      await store.load();
      expect(store.sleepDefaultMinutes, 30);

      expect(LiveSleepTimer.instance.active, isFalse);
      await applyLiveSleepDefault();
      expect(LiveSleepTimer.instance.active, isTrue);
      LiveSleepTimer.instance.cancel();

      await store.resetDefaults();
      expect(store.sleepDefaultMinutes, 0);
      await applyLiveSleepDefault();
      expect(LiveSleepTimer.instance.active, isFalse);
    });

    // 2026-11-27 播放器内嵌批：设置页「直播设置」整类按用户令
    // 摘除——解码进播放器菜单、恢复默认随类撤销；睡眠默认迁进
    // 直播睡眠定时弹窗的「默认时长」行（同一支偏好、值不丢）。
    testWidgets('设置页不再有直播设置分类', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pumpAndSettle();
      expect(find.text('直播设置'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('睡眠默认新家：直播定时弹窗里改默认时长并落盘', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      await LiveSettingsStore.instance.setSleepDefaultMinutes(15);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showLiveSleepTimerDialog(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // 弹窗里有「默认时长」行，行尾是当前默认（15 分钟；与定时
      // 选项行同名文案并存，故限定在该行内找）。
      expect(find.text('默认时长'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('live-sleep-default')),
          matching: find.text('15 分钟'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('live-sleep-default')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('live-sleep-default-30')),
      );
      await tester.pumpAndSettle();
      expect(LiveSettingsStore.instance.sleepDefaultMinutes, 30);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('juhe_live_sleep_minutes'), 30);
    });
  });
}
