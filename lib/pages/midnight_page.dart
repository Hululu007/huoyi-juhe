import 'package:flutter/material.dart';

import '../services/live_sources.dart';
import '../services/midnight_gate.dart';
import 'live_source_page.dart';

class MidnightPage extends StatefulWidget {
  const MidnightPage({super.key});

  @override
  State<MidnightPage> createState() => _MidnightPageState();
}

class _MidnightPageState extends State<MidnightPage> {
  bool _loading = true;
  bool _activated = false;
  String? _selectedSiteId;

  @override
  void initState() {
    super.initState();
    MidnightGate.load().then((value) {
      if (mounted) {
        setState(() {
          _activated = value;
          _loading = false;
        });
      }
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
              FilledButton(
                onPressed: () async {
                  await MidnightGate.save(true);
                  if (mounted) setState(() => _activated = true);
                },
                child: const Text('开启午夜区'),
              ),
            ],
          ),
        ),
      );
    }
    final sources = LiveSources.midnightSources.where(
      (source) => _selectedSiteId == null || source.id == _selectedSiteId,
    );
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
              if (mounted) setState(() => _activated = false);
            },
          ),
        ],
      ),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              '成人直播源',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          for (final source in sources)
            ListTile(
              title: Text(source.name),
              subtitle: Text('${source.description}。点开看分类与频道。'),
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
              '点播区与午夜区站点',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '火蚁TV 点播区与午夜区的 jar / Python 站点尚未迁入本包，'
              '它们的执行引擎（Java 桥与 Python 蜘蛛）还没接，'
              '这里先不列假站点；引擎接通后这些站按 🔞 标记归到午夜区。',
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
