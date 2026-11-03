import 'package:flutter/material.dart';

import '../services/source_registry.dart';
import '../widgets/home/drama_site_grid.dart';
import 'source_management_page.dart';

class VideoPage extends StatefulWidget {
  const VideoPage({super.key});

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  bool _loading = true;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await SourceRegistry.instance.load();
    if (!mounted) return;
    final sites = _playableSites();
    setState(() {
      _loading = false;
      _selectedId = sites.isEmpty ? null : sites.first.id;
    });
  }

  List<SourceEntry> _playableSites() {
    final registry = SourceRegistry.instance;
    return [
      for (final entry in registry.custom)
        if ((entry.kind == SourceKind.customMaccms ||
                entry.kind == SourceKind.pyImport ||
                entry.kind == SourceKind.jarImport ||
                entry.kind == SourceKind.jsImport) &&
            entry.enabled)
          entry,
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final sites = _playableSites();
    final remoteJson = [
      for (final entry in SourceRegistry.instance.custom)
        if (entry.kind == SourceKind.remoteJson && entry.enabled) entry,
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('影视'),
        actions: [
          IconButton(
            icon: const Icon(Icons.list),
            tooltip: '站源管理',
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const SourceManagementPage(),
                ),
              );
              await _load();
            },
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final site in sites)
                        ChoiceChip(
                          label: Text(site.name),
                          selected: site.id == _selectedId,
                          onSelected: (_) =>
                              setState(() => _selectedId = site.id),
                        ),
                    ],
                  ),
                ),
              ),
              if (sites.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      '暂无可播放的影视站源。去站源管理添加 MacCMS 站点，'
                      '或导入 Python / Jar / JS 蜘蛛（引擎仅支持 Android）。',
                    ),
                  ),
                )
              else if (_selectedId != null)
                DramaSiteGrid(
                  key: ValueKey('video-site-$_selectedId'),
                  siteId: _selectedId!,
                  categoryId: 'all',
                  gridWidth: width,
                ),
              if (remoteJson.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                    child: Text(
                      '远程 JSON 配置（已登记，内容接入待补）：'
                      '${remoteJson.map((e) => e.name).join('、')}',
                      style: const TextStyle(fontSize: 13),
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
