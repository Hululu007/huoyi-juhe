import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/live_sources.dart';
import 'player_page.dart';

class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  List<LiveChannel> _channels = const [];
  bool _loading = true;
  String? _importError;

  @override
  void initState() {
    super.initState();
    LiveSources.loadImportedChannels().then((channels) {
      if (mounted) {
        setState(() {
          _channels = channels;
          _loading = false;
        });
      }
    });
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
        _channels = channels;
        _importError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _importError = e.toString());
    }
  }

  void _play(LiveChannel channel) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          bookId: channel.url,
          kind: 'video',
          title: channel.title,
          eps: [
            Chapter(
              itemId: channel.url,
              title: channel.title,
              volumeName: '',
            ),
          ],
          startIndex: 0,
          contentLoader: (_) async => {
            'video_url': channel.url,
            'key_hex': '',
            'variants': <Map<String, dynamic>>[],
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sources = LiveSources.mainTabSources;
    return Scaffold(
      appBar: AppBar(
        title: const Text('直播'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '导入 m3u',
            onPressed: _importDialog,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    '内置直播源',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (final source in sources)
                  ListTile(
                    title: Text(source.name),
                    subtitle: Text(
                      source.id == 'yuhuo_live'
                          ? '${source.description}，暂无频道'
                          : '${source.description}，频道接口待接入',
                    ),
                  ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
                  child: Text(
                    '导入的 m3u 频道',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_importError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      _importError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (_channels.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      '暂无导入频道。点右上角加号粘贴一个 m3u 地址导入，'
                      '频道点开即用原始播放器播。成人直播源不在此页，'
                      '随午夜区接入。',
                    ),
                  ),
                for (final channel in _channels)
                  ListTile(
                    title: Text(channel.title),
                    subtitle: channel.group.isEmpty
                        ? null
                        : Text(channel.group),
                    trailing: const Icon(Icons.play_arrow),
                    onTap: () => _play(channel),
                  ),
              ],
            ),
    );
  }
}
