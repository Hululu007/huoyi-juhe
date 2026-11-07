import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/live_platform.dart';
import '../services/live_sleep_timer.dart';
import '../services/live_sources.dart';
import '../services/live_speed_tracker.dart';
import '../services/native_player.dart';
import '../services/player_system_ui.dart';
import 'live_status_panel.dart';

/// 直播全屏播放页：对齐火蚁TV live_player_screen.dart 的手机端控件层。
///
/// 画面直接用 NativePlayer（与点播同一路原生播放器），只做直播要做的事：
/// 上/下一个频道、频道列表、切换线路、睡眠定时、全屏、方向跟随画面比例。
/// 直播没有进度条与选集面板；顶栏只显示频道名与源名。
/// 控件布局照火蚁TV 复用的点播 PlayerControls（手机端）：
/// 顶栏 [返回 + 标题 + 旋转]，中部 [上一集 / 播放 / 下一集]，
/// 工具行 [睡眠定时 | 倍速 1x | 线路 | 选集]。
/// 方向跟随画面比例：竖屏流全屏仍是竖屏，横屏流全屏是横屏；
/// 用户按过旋转按钮后以手动选择为准，不再自动跟随。
/// 返回键两步走：先退出沉浸式（恢复系统栏），再按退出本页。
class LivePlayerPage extends StatefulWidget {
  const LivePlayerPage({
    super.key,
    required this.channels,
    required this.startIndex,
    required this.source,
  });

  final List<LiveChannel> channels;
  final int startIndex;
  final LiveSource source;

  @override
  State<LivePlayerPage> createState() => _LivePlayerPageState();
}

class _LivePlayerPageState extends State<LivePlayerPage> {
  late List<LiveChannel> _channels;
  late int _index;
  late LiveSource _source;

  final _sleepTimer = LiveSleepTimer.instance;
  final _speedTracker = LiveSpeedTracker();

  NativePlayer? _player;
  List<StreamSubscription<dynamic>> _subs = [];
  int _generation = 0;
  int _route = 0;
  bool _initVideo = true;
  String? _error;
  bool _playing = false;
  bool _controlsVisible = true;
  Timer? _hideTimer;
  bool _panel = false;
  bool _immersed = false;
  bool _landscape = true;
  bool _rotated = false;

  LiveChannel get _channel => _channels[_index];

  void _pauseForSleep() {
    unawaited(_player?.pause());
  }

  // 睡眠定时到期时调的暂停动作：存成字段，dispose 时按身份比对清掉。
  late final VoidCallback _pauseForSleepHandler = _pauseForSleep;

  @override
  void initState() {
    super.initState();
    _channels = widget.channels;
    _index = widget.startIndex.clamp(0, widget.channels.length - 1);
    _source = widget.source;
    _sleepTimer.addListener(_sleepChanged);
    _sleepTimer.pausePlayback = _pauseForSleepHandler;
    unawaited(_loadChannel(_index));
    unawaited(_enterFullscreenSystemUi());
    _scheduleHide();
  }

  void _sleepChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadChannel(int index, {bool keepRoute = false}) async {
    final generation = ++_generation;
    final channel = _channels[index];
    _sleepTimer.clearSleepPaused();
    _speedTracker.reset();
    if (!keepRoute) _route = 0;
    _teardownPlayer();
    setState(() {
      _index = index;
      _initVideo = true;
      _error = null;
      _playing = false;
    });
    final player = NativePlayer();
    _player = player;
    _subscribe(player, generation);
    try {
      // 平台房间地址是明文 http FLV：直接给 ExoPlayer 会被 App 的明文
      // 策略拦掉（列表能拉、一点播就失败），先走本地中继转成 127.0.0.1。
      // 多线路频道按当前线路取地址（火蚁TV playRoute 语义）；单线路
      // 频道 urls 只有一条，_route 恒为 0。
      final route = _route.clamp(0, channel.urls.length - 1);
      final playUrl = await playableLiveUrl(channel.urls[route]);
      await player.create(playUrl, '');
      if (!_isCurrentLoad(generation, player)) {
        await player.dispose();
        return;
      }
      if (player.lastError case final Object error) throw error;
      if (!_isCurrentLoad(generation, player)) return;
      await player.play();
      if (!_isCurrentLoad(generation, player)) return;
      if (mounted) setState(() {});
    } catch (error) {
      if (!_isCurrentLoad(generation, player)) return;
      if (mounted) {
        setState(() {
          _error = error.toString();
          _initVideo = false;
        });
      }
    }
  }

  bool _isCurrentLoad(int generation, NativePlayer player) =>
      mounted && generation == _generation && identical(_player, player);

  void _subscribe(NativePlayer player, int generation) {
    _subs = [
      player.textureIdStream.listen((_) {
        if (_isCurrentLoad(generation, player) && mounted) setState(() {});
      }),
      player.firstFrameStream.listen((_) {
        if (_isCurrentLoad(generation, player) && mounted) {
          setState(() => _initVideo = false);
          _followVideoRatio(player);
        }
      }),
      player.playingStream.listen((playing) {
        if (_isCurrentLoad(generation, player) && mounted) {
          setState(() => _playing = playing);
        }
      }),
      player.bufferingStream.listen((_) {
        if (_isCurrentLoad(generation, player) && mounted) setState(() {});
      }),
      player.videoSizeStream.listen((_) {
        if (_isCurrentLoad(generation, player) && mounted) {
          setState(() {});
          _followVideoRatio(player);
        }
      }),
      player.errorStream.listen((error) {
        if (_isCurrentLoad(generation, player) && mounted) {
          setState(() {
            _error = error.toString();
            _initVideo = false;
          });
        }
      }),
    ];
  }

  void _teardownPlayer() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs = [];
    final player = _player;
    _player = null;
    if (player != null) unawaited(player.dispose());
  }

  /// 全屏方向跟随画面比例：竖屏流全屏仍是竖屏，横屏流全屏是横屏。
  /// 用户按过旋转按钮后以手动选择为准，不再自动跟随。
  void _followVideoRatio(NativePlayer player) {
    if (_rotated) return;
    final width = player.videoWidth;
    final height = player.videoHeight;
    if (width <= 0 || height <= 0) return;
    final landscape = width >= height;
    if (landscape == _landscape) return;
    _landscape = landscape;
    unawaited(_applyOrientation());
  }

  Future<void> _toggleRotate() async {
    _rotated = true;
    setState(() => _landscape = !_landscape);
    await _applyOrientation();
    await PlayerSystemUi.hide();
    _immersed = true;
  }

  Future<void> _applyOrientation() async {
    try {
      await SystemChrome.setPreferredOrientations(
        _landscape
            ? const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : const [
                DeviceOrientation.portraitUp,
                DeviceOrientation.portraitDown,
              ],
      );
    } catch (_) {}
  }

  Future<void> _enterFullscreenSystemUi() async {
    await PlayerSystemUi.hide();
    _immersed = true;
    await _applyOrientation();
  }

  Future<void> _exitFullscreenSystemUi() async {
    try {
      await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);
    } catch (_) {}
    await PlayerSystemUi.show();
    _immersed = false;
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_panel) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  void _showControls() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _scheduleHide();
  }

  void _switchChannel(int index) {
    if (index < 0 || index >= _channels.length || index == _index) return;
    unawaited(_loadChannel(index));
  }

  void _nextChannel() => _switchChannel((_index + 1) % _channels.length);

  void _prevChannel() =>
      _switchChannel((_index - 1 + _channels.length) % _channels.length);

  Future<void> _togglePlay() async {
    final player = _player;
    if (player == null) return;
    _sleepTimer.clearSleepPaused();
    if (_playing) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  Future<void> _showSleepTimer() async {
    _panel = true;
    await showLiveSleepTimerDialog(context);
    _panel = false;
    if (mounted) {
      setState(() {});
      _showControls();
    }
  }

  void _showSpeedToast() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('直播不支持变速'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// 火蚁TV _selectRoute：多线路弹线路选择表，单线路 toast。
  /// 修仙版现有源都只给一条线路，平时走 toast；切线通路与线路表按
  /// 火蚁TV 形态接好，有多条数据的源进来即能用。
  Future<void> _selectRoute() async {
    final channel = _channel;
    if (channel.urls.length < 2) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('当前频道只有一条线路'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    _panel = true;
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xFF1B1B1F),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < channel.urls.length; index++)
              ListTile(
                dense: true,
                leading: const Icon(Icons.route_rounded),
                title: Text(
                  '线路 ${index + 1}',
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () => Navigator.pop(context, index),
              ),
          ],
        ),
      ),
    );
    _panel = false;
    if (!mounted) return;
    setState(() {});
    _showControls();
    if (picked != null && picked != _route) {
      _route = picked;
      unawaited(_loadChannel(_index, keepRoute: true));
    }
  }

  Future<void> _openChannelSheet() async {
    _panel = true;
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xFF1B1B1F),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_source.name} · ${_channels.length} 个频道',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _channels.length,
                itemBuilder: (context, index) {
                  final channel = _channels[index];
                  final selected = index == _index;
                  return ListTile(
                    dense: true,
                    selected: selected,
                    title: Text(
                      channel.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white),
                    ),
                    onTap: () => Navigator.pop(context, index),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    _panel = false;
    if (!mounted) return;
    setState(() {});
    _showControls();
    if (picked != null) _switchChannel(picked);
  }

  void _exit() {
    // 不能用 Navigator.maybePop：本页 PopScope(canPop: false) 会让
    // maybePop 走 onPopInvokedWithResult(false) 而不真正退栈，
    // onPopInvoked 又调回 _liveBack/_exit，形成死循环退不出去。
    // 直接 pop 绕过 canPop 拦截（与 listen_mode_page 的 _exitWithResult
    // 同款做法）；pop 成功后 onPopInvokedWithResult(true) 会再调一次，
    // 被 didPop 守卫挡住，不会重复退栈。
    Navigator.pop(context);
  }

  void _liveBack() {
    if (_immersed) {
      unawaited(PlayerSystemUi.show());
      setState(() => _immersed = false);
      return;
    }
    _exit();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _speedTracker.dispose();
    _sleepTimer.removeListener(_sleepChanged);
    if (_sleepTimer.pausePlayback == _pauseForSleepHandler) {
      _sleepTimer.pausePlayback = null;
    }
    unawaited(_exitFullscreenSystemUi());
    _teardownPlayer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final channel = _channel;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _liveBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              onTap: _toggleControls,
              // 火蚁TV 式上下滑切频道：上滑下一个、下滑上一个。
              onVerticalDragEnd: (details) {
                final velocity = details.primaryVelocity ?? 0;
                if (velocity < -200) {
                  _nextChannel();
                } else if (velocity > 200) {
                  _prevChannel();
                }
              },
              behavior: HitTestBehavior.opaque,
              child: _videoArea(),
            ),
            if (_error != null)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: .82),
                  child: Theme(
                    data: ThemeData.dark(),
                    child: LiveStatusPanel(
                      title: '直播暂时中断',
                      message: _error!,
                      icon: Icons.wifi_off_rounded,
                      action: '重新连接',
                      onRetry: () =>
                          unawaited(_loadChannel(_index, keepRoute: true)),
                      secondaryAction: TextButton(
                        onPressed: _openChannelSheet,
                        child: const Text('换个频道'),
                      ),
                    ),
                  ),
                ),
              )
            else if (_controlsVisible) ...[
              _topBar(channel),
              Positioned(left: 0, right: 0, bottom: 0, child: _bottomBar()),
            ],
          ],
        ),
      ),
    );
  }

  Widget _topBar(LiveChannel channel) {
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black54, Colors.transparent],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 24),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
              onPressed: _exit,
              tooltip: '退出全屏',
            ),
            Expanded(
              child: Text(
                '${channel.title} · ${_source.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
            // 网速：火蚁TV 顶栏的 networkSpeedLabel 位。采样来自 LiveRelay
            // 中继字节（见 live_speed_tracker.dart）；采不到时不显示。
            ValueListenableBuilder<String?>(
              valueListenable: _speedTracker.speedText,
              builder: (context, value, _) {
                if (value == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    value,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                );
              },
            ),
            IconButton(
              icon: const Icon(
                Icons.screen_rotation_alt_rounded,
                color: Colors.white,
              ),
              onPressed: _toggleRotate,
              tooltip: '旋转与全屏',
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 24, 8, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous_rounded, color: Colors.white),
                onPressed: _channels.length > 1 ? _prevChannel : null,
                tooltip: '上一集',
              ),
              const SizedBox(width: 16),
              IconButton(
                icon: Icon(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 32,
                ),
                onPressed: _togglePlay,
                tooltip: _playing ? '暂停播放' : '开始播放',
              ),
              const SizedBox(width: 16),
              IconButton(
                icon: const Icon(Icons.skip_next_rounded, color: Colors.white),
                onPressed: _channels.length > 1 ? _nextChannel : null,
                tooltip: '下一集',
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.bedtime_outlined, color: Colors.white),
                onPressed: _showSleepTimer,
                tooltip: _sleepTimer.active
                    ? '睡眠定时 · ${_sleepTimer.label}'
                    : '睡眠定时',
              ),
              TextButton(
                onPressed: _showSpeedToast,
                child: const Text(
                  '1x',
                  style: TextStyle(color: Colors.white),
                ),
              ),
              TextButton(
                onPressed: _selectRoute,
                child: Text(
                  _channel.urls.length > 1
                      ? '线路 ${_channel.urls.length}'
                      : '线路',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.grid_view_rounded, color: Colors.white),
                onPressed: _openChannelSheet,
                tooltip: '选集',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _videoArea() {
    final player = _player;
    final texture = player?.textureId;
    final waiting =
        _initVideo ||
        texture == null ||
        player == null ||
        !player.firstFrameRendered ||
        player.videoWidth <= 0 ||
        player.videoHeight <= 0;
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (texture != null)
            RotatedBox(
              quarterTurns: player!.videoRotationCorrection ~/ 90,
              child: Texture(
                key: const ValueKey('live-player-texture'),
                textureId: texture,
              ),
            ),
          if (_error == null && (waiting || player.buffering))
            const Center(
              child: SizedBox(
                width: 38,
                height: 38,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            ),
        ],
      ),
    );
  }
}
