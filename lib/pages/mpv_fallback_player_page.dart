import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/media_item.dart' show Chapter;
import '../services/app_log.dart';
import '../services/episode_source_cache.dart';

/// 影视区专属 MPV 兜底播放页（精简版，不搬火蚁TV整套播放器）。
///
/// 只在一种情况下进来：影视区原生播放器（Media3）播失败，且失败原因
/// 是 PlaybackIssue.decoding（格式不支持 / 解码失败，见
/// `player_page.dart` 的 `_maybeOpenMpvFallback`）。网络、超时、取流
/// 失败不走这里——换 MPV 也播不了。短剧区不进这里。
///
/// 取流复用调用方传进来的 [contentLoader]（与 PlayerPage 同一个回调，
/// 即 `openDramaSitePlayback` 的 `resolveSource`）：返回的 map 经
/// [EpisodeSource.fromResponse] 解析；头已由本地媒体代理 bake 进地址，
/// 这里只打开地址本身，不另拼 header。
///
/// 带密钥的流（`keyHex` 非空）MPV 播不了：密钥只给原生层专用解密读
/// 取器用，MPV 拿不到解密后的字节；这种情况如实报错，不静默黑屏。
/// 竖屏沿用现有雏形：取流响应 / 目录的 `vertical` 为真时竖屏播，
/// 不显示全屏（横屏）按钮；否则可切横屏全屏。
class MpvFallbackPlayerPage extends StatefulWidget {
  const MpvFallbackPlayerPage({
    super.key,
    required this.title,
    required this.eps,
    required this.startIndex,
    required this.contentLoader,
    this.fallbackReason = '',
  });

  final String title;
  final List<Chapter> eps;
  final int startIndex;

  /// 与 PlayerPage 的 contentLoader 同形：入参一集，出参取流 map。
  final Future<Map<String, dynamic>> Function(Chapter) contentLoader;

  /// 触发兜底的原生失败原因（`_fail` 里记下的 issue / 错误码 / 状态码），
  /// 只展示，不参与判定。
  final String fallbackReason;

  @override
  State<MpvFallbackPlayerPage> createState() => _MpvFallbackPlayerPageState();
}

class _MpvFallbackPlayerPageState extends State<MpvFallbackPlayerPage> {
  late final Player _player;
  late final VideoController _controller;
  late int _index;
  bool _loading = true;
  String? _error;
  bool _playing = false;
  bool _isVertical = false;
  bool _fullScreen = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  final List<StreamSubscription<dynamic>> _subs = [];
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    MediaKit.ensureInitialized();
    _index = widget.eps.isEmpty
        ? 0
        : widget.startIndex.clamp(0, widget.eps.length - 1);
    _player = Player();
    _controller = VideoController(_player);
    _subs.addAll([
      _player.stream.playing.listen((value) {
        if (mounted) setState(() => _playing = value);
      }),
      _player.stream.position.listen((value) {
        if (mounted) setState(() => _position = value);
      }),
      _player.stream.duration.listen((value) {
        if (mounted) setState(() => _duration = value);
      }),
      _player.stream.completed.listen((completed) {
        if (completed == true) _playNext();
      }),
      _player.stream.error.listen((error) {
        if (!mounted || _error != null) return;
        AppLog.w('mpv-fallback', 'mpv error: $error');
        setState(() {
          _error = 'MPV 播放失败，请返回重试或换一集';
          _loading = false;
        });
      }),
    ]);
    unawaited(_openEpisode(_index));
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    unawaited(_player.dispose());
    unawaited(
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
    super.dispose();
  }

  Future<void> _openEpisode(int index) async {
    if (widget.eps.isEmpty) return;
    final generation = ++_generation;
    final episode = widget.eps[index];
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    EpisodeSource source;
    try {
      final response = await widget.contentLoader(episode);
      source = EpisodeSource.fromResponse(response);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      AppLog.w('mpv-fallback', 'resolve failed: $error');
      setState(() {
        _error = '取流失败，请返回重试';
        _loading = false;
      });
      return;
    }
    if (!mounted || generation != _generation) return;
    if (source.keyHex.isNotEmpty) {
      // 加密流：原生层靠 keyHex 解，MPV 没有这条解密路，如实报，不硬播。
      setState(() {
        _error = '该集为加密流，MPV 无法播放，请返回用原播放器重试';
        _loading = false;
      });
      return;
    }
    final vertical = source.vertical ?? episode.vertical ?? false;
    setState(() => _isVertical = vertical);
    if (vertical && _fullScreen) {
      // 竖屏集不进横屏全屏。
      await _exitFullScreen();
    }
    try {
      await _player.open(Media(source.url), play: true);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      AppLog.w('mpv-fallback', 'open failed: $error');
      setState(() {
        _error = 'MPV 播放失败，请返回重试或换一集';
        _loading = false;
      });
      return;
    }
    if (!mounted || generation != _generation) return;
    setState(() => _loading = false);
  }

  void _playNext() {
    if (_index + 1 >= widget.eps.length) return;
    unawaited(_openEpisode(_index + 1));
  }

  void _playPrevious() {
    if (_index <= 0) return;
    unawaited(_openEpisode(_index - 1));
  }

  Future<void> _enterFullScreen() async {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (mounted) setState(() => _fullScreen = true);
  }

  Future<void> _exitFullScreen() async {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (mounted) setState(() => _fullScreen = false);
  }

  void _toggleFullScreen() {
    if (_fullScreen) {
      unawaited(_exitFullScreen());
    } else {
      unawaited(_enterFullScreen());
    }
  }

  void _openEpisodeSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '选集',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.eps.length,
                itemBuilder: (_, i) {
                  final episode = widget.eps[i];
                  final selected = i == _index;
                  return ListTile(
                    title: Text(
                      episode.title.isEmpty ? '第${i + 1}集' : episode.title,
                      style: TextStyle(
                        color: selected ? Colors.amber : Colors.white,
                      ),
                    ),
                    trailing: selected
                        ? const Icon(Icons.play_arrow, color: Colors.amber)
                        : null,
                    onTap: () {
                      Navigator.pop(sheetContext);
                      if (i != _index) unawaited(_openEpisode(i));
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _format(Duration value) {
    final total = value.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) return '$hours:$mm:$ss';
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final episode = widget.eps.isEmpty ? null : widget.eps[_index];
    final episodeLabel = episode == null
        ? ''
        : (episode.title.isEmpty ? '第${_index + 1}集' : episode.title);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _fullScreen
          ? null
          : AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Text(
                widget.title.isEmpty ? episodeLabel : widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: Chip(
                    label: Text('MPV 兜底', style: TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
      body: SafeArea(
        top: !_fullScreen,
        bottom: !_fullScreen,
        child: Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_error == null)
                    Video(
                      controller: _controller,
                      fit: BoxFit.contain,
                      wakelock: true,
                      controls: (state) => const SizedBox.shrink(),
                    ),
                  if (_loading && _error == null)
                    const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  if (_error != null)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline,
                              color: Colors.white70,
                              size: 40,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white),
                            ),
                            if (widget.fallbackReason.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                '原播放器失败原因：${widget.fallbackReason}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: () => Navigator.of(context).maybePop(),
                              child: const Text('返回'),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (_error == null) _controls(episodeLabel),
          ],
        ),
      ),
    );
  }

  Widget _controls(String episodeLabel) {
    final maxMs = _duration.inMilliseconds;
    final posMs = _position.inMilliseconds.clamp(0, maxMs);
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                icon: Icon(
                  _playing ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                ),
                onPressed: () => unawaited(_player.playOrPause()),
              ),
              IconButton(
                icon: const Icon(Icons.skip_previous, color: Colors.white),
                onPressed: _index > 0 ? _playPrevious : null,
              ),
              IconButton(
                icon: const Icon(Icons.skip_next, color: Colors.white),
                onPressed: _index + 1 < widget.eps.length
                    ? () => _playNext()
                    : null,
              ),
              Expanded(
                child: Text(
                  episodeLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: _openEpisodeSheet,
                child: const Text(
                  '选集',
                  style: TextStyle(color: Colors.white),
                ),
              ),
              // 竖屏集不给横屏全屏按钮（与 PlayerPage「全屏观看」只在非竖屏时
              // 出现一致）。
              if (!_isVertical)
                IconButton(
                  icon: Icon(
                    _fullScreen
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                    color: Colors.white,
                  ),
                  onPressed: _toggleFullScreen,
                ),
            ],
          ),
          Row(
            children: [
              Text(
                _format(_position),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Expanded(
                child: Slider(
                  value: maxMs > 0 ? posMs.toDouble() : 0,
                  min: 0,
                  max: maxMs > 0 ? maxMs.toDouble() : 1,
                  onChanged: (value) => unawaited(
                    _player.seek(Duration(milliseconds: value.toInt())),
                  ),
                ),
              ),
              Text(
                _format(_duration),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
