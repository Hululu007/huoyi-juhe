// 全屏回程修复（用户 2026-11-27 20:14 实报）：详情页内嵌播放 →
// 全屏 → 退出，期望回详情页内嵌舞台续播；实到落进竖屏整页播放态。
// 根因：借来的全屏页退出全屏时 chrome 只把内部 _fullScreen 置
// false、不退栈，整页就以竖屏整页形态留下来。
// 修法：PlayerPage/VideoPlayerChrome 加 popOnFullscreenExit——
// 详情页交接的全屏页退出全屏 = 直接退页；普通整页播放不带此
// 标记、行为不变。本文件验 chrome 层机制（借来的退页/普通的不
// 退）与片库详情页的接线（标记真传到 PlayerPage、退页后回到
// 详情页内嵌舞台）；演员库端的整页往返在 actress_fullscreen_test
// 里另有一条经「退出全屏」钮的用例。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/fakes.dart';
import 'support/series_detail_fixtures.dart';

Widget _borrowedHost(FakeNativePlayer player, {required bool borrowed}) {
  return MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    body: VideoPlayerChrome(
                      player: player,
                      episodes: [
                        Chapter(itemId: '1', title: '第1集', volumeName: ''),
                      ],
                      currentIndex: 0,
                      duration: const Duration(minutes: 2),
                      playing: true,
                      onSelectEpisode: (_) async {},
                      onError: (_) {},
                      openFullScreen: true,
                      popOnFullscreenExit: borrowed,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              );
            },
            child: const Text('go'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('借来的全屏页：点退出全屏直接退页回宿主', (tester) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(_borrowedHost(player, borrowed: true));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('退出全屏'), findsOneWidget);
    await tester.tap(find.byTooltip('退出全屏'));
    await tester.pumpAndSettle();
    // 回到宿主页：整页播放器与它的控制层都不在了。
    expect(find.text('go'), findsOneWidget);
    expect(find.byType(VideoPlayerChrome), findsNothing);
    await player.dispose();
  });

  testWidgets('普通整页：退出全屏留在页内（既有语义不变）', (tester) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(_borrowedHost(player, borrowed: false));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('退出全屏'));
    await tester.pumpAndSettle();
    expect(find.byType(VideoPlayerChrome), findsOneWidget);
    expect(find.byTooltip('全屏'), findsOneWidget);
    expect(find.text('go'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  group('片库详情页接线', () {
    late Directory directory;
    setUpAll(() async {
      directory = await Directory.systemTemp.createTemp(
        'fullscreen-return-test-',
      );
      Hive.init(directory.path);
      await ShelfStore.instance.init();
    });
    tearDownAll(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });
    setUp(() async => ShelfStore.instance.clear());

    testWidgets('内嵌全屏交接：PlayerPage 带双标记，退页后回详情页舞台', (
      tester,
    ) async {
      final chapters = [chapterAt(0), chapterAt(1)];
      await tester.pumpWidget(
        hostPage(
          SeriesDetailPage(
            seriesId: 'film-1',
            historyStore: MemoryReaderStore(),
            title: '抽象三国第一季',
            cover: '',
            episodes: chapters,
            seriesLoader: (_) async => seriesDetailFixture(
              episodeCount: chapters.length,
              episodeLabel: '共2集',
            ),
            siteDetailLoader: (_) async => const FilmSiteDetail(
              synopsis: '这是一段影视简介。',
              extra: {'play_from': 'MissAV'},
              stills: [],
            ),
            commentLoader: (_) async => const PlayletCommentPage(),
            contentLoader: (_, _) async =>
                throw Exception('test-no-stream'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('film-inline-player')),
        findsOneWidget,
      );

      // 内嵌顶栏全屏钮 → 交接推整页：双标记必须都在。
      await tester.tap(
        find.byKey(const ValueKey('film-inline-fullscreen-top')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
      expect(page.openFullScreen, isTrue);
      expect(page.popOnFullscreenExit, isTrue);

      // 整页退回来（退出全屏在真机上走同一条 pop 路）：回到详情页，
      // 内嵌舞台（16:9 黑色区）还在原位。
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      // 真 PlayerPage 起过一台真 NativePlayer，它的保亮一次性
      // 定时器（10 秒）要在测试结束前烧完，免得拆台报挂起。
      await tester.pump(const Duration(seconds: 11));
      expect(find.byType(PlayerPage), findsNothing);
      final stage = find.byKey(const ValueKey('film-inline-player'));
      expect(stage, findsOneWidget);
      final size = tester.getSize(stage);
      expect(size.width / size.height, closeTo(16 / 9, 0.05));
    });
  });
}
