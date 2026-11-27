// 播放器内嵌批预览（2026-11-27）：顶栏/底栏（竖屏+横屏）、
// 更多菜单、弹幕设置、播放信息弹窗五张。视频区是占位色块
// （测试环境没有真解码），控制层与菜单都是真控件真状态。
// 输出目录走 preview_test_support 的 previewOutPath（可用
// MOYI_PREVIEW_OUT_DIR 覆盖）。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/episode_source_cache.dart';
import 'package:fqapp/services/native_player.dart';
import 'package:fqapp/services/playback_fallback.dart';
import 'package:fqapp/services/player_layout_preferences.dart';
import 'package:fqapp/services/player_menu_preferences.dart';
import 'package:fqapp/services/player_preferences.dart';
import 'package:fqapp/services/player_sleep_timer.dart';
import 'package:fqapp/widgets/player/playlet_danmaku_settings.dart';
import 'package:fqapp/widgets/player/player_embed_menu.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'preview_test_support.dart';
import 'support/fakes.dart';

PlayerEmbedPageActions _actions() {
  return PlayerEmbedPageActions(
    seriesTitle: '示例剧场',
    episodeLabel: '第3集',
    sourceLabel: '站点A',
    source: const EpisodeSource(
      'https://cdn.test/play.m3u8?token=1',
      '',
      [],
      null,
      [],
      {'Referer': 'https://site.test/'},
      'https://site.test/watch/123',
    ),
    sleepTimer: PlayerSleepTimer(),
    introSkipSeconds: 90,
    outroSkipSeconds: 45,
    onSkipSettingsChanged: (_, _) {},
    onReload: () {},
    decoder: VideoDecoderPreference.hardware,
    onDecoderChanged: (_) async {},
    backgroundPlay: false,
    onBackgroundPlayChanged: (_) {},
    mutedDefault: false,
    onMutedDefaultChanged: (_) {},
    adBlockEnabled: true,
    onAdBlockChanged: (_) {},
    fallbackMode: PlaybackFallbackMode.all,
    onFallbackModeChanged: (_) {},
    layoutMode: PlayerLayoutMode.immersive,
    onLayoutModeChanged: (_) {},
    episodeIndex: 2,
    episodeCount: 12,
    onLoadDanmakuUrl: () {},
    onLoadDanmakuFile: () {},
  );
}

PlayerInfoData _info() {
  return const PlayerInfoData(
    seriesTitle: '示例剧场',
    episodeLabel: '第3集',
    sourceLabel: '站点A',
    sourceUrl: 'https://cdn.test/play.m3u8?token=1',
    decoderPrefLabel: '硬解',
    position: Duration(minutes: 6, seconds: 12),
    duration: Duration(minutes: 24, seconds: 30),
    rate: 1,
    episodeIndex: 2,
    episodeCount: 12,
    native: PlayerPlaybackInfo(
      videoWidth: 1920,
      videoHeight: 1080,
      videoMimeType: 'video/avc',
      videoCodecs: 'avc1.640028',
      videoBitrate: 4500000,
      audioMimeType: 'audio/mp4a-latm',
      audioBitrate: 128000,
      bandwidthEstimate: 12000000,
      frameRate: 25,
      decoderName: 'c2.android.avc.decoder',
    ),
  );
}

Widget _chromeSurface({required bool landscape}) {
  final player = FakeNativePlayer()..isPlaying = true;
  return RepaintBoundary(
    child: MaterialApp(
      theme: ThemeData(fontFamily: 'NotoSansCJK', brightness: Brightness.dark),
      home: VideoPlayerChrome(
        player: player,
        title: '示例剧场',
        episodes: [
          for (var i = 0; i < 12; i++)
            Chapter(itemId: '$i', title: '第${i + 1}集', volumeName: ''),
        ],
        currentIndex: 2,
        duration: const Duration(minutes: 24, seconds: 30),
        playing: true,
        onSelectEpisode: (_) async {},
        onError: (_) {},
        embedActions: _actions(),
        embedLoadInfo: () async => _info(),
        child: const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF37474F), Color(0xFF102027)],
            ),
          ),
          child: SizedBox.expand(),
        ),
      ),
    ),
  );
}

Future<void> _shot(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary).first,
  );
  late final ui.Image image;
  await tester.runAsync(() async {
    image = await boundary.toImage(pixelRatio: 2.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(previewOutPath(name)).writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PlayerMenuPreferences.resetForTest();
    await PlayerMenuPreferences.loadAll();
  });

  testWidgets('预览1：竖屏播放页顶栏与底栏', (tester) async {
    await loadPreviewFonts(tester);
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_chromeSurface(landscape: false));
    await _shot(tester, 'player_embed_1_portrait_bars.png');
  });

  testWidgets('预览2：横屏播放页顶栏与底栏', (tester) async {
    await loadPreviewFonts(tester);
    tester.view.physicalSize = const Size(900, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_chromeSurface(landscape: true));
    await _shot(tester, 'player_embed_2_landscape_bars.png');
  });

  testWidgets('预览3：更多菜单（竖屏底部弹层）', (tester) async {
    await loadPreviewFonts(tester);
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_chromeSurface(landscape: false));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('更多'));
    await _shot(tester, 'player_embed_3_menu.png');
  });

  testWidgets('预览4：弹幕设置面板', (tester) async {
    await loadPreviewFonts(tester);
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: 'NotoSansCJK',
            brightness: Brightness.dark,
          ),
          home: Scaffold(
            backgroundColor: const Color(0xFF202027),
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showDanmakuSettingsSheet(
                    context,
                    initial: const DanmakuSettings(),
                    onChanged: (_) {},
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _shot(tester, 'player_embed_4_danmaku_settings.png');
  });

  testWidgets('预览5：播放信息弹窗', (tester) async {
    await loadPreviewFonts(tester);
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: 'NotoSansCJK',
            brightness: Brightness.dark,
          ),
          home: Scaffold(
            backgroundColor: const Color(0xFF202027),
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () =>
                      showPlayerInfoDialog(context, loadInfo: () async => _info()),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _shot(tester, 'player_embed_5_info_dialog.png');
  });
}
