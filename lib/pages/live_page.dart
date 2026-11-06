import 'package:flutter/material.dart';

import '../services/cultivation.dart';
import '../services/live_sources.dart';
import 'live_source_page.dart';
import 'mine_page.dart';

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
    CultivationService.instance.snapshotNotifier.addListener(
      _onCultivationChanged,
    );
    LiveSources.loadImportedChannels().then((channels) {
      if (mounted) {
        setState(() {
          _channels = channels;
          _loading = false;
        });
      }
    });
  }

  void _onCultivationChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    CultivationService.instance.snapshotNotifier.removeListener(
      _onCultivationChanged,
    );
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
        _channels = channels;
        _importError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _importError = e.toString());
    }
  }

  void _play(int index) => openLiveChannel(
    context,
    channels: _channels,
    index: index,
    // 导入的 m3u 不是内置源，播放页内换源时仍可切到三个内置源。
    source: const LiveSource(
      id: 'imported',
      name: '导入的频道',
      description: '用户导入的 m3u',
      protocol: LiveProtocol.list,
    ),
  );

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
                MaterialPageRoute<void>(
                  builder: (_) => const MinePage(),
                ),
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
    final sources = unlocked ? LiveSources.builtin : const <LiveSource>[];
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
          : _loading
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
                    subtitle: Text(source.description),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => LiveSourceBrowsePage(source: source),
                      ),
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
                      '频道点开即用原始播放器播。',
                    ),
                  ),
                for (var i = 0; i < _channels.length; i++)
                  ListTile(
                    title: Text(_channels[i].title),
                    subtitle: _channels[i].group.isEmpty
                        ? null
                        : Text(_channels[i].group),
                    trailing: const Icon(Icons.play_arrow),
                    onTap: () => _play(i),
                  ),
              ],
            ),
    );
  }
}
