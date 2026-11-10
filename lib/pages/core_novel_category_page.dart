import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/core_novel_categories.dart';
import '../services/drama_site_content.dart';
import '../services/drama_site_play.dart';
import '../services/source_registry.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/series_detail/moyi_detail_theme.dart';
import 'home_provider.dart';

/// 小说区合并分类的混排目录页：一个合并分类（多站同名分类）点进来，
/// 各站该分类第一页混排在一起（轮流取条，总量 60），不用逐站切换。
/// 点卡走站内详情链路。loader 供页测注入假数据（生产默认走核心客户端，
/// 页测不落网络，同 CategoryPage 的 loader 规矩）。
class CoreNovelCategoryPage extends StatefulWidget {
  const CoreNovelCategoryPage({super.key, required this.category, this.loader});

  final MergedNovelCategory category;

  final Future<List<MediaItem>> Function(MergedNovelCategory)? loader;

  @override
  State<CoreNovelCategoryPage> createState() => _CoreNovelCategoryPageState();
}

class _CoreNovelCategoryPageState extends State<CoreNovelCategoryPage> {
  var _loading = true;
  var _items = const <MediaItem>[];

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
      final items = widget.loader != null
          ? await widget.loader!(widget.category)
          : await _loadMixed(widget.category);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  static Future<List<MediaItem>> _loadMixed(
    MergedNovelCategory category,
  ) async {
    Future<List<MediaItem>> fetch(NovelCategoryEntry entry) async {
      try {
        final client = readingSiteContentClient(entry.siteId);
        if (client == null) return const [];
        final page = await client
            .catalog(entry.categoryId, 1)
            .timeout(const Duration(seconds: 15));
        return [
          for (final item in page.items.take(20))
            coreReadingRecommendItem(item, entry.siteId, ContentType.novel),
        ];
      } catch (_) {
        return const [];
      }
    }

    final perSite = await Future.wait(category.entries.map(fetch));
    return interleaveCatalogItems(perSite);
  }

  void _openItem(MediaItem item) {
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
    return MoyiPageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          title: Text(widget.category.name),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _items.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '暂无${widget.category.name}内容',
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '核心站暂无内容',
                      style: TextStyle(color: moyiMutedOnDark),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _load, child: const Text('重新加载')),
                  ],
                ),
              )
            : GridView.builder(
                key: Key('core-novel-grid-${widget.category.name}'),
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
                  return HomeMediaCard(
                    item: item,
                    onTap: () => _openItem(item),
                  );
                },
              ),
      ),
    );
  }
}
