import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/actress/actress_inline_player.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/series_detail/film_inline_player.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/controlled_player.dart';
import 'support/fakes.dart';

/// 「ExoPlayer 不能滑动快进」修复的断言集（2026-11-27）：
/// - 内嵌面（演员库/片库详情页内起播）此前没有横滑快进，进度条拖动
///   每动一下就 seek 一次、且被原生位置回声把拇指拽回旧位置；
/// - 修复口径与主播放页 chrome 一致：拖动只更新预览、松手 seek 一次；
/// - 点播（总时长已知）可拖；总时长未知（直播式）不许拖——两边分开断言。
Future<void> _until(
  WidgetTester tester,
  bool Function() condition, {
  int maxPumps = 80,
}) async {
  for (var i = 0; i < maxPumps && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue, reason: '条件未在限定帧内达成');
}

List<String> _seeksOf(List<String> calls) =>
    calls.where((c) => c.startsWith('seek:')).toList();

int _seekMs(String call) =>
    int.parse(call.substring(5, call.length - 2));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          (call) async => null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          null,
        );
  });

  group('演员库内嵌播放器', () {
    Future<ControlledNativePlayer> mountPlaying(
      WidgetTester tester, {
      bool withDuration = true,
    }) async {
      final player = ControlledNativePlayer();
      if (!withDuration) {
        // 假件默认总时长 2 分钟且播放器起播时会先读一次，光不发
        // duration 事件不算「未知」；把假件总时长钉成 0 才真实。
        player.totalDuration = Duration.zero;
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ActressInlinePlayer(
              url: 'https://v.test/a.m3u8',
              playerFactory: () => player,
            ),
          ),
        ),
      );
      await _until(tester, () => player.calls.contains('created'));
      player.emitFirstFrame();
      // 必须补发缓冲结束：假件不发的话播放器一直停在「缓冲中」，
      // 缓冲转圈层（Stack 里在手势层之上、命中即吸收）会把画面
      // 手势全挡住——真机上原生起播后会发这个事件。
      player.emitBuffering(false);
      if (withDuration) {
        player.emitDuration(const Duration(seconds: 120));
      }
      player.emitPosition(const Duration(seconds: 10));
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('inline-player-seek'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.pump();
      return player;
    }

    testWidgets('拖进度条：途中不发 seek、回声不拽回、松手只 seek 一次到目标', (
      tester,
    ) async {
      final player = await mountPlaying(tester);
      final slider = find.byKey(const ValueKey('inline-player-seek'));
      final rect = tester.getRect(slider);
      final gesture = await tester.startGesture(
        Offset(rect.left + rect.width * 0.1, rect.center.dy),
      );
      await gesture.moveTo(
        Offset(rect.left + rect.width * 0.4, rect.center.dy),
      );
      await tester.pump();
      // 拖动途中：不许发 seek。
      expect(_seeksOf(player.calls), isEmpty);
      // 原生位置回声（seek 落地前的旧位置）到达：显示不许被拽回 00:10，
      // 应停在手指对应的预览时间（40% ≈ 48 秒，滑杆轨道有内边距，
      // 按 40–55 秒的宽口径断言）。
      player.emitPosition(const Duration(seconds: 10));
      await tester.pump();
      expect(find.text('00:10'), findsNothing);
      final shownTexts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();
      expect(
        shownTexts.any((s) => RegExp(r'^00:(4\d|5[0-5])$').hasMatch(s)),
        isTrue,
        reason: '当前时间应显示拖动预览（约 00:48），实际文本：$shownTexts',
      );
      await gesture.moveTo(
        Offset(rect.left + rect.width * 0.75, rect.center.dy),
      );
      await tester.pump();
      expect(_seeksOf(player.calls), isEmpty);
      await gesture.up();
      await tester.pump();
      // 松手：恰好一次 seek，落在 75% 附近（120 秒 → 约 90 秒）。
      final seeks = _seeksOf(player.calls);
      expect(seeks, hasLength(1));
      expect(_seekMs(seeks.single), inInclusiveRange(85000, 95000));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('横滑画面快进：松手 seek 一次到目标；竖向主导滑动不触发', (
      tester,
    ) async {
      final player = await mountPlaying(tester);
      final surface = find.byType(ActressInlinePlayer);
      final center = tester.getCenter(surface);
      // 横滑到画面 3/4 处（多步移动：真实拖动是一串 move 事件，
      // 单次大跳只够触发 dragStart、没有 update，预览不会动）。
      final swipe = await tester.startGesture(center);
      for (var i = 0; i < 5; i++) {
        await swipe.moveBy(const Offset(44, 1));
        await tester.pump();
      }
      expect(_seeksOf(player.calls), isEmpty);
      await swipe.up();
      await tester.pump();
      var seeks = _seeksOf(player.calls);
      expect(seeks, hasLength(1));
      // 起点在画面中点、终点约 74% 宽 → 目标约 89 秒。
      expect(_seekMs(seeks.single), inInclusiveRange(80000, 100000));
      // 竖向主导的滑动（划详情页）不许误触快进。
      player.calls.clear();
      final vertical = await tester.startGesture(center);
      for (var i = 0; i < 5; i++) {
        await vertical.moveBy(const Offset(1, -40));
        await tester.pump();
      }
      await vertical.up();
      await tester.pump();
      seeks = _seeksOf(player.calls);
      expect(seeks, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('总时长未知：进度条禁用、横滑不发 seek（直播式口径）', (
      tester,
    ) async {
      final player = await mountPlaying(tester, withDuration: false);
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('inline-player-seek')),
      );
      expect(slider.onChanged, isNull);
      final surface = find.byType(ActressInlinePlayer);
      final center = tester.getCenter(surface);
      final swipe = await tester.startGesture(center);
      await swipe.moveTo(Offset(center.dx + 220, center.dy));
      await tester.pump();
      await swipe.up();
      await tester.pump();
      expect(_seeksOf(player.calls), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('片库内嵌播放器', () {
    Future<ControlledNativePlayer> mountPlaying(WidgetTester tester) async {
      final player = ControlledNativePlayer();
      final key = GlobalKey<FilmInlinePlayerState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilmInlinePlayer(
              key: key,
              seriesId: 'series-1',
              title: '样本',
              coverUrl: '',
              episodes: [
                Chapter(itemId: 'ep-1', title: '第一集', volumeName: ''),
              ],
              episodeIndex: 0,
              contentLoader: (id, tab) async => {
                'video_url': 'https://v.test/a.m3u8',
                'key_hex': '',
              },
              playerFactory: () => player,
            ),
          ),
        ),
      );
      await key.currentState!.playEpisode(0);
      await _until(tester, () => player.calls.contains('created'));
      player.emitFirstFrame();
      player.emitBuffering(false);
      player.emitDuration(const Duration(seconds: 120));
      player.emitPosition(const Duration(seconds: 10));
      await _until(tester, () => find.byType(Slider).evaluate().isNotEmpty);
      await tester.pump();
      return player;
    }

    // 拖进度条与横滑合并在一条用例里：FilmInlinePlayer 起播前要读
    // 本地历史（真异步落盘），同一进程里第二次起播会卡在 FakeAsync
    // 里回不来（仓库既有环境特性），所以只挂载一次、两段都验。
    testWidgets('拖进度条与横滑快进：都只在松手 seek 一次到目标', (tester) async {
      final player = await mountPlaying(tester);
      // —— 拖进度条 ——
      final rect = tester.getRect(find.byType(Slider));
      final gesture = await tester.startGesture(
        Offset(rect.left + rect.width * 0.1, rect.center.dy),
      );
      await gesture.moveTo(
        Offset(rect.left + rect.width * 0.5, rect.center.dy),
      );
      await tester.pump();
      expect(_seeksOf(player.calls), isEmpty);
      // 位置回声到达：滑杆值不许被拽回旧位置（10/120≈0.083 → 10 秒位）。
      player.emitPosition(const Duration(seconds: 10));
      await tester.pump();
      final during = tester.widget<Slider>(find.byType(Slider));
      expect(during.value, greaterThan(40000));
      await gesture.up();
      await tester.pump();
      var seeks = _seeksOf(player.calls);
      expect(seeks, hasLength(1));
      expect(_seekMs(seeks.single), inInclusiveRange(50000, 70000));
      // —— 横滑画面 ——
      player.calls.clear();
      final surface = find.byKey(const ValueKey('film-inline-player'));
      final sRect = tester.getRect(surface);
      final start = Offset(sRect.left + sRect.width * 0.2, sRect.center.dy);
      final swipe = await tester.startGesture(start);
      // 多步移动到 80% 宽（单次大跳只有 dragStart、没有 update）。
      for (var i = 0; i < 6; i++) {
        await swipe.moveBy(Offset(sRect.width * 0.1, 0));
        await tester.pump();
      }
      expect(_seeksOf(player.calls), isEmpty);
      await swipe.up();
      await tester.pump();
      seeks = _seeksOf(player.calls);
      expect(seeks, hasLength(1));
      expect(_seekMs(seeks.single), inInclusiveRange(85000, 105000));
      await tester.pumpWidget(const SizedBox.shrink());
      // 放掉 seek 后挂起的历史保存定时器，避免收尾不变量误报。
      await tester.pump(const Duration(minutes: 1));
    });
  });

  group('主播放页口径：点播可拖 / 总时长未知不可拖', () {
    Future<FakeNativePlayer> mountChrome(
      WidgetTester tester, {
      required Duration total,
    }) async {
      final player = FakeNativePlayer(totalDuration: total)
        ..currentPosition = const Duration(seconds: 10);
      await tester.pumpWidget(
        MaterialApp(
          home: VideoPlayerChrome(
            player: player,
            title: '样本',
            episodes: [
              Chapter(itemId: '1', title: '第一集', volumeName: ''),
            ],
            currentIndex: 0,
            duration: total,
            playing: true,
            onSelectEpisode: (_) async {},
            onError: (_) {},
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return player;
    }

    testWidgets('点播（时长已知）：横滑画面能 seek', (tester) async {
      tester.view.physicalSize = const Size(400, 888);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final player = await mountChrome(
        tester,
        total: const Duration(seconds: 120),
      );
      await tester.drag(
        find.byKey(const ValueKey('video-surface')),
        const Offset(120, 0),
      );
      await tester.pumpAndSettle();
      expect(
        player.calls.where((c) => c.startsWith('seek:')),
        isNotEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    });

    testWidgets('总时长未知（直播式）：横滑与进度条都不发 seek', (tester) async {
      tester.view.physicalSize = const Size(400, 888);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final player = await mountChrome(tester, total: Duration.zero);
      await tester.drag(
        find.byKey(const ValueKey('video-surface')),
        const Offset(120, 0),
      );
      await tester.pumpAndSettle();
      final bar = find.byKey(const ValueKey('video-seek'));
      if (bar.evaluate().isNotEmpty) {
        await tester.drag(bar, const Offset(120, 0));
        await tester.pumpAndSettle();
      }
      expect(player.calls.where((c) => c.startsWith('seek:')), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    });
  });
}
