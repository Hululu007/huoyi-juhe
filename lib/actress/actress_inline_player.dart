import 'dart:async';

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';

import '../services/native_player.dart' show NativePlayer;
import '../services/player_menu_preferences.dart';
import '../services/player_preferences.dart';

/// 作品详情页内嵌播放器（2026-11-27 用户令：详情页点海报在
/// 页内起播、不跳播放器页，与片库详情页的播放形态对齐）：
/// 海报区原地变播放器，钉在详情页顶部，下方内容照常滚动。
///
/// 只吃一个已备好的可播地址（带请求头的线路在外层先经本地
/// 代理注册成裸地址再递进来）；自带播放/暂停键、进度条与
/// 失败态（失败原因上屏 + 重试/换线由外层接），加载有总时
/// 限——超时落错误态，不许无限转圈。
///
/// 全屏走片库详情页同款路径（2026-11-27 修复「演员库不能
/// 全屏」）：本控件只带全屏按钮，点按时先销毁自己的播放器
/// （避免与整页播放器两台原生播放器抢解码器，同
/// FilmInlinePlayer 的做法），再把当前进度经 [onFullscreen]
/// 交给外层，外层推整页 PlayerPage 续播；不传 [onFullscreen]
/// 就不出全屏按钮，不留死入口。
class ActressInlinePlayer extends StatefulWidget {
  const ActressInlinePlayer({
    super.key,
    required this.url,
    this.poster = '',
    this.playerFactory,
    this.onPlaybackError,
    this.onFullscreen,
    this.startPosition,
    this.loadTimeout = const Duration(seconds: 30),
  });

  /// 已备好的可播地址（裸直链或本地代理地址）。
  final String url;

  /// 起播前/失败时垫底显示的海报地址。
  final String poster;

  /// 测试注入播放器实现；默认真 NativePlayer。
  final NativePlayer Function()? playerFactory;

  /// 播放出错（原生报错/起播超时）时回调外层（外层可自动
  /// 换下一条已验活线路）；参数是给用户看的原因。
  final void Function(String message)? onPlaybackError;

  /// 全屏：点按时本控件先销毁自有播放器，再把当前播放
  /// 进度交给外层推整页播放器。为空则不显示全屏按钮。
  final void Function(Duration position)? onFullscreen;

  /// 起播位置（从整页播放器退回时续播用）：经原生 create
  /// 的 startMs 下发，零/空则从头播。
  final Duration? startPosition;

  /// 起播总时限：create + 首帧超过它落错误态。
  final Duration loadTimeout;

  @override
  State<ActressInlinePlayer> createState() => _ActressInlinePlayerState();
}

class _ActressInlinePlayerState extends State<ActressInlinePlayer> {
  NativePlayer? _player;
  final _subs = <StreamSubscription<dynamic>>[];
  int? _textureId;
  var _firstFrame = false;
  var _playing = false;
  var _buffering = true;
  var _position = Duration.zero;
  var _duration = Duration.zero;
  String? _error;
  var _stamp = 0;
  Timer? _loadTimer;

  // 照录屏改造批：内嵌面与主播放页同一口径——倍速档（与主播放页
  // 同一份倍率表/落盘值）、长按倍速（倍率走菜单偏好）、控制栏
  // 播放中自动隐藏（隐藏时单击只亮栏、不切播放）。
  double _rate = 1;
  var _controlsVisible = true;
  var _boosting = false;
  Timer? _hideTimer;

  /// 拖动预览比例（拖进度条或横滑画面时非空）：这段时间里进度条与
  /// 时间文字都以它为准，原生每 200ms 回来的位置回声（seek 落地前
  /// 还是旧位置）不许把拇指拽回去；松手才真正 seek 一次（与主播放
  /// 页 chrome 的 `_finishSeek` 同口径）。此前内嵌面没有这一层：
  /// onChanged 每动一下就 seek 一次、回声一到拇指就弹回旧位置，
  /// 真机上就是「拖不动 / 不能滑动快进」。
  double? _scrubFraction;

  /// 横滑起点：先证明横向主导才接管，避免竖着划详情页时误触快进。
  Offset? _swipeOrigin;

  @override
  void initState() {
    super.initState();
    unawaited(_loadRate());
    _start();
  }

  Future<void> _loadRate() async {
    final rate = await PlayerPreferences.loadPlaybackRate();
    if (!mounted) return;
    setState(() => _rate = rate);
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted && _playing && _error == null) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  @override
  void didUpdateWidget(ActressInlinePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _start();
  }

  @override
  void dispose() {
    _stamp++;
    _loadTimer?.cancel();
    _hideTimer?.cancel();
    _teardownPlayer();
    super.dispose();
  }

  void _teardownPlayer() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    final player = _player;
    _player = null;
    if (player != null) unawaited(player.dispose());
  }

  Future<void> _start() async {
    final stamp = ++_stamp;
    _loadTimer?.cancel();
    _teardownPlayer();
    final startAt = widget.startPosition ?? Duration.zero;
    setState(() {
      _textureId = null;
      _firstFrame = false;
      _playing = false;
      _buffering = true;
      _position = startAt;
      _duration = Duration.zero;
      _error = null;
    });
    final factory = widget.playerFactory ?? () => NativePlayer();
    final player = factory();
    _player = player;
    _subs.add(
      player.textureIdStream.listen((id) {
        if (mounted && stamp == _stamp) setState(() => _textureId = id);
      }),
    );
    _subs.add(
      player.firstFrameStream.listen((_) {
        if (!mounted || stamp != _stamp) return;
        _loadTimer?.cancel();
        setState(() => _firstFrame = true);
      }),
    );
    _subs.add(
      player.playingStream.listen((playing) {
        if (mounted && stamp == _stamp) {
          setState(() => _playing = playing);
          if (playing) {
            _scheduleHide();
          } else {
            _hideTimer?.cancel();
            if (!_controlsVisible) setState(() => _controlsVisible = true);
          }
        }
      }),
    );
    _subs.add(
      player.bufferingStream.listen((buffering) {
        if (mounted && stamp == _stamp) {
          setState(() => _buffering = buffering);
        }
      }),
    );
    _subs.add(
      player.positionStream.listen((position) {
        if (mounted && stamp == _stamp) setState(() => _position = position);
      }),
    );
    _subs.add(
      player.durationStream.listen((duration) {
        if (mounted && stamp == _stamp) setState(() => _duration = duration);
      }),
    );
    _subs.add(
      player.errorStream.listen((error) {
        if (!mounted || stamp != _stamp) return;
        _fail('播放失败：${_shortError(error)}', stamp);
      }),
    );
    _loadTimer = Timer(widget.loadTimeout, () {
      if (!mounted || stamp != _stamp || _firstFrame) return;
      _fail('起播超时，这条线路可能已失效', stamp);
    });
    try {
      final textureId = await player.create(
        widget.url,
        '',
        startMs: startAt > Duration.zero ? startAt.inMilliseconds : null,
      );
      if (!mounted || stamp != _stamp) return;
      setState(() {
        _textureId = textureId;
        _playing = player.playing;
        _duration = player.duration;
      });
      await player.play();
      if (_rate != 1) await player.setRate(_rate);
      _showControls();
    } catch (error) {
      if (!mounted || stamp != _stamp) return;
      _fail('起播失败：${_shortError(error)}', stamp);
    }
  }

  void _fail(String message, int stamp) {
    if (!mounted || stamp != _stamp) return;
    _loadTimer?.cancel();
    setState(() {
      _error = message;
      _buffering = false;
    });
    widget.onPlaybackError?.call(message);
  }

  String _shortError(Object error) {
    final text = error.toString().split('\n').first.trim();
    return text.length > 60 ? '${text.substring(0, 60)}…' : text;
  }

  Future<void> _togglePlay() async {
    final player = _player;
    if (player == null || _error != null) return;
    if (_playing) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  /// 单击：控制栏隐藏时只亮栏（不切播放），在屏时才切播放/暂停。
  void _onTap() {
    if (!_controlsVisible) {
      _showControls();
      return;
    }
    unawaited(_togglePlay());
    _scheduleHide();
  }

  /// 倍速档循环（与主播放页同一份倍率表），落盘口径同主播放页。
  Future<void> _cycleRate() async {
    final rates = PlayerPreferences.playbackRates;
    final next = rates[(rates.indexOf(_rate) + 1) % rates.length];
    setState(() => _rate = next);
    await _player?.setRate(next);
    unawaited(PlayerPreferences.savePlaybackRate(next));
    _showControls();
  }

  void _startBoost() {
    if (_boosting || !_playing || _error != null) return;
    _boosting = true;
    unawaited(_player?.setRate(PlayerMenuPreferences.boostRate.value));
  }

  void _endBoost() {
    if (!_boosting) return;
    _boosting = false;
    unawaited(_player?.setRate(_rate));
  }

  /// 当前应显示的进度比例：拖动中以预览为准，否则按真实位置。
  double get _displayFraction {
    final scrub = _scrubFraction;
    if (scrub != null) return scrub;
    final total = _duration.inMilliseconds;
    return total == 0
        ? 0
        : (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  /// 当前应显示的时间：拖动中显示将要跳到的目标时间。
  Duration get _displayPosition {
    final scrub = _scrubFraction;
    if (scrub == null) return _position;
    return Duration(milliseconds: (scrub * _duration.inMilliseconds).round());
  }

  /// 拖动收尾：预览清掉、位置先乐观落到目标、真正 seek 只发一次。
  void _commitScrub() {
    final scrub = _scrubFraction;
    _swipeOrigin = null;
    if (scrub == null) return;
    final target = Duration(
      milliseconds: (scrub * _duration.inMilliseconds).round(),
    );
    setState(() {
      _scrubFraction = null;
      _position = target;
    });
    unawaited(_player?.seek(target));
    _scheduleHide();
  }

  void _cancelScrub() {
    _swipeOrigin = null;
    if (_scrubFraction != null) setState(() => _scrubFraction = null);
    _scheduleHide();
  }

  /// 横滑快进（与主播放页 chrome 同规则：横向位移映射整片时间轴）。
  /// 总时长未知（直播式/未就绪）时不接管，与进度条的禁用门一致。
  void _startSwipeSeek(DragStartDetails details) {
    if (_duration <= Duration.zero || _error != null) return;
    _swipeOrigin = details.localPosition;
    _hideTimer?.cancel();
    if (!_controlsVisible) setState(() => _controlsVisible = true);
  }

  void _updateSwipeSeek(DragUpdateDetails details) {
    final origin = _swipeOrigin;
    if (origin == null) return;
    if (_scrubFraction == null) {
      final dx = details.localPosition.dx - origin.dx;
      final dy = details.localPosition.dy - origin.dy;
      if (dx.abs() < kTouchSlop || dx.abs() < dy.abs()) return;
    }
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    setState(
      () => _scrubFraction = (details.localPosition.dx / width).clamp(
        0.0,
        1.0,
      ),
    );
  }

  /// 全屏（同 FilmInlinePlayer 的交接法）：先把自有播放器
  /// 销毁，再把当前进度交给外层推整页播放器——整页播放器
  /// 会另建一台原生实例，两台并存会抢解码器。交接后本控件
  /// 回到海报垫底态，外层随即卸载本控件并推页。
  void _openFullscreen() {
    final callback = widget.onFullscreen;
    if (callback == null || _error != null) return;
    final position = _position;
    _stamp++;
    _loadTimer?.cancel();
    _teardownPlayer();
    if (mounted) {
      setState(() {
        _textureId = null;
        _firstFrame = false;
        _playing = false;
        _buffering = false;
      });
    }
    callback(position);
  }

  String _clock(Duration value) {
    final total = value.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final textureId = _textureId;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (textureId != null)
            Texture(textureId: textureId)
          else if (widget.poster.isNotEmpty)
            Image.network(
              widget.poster,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          if (_error == null && _firstFrame)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _onTap,
                onLongPressStart: (_) => _startBoost(),
                onLongPressEnd: (_) => _endBoost(),
                onLongPressCancel: _endBoost,
                onHorizontalDragStart: _startSwipeSeek,
                onHorizontalDragUpdate: _updateSwipeSeek,
                onHorizontalDragEnd: (_) => _commitScrub(),
                onHorizontalDragCancel: _cancelScrub,
                // 与片库内嵌面同结构给一层占满子控件（命中更稳）。
                child: const SizedBox.expand(),
              ),
            ),
          if (_boosting)
            const Positioned(
              top: 10,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0x99000000),
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      child: Text(
                        '倍速播放中',
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (!_firstFrame && _error == null)
            const Center(
              child: CircularProgressIndicator(color: Colors.white70),
            ),
          if (_firstFrame && _buffering)
            const Center(
              child: CircularProgressIndicator(color: Colors.white70),
            ),
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: () => unawaited(_start()),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white38),
                      ),
                      child: const Text('重试这条线路'),
                    ),
                  ],
                ),
              ),
            ),
          if (_error == null && _controlsVisible)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xB3000000)],
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(6, 14, 6, 2),
                child: Row(
                  children: [
                    IconButton(
                      key: const ValueKey('inline-player-toggle'),
                      onPressed: () => unawaited(_togglePlay()),
                      icon: Icon(
                        _playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                    Text(
                      _clock(_displayPosition),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        key: const ValueKey('inline-player-seek'),
                        value: _displayFraction,
                        onChangeStart: _duration.inMilliseconds == 0
                            ? null
                            : (value) {
                                _hideTimer?.cancel();
                                setState(() => _scrubFraction = value);
                              },
                        onChanged: _duration.inMilliseconds == 0
                            ? null
                            : (value) {
                                // 拖动中只更新预览，不发 seek：每动一下
                                // 就 seek 一次会把原生侧塞满过期目标，
                                // 位置回声还会把拇指拽回旧位置。
                                setState(() => _scrubFraction = value);
                              },
                        onChangeEnd: _duration.inMilliseconds == 0
                            ? null
                            : (_) => _commitScrub(),
                        activeColor: Colors.white,
                        inactiveColor: Colors.white24,
                      ),
                    ),
                    Text(
                      _clock(_duration),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('inline-player-rate'),
                      onPressed: () => unawaited(_cycleRate()),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(0, 36),
                      ),
                      child: Text(
                        '${_rate == _rate.roundToDouble() ? _rate.toInt() : _rate}x',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    if (widget.onFullscreen != null)
                      IconButton(
                        key: const ValueKey('inline-player-fullscreen'),
                        tooltip: '全屏',
                        onPressed: _openFullscreen,
                        icon: const Icon(
                          Icons.fullscreen_rounded,
                          color: Colors.white,
                          size: 26,
                        ),
                      ),
                    const SizedBox(width: 6),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
