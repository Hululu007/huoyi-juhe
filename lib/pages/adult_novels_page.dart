import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/drama_site_content.dart';
import '../services/drama_site_play.dart';
import '../services/midnight_gate.dart';
import '../services/source_registry.dart';
import '../widgets/home/home_media_card.dart';
import 'home_provider.dart';

/// 小说分类里的成人聚合页：小说 / 漫画 / 听书三个子 tab，
///
/// 每个 tab 把全部成人源（名字带 🔞、已启用、内容是该类型）的首分类
/// 第一页混排在一起，不用逐站切换；切换类型的方式和阅读区 tab 一样，
/// 点顶部 tab 即可。点卡走站内详情链路。
///
/// 门禁：入口只在午夜区开启后出现；本页打开时门禁未开只显示锁定页，
/// 不取数、不露内容。
class AdultNovelsPage extends StatelessWidget {
  const AdultNovelsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: MidnightGate.activated,
      builder: (context, open, _) {
        return DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('成人小说'),
              bottom: open
                  ? const TabBar(
                      tabs: [
                        Tab(text: '小说'),
                        Tab(text: '漫画'),
                        Tab(text: '听书'),
                      ],
                    )
                  : null,
            ),
            body: open
                ? const TabBarView(
                    children: [
                      _AdultTypeGrid(ContentType.novel),
                      _AdultTypeGrid(ContentType.comic),
                      _AdultTypeGrid(ContentType.audio),
                    ],
                  )
                : Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.lock_outline, size: 48),
                        const SizedBox(height: 12),
                        const Text('午夜区未开启'),
                        const SizedBox(height: 4),
                        const Text('成人小说只在午夜区开启后显示'),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('返回'),
                        ),
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }
}

/// 小说 tab 顶部的成人小说入口：门禁未开时不占高度、不露痕迹。
class AdultNovelsEntrySliver extends StatefulWidget {
  const AdultNovelsEntrySliver({super.key});

  @override
  State<AdultNovelsEntrySliver> createState() => _AdultNovelsEntrySliverState();
}

class _AdultNovelsEntrySliverState extends State<AdultNovelsEntrySliver> {
  @override
  void initState() {
    super.initState();
    unawaited(MidnightGate.ensureLoaded());
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: ValueListenableBuilder<bool>(
        valueListenable: MidnightGate.activated,
        builder: (context, open, _) {
          if (!open) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Card(
              key: const Key('adult-novels-entry'),
              child: ListTile(
                leading: const Icon(Icons.nightlight_round),
                title: const Text('成人小说'),
                subtitle: const Text('全部成人小说 · 漫画 · 听书，不用切换站点'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const AdultNovelsPage(),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AdultTypeGrid extends StatefulWidget {
  const _AdultTypeGrid(this.type);

  final ContentType type;

  @override
  State<_AdultTypeGrid> createState() => _AdultTypeGridState();
}

class _AdultTypeGridState extends State<_AdultTypeGrid> {
  var _loading = true;
  var _items = const <MediaItem>[];

  String get _typeName => switch (widget.type) {
    ContentType.novel => '小说',
    ContentType.comic => '漫画',
    ContentType.audio => '听书',
    _ => '内容',
  };

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
    });
    try {
      await SourceRegistry.instance.load();
      final sources = adultRecommendSources(SourceRegistry.instance.custom)
          .where((entry) => entry.contentType == widget.type);
      Future<List<MediaItem>> fetch(SourceEntry entry) async {
        try {
          final client = await SourceRegistry.instance.clientFor(entry.id);
          if (client == null) return const [];
          final categories = await client.categories();
          if (categories.isEmpty) return const [];
          final page = await client.catalog(categories.first.id, 1);
          return [
            for (final item in page.items.take(20))
              adultRecommendItem(item, entry),
          ];
        } catch (_) {
          return const [];
        }
      }

      final results = await Future.wait(
        sources.map(
          (entry) => fetch(entry).timeout(
            const Duration(seconds: 15),
            onTimeout: () => const <MediaItem>[],
          ),
        ),
      );
      if (!mounted) return;
      setState(() {
        _items = [
          for (final list in results) ...list,
        ].take(60).toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  void _openItem(MediaItem item) {
    // 全部是 engine: 卡：走站内详情链路，不进番茄详情页。
    if (!item.source.startsWith('engine:')) return;
    final siteId = item.source.substring('engine:'.length);
    unawaited(
      openDramaSiteItem(
        context,
        siteId,
        DramaSiteItem(
          id: item.seriesId ?? item.id,
          title: item.title,
          cover: item.cover,
          remark: item.ep,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('暂无成人$_typeName'),
            const SizedBox(height: 4),
            const Text('可在设置 → 书源里导入成人源'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _load,
              child: const Text('重新加载'),
            ),
          ],
        ),
      );
    }
    return GridView.builder(
      key: Key('adult-grid-${widget.type.name}'),
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.62,
      ),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        return HomeMediaCard(item: item, onTap: () => _openItem(item));
      },
    );
  }
}
