import 'package:flutter/material.dart';

import '../services/live_platform.dart';
import '../services/live_sources.dart';
import '../widgets/series_detail/moyi_detail_theme.dart';
import 'live_player_page.dart';

/// 打开直播专用播放器：带上整个频道表与当前下标，播放页内可上下切频道、
/// 打开频道列表、切换直播源。不再走通用点播 PlayerPage。
Future<void> openLiveChannel(
  BuildContext context, {
  required List<LiveChannel> channels,
  required int index,
  required LiveSource source,
}) async {
  if (channels.isEmpty || !context.mounted) return;
  Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => LivePlayerPage(
        channels: channels,
        startIndex: index.clamp(0, channels.length - 1),
        source: source,
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
      case LiveProtocol.pingtai:
        return _PingtaiPlatformsPage(source: source);
    }
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.channels,
    required this.index,
    required this.source,
  });

  final List<LiveChannel> channels;
  final int index;
  final LiveSource source;

  @override
  Widget build(BuildContext context) {
    final channel = channels[index];
    return ListTile(
      title: Text(channel.title, style: const TextStyle(color: moyiBodyOnDark)),
      subtitle: channel.subtitle.isEmpty
          ? (channel.group.isEmpty
                ? null
                : Text(
                    channel.group,
                    style: const TextStyle(color: moyiMutedOnDark),
                  ))
          : Text(
              channel.group.isEmpty
                  ? channel.subtitle
                  : '${channel.group} · ${channel.subtitle}',
              style: const TextStyle(color: moyiMutedOnDark),
            ),
      trailing: const Icon(Icons.play_arrow, color: moyiMutedOnDark),
      onTap: () => openLiveChannel(
        context,
        channels: channels,
        index: index,
        source: source,
      ),
    );
  }
}

class _ListChannelsPage extends StatelessWidget {
  const _ListChannelsPage({required this.source});

  final LiveSource source;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(source.name),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        foregroundColor: Colors.white,
      ),
      body: MoyiPageBackground(
        child: FutureBuilder<List<LiveChannel>>(
          future: LiveSources.loadBuiltinListChannels(source),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Text(
                  '频道表加载失败：${snapshot.error}',
                  style: const TextStyle(color: moyiBodyOnDark),
                ),
              );
            }
            final channels = snapshot.data ?? const [];
            if (channels.isEmpty) {
              return const Center(
                child: Text('暂无频道', style: TextStyle(color: moyiBodyOnDark)),
              );
            }
            return ListView.builder(
              itemCount: channels.length,
              itemBuilder: (context, index) => _ChannelTile(
                channels: channels,
                index: index,
                source: source,
              ),
            );
          },
        ),
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
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(source.name),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        foregroundColor: Colors.white,
      ),
      body: MoyiPageBackground(
        child: FutureBuilder<List<LivePlatform>>(
          future: fetchPingtaiPlatforms(source),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Text(
                  '分类加载失败：${snapshot.error}',
                  style: const TextStyle(color: moyiBodyOnDark),
                ),
              );
            }
            final platforms = snapshot.data ?? const [];
            if (platforms.isEmpty) {
              return const Center(
                child: Text('暂无分类', style: TextStyle(color: moyiBodyOnDark)),
              );
            }
            return ListView(
              children: [
                for (final platform in platforms)
                  ListTile(
                    title: Text(
                      platform.name,
                      style: const TextStyle(color: moyiBodyOnDark),
                    ),
                    subtitle: platform.count > 0
                        ? Text(
                            '${platform.count} 个频道',
                            style: const TextStyle(color: moyiMutedOnDark),
                          )
                        : null,
                    trailing: const Icon(
                      Icons.chevron_right,
                      color: moyiMutedOnDark,
                    ),
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
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(platform.name),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        foregroundColor: Colors.white,
      ),
      body: MoyiPageBackground(
        child: FutureBuilder<List<LiveChannel>>(
          future: fetchPingtaiChannels(source, platform),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Text(
                  '频道加载失败：${snapshot.error}',
                  style: const TextStyle(color: moyiBodyOnDark),
                ),
              );
            }
            final channels = snapshot.data ?? const [];
            if (channels.isEmpty) {
              return const Center(
                child: Text(
                  '该分类暂时没有频道',
                  style: TextStyle(color: moyiBodyOnDark),
                ),
              );
            }
            return ListView.builder(
              itemCount: channels.length,
              itemBuilder: (context, index) => _ChannelTile(
                channels: channels,
                index: index,
                source: source,
              ),
            );
          },
        ),
      ),
    );
  }
}
