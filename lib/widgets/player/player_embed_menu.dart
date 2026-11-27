/// 播放器内嵌「更多」菜单（照录屏改造批）：把原先散在左缘浮钮、
/// 设置页与短剧专属面板里的播放设置收成一份全形态共用的菜单。
///
/// 竖屏走底部弹层、横屏走右侧栏（PlayerSidePanel），内容同一份
/// [PlayerEmbedMenuBody]。菜单是打开瞬间的快照：活值（定时/顺序/
/// 解码档）点选后就地刷新本菜单行，真正的生效动作走回调交回播放页。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/episode_source_cache.dart';
import '../../services/native_player.dart';
import '../../services/playback_fallback.dart';
import '../../services/player_layout_preferences.dart';
import '../../services/player_menu_preferences.dart';
import '../../services/player_preferences.dart';
import '../../services/player_sleep_timer.dart';
import 'playlet_danmaku_settings.dart';
import 'player_side_panel.dart';
import 'player_track_picker.dart';

/// 播放页供给菜单的页面级数据与动作（播放页组装，控制层透传）。
class PlayerEmbedPageActions {
  const PlayerEmbedPageActions({
    required this.seriesTitle,
    required this.episodeLabel,
    required this.sourceLabel,
    required this.source,
    required this.sleepTimer,
    required this.introSkipSeconds,
    required this.outroSkipSeconds,
    required this.onSkipSettingsChanged,
    required this.onReload,
    required this.decoder,
    required this.onDecoderChanged,
    required this.backgroundPlay,
    required this.onBackgroundPlayChanged,
    required this.mutedDefault,
    required this.onMutedDefaultChanged,
    required this.adBlockEnabled,
    required this.onAdBlockChanged,
    required this.fallbackMode,
    required this.onFallbackModeChanged,
    required this.layoutMode,
    required this.onLayoutModeChanged,
    required this.episodeIndex,
    required this.episodeCount,
    this.onOpenListenMode,
    this.onOpenDownload,
    this.onOpenQuality,
    this.onLoadDanmakuUrl,
    this.onLoadDanmakuFile,
    this.displayModeLabel,
    this.onCycleDisplayMode,
    this.rotationLabel,
    this.onCycleRotation,
    this.seasonAutoplay,
    this.onSeasonAutoplayChanged,
  });

  final String seriesTitle;

  /// 当前集标签（如「第 5 集」；单集内容为空串）。
  final String episodeLabel;

  /// 播放源名（站名/线路名；播放地址弹窗的「播放源」行）。
  final String sourceLabel;

  /// 当前集的取流结果快照（播放地址/播放信息弹窗的数据来源）。
  final EpisodeSource? source;

  final PlayerSleepTimer sleepTimer;
  final int introSkipSeconds;
  final int outroSkipSeconds;
  final void Function(int introSeconds, int outroSeconds)
  onSkipSettingsChanged;

  final VoidCallback onReload;

  /// 当前解码偏好（菜单打开瞬间值）；切换走 [onDecoderChanged]
  /// （播放页负责落盘 + 重载当前集生效）。
  final VideoDecoderPreference decoder;
  final Future<void> Function(VideoDecoderPreference) onDecoderChanged;

  final bool backgroundPlay;
  final ValueChanged<bool> onBackgroundPlayChanged;
  final bool mutedDefault;
  final ValueChanged<bool> onMutedDefaultChanged;
  final bool adBlockEnabled;
  final ValueChanged<bool> onAdBlockChanged;
  final PlaybackFallbackMode fallbackMode;
  final ValueChanged<PlaybackFallbackMode> onFallbackModeChanged;
  final PlayerLayoutMode layoutMode;
  final ValueChanged<PlayerLayoutMode> onLayoutModeChanged;

  final int episodeIndex;
  final int episodeCount;

  /// 空 = 当前形态没有这项能力，菜单不摆这一行。
  final VoidCallback? onOpenListenMode;
  final VoidCallback? onOpenDownload;
  final VoidCallback? onOpenQuality;
  final VoidCallback? onLoadDanmakuUrl;
  final VoidCallback? onLoadDanmakuFile;

  /// 左缘浮钮迁入项：画面模式（点按循环、回新档名）、旋转（同上）、
  /// 跨季连播开关。为空时不摆行。
  final String? displayModeLabel;
  final String Function()? onCycleDisplayMode;
  final String? rotationLabel;
  final String Function()? onCycleRotation;
  final bool? seasonAutoplay;
  final ValueChanged<bool>? onSeasonAutoplayChanged;
}

/// 播放信息弹窗的数据（SPEC I1–I9）：取不到的字段留空，弹窗显「—」，
/// 不编造。
class PlayerInfoData {
  const PlayerInfoData({
    required this.seriesTitle,
    required this.episodeLabel,
    required this.sourceLabel,
    required this.sourceUrl,
    required this.decoderPrefLabel,
    required this.position,
    required this.duration,
    required this.rate,
    required this.episodeIndex,
    required this.episodeCount,
    this.native,
    this.fallbackWidth = 0,
    this.fallbackHeight = 0,
  });

  final String seriesTitle;
  final String episodeLabel;
  final String sourceLabel;
  final String sourceUrl;
  final String decoderPrefLabel;
  final Duration position;
  final Duration duration;
  final double rate;
  final int episodeIndex;
  final int episodeCount;
  final PlayerPlaybackInfo? native;
  final int fallbackWidth;
  final int fallbackHeight;
}

const _menuBg = Color(0xFF1B1B1F);
const _menuText = Colors.white;
const _menuSub = Color(0xFF9E9EA7);
const _menuAccent = Color(0xFFD81B60);

TextStyle get _rowLabelStyle =>
    const TextStyle(color: _menuText, fontSize: 14.5);
TextStyle get _rowValueStyle =>
    const TextStyle(color: _menuSub, fontSize: 12.5);
TextStyle get _sectionStyle => const TextStyle(
  color: _menuSub,
  fontSize: 12,
  fontWeight: FontWeight.w600,
);

/// 打开统一「更多」菜单：横屏右侧栏、竖屏底部弹层。
Future<void> showPlayerEmbedMenu({
  required BuildContext context,
  required bool landscape,
  required NativePlayer? player,
  required double rate,
  required VoidCallback onOpenRatePanel,
  required PlayerEmbedPageActions pageActions,
  required Future<PlayerInfoData> Function() loadInfo,
  String? fillLabel,
  String Function()? onCycleFill,
  bool? danmakuEnabled,
  ValueChanged<bool>? onDanmakuEnabledChanged,
  DanmakuSettings? danmakuSettings,
  ValueChanged<DanmakuSettings>? onDanmakuSettingsChanged,
  VoidCallback? onOpenFontScale,
  bool mirrorH = false,
  bool mirrorV = false,
  ValueChanged<bool>? onMirrorHChanged,
  ValueChanged<bool>? onMirrorVChanged,
}) {
  final body = PlayerEmbedMenuBody(
    player: player,
    rate: rate,
    onOpenRatePanel: onOpenRatePanel,
    pageActions: pageActions,
    loadInfo: loadInfo,
    fillLabel: fillLabel,
    onCycleFill: onCycleFill,
    danmakuEnabled: danmakuEnabled,
    onDanmakuEnabledChanged: onDanmakuEnabledChanged,
    danmakuSettings: danmakuSettings,
    onDanmakuSettingsChanged: onDanmakuSettingsChanged,
    onOpenFontScale: onOpenFontScale,
    mirrorH: mirrorH,
    mirrorV: mirrorV,
    onMirrorHChanged: onMirrorHChanged,
    onMirrorVChanged: onMirrorVChanged,
  );
  if (landscape) {
    return PlayerSidePanel.show<void>(
      context: context,
      background: _menuBg,
      builder: (_) => SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PlayerSidePanelHeader(title: '更多'),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: _menuBg,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetContext).size.height * 0.78,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(
                children: [
                  const Text(
                    '更多',
                    style: TextStyle(
                      color: _menuText,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    icon: const Icon(Icons.close, color: _menuSub, size: 20),
                  ),
                ],
              ),
            ),
            Flexible(child: body),
          ],
        ),
      ),
    ),
  );
}

class PlayerEmbedMenuBody extends StatefulWidget {
  const PlayerEmbedMenuBody({
    super.key,
    required this.player,
    required this.rate,
    required this.onOpenRatePanel,
    required this.pageActions,
    required this.loadInfo,
    this.fillLabel,
    this.onCycleFill,
    this.danmakuEnabled,
    this.onDanmakuEnabledChanged,
    this.danmakuSettings,
    this.onDanmakuSettingsChanged,
    this.onOpenFontScale,
    this.mirrorH = false,
    this.mirrorV = false,
    this.onMirrorHChanged,
    this.onMirrorVChanged,
  });

  final NativePlayer? player;
  final double rate;
  final VoidCallback onOpenRatePanel;
  final PlayerEmbedPageActions pageActions;
  final Future<PlayerInfoData> Function() loadInfo;
  final String? fillLabel;
  final String Function()? onCycleFill;
  final bool? danmakuEnabled;
  final ValueChanged<bool>? onDanmakuEnabledChanged;
  final DanmakuSettings? danmakuSettings;
  final ValueChanged<DanmakuSettings>? onDanmakuSettingsChanged;
  final VoidCallback? onOpenFontScale;
  final bool mirrorH;
  final bool mirrorV;
  final ValueChanged<bool>? onMirrorHChanged;
  final ValueChanged<bool>? onMirrorVChanged;

  @override
  State<PlayerEmbedMenuBody> createState() => _PlayerEmbedMenuBodyState();
}

class _PlayerEmbedMenuBodyState extends State<PlayerEmbedMenuBody> {
  late bool _mirrorH = widget.mirrorH;
  late bool _mirrorV = widget.mirrorV;
  late bool _backgroundPlay = widget.pageActions.backgroundPlay;
  late bool _mutedDefault = widget.pageActions.mutedDefault;
  late bool _adBlock = widget.pageActions.adBlockEnabled;
  late bool? _danmakuEnabled = widget.danmakuEnabled;
  late VideoDecoderPreference _decoder = widget.pageActions.decoder;
  late PlaybackFallbackMode _fallbackMode = widget.pageActions.fallbackMode;
  late PlayerLayoutMode _layoutMode = widget.pageActions.layoutMode;
  late String? _fillLabel = widget.fillLabel;
  late int _introSkip = widget.pageActions.introSkipSeconds;
  late int _outroSkip = widget.pageActions.outroSkipSeconds;
  late String? _displayModeLabel = widget.pageActions.displayModeLabel;
  late String? _rotationLabel = widget.pageActions.rotationLabel;
  late bool? _seasonAutoplay = widget.pageActions.seasonAutoplay;

  PlayerEmbedPageActions get _actions => widget.pageActions;

  @override
  Widget build(BuildContext context) {
    final timer = _actions.sleepTimer;
    return ListView(
      key: const ValueKey('player-embed-menu'),
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        _section('播放'),
        _navRow(
          key: const ValueKey('embed-menu-sleep'),
          icon: Icons.timer_outlined,
          label: '定时关闭',
          value: timer.active ? timer.label : '关闭',
          onTap: () async {
            await showPlayerSleepSheet(context, timer: timer);
            if (mounted) setState(() {});
          },
        ),
        ValueListenableBuilder<PlayOrderMode>(
          valueListenable: PlayerMenuPreferences.playOrder,
          builder: (context, order, _) => _navRow(
            key: const ValueKey('embed-menu-play-order'),
            icon: Icons.repeat,
            label: '播放顺序',
            value: order.label,
            onTap: () => _pickPlayOrder(context),
          ),
        ),
        _navRow(
          key: const ValueKey('embed-menu-address'),
          icon: Icons.link,
          label: '播放地址',
          onTap: () => showPlayerAddressDialog(
            context,
            sourceLabel: _actions.sourceLabel,
            episodeLabel: _actions.episodeLabel,
            source: _actions.source,
          ),
        ),
        _navRow(
          key: const ValueKey('embed-menu-info'),
          icon: Icons.info_outline,
          label: '播放信息',
          onTap: () =>
              showPlayerInfoDialog(context, loadInfo: widget.loadInfo),
        ),
        _navRow(
          key: const ValueKey('embed-menu-cast'),
          icon: Icons.cast,
          label: '投屏',
          onTap: () => showPlayerCastSheet(context),
        ),
        _navRow(
          key: const ValueKey('embed-menu-kernel'),
          icon: Icons.memory,
          label: '内核切换',
          value: 'ExoPlayer',
          onTap: () => showPlayerKernelSheet(context),
        ),
        _navRow(
          key: const ValueKey('embed-menu-reload'),
          icon: Icons.refresh,
          label: '重载',
          onTap: () {
            Navigator.of(context).pop();
            _actions.onReload();
          },
        ),
        _navRow(
          key: const ValueKey('embed-menu-rate'),
          icon: Icons.speed,
          label: '倍速',
          value: _rateLabel(widget.rate),
          onTap: widget.onOpenRatePanel,
        ),
        ValueListenableBuilder<double>(
          valueListenable: PlayerMenuPreferences.boostRate,
          builder: (context, boost, _) => _navRow(
            key: const ValueKey('embed-menu-boost-rate'),
            icon: Icons.touch_app_outlined,
            label: '长按倍速',
            value: '${_trimRate(boost)}x',
            onTap: () => _pickBoostRate(context),
          ),
        ),
        _navRow(
          key: const ValueKey('embed-menu-skip'),
          icon: Icons.skip_next_outlined,
          label: '跳过片头片尾',
          value: _introSkip <= 0 && _outroSkip <= 0
              ? '关闭'
              : '片头 ${_introSkip}s · 片尾 ${_outroSkip}s',
          onTap: () async {
            final saved = await showSkipSettingsDialog(
              context,
              introSeconds: _introSkip,
              outroSeconds: _outroSkip,
            );
            if (saved == null || !mounted) return;
            setState(() {
              _introSkip = saved.$1;
              _outroSkip = saved.$2;
            });
            _actions.onSkipSettingsChanged(saved.$1, saved.$2);
          },
        ),
        if (_danmakuEnabled != null) ...[
          _section('弹幕'),
          _switchRow(
            key: const ValueKey('embed-menu-danmaku-switch'),
            icon: Icons.subtitles_outlined,
            label: '弹幕',
            value: _danmakuEnabled!,
            onChanged: (value) {
              setState(() => _danmakuEnabled = value);
              widget.onDanmakuEnabledChanged?.call(value);
            },
          ),
          if (_actions.onLoadDanmakuUrl != null ||
              _actions.onLoadDanmakuFile != null)
            _navRow(
              key: const ValueKey('embed-menu-danmaku-load'),
              icon: Icons.cloud_upload_outlined,
              label: '弹幕加载',
              onTap: () => showDanmakuLoadSheet(
                context,
                onLoadUrl: _actions.onLoadDanmakuUrl,
                onLoadFile: _actions.onLoadDanmakuFile,
              ),
            ),
          if (widget.danmakuSettings != null)
            _navRow(
              key: const ValueKey('embed-menu-danmaku-settings'),
              icon: Icons.tune,
              label: '弹幕设置',
              onTap: () => showDanmakuSettingsSheet(
                context,
                initial: widget.danmakuSettings!,
                onChanged: widget.onDanmakuSettingsChanged ?? (_) {},
              ),
            ),
        ],
        _section('画面与轨道'),
        if (widget.player != null) ...[
          _navRow(
            key: const ValueKey('embed-menu-track-audio'),
            icon: Icons.audiotrack,
            label: '音轨',
            onTap: () => showPlayerTrackPicker(
              context: context,
              player: widget.player!,
              section: PlayerTrackSection.audio,
            ),
          ),
          _navRow(
            key: const ValueKey('embed-menu-track-video'),
            icon: Icons.video_settings_outlined,
            label: '视轨',
            onTap: () => showPlayerTrackPicker(
              context: context,
              player: widget.player!,
              section: PlayerTrackSection.video,
            ),
          ),
          _navRow(
            key: const ValueKey('embed-menu-track-subtitle'),
            icon: Icons.closed_caption_outlined,
            label: '字幕',
            onTap: () => showPlayerTrackPicker(
              context: context,
              player: widget.player!,
              section: PlayerTrackSection.subtitles,
            ),
          ),
        ],
        _navRow(
          key: const ValueKey('embed-menu-subtitle-settings'),
          icon: Icons.text_fields,
          label: '字幕设置',
          onTap: () => showSubtitleStyleSheet(context),
        ),
        if (widget.onMirrorHChanged != null)
          _switchRow(
            key: const ValueKey('embed-menu-mirror-h'),
            icon: Icons.flip,
            label: '左右翻转',
            value: _mirrorH,
            onChanged: (value) {
              setState(() => _mirrorH = value);
              widget.onMirrorHChanged!.call(value);
            },
          ),
        if (widget.onMirrorVChanged != null)
          _switchRow(
            key: const ValueKey('embed-menu-mirror-v'),
            icon: Icons.flip,
            label: '上下翻转',
            value: _mirrorV,
            flipVertical: true,
            onChanged: (value) {
              setState(() => _mirrorV = value);
              widget.onMirrorVChanged!.call(value);
            },
          ),
        if (widget.onCycleFill != null)
          _navRow(
            key: const ValueKey('embed-menu-fill'),
            icon: Icons.fit_screen_outlined,
            label: '画面撑满',
            value: _fillLabel ?? '',
            onTap: () {
              final next = widget.onCycleFill!.call();
              setState(() => _fillLabel = next);
            },
          ),
        if (_actions.onCycleDisplayMode != null)
          _navRow(
            key: const ValueKey('embed-menu-display-mode'),
            icon: Icons.aspect_ratio_outlined,
            label: '画面模式',
            value: _displayModeLabel ?? '',
            onTap: () {
              final next = _actions.onCycleDisplayMode!.call();
              setState(() => _displayModeLabel = next);
            },
          ),
        if (_actions.onCycleRotation != null)
          _navRow(
            key: const ValueKey('embed-menu-rotation'),
            icon: Icons.screen_rotation_outlined,
            label: '旋转',
            value: _rotationLabel ?? '',
            onTap: () {
              final next = _actions.onCycleRotation!.call();
              setState(() => _rotationLabel = next);
            },
          ),
        if (_seasonAutoplay != null && _actions.onSeasonAutoplayChanged != null)
          _switchRow(
            key: const ValueKey('embed-menu-season-autoplay'),
            icon: Icons.queue_play_next_outlined,
            label: '跨季连播',
            value: _seasonAutoplay!,
            onChanged: (value) {
              setState(() => _seasonAutoplay = value);
              _actions.onSeasonAutoplayChanged!.call(value);
            },
          ),
        _navRow(
          key: const ValueKey('embed-menu-osd'),
          icon: Icons.monitor_outlined,
          label: '屏显设置',
          onTap: () => showOsdSettingsSheet(context),
        ),
        ValueListenableBuilder<PersistentProgressMode>(
          valueListenable: PlayerMenuPreferences.progressMode,
          builder: (context, mode, _) => _navRow(
            key: const ValueKey('embed-menu-progress-mode'),
            icon: Icons.linear_scale,
            label: '底部进度条',
            value: mode.label,
            onTap: () => _pickProgressMode(context),
          ),
        ),
        _section('解码'),
        _switchRow(
          key: const ValueKey('embed-menu-hw-accel'),
          icon: Icons.developer_board_outlined,
          label: '硬件加速',
          value: _decoder != VideoDecoderPreference.software,
          onChanged: (value) => _setDecoder(
            value ? VideoDecoderPreference.hardware : VideoDecoderPreference.software,
          ),
        ),
        _navRow(
          key: const ValueKey('embed-menu-decoder'),
          icon: Icons.settings_input_component_outlined,
          label: '硬解模式',
          value: _decoder.label,
          onTap: () => _pickDecoder(context),
        ),
        if (_decoder != VideoDecoderPreference.software)
          _navRow(
            key: const ValueKey('embed-menu-to-software'),
            icon: Icons.swap_horiz,
            label: '快速切换到软解',
            onTap: () => _setDecoder(VideoDecoderPreference.software),
          ),
        _section('更多设置'),
        _switchRow(
          key: const ValueKey('embed-menu-mute-default'),
          icon: Icons.volume_off_outlined,
          label: '默认静音',
          value: _mutedDefault,
          onChanged: (value) {
            setState(() => _mutedDefault = value);
            _actions.onMutedDefaultChanged(value);
          },
        ),
        _switchRow(
          key: const ValueKey('embed-menu-ad-block'),
          icon: Icons.block_outlined,
          label: '去广告',
          value: _adBlock,
          onChanged: (value) {
            setState(() => _adBlock = value);
            _actions.onAdBlockChanged(value);
          },
        ),
        _switchRow(
          key: const ValueKey('embed-menu-background-play'),
          icon: Icons.picture_in_picture_alt_outlined,
          label: '后台播放',
          value: _backgroundPlay,
          onChanged: (value) {
            setState(() => _backgroundPlay = value);
            _actions.onBackgroundPlayChanged(value);
          },
        ),
        _navRow(
          key: const ValueKey('embed-menu-fallback'),
          icon: Icons.alt_route,
          label: '自动回退',
          value: _fallbackMode.label,
          onTap: () => _pickFallbackMode(context),
        ),
        _navRow(
          key: const ValueKey('embed-menu-layout'),
          icon: Icons.view_sidebar_outlined,
          label: '播放页布局',
          value: _layoutMode.label,
          onTap: () => _pickLayoutMode(context),
        ),
        if (_actions.onOpenListenMode != null)
          _navRow(
            key: const ValueKey('embed-menu-listen'),
            icon: Icons.headphones_outlined,
            label: '听视频',
            onTap: _actions.onOpenListenMode,
          ),
        if (_actions.onOpenQuality != null)
          _navRow(
            key: const ValueKey('embed-menu-quality'),
            icon: Icons.high_quality_outlined,
            label: '清晰度',
            onTap: _actions.onOpenQuality,
          ),
        if (widget.onOpenFontScale != null)
          _navRow(
            key: const ValueKey('embed-menu-font-scale'),
            icon: Icons.format_size,
            label: '字体大小',
            onTap: widget.onOpenFontScale,
          ),
        if (_actions.onOpenDownload != null)
          _navRow(
            key: const ValueKey('embed-menu-download'),
            icon: Icons.download_outlined,
            label: '离线缓存',
            onTap: _actions.onOpenDownload,
          ),
      ],
    );
  }

  Future<void> _setDecoder(VideoDecoderPreference value) async {
    setState(() => _decoder = value);
    await _actions.onDecoderChanged(value);
  }

  Future<void> _pickPlayOrder(BuildContext context) async {
    final picked = await showEmbedRadioSheet<PlayOrderMode>(
      context,
      title: '播放顺序',
      options: [
        for (final mode in PlayOrderMode.values) (mode, mode.label, null),
      ],
      current: PlayerMenuPreferences.playOrder.value,
    );
    if (picked != null) await PlayerMenuPreferences.setPlayOrder(picked);
  }

  Future<void> _pickBoostRate(BuildContext context) async {
    final picked = await showEmbedRadioSheet<double>(
      context,
      title: '长按倍速',
      options: [
        for (final rate in PlayerMenuPreferences.boostRates)
          (rate, '${_trimRate(rate)}x', null),
      ],
      current: PlayerMenuPreferences.boostRate.value,
    );
    if (picked != null) await PlayerMenuPreferences.setBoostRate(picked);
  }

  Future<void> _pickProgressMode(BuildContext context) async {
    final picked = await showEmbedRadioSheet<PersistentProgressMode>(
      context,
      title: '底部进度条展示',
      options: [
        for (final mode in PersistentProgressMode.values)
          (mode, mode.label, null),
      ],
      current: PlayerMenuPreferences.progressMode.value,
    );
    if (picked != null) await PlayerMenuPreferences.setProgressMode(picked);
  }

  Future<void> _pickDecoder(BuildContext context) async {
    final picked = await showEmbedRadioSheet<VideoDecoderPreference>(
      context,
      title: '硬解模式',
      options: [
        for (final pref in VideoDecoderPreference.values)
          (pref, pref.label, null),
      ],
      current: _decoder,
    );
    if (picked != null) await _setDecoder(picked);
  }

  Future<void> _pickFallbackMode(BuildContext context) async {
    final picked = await showEmbedRadioSheet<PlaybackFallbackMode>(
      context,
      title: '自动回退',
      options: [
        for (final mode in PlaybackFallbackMode.values)
          (mode, mode.label, mode.description),
      ],
      current: _fallbackMode,
    );
    if (picked == null) return;
    setState(() => _fallbackMode = picked);
    _actions.onFallbackModeChanged(picked);
  }

  Future<void> _pickLayoutMode(BuildContext context) async {
    final picked = await showEmbedRadioSheet<PlayerLayoutMode>(
      context,
      title: '播放页布局',
      options: [
        for (final mode in PlayerLayoutMode.values)
          (mode, mode.label, mode.description),
      ],
      current: _layoutMode,
    );
    if (picked == null) return;
    setState(() => _layoutMode = picked);
    _actions.onLayoutModeChanged(picked);
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Text(title, style: _sectionStyle),
  );

  Widget _navRow({
    required Key key,
    required IconData icon,
    required String label,
    String? value,
    VoidCallback? onTap,
  }) {
    return InkWell(
      key: key,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(icon, color: _menuSub, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: _rowLabelStyle)),
            if (value != null && value.isNotEmpty) ...[
              Flexible(
                child: Text(
                  value,
                  style: _rowValueStyle,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
            ],
            const Icon(Icons.chevron_right, color: _menuSub, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _switchRow({
    required Key key,
    required IconData icon,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool flipVertical = false,
  }) {
    return Container(
      key: key,
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Transform(
            alignment: Alignment.center,
            transform: flipVertical
                ? (Matrix4.identity()..scaleByDouble(1, -1, 1, 1))
                : Matrix4.identity(),
            child: Icon(icon, color: _menuSub, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: _rowLabelStyle)),
          Switch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: _menuAccent,
          ),
        ],
      ),
    );
  }
}

String _trimRate(double rate) =>
    rate == rate.roundToDouble() ? rate.toInt().toString() : '$rate';

String _rateLabel(double rate) => '${_trimRate(rate)}x';

/// 弹幕设置弹层：复用既有 [PlayletDanmakuSettingsPanel]（含改造批
/// 新增的八项），改动经 [onChanged] 回页面落盘并即时生效。
Future<void> showDanmakuSettingsSheet(
  BuildContext context, {
  required DanmakuSettings initial,
  required ValueChanged<DanmakuSettings> onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: _menuBg,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetContext).size.height * 0.75,
        ),
        child: PlayletDanmakuSettingsPanel(
          settings: initial,
          landscape: false,
          onChanged: onChanged,
          onClose: () => Navigator.of(sheetContext).pop(),
        ),
      ),
    ),
  );
}

/// 单选弹层（菜单各档位共用）：当前项带勾，点选即回值并关闭。
Future<T?> showEmbedRadioSheet<T>(
  BuildContext context, {
  required String title,
  required List<(T, String, String?)> options,
  required T current,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: _menuBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                title,
                style: const TextStyle(
                  color: _menuText,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          for (final (value, label, description) in options)
            InkWell(
              onTap: () => Navigator.of(sheetContext).pop(value),
              child: Container(
                constraints: BoxConstraints(
                  minHeight: description == null ? 48 : 60,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(label, style: _rowLabelStyle),
                          if (description != null) ...[
                            const SizedBox(height: 2),
                            Text(description, style: _rowValueStyle),
                          ],
                        ],
                      ),
                    ),
                    if (value == current)
                      const Icon(Icons.check, color: _menuAccent, size: 20),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

/// 定时关闭弹层（SPEC M2）：预置档位 + 自定义分钟，落到页面持有的
/// [PlayerSleepTimer] 上（宿主心跳负责到点真停）。
Future<void> showPlayerSleepSheet(
  BuildContext context, {
  required PlayerSleepTimer timer,
}) async {
  final custom = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: _menuBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                '定时关闭',
              style: TextStyle(
                color: _menuText,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final choice in PlayerSleepChoice.values)
            InkWell(
              onTap: () {
                choice.applyTo(timer);
                Navigator.of(sheetContext).pop(false);
              },
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                alignment: Alignment.centerLeft,
                child: Text(choice.label, style: _rowLabelStyle),
              ),
            ),
          InkWell(
            onTap: () => Navigator.of(sheetContext).pop(true),
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.centerLeft,
              child: Text('自定义分钟…', style: _rowLabelStyle),
            ),
          ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
  if (custom != true || !context.mounted) return;
  final minutes = await _askMinutes(context, title: '自定义定时（分钟）');
  if (minutes != null && minutes > 0) timer.afterMinutes(minutes);
}

Future<int?> _askMinutes(
  BuildContext context, {
  required String title,
  int initial = 0,
}) async {
  final controller = TextEditingController(
    text: initial > 0 ? '$initial' : '',
  );
  final value = await showDialog<int>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: _menuBg,
      title: Text(
        title,
        style: const TextStyle(color: _menuText, fontSize: 16),
      ),
      content: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        autofocus: true,
        style: const TextStyle(color: _menuText),
        decoration: const InputDecoration(
          hintText: '输入分钟数',
          hintStyle: TextStyle(color: _menuSub),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(
            dialogContext,
          ).pop(int.tryParse(controller.text.trim()) ?? 0),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  controller.dispose();
  return value;
}

/// 播放地址弹窗（SPEC A1–A5）：四段各带复制钮；请求头为空时如实
/// 显「（无）」。
Future<void> showPlayerAddressDialog(
  BuildContext context, {
  required String sourceLabel,
  required String episodeLabel,
  required EpisodeSource? source,
}) {
  final headersText = source == null || source.headers.isEmpty
      ? ''
      : source.headers.entries.map((e) => '${e.key}: ${e.value}').join('\n');
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: _menuBg,
      title: const Text(
        '播放地址',
        style: TextStyle(color: _menuText, fontSize: 17),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _addressBlock(
              dialogContext,
              label: '播放源',
              value: sourceLabel.isEmpty ? '—' : sourceLabel,
            ),
            _addressBlock(
              dialogContext,
              label: '原始链接',
              value: source == null || source.originalUrl.isEmpty
                  ? (source?.url ?? '—')
                  : source.originalUrl,
              copyable: true,
            ),
            _addressBlock(
              dialogContext,
              label: '实际播放链接',
              value: source?.url ?? '—',
              copyable: true,
            ),
            _addressBlock(
              dialogContext,
              label: '请求头',
              value: headersText.isEmpty ? '（无）' : headersText,
              copyable: headersText.isNotEmpty,
            ),
            _addressBlock(
              dialogContext,
              label: '集名',
              value: episodeLabel.isEmpty ? '—' : episodeLabel,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

Widget _addressBlock(
  BuildContext context, {
  required String label,
  required String value,
  bool copyable = false,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: _sectionStyle),
            const Spacer(),
            if (copyable)
              InkWell(
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: value));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已复制'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  }
                },
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.copy, size: 15, color: _menuSub),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        SelectableText(
          value,
          style: const TextStyle(color: _menuText, fontSize: 12.5),
        ),
      ],
    ),
  );
}

/// 播放信息弹窗（SPEC I1–I9）：字段取到多少显多少，缺的显「—」。
Future<void> showPlayerInfoDialog(
  BuildContext context, {
  required Future<PlayerInfoData> Function() loadInfo,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: _menuBg,
      title: const Text(
        '播放信息',
        style: TextStyle(color: _menuText, fontSize: 20),
      ),
      content: FutureBuilder<PlayerInfoData>(
        future: loadInfo(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox(
              height: 120,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final info = snapshot.data;
          if (info == null) {
            return const Text(
              '暂时取不到播放信息',
              style: TextStyle(color: _menuText, fontSize: 13),
            );
          }
          final native = info.native;
          final width = (native?.videoWidth ?? 0) > 0
              ? native!.videoWidth
              : info.fallbackWidth;
          final height = (native?.videoHeight ?? 0) > 0
              ? native!.videoHeight
              : info.fallbackHeight;
          final rows = <(String, String)>[
            (
              '标题',
              info.episodeLabel.isEmpty
                  ? info.seriesTitle
                  : '${info.seriesTitle} ${info.episodeLabel}',
            ),
            ('播放源', info.sourceLabel.isEmpty ? '—' : info.sourceLabel),
            ('播放核', 'ExoPlayer'),
            (
              '解码器',
              (native?.decoderName.isNotEmpty ?? false)
                  ? native!.decoderName
                  : info.decoderPrefLabel,
            ),
            (
              '分辨率',
              width > 0 && height > 0 ? '${width}x$height' : '—',
            ),
            (
              '帧率',
              (native?.frameRate ?? 0) > 0
                  ? '${native!.frameRate.toStringAsFixed(1)} fps'
                  : '—',
            ),
            (
              '视频编码',
              _joinNonEmpty([
                native?.videoCodecs ?? '',
                native?.videoMimeType ?? '',
              ]),
            ),
            ('视频码率', _formatBitrate(native?.videoBitrate ?? 0)),
            (
              '音频编码',
              _joinNonEmpty([
                native?.audioCodecs ?? '',
                native?.audioMimeType ?? '',
              ]),
            ),
            ('音频码率', _formatBitrate(native?.audioBitrate ?? 0)),
            (
              '采样率',
              (native?.audioSampleRate ?? 0) > 0
                  ? '${native!.audioSampleRate} Hz'
                  : '—',
            ),
            (
              '声道数',
              (native?.audioChannelCount ?? 0) > 0
                  ? '${native!.audioChannelCount}'
                  : '—',
            ),
            ('当前网速', _formatBitrate(native?.bandwidthEstimate ?? 0)),
            (
              '播放进度',
              '${_formatClock(info.position)} / ${_formatClock(info.duration)}',
            ),
            ('播放倍率', '${_trimRate(info.rate)}x'),
            (
              '集数',
              info.episodeCount > 0
                  ? '第 ${info.episodeIndex + 1} 集 / 共 ${info.episodeCount} 集'
                  : '—',
            ),
            ('播放地址', info.sourceUrl.isEmpty ? '—' : info.sourceUrl),
          ];
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (label, value) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 64,
                          child: Text(label, style: _rowValueStyle),
                        ),
                        Expanded(
                          child: SelectableText(
                            value,
                            style: const TextStyle(
                              color: _menuText,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

String _joinNonEmpty(List<String> parts) {
  final kept = parts.where((part) => part.isNotEmpty).toList();
  return kept.isEmpty ? '—' : kept.join(' · ');
}

String _formatBitrate(int bps) {
  if (bps <= 0) return '—';
  if (bps >= 1000000) return '${(bps / 1000000).toStringAsFixed(2)} Mbps';
  if (bps >= 1000) return '${(bps / 1000).toStringAsFixed(0)} Kbps';
  return '$bps bps';
}

String _formatClock(Duration duration) {
  final total = duration.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// 投屏页（SPEC T7）：本批没有投屏协议本体，按参考形态落入口与
/// 空态，文案如实说暂不支持，不假装能投。
Future<void> showPlayerCastSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: _menuBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => const SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 20, 16, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '投屏',
              style: TextStyle(
                color: _menuText,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 24),
            Icon(Icons.cast_connected_outlined, color: _menuSub, size: 40),
            SizedBox(height: 12),
            Text(
              '未发现可用设备',
              textAlign: TextAlign.center,
              style: TextStyle(color: _menuText, fontSize: 14),
            ),
            SizedBox(height: 6),
            Text(
              '当前版本暂不支持投屏，功能开发中。',
              textAlign: TextAlign.center,
              style: TextStyle(color: _menuSub, fontSize: 12.5),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 内核切换页（SPEC T6）：现只有 ExoPlayer 一个核，如实只列它，
/// 不摆假选项。
Future<void> showPlayerKernelSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: _menuBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              '内核切换',
              style: TextStyle(
                color: _menuText,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(child: Text('ExoPlayer', style: _rowLabelStyle)),
                const Text(
                  '当前',
                  style: TextStyle(color: _menuAccent, fontSize: 12.5),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.check, color: _menuAccent, size: 20),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Text(
              '当前版本仅内置 ExoPlayer 一个播放内核。',
              style: TextStyle(color: _menuSub, fontSize: 12.5),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 跳过片头片尾弹窗（SPEC K1–K4）：秒数直填 + 快捷胶囊，清除/取消/
/// 确定。保存口径沿用播放页既有按剧持久化，返回值 (片头, 片尾)。
Future<(int, int)?> showSkipSettingsDialog(
  BuildContext context, {
  required int introSeconds,
  required int outroSeconds,
}) {
  return showDialog<(int, int)>(
    context: context,
    builder: (dialogContext) => _SkipSettingsDialog(
      introSeconds: introSeconds,
      outroSeconds: outroSeconds,
    ),
  );
}

class _SkipSettingsDialog extends StatefulWidget {
  const _SkipSettingsDialog({
    required this.introSeconds,
    required this.outroSeconds,
  });

  final int introSeconds;
  final int outroSeconds;

  @override
  State<_SkipSettingsDialog> createState() => _SkipSettingsDialogState();
}

class _SkipSettingsDialogState extends State<_SkipSettingsDialog> {
  late final TextEditingController _intro = TextEditingController(
    text: widget.introSeconds > 0 ? '${widget.introSeconds}' : '',
  );
  late final TextEditingController _outro = TextEditingController(
    text: widget.outroSeconds > 0 ? '${widget.outroSeconds}' : '',
  );

  @override
  void dispose() {
    _intro.dispose();
    _outro.dispose();
    super.dispose();
  }

  int _parse(TextEditingController controller) {
    final value = int.tryParse(controller.text.trim()) ?? 0;
    return value.clamp(0, 3600);
  }

  Widget _field(String label, TextEditingController controller, Key key) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: _sectionStyle),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: key,
                controller: controller,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: _menuText),
                decoration: const InputDecoration(
                  hintText: '0',
                  hintStyle: TextStyle(color: _menuSub),
                  suffixText: '秒',
                  suffixStyle: TextStyle(color: _menuSub),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final seconds in const [30, 60, 90])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ActionChip(
                  label: Text('${seconds}s'),
                  onPressed: () =>
                      setState(() => controller.text = '$seconds'),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _menuBg,
      title: const Text(
        '跳过片头片尾',
        style: TextStyle(color: _menuText, fontSize: 17),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _field('片头', _intro, const ValueKey('skip-intro-field')),
            _field('片尾', _outro, const ValueKey('skip-outro-field')),
            const Text(
              '按本剧保存：起播自动跳过片头，临近片尾自动切下一集。',
              style: TextStyle(color: _menuSub, fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop((0, 0)),
          child: const Text('清除'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop((_parse(_intro), _parse(_outro))),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 字幕设置弹层（SPEC M18）：字号倍率/颜色/位置/描边，写
/// [PlayerMenuPreferences.subtitleStyle]，字幕层监听即时生效。
Future<void> showSubtitleStyleSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: _menuBg,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => const SafeArea(child: _SubtitleStyleSheetBody()),
  );
}

class _SubtitleStyleSheetBody extends StatelessWidget {
  const _SubtitleStyleSheetBody();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SubtitleStyleSettings>(
      valueListenable: PlayerMenuPreferences.subtitleStyle,
      builder: (context, style, _) {
        void update(SubtitleStyleSettings next) =>
            PlayerMenuPreferences.setSubtitleStyle(next);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '字幕设置',
                style: TextStyle(
                  color: _menuText,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('字号', style: TextStyle(color: _menuText)),
                  Expanded(
                    child: Slider(
                      value: style.fontScale,
                      min: 0.5,
                      max: 2,
                      divisions: 15,
                      activeColor: _menuAccent,
                      onChanged: (value) =>
                          update(style.copyWith(fontScale: value)),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${(style.fontScale * 100).round()}%',
                      style: _rowValueStyle,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  const Text('颜色', style: TextStyle(color: _menuText)),
                  const SizedBox(width: 16),
                  for (
                    var i = 0;
                    i < SubtitleStyleSettings.colorLabels.length;
                    i++
                  )
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(SubtitleStyleSettings.colorLabels[i]),
                        selected: style.colorIndex == i,
                        onSelected: (_) =>
                            update(style.copyWith(colorIndex: i)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '显示在上方',
                      style: TextStyle(color: _menuText),
                    ),
                  ),
                  Switch(
                    value: style.positionTop,
                    activeTrackColor: _menuAccent,
                    onChanged: (value) =>
                        update(style.copyWith(positionTop: value)),
                  ),
                ],
              ),
              Row(
                children: [
                  const Expanded(
                    child: Text('描边', style: TextStyle(color: _menuText)),
                  ),
                  Switch(
                    value: style.stroke,
                    activeTrackColor: _menuAccent,
                    onChanged: (value) =>
                        update(style.copyWith(stroke: value)),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 屏显设置弹层（SPEC M10）：时间/网速/进度/标题四开关 + 字号步进，
/// 写 [PlayerMenuPreferences.osd]，顶栏监听即时生效。
Future<void> showOsdSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: _menuBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => const SafeArea(child: _OsdSettingsSheetBody()),
  );
}

class _OsdSettingsSheetBody extends StatelessWidget {
  const _OsdSettingsSheetBody();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlayerOsdSettings>(
      valueListenable: PlayerMenuPreferences.osd,
      builder: (context, osd, _) {
        void update(PlayerOsdSettings next) =>
            PlayerMenuPreferences.setOsd(next);
        Widget switchLine(String label, bool value, ValueChanged<bool> set) {
          return Row(
            children: [
              Expanded(
                child: Text(label, style: _rowLabelStyle),
              ),
              Switch(
                value: value,
                activeTrackColor: _menuAccent,
                onChanged: set,
              ),
            ],
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '屏显设置',
                style: TextStyle(
                  color: _menuText,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              switchLine(
                '时间',
                osd.showTime,
                (v) => update(osd.copyWith(showTime: v)),
              ),
              switchLine(
                '网速',
                osd.showSpeed,
                (v) => update(osd.copyWith(showSpeed: v)),
              ),
              switchLine(
                '分辨率',
                osd.showResolution,
                (v) => update(osd.copyWith(showResolution: v)),
              ),
              switchLine(
                '标题',
                osd.showTitle,
                (v) => update(osd.copyWith(showTitle: v)),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('字体大小', style: TextStyle(color: _menuText)),
                  const Spacer(),
                  IconButton(
                    onPressed: osd.fontSize > 8
                        ? () => update(
                            osd.copyWith(fontSize: osd.fontSize - 1),
                          )
                        : null,
                    icon: const Icon(Icons.remove, color: _menuText),
                  ),
                  SizedBox(
                    width: 32,
                    child: Text(
                      '${osd.fontSize}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: _menuText, fontSize: 14),
                    ),
                  ),
                  IconButton(
                    onPressed: osd.fontSize < 20
                        ? () => update(
                            osd.copyWith(fontSize: osd.fontSize + 1),
                          )
                        : null,
                    icon: const Icon(Icons.add, color: _menuText),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 弹幕加载弹层（SPEC D1–D4）：链接/文件两路走页面回调（页面负责
/// 真加载与合并），D3/D4 的口径写在说明里，不摆假的清除钮——
/// 外部弹幕随切集自动清空，本层只留说明。
Future<void> showDanmakuLoadSheet(
  BuildContext context, {
  VoidCallback? onLoadUrl,
  VoidCallback? onLoadFile,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: _menuBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              '弹幕加载',
              style: TextStyle(
                color: _menuText,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (onLoadUrl != null)
            InkWell(
              onTap: () {
                Navigator.of(sheetContext).pop();
                onLoadUrl();
              },
              child: Container(
                constraints: const BoxConstraints(minHeight: 52),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Icon(Icons.link, color: _menuSub, size: 20),
                    const SizedBox(width: 12),
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('输入 XML 地址', style: _rowLabelStyle),
                        Text('B 站格式弹幕 XML 链接', style: _rowValueStyle),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (onLoadFile != null)
            InkWell(
              onTap: () {
                Navigator.of(sheetContext).pop();
                onLoadFile();
              },
              child: Container(
                constraints: const BoxConstraints(minHeight: 52),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Icon(
                      Icons.folder_open_outlined,
                      color: _menuSub,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('选择本地文件', style: _rowLabelStyle),
                        Text('手机里的 .xml 弹幕文件', style: _rowValueStyle),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Text(
              '加载的弹幕会与本集弹幕合并显示；切换集数后自动清空，'
              '不会写进任何存档。',
              style: TextStyle(color: _menuSub, fontSize: 12.5),
            ),
          ),
        ],
      ),
    ),
  );
}
