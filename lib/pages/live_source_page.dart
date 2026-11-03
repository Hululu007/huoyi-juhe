import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/live_platform.dart';
import '../services/live_sources.dart';
import 'player_page.dart';

Future<void> openLiveChannel(BuildContext context, LiveChannel channel) async {
  var playUrl = channel.url;
  final needsResolve =
      (channel.sourceId == 'bilibili' || channel.sourceId == 'huya') &&
      channel.token.isNotEmpty;
  if (needsResolve) {
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final resolved = await resolvePlatformPlaybackUrl(channel);
      if (!context.mounted) return;
      Navigator.pop(context);
      if (resolved == null || resolved.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('该直播间暂时取不到播放地址')));
        return;
      }
      playUrl = resolved;
    } catch (error) {
      if (!context.mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('取流失败：$error')));
      return;
    }
  }
  if (!context.mounted) return;
  Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => PlayerPage(
        bookId: playUrl,
        kind: 'video',
        title: channel.title,
        eps: [
          Chapter(itemId: playUrl, title: channel.title, volumeName: ''),
        ],
        startIndex: 0,
        contentLoader: (_) async => {
          'video_url': playUrl,
          'key_hex': '',
          'variants': <Map<String, dynamic>>[],
        },
      ),
    ),
  );
}

class LiveSourceBrowsePage extends StatelessWidget {
  const LiveSourceBrowsePage({super.key, required this.source});

  final LiveSource source;

  @override
  Widget build(BuildContext context) {
    switch (source.protocol) {
      case LiveProtocol.list:
        return _ListChannelsPage(source: source);
      case LiveProtocol.platform:
        return _PlatformListPage(source: source);
      case LiveProtocol.pingtai:
        return _PingtaiPlatformsPage(source: source);
    }
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({required this.channel});

  final LiveChannel channel;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(channel.title),
      subtitle: channel.subtitle.isEmpty
          ? (channel.group.isEmpty ? null : Text(channel.group))
          : Text(
              channel.group.isEmpty
                  ? channel.subtitle
                  : '${channel.group} · ${channel.subtitle}',
            ),
      trailing: const Icon(Icons.play_arrow),
      onTap: () => openLiveChannel(context, channel),
    );
  }
}

class _ListChannelsPage extends StatelessWidget {
  const _ListChannelsPage({required this.source});

  final LiveSource source;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(source.name)),
      body: FutureBuilder<List<LiveChannel>>(
        future: LiveSources.loadBuiltinListChannels(source),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('频道表加载失败：${snapshot.error}'));
          }
          final channels = snapshot.data ?? const [];
          if (channels.isEmpty) {
            return const Center(child: Text('暂无频道'));
          }
          return ListView.builder(
            itemCount: channels.length,
            itemBuilder: (context, index) =>
                _ChannelTile(channel: channels[index]),
          );
        },
      ),
    );
  }
}

class _PlatformListPage extends StatelessWidget {
  const _PlatformListPage({required this.source});

  final LiveSource source;

  @override
  Widget build(BuildContext context) {
    final platforms = livePlatformCategories(source.id);
    return Scaffold(
      appBar: AppBar(title: Text(source.name)),
      body: ListView(
        children: [
          for (final platform in platforms)
            ListTile(
              title: Text(platform.name),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => _PlatformRoomsPage(
                    source: source,
                    platform: platform,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PlatformRoomsPage extends StatefulWidget {
  const _PlatformRoomsPage({required this.source, required this.platform});

  final LiveSource source;
  final LivePlatform platform;

  @override
  State<_PlatformRoomsPage> createState() => _PlatformRoomsPageState();
}

class _PlatformRoomsPageState extends State<_PlatformRoomsPage> {
  final _rooms = <LiveChannel>[];
  var _page = 1;
  var _loading = true;
  var _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPage(1);
  }

  Future<void> _loadPage(int page) async {
    try {
      final rooms = await fetchPlatformRooms(
        widget.source.id,
        widget.platform,
        page,
      );
      if (!mounted) return;
      setState(() {
        if (page == 1) _rooms.clear();
        _rooms.addAll(rooms);
        _page = page;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.platform.name)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _rooms.isEmpty
              ? Center(child: Text('加载失败：$_error'))
              : ListView.builder(
                  itemCount: _rooms.length + 1,
                  itemBuilder: (context, index) {
                    if (index == _rooms.length) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Center(
                          child: _loadingMore
                              ? const CircularProgressIndicator()
                              : TextButton(
                                  onPressed: () {
                                    setState(() => _loadingMore = true);
                                    _loadPage(_page + 1);
                                  },
                                  child: const Text('加载更多'),
                                ),
                        ),
                      );
                    }
                    return _ChannelTile(channel: _rooms[index]);
                  },
                ),
    );
  }
}

class _PingtaiPlatformsPage extends StatelessWidget {
  const _PingtaiPlatformsPage({required this.source});

  final LiveSource source;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(source.name)),
      body: FutureBuilder<List<LivePlatform>>(
        future: fetchPingtaiPlatforms(source),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('分类加载失败：${snapshot.error}'));
          }
          final platforms = snapshot.data ?? const [];
          if (platforms.isEmpty) {
            return const Center(child: Text('暂无分类'));
          }
          return ListView(
            children: [
              for (final platform in platforms)
                ListTile(
                  title: Text(platform.name),
                  subtitle: platform.count > 0
                      ? Text('${platform.count} 个频道')
                      : null,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => _PingtaiChannelsPage(
                        source: source,
                        platform: platform,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _PingtaiChannelsPage extends StatelessWidget {
  const _PingtaiChannelsPage({required this.source, required this.platform});

  final LiveSource source;
  final LivePlatform platform;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(platform.name)),
      body: FutureBuilder<List<LiveChannel>>(
        future: fetchPingtaiChannels(source, platform),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('频道加载失败：${snapshot.error}'));
          }
          final channels = snapshot.data ?? const [];
          if (channels.isEmpty) {
            return const Center(child: Text('该分类暂时没有频道'));
          }
          return ListView.builder(
            itemCount: channels.length,
            itemBuilder: (context, index) =>
                _ChannelTile(channel: channels[index]),
          );
        },
      ),
    );
  }
}
