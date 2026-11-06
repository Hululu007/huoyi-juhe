import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/drama_site_content.dart';
import '../services/drama_site_play.dart';
import '../services/source_registry.dart';
import '../widgets/home/home_media_card.dart';
import 'home_provider.dart';

/// 成人分类聚合页（独立分类，不再是三个子 tab 的合集页）：
///
/// 一类一页（成人小说 / 成人漫画 / 成人听书各一页），把该类的全部成人源
/// 首分类第一页混排在一起，不用逐站切换。成人源分两路合并取数：
/// 核心站（火蚁TV 内置 27 个阅读源里该类的成人站，走核心阅读客户端）
/// 与登记源（名字带 🔞、已启用、内容是该类型的导入源）。点卡走站内
/// 详情链路。
///
/// 无门禁：成人书不再设门禁、不再隐藏，本页与入口常显，不取 MidnightGate。
class AdultNovelsPage extends StatelessWidget {
  const AdultNovelsPage({super.key, this.type = ContentType.novel, this.loader});

  final ContentType type;

  /// 预览/页测注入假数据用（同 CoreNovelCategoryPage 的 loader 规矩）：
  /// 不为空时 _load() 直接用它的结果，不走核心与登记源的真实网络；
  /// 为空时生产逻辑原样不动。
  final Future<List<MediaItem>> Function()? loader;

  String get _title => switch (type) {
    ContentType.comic => '成人漫画',
    ContentType.audio => '成人听书',
    _ => '成人小说',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: _AdultTypeGrid(type, loader: loader),
    );
  }
}

/// 阅读区各 tab 顶部的成人分类入口（一类一个，常显，无门禁）。
class AdultNovelsEntrySliver extends StatelessWidget {
  const AdultNovelsEntrySliver({super.key, this.type = ContentType.novel});

  final ContentType type;

  String get _title => switch (type) {
    ContentType.comic => '成人漫画',
    ContentType.audio => '成人听书',
    _ => '成人小说',
  };

  String get _subtitle => switch (type) {
    ContentType.comic => '全部成人漫画，不用切换站点',
    ContentType.audio => '全部成人听书，不用切换站点',
    _ => '全部成人小说，不用切换站点',
  };

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Card(
          key: Key(
            type == ContentType.novel
                ? 'adult-novels-entry'
                : 'adult-entry-${type.name}',
          ),
          child: ListTile(
            leading: const Icon(Icons.nightlight_round),
            title: Text(_title),
            subtitle: Text(_subtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => AdultNovelsPage(type: type),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AdultTypeGrid extends StatefulWidget {
  const _AdultTypeGrid(this.type, {this.loader});

  final ContentType type;

  final Future<List<MediaItem>> Function()? loader;

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

  String get _kindKey => switch (widget.type) {
    ContentType.comic => 'comic',
    ContentType.audio => 'audio',
    _ => 'novel',
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
    if (widget.loader != null) {
      try {
        final items = await widget.loader!();
        if (!mounted) return;
        setState(() {
          _items = items.take(60).toList();
          _loading = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _loading = false;
        });
      }
      return;
    }
    try {
      await SourceRegistry.instance.load();
      final sources = adultRecommendSources(
        SourceRegistry.instance.custom,
        types: {widget.type},
      );
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

      // 核心成人站（与登记源合并取数，核心在前）。
      final coreSiteIds = [
        for (final id in coreAdultReadingSiteIds)
          if (coreReadingKinds[id] == _kindKey) id,
      ];
      Future<List<MediaItem>> fetchCore(String siteId) async {
        try {
          final client = readingSiteContentClient(siteId);
          if (client == null) return const [];
          final categories = await client.categories();
          if (categories.isEmpty) return const [];
          final page = await client.catalog(categories.first.id, 1);
          return [
            for (final item in page.items.take(20))
              coreAdultRecommendItem(item, siteId, widget.type),
          ];
        } catch (_) {
          return const [];
        }
      }

      Future<List<MediaItem>> timed(Future<List<MediaItem>> f) => f.timeout(
        const Duration(seconds: 15),
        onTimeout: () => const <MediaItem>[],
      );

      final results = await Future.wait([
        ...coreSiteIds.map((id) => timed(fetchCore(id))),
        ...sources.map((entry) => timed(fetch(entry))),
      ]);
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
            const Text('核心站与已导入的成人源暂无内容'),
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
        childAspectRatio: 0.55,
      ),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        return HomeMediaCard(item: item, onTap: () => _openItem(item));
      },
    );
  }
}
