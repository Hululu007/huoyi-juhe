import 'package:flutter/material.dart';

import '../services/live_sources.dart';
import '../services/midnight_gate.dart';
import '../services/source_registry.dart';
import '../widgets/home/drama_site_grid.dart';
import 'live_source_page.dart';

/// 午夜页视频站列表：jar 内置批的视频站（已启用），
/// 音频听书站不在此列。
List<SourceEntry> midnightJarVideoSites(List<SourceEntry> entries) {
  return [
    for (final entry in entries)
      if (isMidnightJarBuiltin(entry) && entry.enabled) entry,
  ];
}

class MidnightPage extends StatefulWidget {
  const MidnightPage({super.key});

  @override
  State<MidnightPage> createState() => _MidnightPageState();
}

class _MidnightPageState extends State<MidnightPage> {
  bool _loading = true;
  bool _activated = false;
  String? _selectedSiteId;
  String? _selectedVideoId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final activated = await MidnightGate.load();
    await SourceRegistry.instance.load();
    if (!mounted) {
      return;
    }
    final videoSites = midnightJarVideoSites(
      SourceRegistry.instance.custom,
    );
    setState(() {
      _activated = activated;
      _loading = false;
      _selectedVideoId = videoSites.isEmpty ? null : videoSites.first.id;
    });
  }

  Future<void> _openSiteSwitcher() async {
    final sources = LiveSources.midnightSources;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const Text('全部午夜源'),
              trailing: _selectedSiteId == null
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.pop(sheetContext, ''),
            ),
            for (final source in sources)
              ListTile(
                title: Text(source.name),
                subtitle: Text(source.description),
                trailing: source.id == _selectedSiteId
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(sheetContext, source.id),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _selectedSiteId = picked.isEmpty ? null : picked);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_activated) {
      return Scaffold(
        appBar: AppBar(title: const Text('午夜区')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '午夜区未开启',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              const Text(
                '开启后才能看到成人站源与成人直播源；'
                '未开启时这些内容不会出现在首页、搜索、影视与直播里。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('返回'),
              ),
            ],
          ),
        ),
      );
    }
    final sources = LiveSources.midnightSources
        .where(
          (source) => _selectedSiteId == null || source.id == _selectedSiteId,
        )
        .toList();
    final videoSites = midnightJarVideoSites(
      SourceRegistry.instance.custom,
    );
    final selectedVideoId = _selectedVideoId != null &&
            videoSites.any((site) => site.id == _selectedVideoId)
        ? _selectedVideoId
        : (videoSites.isEmpty ? null : videoSites.first.id);
    return Scaffold(
      appBar: AppBar(
        title: const Text('午夜区'),
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: '切换站点',
            onPressed: _openSiteSwitcher,
          ),
          IconButton(
            icon: const Icon(Icons.lock_outline),
            tooltip: '关闭午夜区',
            onPressed: () async {
              await MidnightGate.save(false);
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return CustomScrollView(
            slivers: [
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    '成人直播源',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              SliverList.builder(
                itemCount: sources.length,
                itemBuilder: (context, index) {
                  final source = sources[index];
                  return ListTile(
                    title: Text(source.name),
                    subtitle: Text(
                      '${source.description}。点开看分类与频道。',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            LiveSourceBrowsePage(source: source),
                      ),
                    ),
                  );
                },
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '视频站',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (videoSites.isEmpty)
                        const Text('暂无视频站。')
                      else
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final site in videoSites)
                              ChoiceChip(
                                label: Text(site.name),
                                selected: site.id == selectedVideoId,
                                onSelected: (_) => setState(
                                  () => _selectedVideoId = site.id,
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              if (selectedVideoId != null)
                DramaSiteGrid(
                  key: ValueKey('midnight-site-$selectedVideoId'),
                  siteId: selectedVideoId,
                  categoryId: 'all',
                  gridWidth: constraints.maxWidth,
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          );
        },
      ),
    );
  }
}
