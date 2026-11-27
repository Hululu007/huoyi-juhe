// 播放器内嵌菜单批（2026-11-27 照录屏改造）新功能套件：
// - 统一更多菜单行齐全（定时/地址/信息/投屏/内核/重载/倍速/长按倍速/
//   跳片头片尾/弹幕/轨道/字幕设置/镜像/填充/屏显/常驻进度/解码/
//   静音默认/去广告/后台播放/回退/布局/听书/清晰度/字号/下载）；
// - 播放地址弹窗四段可看（含请求头与原始链接）；
// - 播放信息弹窗走宿主 + 原生信息；
// - 投屏诚实提示、内核只列现有 ExoPlayer；
// - 播放顺序/常驻进度/长按倍速/字幕样式落盘往返与旧键迁移；
// - chrome 的 ⋮ 在带 embedActions 时开新菜单（旧面板不再出现）。
import 'package:flutter/material.dart';
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

import 'support/fakes.dart';

PlayerEmbedPageActions _actions({
  PlayerSleepTimer? sleepTimer,
  void Function(VideoDecoderPreference)? onDecoder,
  void Function(int, int)? onSkip,
}) {
  return PlayerEmbedPageActions(
    seriesTitle: '测试剧',
    episodeLabel: '第3集',
    sourceLabel: '站点A',
    source: const EpisodeSource(
      'https://cdn.test/play.m3u8?token=1',
      '',
      [],
      null,
      [],
      {'Referer': 'https://site.test/', 'X-Test': 'yes'},
      'https://site.test/watch/123',
    ),
    sleepTimer: sleepTimer ?? PlayerSleepTimer(),
    introSkipSeconds: 0,
    outroSkipSeconds: 0,
    onSkipSettingsChanged: onSkip ?? (_, _) {},
    onReload: () {},
    decoder: VideoDecoderPreference.hardware,
    onDecoderChanged: (d) async => onDecoder?.call(d),
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
    seriesTitle: '测试剧',
    episodeLabel: '第3集',
    sourceLabel: '站点A',
    sourceUrl: 'https://cdn.test/play.m3u8?token=1',
    decoderPrefLabel: '硬解',
    position: Duration(seconds: 65),
    duration: Duration(minutes: 24),
    rate: 1,
    episodeIndex: 2,
    episodeCount: 12,
    native: PlayerPlaybackInfo(
      videoWidth: 1280,
      videoHeight: 720,
      videoMimeType: 'video/avc',
      videoBitrate: 2500000,
      bandwidthEstimate: 8000000,
      decoderName: 'c2.android.avc.decoder',
    ),
  );
}

Future<void> _openMenu(WidgetTester tester, {PlayerInfoData? info}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showPlayerEmbedMenu(
                context: context,
                landscape: false,
                player: FakeNativePlayer(),
                rate: 1,
                onOpenRatePanel: () {},
                pageActions: _actions(),
                loadInfo: () async => info ?? _info(),
                danmakuEnabled: true,
                onDanmakuEnabledChanged: (_) {},
                danmakuSettings: const DanmakuSettings(),
                onDanmakuSettingsChanged: (_) {},
                mirrorH: false,
                onMirrorHChanged: (_) {},
                mirrorV: false,
                onMirrorVChanged: (_) {},
                fillLabel: '适应',
                onCycleFill: () => '撑满',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder _row(String key) => find.byKey(ValueKey('embed-menu-$key'));

/// 手动拖菜单列表直到目标行出现（懒加载回收下 scrollUntilVisible
/// 不稳）。调用方负责断言。
Future<void> scrollMenuToRow(WidgetTester tester, String key) async {
  final list = find.descendant(
    of: find.byKey(const ValueKey('player-embed-menu')),
    matching: find.byType(Scrollable),
  );
  for (var i = 0; i < 30 && _row(key).evaluate().isEmpty; i++) {
    await tester.drag(list, const Offset(0, -300));
    await tester.pumpAndSettle();
  }
  // 目标行刚建出来时可能还在视口下缘：只在它确实靠下时再带一段，
  // 避免把靠上的行拖出回收区。
  if (_row(key).evaluate().isNotEmpty) {
    final viewHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    for (var i = 0; i < 4; i++) {
      final rect = tester.getRect(_row(key));
      if (rect.center.dy < viewHeight * 0.7) break;
      await tester.drag(list, const Offset(0, -200));
      await tester.pumpAndSettle();
      if (_row(key).evaluate().isEmpty) break;
    }
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PlayerMenuPreferences.resetForTest();
    await PlayerMenuPreferences.loadAll();
  });

  testWidgets('菜单行齐全：核心行都在（含弹幕三行与轨道三行）', (tester) async {
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _openMenu(tester);
    // 弹层是懒加载列表、滚过的行会被回收：从头拖到尾，沿途把
    // 出现过的行 key 全收集下来再对总账。
    final seen = <String>{};
    void collect() {
      for (final element in find
          .descendant(
            of: find.byKey(const ValueKey('player-embed-menu')),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget.key is ValueKey<String> &&
                  (widget.key as ValueKey<String>).value.startsWith(
                    'embed-menu-',
                  ),
            ),
          )
          .evaluate()) {
        final key = element.widget.key as ValueKey<String>;
        seen.add(key.value.substring('embed-menu-'.length));
      }
    }

    collect();
    final list = find.descendant(
      of: find.byKey(const ValueKey('player-embed-menu')),
      matching: find.byType(Scrollable),
    );
    for (var i = 0; i < 14; i++) {
      await tester.drag(list, const Offset(0, -350));
      await tester.pumpAndSettle();
      collect();
    }
    for (final key in [
      'sleep',
      'play-order',
      'address',
      'info',
      'cast',
      'kernel',
      'reload',
      'rate',
      'boost-rate',
      'skip',
      'danmaku-switch',
      'danmaku-load',
      'danmaku-settings',
      'track-audio',
      'track-video',
      'track-subtitle',
      'subtitle-settings',
      'mirror-h',
      'mirror-v',
      'fill',
      'osd',
      'progress-mode',
      'hw-accel',
      'decoder',
      'mute-default',
      'ad-block',
      'background-play',
      'fallback',
      'layout',
    ]) {
      expect(seen, contains(key), reason: '缺行 embed-menu-$key');
    }
  });

  testWidgets('播放地址弹窗：四段齐全，含请求头与原始链接', (tester) async {
    await _openMenu(tester);
    await tester.tap(_row('address'));
    await tester.pumpAndSettle();
    // 菜单行与弹窗标题同名，两处都在。
    expect(find.text('播放地址'), findsWidgets);
    expect(find.text('站点A'), findsOneWidget);
    expect(find.text('https://site.test/watch/123'), findsOneWidget);
    expect(find.text('https://cdn.test/play.m3u8?token=1'), findsOneWidget);
    expect(find.textContaining('Referer: https://site.test/'), findsOneWidget);
    expect(find.textContaining('X-Test: yes'), findsOneWidget);
  });

  testWidgets('播放信息弹窗：分辨率/码率/解码器来自原生信息', (tester) async {
    await _openMenu(tester);
    await tester.tap(_row('info'));
    await tester.pumpAndSettle();
    expect(find.text('播放信息'), findsWidgets);
    expect(find.text('1280x720'), findsOneWidget);
    expect(find.text('2.50 Mbps'), findsOneWidget);
    expect(find.text('c2.android.avc.decoder'), findsOneWidget);
    expect(find.text('ExoPlayer'), findsWidgets);
  });

  testWidgets('投屏：只给诚实提示，不假装能投', (tester) async {
    await _openMenu(tester);
    await tester.tap(_row('cast'));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂不支持投屏'), findsOneWidget);
  });

  testWidgets('内核切换：只列现有 ExoPlayer 一个核', (tester) async {
    await _openMenu(tester);
    await tester.tap(_row('kernel'));
    await tester.pumpAndSettle();
    expect(find.text('ExoPlayer'), findsWidgets);
    expect(find.textContaining('仅内置 ExoPlayer 一个播放内核'), findsOneWidget);
  });

  testWidgets('定时关闭：选 30 分钟后定时器生效', (tester) async {
    final timer = PlayerSleepTimer();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showPlayerEmbedMenu(
                  context: context,
                  landscape: false,
                  player: FakeNativePlayer(),
                  rate: 1,
                  onOpenRatePanel: () {},
                  pageActions: _actions(sleepTimer: timer),
                  loadInfo: () async => _info(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(_row('sleep'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 分钟后停止'));
    await tester.pumpAndSettle();
    expect(timer.active, isTrue);
    expect(timer.label, contains('30'));
  });

  testWidgets('跳片头片尾：填秒数确定后回宿主', (tester) async {
    int? intro;
    int? outro;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showPlayerEmbedMenu(
                  context: context,
                  landscape: false,
                  player: FakeNativePlayer(),
                  rate: 1,
                  onOpenRatePanel: () {},
                  pageActions: _actions(
                    onSkip: (i, o) {
                      intro = i;
                      outro = o;
                    },
                  ),
                  loadInfo: () async => _info(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await scrollMenuToRow(tester, 'skip');
    await tester.tap(_row('skip'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('skip-intro-field')),
      '90',
    );
    await tester.enterText(
      find.byKey(const ValueKey('skip-outro-field')),
      '45',
    );
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(intro, 90);
    expect(outro, 45);
  });

  testWidgets('硬解模式：选软解回宿主 VideoDecoderPreference.software', (
    tester,
  ) async {
    VideoDecoderPreference? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showPlayerEmbedMenu(
                  context: context,
                  landscape: false,
                  player: FakeNativePlayer(),
                  rate: 1,
                  onOpenRatePanel: () {},
                  pageActions: _actions(onDecoder: (d) => picked = d),
                  loadInfo: () async => _info(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await scrollMenuToRow(tester, 'decoder');
    await tester.tap(_row('decoder'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('软解'));
    await tester.pumpAndSettle();
    expect(picked, VideoDecoderPreference.software);
  });

  testWidgets('chrome ⋮ 带 embedActions 时开统一菜单', (tester) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoPlayerChrome(
          player: player,
          episodes: [
            Chapter(itemId: '1', title: '第1集', volumeName: ''),
          ],
          currentIndex: 0,
          duration: const Duration(minutes: 2),
          playing: true,
          onSelectEpisode: (_) async {},
          onError: (_) {},
          embedActions: _actions(),
          embedLoadInfo: () async => _info(),
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(_row('sleep'), findsOneWidget);
    expect(_row('address'), findsOneWidget);
    // 旧通用面板的倍速行不再出现（已并入统一菜单）。
    expect(
      find.byKey(const ValueKey('player-more-rate-row')),
      findsNothing,
    );
  });

  group('PlayerMenuPreferences 往返与迁移', () {
    test('播放顺序默认自动连播；旧自动连播关 → 播完暂停', () async {
      SharedPreferences.setMockInitialValues({});
      PlayerMenuPreferences.resetForTest();
      await PlayerMenuPreferences.loadAll();
      expect(
        PlayerMenuPreferences.playOrder.value,
        PlayOrderMode.autoNext,
      );

      SharedPreferences.setMockInitialValues({
        'player_auto_advance': false,
      });
      PlayerMenuPreferences.resetForTest();
      await PlayerMenuPreferences.loadAll();
      expect(
        PlayerMenuPreferences.playOrder.value,
        PlayOrderMode.stopAtEnd,
      );
    });

    test('setPlayOrder 同步旧自动连播键（只有自动连播写开）', () async {
      await PlayerMenuPreferences.setPlayOrder(PlayOrderMode.autoNext);
      expect(await PlayerPreferences.loadAutoAdvance(), isTrue);
      await PlayerMenuPreferences.setPlayOrder(PlayOrderMode.singleLoop);
      expect(await PlayerPreferences.loadAutoAdvance(), isFalse);
      await PlayerMenuPreferences.setPlayOrder(PlayOrderMode.stopAtEnd);
      expect(await PlayerPreferences.loadAutoAdvance(), isFalse);
    });

    test('屏显/常驻进度/长按倍速/字幕样式落盘往返', () async {
      await PlayerMenuPreferences.setOsd(
        const PlayerOsdSettings(
          showTime: false,
          showSpeed: true,
          showResolution: false,
          showTitle: true,
          fontSize: 15,
        ),
      );
      await PlayerMenuPreferences.setProgressMode(
        PersistentProgressMode.always,
      );
      await PlayerMenuPreferences.setBoostRate(2.5);
      await PlayerMenuPreferences.setSubtitleStyle(
        const SubtitleStyleSettings(
          fontScale: 1.5,
          colorIndex: 1,
          positionTop: true,
          stroke: false,
        ),
      );
      PlayerMenuPreferences.resetForTest();
      await PlayerMenuPreferences.loadAll();
      final osd = PlayerMenuPreferences.osd.value;
      expect(osd.showTime, isFalse);
      expect(osd.showResolution, isFalse);
      expect(osd.fontSize, 15);
      expect(
        PlayerMenuPreferences.progressMode.value,
        PersistentProgressMode.always,
      );
      expect(PlayerMenuPreferences.boostRate.value, 2.5);
      final style = PlayerMenuPreferences.subtitleStyle.value;
      expect(style.fontScale, 1.5);
      expect(style.colorIndex, 1);
      expect(style.positionTop, isTrue);
      expect(style.stroke, isFalse);
      expect(SubtitleStyleSettings.colorLabels[style.colorIndex], '黄色');
    });

    test('长按倍速越界钳回档位表', () async {
      await PlayerMenuPreferences.setBoostRate(9);
      expect(
        PlayerMenuPreferences.boostRate.value,
        PlayerMenuPreferences.boostRates.last,
      );
    });
  });
}
