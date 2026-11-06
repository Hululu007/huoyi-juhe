import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/live_platform.dart';
import '../services/live_sources.dart';
import '../services/native_player.dart';
import '../services/playback_issue.dart';
import '../services/player_system_ui.dart';
import '../widgets/player/player_feedback.dart';

/// 直播专用播放器：不走通用点播 PlayerPage。
///
/// 画面直接用 NativePlayer（与点播同一路原生播放器），只做直播要做的事：
/// 上/下一个频道、频道列表、切换直播源、全屏、静音、后台继续播（切后台不暂停，
/// 原生播放器继续出声；退出本页时才释放播放器）。
/// 直播没有进度条与选集面板，顶栏只显示频道名与「直播中」。
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

  NativePlayer? _player;
  List<StreamSubscription<dynamic>> _subs = [];
  int _generation = 0;
  bool _initVideo = true;
  PlaybackIssue? _error;
  bool _playing = false;
  bool _muted = false;
  // 火蚁TV 的直播播放器一点开就是全屏横屏（直播全屏），本页照此做：
  // 进页即沉浸 + 锁横屏，返回键先退回竖屏、再按退出。
  bool _fullscreen = true;
  bool _controlsVisible = true;
  Timer? _hideTimer;

  LiveChannel get _channel => _channels[_index];

  @override
  void initState() {
    super.initState();
    _channels = widget.channels;
    _index = widget.startIndex.clamp(0, widget.channels.length - 1);
    _source = widget.source;
    unawaited(_loadChannel(_index));
    unawaited(_enterFullscreenSystemUi());
    _scheduleHide();
  }

  Future<void> _loadChannel(int index) async {
    final generation = ++_generation;
    final channel = _channels[index];
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
      await player.create(channel.url, '');
      if (!_isCurrentLoad(generation, player)) {
        await player.dispose();
        return;
      }
      if (player.lastError case final Object error) throw error;
      await player.setVolume(_muted ? 0 : 1);
      if (!_isCurrentLoad(generation, player)) return;
      await player.play();
      if (!_isCurrentLoad(generation, player)) return;
      if (mounted) setState(() {});
    } catch (error) {
      if (!_isCurrentLoad(generation, player)) return;
      if (mounted) {
        setState(() {
          _error = PlaybackIssue.fromError(error);
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
        if (_isCurrentLoad(generation, player) && mounted) setState(() {});
      }),
      player.errorStream.listen((error) {
        if (_isCurrentLoad(generation, player) && mounted) {
          setState(() {
            _error = PlaybackIssue.fromError(error);
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

  void _switchChannel(int index) {
    if (index < 0 || index >= _channels.length || index == _index) return;
    unawaited(_loadChannel(index));
  }

  void _nextChannel() =>
      _switchChannel((_index + 1) % _channels.length);

  void _prevChannel() =>
      _switchChannel((_index - 1 + _channels.length) % _channels.length);

  Future<void> _togglePlay() async {
    final player = _player;
    if (player == null) return;
    if (_playing) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  Future<void> _toggleMute() async {
    final player = _player;
    final muted = !_muted;
    setState(() => _muted = muted);
    if (player != null) {
      try {
        await player.setVolume(muted ? 0 : 1);
      } catch (_) {}
    }
  }

  Future<void> _toggleFullscreen() async {
    final entering = !_fullscreen;
    setState(() {
      _fullscreen = entering;
      _controlsVisible = true;
    });
    if (entering) {
      await _enterFullscreenSystemUi();
      _scheduleHide();
    } else {
      await _exitFullscreenSystemUi();
    }
    if (mounted) setState(() {});
  }

  Future<void> _enterFullscreenSystemUi() async {
    await PlayerSystemUi.hide();
    try {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } catch (_) {}
  }

  Future<void> _exitFullscreenSystemUi() async {
    try {
      await SystemChrome.setPreferredOrientations(
        const <DeviceOrientation>[],
      );
    } catch (_) {}
    await PlayerSystemUi.show();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_fullscreen) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _fullscreen) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleControls() {
    if (!_fullscreen) return;
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  Future<void> _openChannelSheet() async {
    final picked = await showModalBottomSheet<_LivePick>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _LiveChannelSheet(
        source: _source,
        channels: _channels,
        index: _index,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _source = picked.source;
      _channels = picked.channels;
    });
    await _loadChannel(picked.index);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    if (_fullscreen) {
      unawaited(_exitFullscreenSystemUi());
    }
    _teardownPlayer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final channel = _channel;
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && _fullscreen) await _toggleFullscreen();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: _fullscreen
            ? null
            : AppBar(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(channel.title),
                    Text(
                      _source.name,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
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
            if (_fullscreen && _controlsVisible) ...[
              _fullscreenTopBar(channel),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _bottomBar(),
              ),
            ] else if (!_fullscreen)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _bottomBar(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _fullscreenTopBar(LiveChannel channel) {
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
        padding: const EdgeInsets.fromLTRB(8, 12, 16, 24),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: _toggleFullscreen,
              tooltip: '退出全屏',
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    channel.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _source.name,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar() {
    final channel = _channel;
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
            children: [
              const _LiveBadge(),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  channel.group.isEmpty
                      ? channel.title
                      : '${channel.group} · ${channel.title}',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous, color: Colors.white),
                onPressed: _channels.length > 1 ? _prevChannel : null,
                tooltip: '上一个频道',
              ),
              IconButton(
                icon: Icon(
                  _playing ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                  size: 32,
                ),
                onPressed: _togglePlay,
                tooltip: _playing ? '暂停' : '播放',
              ),
              IconButton(
                icon: const Icon(Icons.skip_next, color: Colors.white),
                onPressed: _channels.length > 1 ? _nextChannel : null,
                tooltip: '下一个频道',
              ),
              IconButton(
                icon: Icon(
                  _muted ? Icons.volume_off : Icons.volume_up,
                  color: Colors.white,
                ),
                onPressed: _toggleMute,
                tooltip: _muted ? '取消静音' : '静音',
              ),
              IconButton(
                icon: const Icon(Icons.list, color: Colors.white),
                onPressed: _openChannelSheet,
                tooltip: '频道列表',
              ),
              IconButton(
                icon: Icon(
                  _fullscreen
                      ? Icons.fullscreen_exit
                      : Icons.fullscreen,
                  color: Colors.white,
                ),
                onPressed: _toggleFullscreen,
                tooltip: _fullscreen ? '退出全屏' : '全屏',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _videoArea() {
    final generation = _generation;
    void retry() {
      if (mounted && generation == _generation) {
        unawaited(_loadChannel(_index));
      }
    }

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
          if (_error != null)
            PlayerErrorFeedback(
              key: const ValueKey('live-player-error'),
              issue: _error!,
              onRetry: retry,
              // 报错卡片不滚动：上下滑切频道的手势不再被卡片吃掉。
              scrollable: false,
            ),
          if (_error == null && (waiting || player.buffering))
            PlayerLoadingFeedback(
              key: ValueKey('live-player-loading-$generation'),
              label: '正在加载频道',
              onRetry: retry,
            ),
        ],
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        '直播中',
        style: TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _LivePick {
  const _LivePick({
    required this.source,
    required this.channels,
    required this.index,
  });

  final LiveSource source;
  final List<LiveChannel> channels;
  final int index;
}

/// 频道列表 + 换源：先是当前源的频道（按分组排），顶部一行是三个内置源。
/// 点别的源：列表源直接拉频道表；平台源先列平台，点平台再拉该平台的频道。
/// 点频道才回传给播放页（换源 + 切频道一次完成）。
class _LiveChannelSheet extends StatefulWidget {
  const _LiveChannelSheet({
    required this.source,
    required this.channels,
    required this.index,
  });

  final LiveSource source;
  final List<LiveChannel> channels;
  final int index;

  @override
  State<_LiveChannelSheet> createState() => _LiveChannelSheetState();
}

class _LiveChannelSheetState extends State<_LiveChannelSheet> {
  late LiveSource _source;
  late List<LiveChannel> _channels;
  late int _index;
  List<LivePlatform>? _platforms;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _source = widget.source;
    _channels = widget.channels;
    _index = widget.index;
  }

  Future<void> _switchSource(LiveSource source) async {
    if (source.id == _source.id) return;
    setState(() {
      _loading = true;
      _error = null;
      _platforms = null;
    });
    try {
      if (source.protocol == LiveProtocol.list) {
        final channels = await LiveSources.loadBuiltinListChannels(source);
        if (!mounted) return;
        setState(() {
          _source = source;
          _channels = channels;
          _index = 0;
          _loading = false;
        });
      } else {
        final platforms = await fetchPingtaiPlatforms(source);
        if (!mounted) return;
        setState(() {
          _source = source;
          _platforms = platforms;
          _loading = false;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _openPlatform(LivePlatform platform) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final channels = await fetchPingtaiChannels(_source, platform);
      if (!mounted) return;
      setState(() {
        _channels = channels;
        _index = 0;
        _platforms = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  void _pick(int index) {
    Navigator.pop(
      context,
      _LivePick(source: _source, channels: _channels, index: index),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sources = LiveSources.builtin;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Text(
                    _platforms == null ? '频道' : '选平台',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  if (_platforms != null)
                    TextButton(
                      onPressed: () => setState(() => _platforms = null),
                      child: const Text('返回频道'),
                    ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (final source in sources)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(source.name),
                        selected: source.id == _source.id,
                        onSelected: (_) => _switchSource(source),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '加载失败：$_error',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              )
            else if (_platforms != null)
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: _platforms!.length,
                  itemBuilder: (context, i) {
                    final platform = _platforms![i];
                    return ListTile(
                      title: Text(platform.name),
                      subtitle: platform.count > 0
                          ? Text('${platform.count} 个频道')
                          : null,
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openPlatform(platform),
                    );
                  },
                ),
              )
            else if (_channels.isEmpty)
              const Expanded(
                child: Center(child: Text('暂无频道')),
              )
            else
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: _channels.length,
                  itemBuilder: (context, i) {
                    final channel = _channels[i];
                    final selected =
                        _source.id == widget.source.id && i == _index;
                    return ListTile(
                      title: Text(channel.title),
                      subtitle: channel.group.isEmpty
                          ? null
                          : Text(channel.group),
                      selected: selected,
                      selectedTileColor: Theme.of(
                        context,
                      ).colorScheme.primaryContainer.withValues(alpha: 0.4),
                      trailing: selected
                          ? const Icon(Icons.play_arrow)
                          : null,
                      onTap: () => _pick(i),
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}
