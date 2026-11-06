import 'dart:async';

import 'package:flutter/material.dart';

import '../services/cultivation.dart';
import '../services/live_platform.dart';
import '../services/live_sleep_timer.dart';
import '../services/live_sources.dart';
import '../services/live_store.dart';
import '../services/native_player.dart';
import 'live_player_page.dart';
import 'live_status_panel.dart';
import 'mine_page.dart';

/// 直播页：对齐火蚁TV live_screen.dart 的结构与做法。
///
/// 布局：上半内嵌播放器 / 下半列表面板，按 9 : 14 分栏（火蚁TV 的
/// _playbackShare / _listShare）；点视频画面进全屏、双击重试；
/// 下半是当前频道卡 + 收藏/刷新行 + 左平台栏 / 右频道列表。
/// 换源不走横向 chips，走当前卡电视按钮弹出的分组选择框
///（平台源 / 导入源），与火蚁TV 的源选择框一致。
/// 内嵌播放与全屏播放各用一个 NativePlayer：进全屏前先暂停内嵌，
/// 回来再续播，避免两个播放器同时出声。
/// 切到底部别的 tab 时内嵌暂停（LazyIndexedStack 下本页常驻，
/// 靠 TickerMode 判断本 tab 是否可见），切回来再续播。
/// 收藏与睡眠定时是最小本地版：收藏走 SharedPreferences
///（live_store.dart），睡眠定时走纯 Dart 计时器
///（live_sleep_timer.dart），都不依赖账号。
class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  static const _importedSource = LiveSource(
    id: 'imported',
    name: '导入的频道',
    description: '用户导入的 m3u',
    protocol: LiveProtocol.list,
  );
  static const _favouritesId = '__favourites';
  static const _pageSize = 60;

  List<LiveChannel> _importedChannels = const [];
  bool _importLoading = true;
  String? _importError;

  final _store = LiveStore.instance;
  final _sleepTimer = LiveSleepTimer.instance;

  LiveSource _source = LiveSources.builtin.first;
  List<LivePlatform> _platforms = const [];
  String _group = '';
  List<LiveChannel> _allChannels = const [];
  List<LiveChannel> _channels = const [];
  int _page = 1;
  bool _hasMore = false;
  ({String group, List<LiveChannel> channels})? _lastGood;
  int _index = 0;
  bool _loading = false;
  String? _error;
  int _loadGeneration = 0;

  NativePlayer? _player;
  List<StreamSubscription<dynamic>> _subs = [];
  int _playerGeneration = 0;
  bool _initVideo = true;
  String? _playerError;
  bool _tabVisible = true;
  bool _fullscreenOpened = false;

  LiveChannel? get _channel => _channels.isEmpty
      ? null
      : _channels[_index.clamp(0, _channels.length - 1)];

  List<({String id, String name, int count})> get _entries => [
    (id: _favouritesId, name: '收藏', count: _store.favourites.length),
    for (final platform in _platforms)
      (id: platform.id, name: platform.name, count: platform.count),
  ];

  String get _groupName =>
      _entries
          .where((entry) => entry.id == _group)
          .map((entry) => entry.name)
          .firstOrNull ??
      '直播';

  String _numberFor(int index, LiveChannel channel) =>
      channel.number.isEmpty
      ? (index + 1).toString().padLeft(3, '0')
      : channel.number;

  void _pauseInline() {
    unawaited(_player?.pause());
  }

  // 睡眠定时到期时调的暂停动作：存成字段，dispose 时按身份比对清掉。
  late final VoidCallback _pauseInlineHandler = _pauseInline;

  @override
  void initState() {
    super.initState();
    CultivationService.instance.snapshotNotifier.addListener(
      _onCultivationChanged,
    );
    _store.addListener(_storeChanged);
    _sleepTimer.addListener(_sleepChanged);
    _sleepTimer.pausePlayback = _pauseInlineHandler;
    unawaited(_store.load());
    LiveSources.loadImportedChannels().then((channels) {
      if (!mounted) return;
      setState(() {
        _importedChannels = channels;
        _importLoading = false;
      });
      if (CultivationService.instance.snapshot.unlockedVideo) {
        unawaited(_loadSource(_source));
      }
    });
  }

  void _onCultivationChanged() {
    if (!mounted) return;
    setState(() {});
    // 刚解锁、且还没拉过任何频道时开始拉默认源。
    if (CultivationService.instance.snapshot.unlockedVideo &&
        _channels.isEmpty &&
        _platforms.isEmpty &&
        _error == null &&
        !_importLoading) {
      unawaited(_loadSource(_source));
    }
  }

  void _storeChanged() {
    if (!mounted) return;
    // 只同步列表内容，不重建播放，否则刚点开的频道会被重置回第一条。
    setState(() {
      if (_group == _favouritesId) _channels = _store.favourites;
    });
  }

  void _sleepChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible == _tabVisible) return;
    _tabVisible = visible;
    if (!visible) {
      unawaited(_player?.pause());
    } else {
      _sleepTimer.pausePlayback = _pauseInlineHandler;
      if (!_fullscreenOpened) {
        _resumeInline();
      }
    }
  }

  void _resumeInline() {
    if (_channels.isEmpty) return;
    if (_sleepTimer.sleepPaused) return;
    if (_player == null || _playerError != null) {
      unawaited(_loadInline(_index));
    } else {
      unawaited(_player?.play());
    }
  }

  @override
  void dispose() {
    CultivationService.instance.snapshotNotifier.removeListener(
      _onCultivationChanged,
    );
    _store.removeListener(_storeChanged);
    _sleepTimer.removeListener(_sleepChanged);
    if (_sleepTimer.pausePlayback == _pauseInlineHandler) {
      _sleepTimer.pausePlayback = null;
    }
    _teardownPlayer();
    super.dispose();
  }

  Future<void> _importDialog() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入 m3u 直播源'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'm3u 地址',
            hintText: 'https://…/playlist.m3u',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (url == null || url.trim().isEmpty || !mounted) return;
    try {
      final channels = await LiveSources.importM3uUrl(url);
      if (!mounted) return;
      setState(() {
        _importedChannels = channels;
        _importError = null;
      });
      unawaited(_loadSource(_importedSource));
    } catch (e) {
      if (mounted) setState(() => _importError = e.toString());
    }
  }

  Future<void> _loadSource(LiveSource source) async {
    final generation = ++_loadGeneration;
    _teardownPlayer();
    setState(() {
      _source = source;
      _loading = true;
      _error = null;
      _platforms = const [];
      _group = '';
      _allChannels = const [];
      _channels = const [];
      _page = 1;
      _hasMore = false;
      _lastGood = null;
      _index = 0;
      _playerError = null;
      _initVideo = true;
    });
    try {
      if (source.protocol == LiveProtocol.list) {
        final channels = source.id == 'imported'
            ? _importedChannels
            : await LiveSources.loadBuiltinListChannels(source);
        if (!mounted || generation != _loadGeneration) return;
        setState(() {
          _allChannels = channels;
          _page = 1;
          _loading = false;
        });
        _applyPage();
        if (channels.isNotEmpty) unawaited(_loadInline(0));
        return;
      }
      await _loadPlatforms(generation: generation);
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _loadPlatforms({int? generation, String keepGroup = ''}) async {
    final source = _source;
    final gen = generation ?? ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
      _platforms = const [];
      _channels = const [];
      _allChannels = const [];
      _group = '';
      _lastGood = null;
      _page = 1;
      _hasMore = false;
    });
    try {
      final platforms = await fetchPingtaiPlatforms(source);
      if (!mounted || gen != _loadGeneration) return;
      if (platforms.isEmpty) throw StateError('该直播源没有可用分类');
      setState(() {
        _platforms = platforms;
        _loading = false;
      });
      final target =
          keepGroup.isNotEmpty &&
              platforms.any((platform) => platform.id == keepGroup)
          ? keepGroup
          : platforms.first.id;
      await _loadChannels(target);
    } catch (error) {
      if (!mounted || gen != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  /// 列表型源（m3u）取数接口没有分页参数：整表一次拉回，
  /// 按 60 条一页展示追加，与火蚁TV 的滚动续载行为一致。
  void _applyPage() {
    setState(() {
      _channels = _allChannels.take(_page * _pageSize).toList();
      _hasMore =
          _source.paginated && _allChannels.length > _page * _pageSize;
    });
  }

  Future<void> _loadChannels(String id, {bool append = false}) async {
    final source = _source;
    if (id == _favouritesId) {
      _loadGeneration++;
      final channels = _store.favourites;
      _lastGood = (group: id, channels: channels);
      // 切到收藏只换列表，不打断正在播放的频道。
      setState(() {
        _group = id;
        _allChannels = channels;
        _channels = channels;
        _error = null;
        _loading = false;
        _page = 1;
        _hasMore = false;
      });
      return;
    }
    final platform = _platforms.where((entry) => entry.id == id).firstOrNull;
    if (platform == null) return;
    if (append && !_hasMore) return;
    if (!append && id == _group) return;
    if (!append) _lastGood = (group: _group, channels: _channels);
    final gen = _loadGeneration;
    setState(() {
      _group = id;
      _error = null;
      if (!append) {
        _loading = true;
        _hasMore = false;
        _page = 1;
        _channels = const [];
        _allChannels = const [];
      }
    });
    try {
      final channels = await fetchPingtaiChannels(source, platform);
      if (!mounted || gen != _loadGeneration) return;
      if (!append) _lastGood = (group: id, channels: channels);
      setState(() {
        _allChannels = channels;
        _page = 1;
        _loading = false;
      });
      _applyPage();
      if (!append && channels.isNotEmpty) unawaited(_loadInline(0));
    } catch (error) {
      if (!mounted || gen != _loadGeneration) return;
      final restore = _lastGood;
      final fallback =
          !append && restore != null && restore.channels.isNotEmpty;
      setState(() {
        _loading = false;
        if (fallback) {
          _group = restore.group;
          _allChannels = restore.channels;
          _channels = restore.channels;
          _error = null;
        } else {
          _error = error.toString();
        }
      });
      if (fallback && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${platform.name} 暂时不可用，已保留原分类')),
        );
      }
    }
  }

  /// 手动刷新：强制重新抓取直播分类与当前分类的频道列表。
  Future<void> _refreshLive() async {
    if (_loading) return;
    if (_group == _favouritesId) {
      setState(() => _channels = _store.favourites);
      return;
    }
    await _loadPlatforms(keepGroup: _group);
  }

  Future<void> _pickSource() async {
    final sources = [
      ...LiveSources.builtin,
      if (_importedChannels.isNotEmpty) _importedSource,
    ];
    final builtin = [
      for (final source in sources)
        if (source.id != 'imported') source,
    ];
    final imported = [
      for (final source in sources)
        if (source.id == 'imported') source,
    ];
    final grouped = builtin.isNotEmpty && imported.isNotEmpty;
    final picked = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('切换直播源'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (grouped) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text(
                    '平台源',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
              for (final source in builtin)
                ListTile(
                  title: Text(source.name),
                  trailing: source.id == _source.id
                      ? Icon(
                          Icons.check,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () => Navigator.pop(dialogContext, source.id),
                ),
              if (imported.isNotEmpty) ...[
                if (grouped)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text(
                      '导入源',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                for (final source in imported)
                  ListTile(
                    title: Text(source.name),
                    trailing: source.id == _source.id
                        ? Icon(
                            Icons.check,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : null,
                    onTap: () => Navigator.pop(dialogContext, source.id),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final source = sources.where((item) => item.id == picked).firstOrNull;
    if (source != null && source.id != _source.id) {
      unawaited(_loadSource(source));
    }
  }

  void _selectChannel(int index) {
    if (index < 0 || index >= _channels.length) return;
    unawaited(_loadInline(index));
  }

  Future<void> _openFullscreen() async {
    if (_channels.isEmpty || !mounted) return;
    await _player?.pause();
    if (!mounted) return;
    _fullscreenOpened = true;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => LivePlayerPage(
          channels: _channels,
          startIndex: _index,
          source: _source,
        ),
      ),
    );
    _fullscreenOpened = false;
    if (!mounted) return;
    _sleepTimer.pausePlayback = _pauseInlineHandler;
    // 全屏页内可能换了频道，内嵌播回自己当前频道。
    if (_tabVisible) _resumeInline();
  }

  Future<void> _loadInline(int index) async {
    if (_channels.isEmpty) return;
    _sleepTimer.clearSleepPaused();
    final generation = ++_playerGeneration;
    final channel = _channels[index.clamp(0, _channels.length - 1)];
    _teardownPlayer();
    setState(() {
      _index = index.clamp(0, _channels.length - 1);
      _initVideo = true;
      _playerError = null;
    });
    final player = NativePlayer();
    _player = player;
    _subscribe(player, generation);
    try {
      // 平台房间地址是明文 http FLV：直接给 ExoPlayer 会被 App 的明文
      // 策略拦掉（列表能拉、一点播就失败），先走本地中继转成 127.0.0.1。
      final playUrl = await playableLiveUrl(channel.url);
      await player.create(playUrl, '');
      if (!_isCurrentPlayer(generation, player)) {
        await player.dispose();
        return;
      }
      if (player.lastError case final Object error) throw error;
      await player.play();
      if (!_isCurrentPlayer(generation, player)) return;
      if (mounted) setState(() {});
    } catch (error) {
      if (!_isCurrentPlayer(generation, player)) return;
      if (mounted) {
        setState(() {
          _playerError = error.toString();
          _initVideo = false;
        });
      }
    }
  }

  bool _isCurrentPlayer(int generation, NativePlayer player) =>
      mounted && generation == _playerGeneration && identical(_player, player);

  void _subscribe(NativePlayer player, int generation) {
    _subs = [
      player.textureIdStream.listen((_) {
        if (_isCurrentPlayer(generation, player) && mounted) setState(() {});
      }),
      player.firstFrameStream.listen((_) {
        if (_isCurrentPlayer(generation, player) && mounted) {
          setState(() => _initVideo = false);
        }
      }),
      player.bufferingStream.listen((_) {
        if (_isCurrentPlayer(generation, player) && mounted) setState(() {});
      }),
      player.videoSizeStream.listen((_) {
        if (_isCurrentPlayer(generation, player) && mounted) setState(() {});
      }),
      player.errorStream.listen((error) {
        if (_isCurrentPlayer(generation, player) && mounted) {
          setState(() {
            _playerError = error.toString();
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

  Future<void> _showSleepTimer() async {
    await showLiveSleepTimerDialog(context);
    if (mounted) setState(() {});
  }

  /// 未到元婴期时的上锁页：不露源名与频道，只写还差多少修为。
  /// 直播里的成人源与影视区一样按修为解锁：修为不到不显示，
  /// 修为到了才列出来。
  Widget _lockedBody(BuildContext context) {
    final snapshot = CultivationService.instance.snapshot;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 48),
            const SizedBox(height: 16),
            const Text(
              '直播源需要元婴期',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '还差 ${snapshot.xpToVideoZone} 修为（约 ${snapshot.episodesToVideoZone} 集短剧）解锁，修为到了自动显示直播源。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const MinePage()),
              ),
              child: const Text('去我的页看进度'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 直播内置源全是成人，元婴期（3000 修为）解锁；修为不到不显示，
    // 修为到了才列出来。
    final unlocked = CultivationService.instance.snapshot.unlockedVideo;
    return Scaffold(
      appBar: AppBar(
        title: const Text('直播'),
        actions: [
          if (unlocked)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: '导入 m3u',
              onPressed: _importDialog,
            ),
        ],
      ),
      body: !unlocked
          ? _lockedBody(context)
          : _importLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(flex: 9, child: _videoArea()),
                Expanded(flex: 14, child: _panel()),
              ],
            ),
    );
  }

  Widget _videoArea() {
    final channel = _channel;
    final player = _player;
    final texture = player?.textureId;
    final waiting =
        _initVideo ||
        texture == null ||
        player == null ||
        !player.firstFrameRendered ||
        player.videoWidth <= 0 ||
        player.videoHeight <= 0;
    return ColoredBox(
      key: const ValueKey('live-stage'),
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Stack(
            fit: StackFit.expand,
            children: [
              if (texture != null)
                RotatedBox(
                  quarterTurns: player!.videoRotationCorrection ~/ 90,
                  child: Texture(
                    key: const ValueKey('live-inline-texture'),
                    textureId: texture,
                  ),
                ),
              if (_playerError == null &&
                  !_loading &&
                  channel == null &&
                  _channels.isEmpty)
                const Center(
                  child: Text(
                    '选择频道开始播放',
                    style: TextStyle(color: Color(0xFF8B8F99), fontSize: 12),
                  ),
                ),
            ],
          ),
          // 点画面进全屏、双击重试：这层手势盖在视频上、控制条之下，
          // 所以暂停/全屏/收藏按钮先响应，不会被抢点击；报错时不盖，
          // 报错卡片自己的重试按钮先响应。
          if (_playerError == null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _openFullscreen,
                onDoubleTap: () {
                  if (_channels.isNotEmpty) {
                    unawaited(_loadInline(_index));
                  }
                },
                child: const SizedBox.expand(),
              ),
            ),
          if (_playerError != null)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: .82),
                child: Theme(
                  data: ThemeData.dark(),
                  child: LiveStatusPanel(
                    title: '直播暂时中断',
                    message: _playerError!,
                    icon: Icons.wifi_off_rounded,
                    action: '重新连接',
                    onRetry: () {
                      if (_channels.isNotEmpty) {
                        unawaited(_loadInline(_index));
                      }
                    },
                  ),
                ),
              ),
            )
          else if (_loading || waiting || player.buffering)
            const Center(
              child: SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            ),
          if (channel != null && _playerError == null)
            Align(
              alignment: Alignment.bottomCenter,
              child: _nowPlaying(channel),
            ),
        ],
      ),
    );
  }

  Widget _nowPlaying(LiveChannel channel) {
    final favourite = _store.isFavourite(channel.key);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xB3000000), Color(0x00000000)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 4, 4),
        child: Row(
          children: [
            Text(
              _numberFor(_index, channel),
              style: const TextStyle(
                color: Color(0xB3FFFFFF),
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              channel.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (channel.subtitle.isNotEmpty) ...[
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  channel.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xB3FFFFFF),
                    fontSize: 12,
                  ),
                ),
              ),
            ] else
              const Spacer(),
            if (channel.urls.length > 1)
              Text(
                '线路 ${channel.urls.length}',
                style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 12),
              ),
            IconButton(
              key: const ValueKey('live-sleep-timer'),
              visualDensity: VisualDensity.compact,
              tooltip: _sleepTimer.active
                  ? '睡眠定时 · ${_sleepTimer.label}'
                  : '睡眠定时',
              onPressed: _showSleepTimer,
              icon: const Icon(
                Icons.bedtime_outlined,
                size: 20,
                color: Colors.white,
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '全屏与旋转',
              onPressed: _openFullscreen,
              icon: const Icon(
                Icons.screen_rotation_alt_rounded,
                size: 20,
                color: Colors.white,
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: favourite ? '取消收藏' : '收藏频道',
              onPressed: () => unawaited(_store.toggleFavourite(channel)),
              icon: Icon(
                favourite ? Icons.star_rounded : Icons.star_border_rounded,
                size: 20,
                color: favourite
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _panel() => Column(
    children: [
      _currentCard(),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: TextButton.icon(
                key: const ValueKey('live-favourites-button'),
                onPressed: () => unawaited(_loadChannels(_favouritesId)),
                icon: Icon(
                  _group == _favouritesId
                      ? Icons.star_rounded
                      : Icons.star_border_rounded,
                ),
                label: Text('直播收藏（${_store.favourites.length}）'),
              ),
            ),
            if (_group == _favouritesId)
              TextButton.icon(
                key: const ValueKey('live-categories-button'),
                onPressed: () => unawaited(_loadPlatforms()),
                icon: const Icon(Icons.list_rounded),
                label: const Text('直播分类'),
              ),
            IconButton(
              key: const ValueKey('live-refresh-button'),
              tooltip: '刷新直播',
              onPressed: _loading ? null : _refreshLive,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
      ),
      if (_importError != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            _importError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      Expanded(child: _lists()),
    ],
  );

  Widget _currentCard() {
    final theme = Theme.of(context);
    final channel = _channel;
    final logo = channel?.logo ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          height: 86,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
            child: Row(
              children: [
                SizedBox(
                  width: 58,
                  height: 58,
                  child: logo.isEmpty
                      ? _logoFallback(theme)
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.network(
                            logo,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => _logoFallback(theme),
                          ),
                        ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        channel?.title ?? _groupName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        _caption(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 46,
                  height: 46,
                  child: IconButton(
                    key: const ValueKey('live-source-button'),
                    tooltip: '切换直播源',
                    onPressed: _pickSource,
                    icon: const Icon(Icons.tv_rounded),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _caption() {
    if (_loading) return '载入中…';
    final channel = _channel;
    if (channel == null) return '${_source.name} · 选择一个频道';
    return '${_source.name} · ${channel.group} · '
        '${_index + 1}/${_channels.length}';
  }

  Widget _logoFallback(ThemeData theme) => Container(
    decoration: BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(10),
    ),
    alignment: Alignment.center,
    child: Text(
      'TV',
      style: theme.textTheme.titleLarge?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  Widget _lists() {
    final error = _error;
    if (_group != _favouritesId &&
        _platforms.isEmpty &&
        error != null &&
        !_loading) {
      return LiveStatusPanel(
        title: '${_source.name} 直播源暂时不可用',
        message: error,
        icon: Icons.wifi_off_rounded,
        onRetry: () => unawaited(_loadPlatforms()),
      );
    }
    final entries = _entries;
    if (entries.isEmpty) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return const LiveStatusPanel(
        title: '没有可用分类',
        message: '可以切换其他直播源。',
        icon: Icons.live_tv_rounded,
      );
    }
    return Row(
      children: [
        Expanded(flex: 31, child: _groupRail(entries)),
        Expanded(flex: 57, child: _channelPane()),
      ],
    );
  }

  Widget _channelPane() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null && _channels.isEmpty) {
      return LiveStatusPanel(
        title: '这个分类暂时不可用',
        message: error,
        icon: Icons.wifi_off_rounded,
        onRetry: () => _loadChannels(_group),
      );
    }
    return _channelList();
  }

  Widget _groupRail(List<({String id, String name, int count})> entries) {
    final theme = Theme.of(context);
    return ListView.builder(
      key: const ValueKey('live-group-rail'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final selected = entry.id == _group;
        return InkWell(
          key: ValueKey('live-group-${entry.id}'),
          onTap: () => unawaited(_loadChannels(entry.id)),
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 2, 6, 2),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
            decoration: BoxDecoration(
              color: selected
                  ? theme.colorScheme.primaryContainer
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              entry.name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _channelList() {
    final theme = Theme.of(context);
    if (_channels.isEmpty) {
      return LiveStatusPanel(
        title: _group == _favouritesId ? '还没有收藏频道' : '没有可用频道',
        message: _group == _favouritesId
            ? '播放时点星标即可加入收藏。'
            : '可以切换其他分类或直播源。',
        icon: Icons.live_tv_rounded,
      );
    }
    final current = _channel;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 600 &&
            _hasMore &&
            _group != _favouritesId) {
          _page++;
          _applyPage();
        }
        return false;
      },
      child: ListView.builder(
        key: const ValueKey('live-channel-list'),
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _channels.length,
        itemBuilder: (context, index) {
          final channel = _channels[index];
          final selected = identical(channel, current);
          return InkWell(
            key: ValueKey('live-channel-$index'),
            onTap: () => _selectChannel(index),
            child: Container(
              margin: const EdgeInsets.fromLTRB(6, 2, 12, 2),
              padding: const EdgeInsets.symmetric(
                vertical: 10,
                horizontal: 10,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? theme.colorScheme.secondaryContainer
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 34,
                    child: Text(
                      _numberFor(index, channel),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: selected
                            ? theme.colorScheme.onSecondaryContainer
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      channel.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        color: selected
                            ? theme.colorScheme.onSecondaryContainer
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
