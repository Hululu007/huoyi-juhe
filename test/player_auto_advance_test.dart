import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/services/player_menu_preferences.dart';
import 'package:fqapp/services/player_style_config.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/controlled_player.dart';
import 'support/fakes.dart';

/// 官方短剧恒连播（`aq3/a.java:338-356`：一集播完自动下一集，**最后一集
/// 播完=暂停**）。2026-11-27 播放器内嵌批按录屏口径新增「播放顺序」
/// （自动连播/单集循环/播完暂停，⋮ 统一菜单里改）：默认仍是自动
/// 连播；旧「自动连播」开关的存值迁移成初始播放顺序（关=播完暂停）。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 播放顺序偏好有进程内一次性闩：每条用例复位，让 loadAll 按
    // 本例的存值重新迁移。
    PlayerMenuPreferences.resetForTest();
    // 面板交互用例钉住深色分支（play_control_panel_style_v681.style=1）：
    // 药丸拖选/取消行是深色面板独有的交互，浅色分支另有用例覆盖。
    PlayerStyleConfig.instance = const PlayerStyleConfig(
      useNewPlayerBottomStyle: true,
      morePanelStyle: 1,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          (_) async => null,
        );
  });

  tearDown(() {
    PlayerStyleConfig.instance = PlayerStyleConfig.defaults;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          null,
        );
  });

  testWidgets('automatic next episode remains enabled by default', (
    tester,
  ) async {
    final session = _Session();
    await _mount(tester, session);
    final first = session.players.single;
    first.emitCompleted();
    first.emitCompleted();
    await _flush(tester);
    expect(_chrome(tester).currentIndex, 1);
    expect(session.players, hasLength(2));
    expect(
      session.players.last.calls.where((call) => call == 'play'),
      hasLength(1),
    );
    await _unmount(tester);
  });

  testWidgets('a stale saved stop-at-end becomes the initial play order', (
    tester,
  ) async {
    // 2026-11-27 内嵌批口径变更：旧「自动连播」开关的存值不再作废，
    // 而是迁移成新「播放顺序」的初始值（关 = 播完暂停）——现在有
    // 正式入口可改（⋮ 菜单的播放顺序行），不存在「卡死没入口」。
    SharedPreferences.setMockInitialValues({'player_auto_advance': false});
    PlayerMenuPreferences.resetForTest();
    final session = _Session();
    await _mount(tester, session);
    expect(
      PlayerMenuPreferences.playOrder.value,
      PlayOrderMode.stopAtEnd,
    );
    final first = session.players.single;
    first.emitCompleted();
    await _flush(tester);
    // 播完暂停：不进下一集、不建新播放器。
    expect(_chrome(tester).currentIndex, 0);
    expect(session.players, hasLength(1));
    await _unmount(tester);
  });

  testWidgets('the last episode pauses at the end instead of looping', (
    tester,
  ) async {
    final session = _Session();
    await _mount(tester, session);
    await _tapNext(tester);
    await _tapNext(tester);
    expect(_chrome(tester).currentIndex, 2);
    final last = session.players.last;
    await last.pause();
    last.emitCompleted();
    await _flush(tester);
    expect(_chrome(tester).currentIndex, 2);
    expect(session.players, hasLength(3));
    expect(session.store.entry?['position'], 120);
    expect(find.byTooltip('播放'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets(
    'the more menu offers the rate row and the play-order row',
    (tester) async {
      // 2026-11-27 内嵌批：⋮ 开统一菜单——倍速行与「播放顺序」行
      // （旧自动连播开关的继任者）都在；旧面板的行 key 不再出现。
      final session = _Session();
      await _mount(tester, session);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('embed-menu-play-order')),
        findsOneWidget,
      );
      expect(find.text('播放顺序'), findsOneWidget);
      final list = find.descendant(
        of: find.byKey(const ValueKey('player-embed-menu')),
        matching: find.byType(Scrollable),
      );
      for (var i = 0;
          i < 10 &&
              find
                  .byKey(const ValueKey('embed-menu-rate'))
                  .evaluate()
                  .isEmpty;
          i++) {
        await tester.drag(list, const Offset(0, -200));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const ValueKey('embed-menu-rate')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('player-more-rate-row')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('player-auto-advance')), findsNothing);
      await _unmount(tester);
    },
  );

  testWidgets('completion waits for an in-flight paging gesture to settle', (
    tester,
  ) async {
    final session = _Session();
    await _mount(tester, session);
    _chrome(tester).onPagingChanged!(true);
    session.players.single.emitCompleted();
    _chrome(tester).onPagingChanged!(false);
    await _flush(tester);
    expect(_chrome(tester).currentIndex, 1);
    expect(session.players, hasLength(2));
    await _unmount(tester);
  });

  testWidgets('play at the end of the last episode restarts it from zero', (
    tester,
  ) async {
    final session = _Session();
    await _mount(tester, session);
    await _tapNext(tester);
    await _tapNext(tester);
    final last = session.players.last;
    await last.pause();
    last.emitCompleted();
    await _flush(tester);
    last.calls.clear();
    await tester.tap(find.byTooltip('播放'));
    await _flush(tester);
    expect(last.calls, containsAllInOrder(['seek:0ms', 'play']));
    expect(last.position, Duration.zero);
    expect(session.players, hasLength(3));
    await _unmount(tester);
  });

  testWidgets(
    'backgrounding during a pending restart cannot start playback later',
    (tester) async {
      final session = _Session();
      await _mount(tester, session);
      await _tapNext(tester);
      await _tapNext(tester);
      final last = session.players.last;
      await last.pause();
      last.emitCompleted();
      await _flush(tester);
      final seek = Completer<void>();
      last.seekGate = seek;
      last.calls.clear();
      try {
        await tester.tap(find.byTooltip('播放'));
        await tester.pump();
        expect(last.calls, contains('seek:0ms'));
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        seek.complete();
        await _flush(tester);
        expect(last.calls, isNot(contains('play')));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _flush(tester);
        expect(last.calls, isNot(contains('play')));
      } finally {
        if (!seek.isCompleted) seek.complete();
        await _unmount(tester);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
    },
  );
}

VideoPlayerChrome _chrome(WidgetTester tester) =>
    tester.widget<VideoPlayerChrome>(find.byType(VideoPlayerChrome));

/// 切集后新播放器要等创建+首帧，`_ready` 才为真、运输条才挂载；直接 tap 会在
/// 加载窗口里找不到按钮。
Future<void> _tapNext(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    if (find.byTooltip('下一集').evaluate().isNotEmpty) break;
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.tap(find.byTooltip('下一集'));
  await _flush(tester);
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.pump();
}

Future<void> _mount(WidgetTester tester, _Session session) async {
  await tester.binding.setSurfaceSize(const Size(400, 800));
  addTearDown(() async {
    await _unmount(tester);
    await tester.binding.setSurfaceSize(null);
  });
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(session.app());
  await _flush(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _flush(tester);
}

class _Session {
  final players = <ControlledNativePlayer>[];
  final store = MemoryReaderStore();

  Widget app() => MaterialApp(
    home: PlayerPage(
      bookId: 'series-controls',
      title: '测试短剧',
      eps: List.generate(
        3,
        (index) => Chapter(
          itemId: '$index',
          title: '第 ${index + 1} 集',
          volumeName: '',
        ),
      ),
      startIndex: 0,
      historyStore: store,
      contentLoader: (episode) async => {
        'video_url': 'https://example.invalid/${episode.itemId}.mp4',
      },
      playerFactory: () {
        final player = ControlledNativePlayer();
        players.add(player);
        return player;
      },
    ),
  );
}
