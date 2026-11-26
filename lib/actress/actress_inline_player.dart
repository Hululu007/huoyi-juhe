import 'dart:async';

import 'package:flutter/material.dart';

import '../services/native_player.dart' show NativePlayer;

/// 作品详情页内嵌播放器（2026-11-27 用户令：详情页点海报在
/// 页内起播、不跳播放器页，与片库详情页的播放形态对齐）：
/// 海报区原地变播放器，钉在详情页顶部，下方内容照常滚动。
///
/// 只吃一个已备好的可播地址（带请求头的线路在外层先经本地
/// 代理注册成裸地址再递进来）；自带播放/暂停键、进度条与
/// 失败态（失败原因上屏 + 重试/换线由外层接），加载有总时
/// 限——超时落错误态，不许无限转圈。
class ActressInlinePlayer extends StatefulWidget {
  const ActressInlinePlayer({
    super.key,
    required this.url,
    this.poster = '',
    this.playerFactory,
    this.onPlaybackError,
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

  @override
  void initState() {
    super.initState();
    _start();
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
    setState(() {
      _textureId = null;
      _firstFrame = false;
      _playing = false;
      _buffering = true;
      _position = Duration.zero;
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
        if (mounted && stamp == _stamp) setState(() => _playing = playing);
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
      final textureId = await player.create(widget.url, '');
      if (!mounted || stamp != _stamp) return;
      setState(() {
        _textureId = textureId;
        _playing = player.playing;
        _duration = player.duration;
      });
      await player.play();
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
                onTap: () => unawaited(_togglePlay()),
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
          if (_error == null)
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
                      _clock(_position),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        key: const ValueKey('inline-player-seek'),
                        value: _duration.inMilliseconds == 0
                            ? 0
                            : (_position.inMilliseconds /
                                      _duration.inMilliseconds)
                                  .clamp(0.0, 1.0),
                        onChanged: _duration.inMilliseconds == 0
                            ? null
                            : (value) {
                                final target = Duration(
                                  milliseconds:
                                      (value * _duration.inMilliseconds)
                                          .round(),
                                );
                                setState(() => _position = target);
                                unawaited(_player?.seek(target));
                              },
                        activeColor: Colors.white,
                        inactiveColor: Colors.white24,
                      ),
                    ),
                    Text(
                      _clock(_duration),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
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
