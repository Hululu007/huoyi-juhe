import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/drama_site_content.dart';
import '../services/drama_site_play.dart';
import '../services/drama_sites.dart';
import '../services/unified_video_categories.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_feed_states.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_shelf.dart';

/// 统一浏览内容页：一个分类（或标签）名下，各站内容的汇总。
///
/// 分类和标签共用这一页：调用方把该名下的站 + 路径（分类是 CATS 的
/// path，标签是标签链接 url）拼成 [UnifiedCategorySite] 传进来，
/// 本页按站逐批取 `catalog(path, 1)` 并按站分组展示。
///
/// 站多时不一次全取：首批取 [batchSize] 站（并行），点「加载更多站点」
/// 再取下一批；某站取不到就跳过该站（页脚记一笔，不卡住整页）。
/// 卡片点开走原站详情页（与 [DramaSiteGrid] 同路）。
class UnifiedBrowseContentPage extends StatefulWidget {
  const UnifiedBrowseContentPage({
    super.key,
    required this.title,
    required this.entries,
    this.clientForSite,
  });

  /// 页标题：分类名或标签名。
  final String title;

  /// 该名下的站 + 路径（分类 path / 标签 url）。
  final List<UnifiedCategorySite> entries;

  /// 取数客户端注入（生产默认 [dramaSiteContentClient]；测试替换，
  /// 页测不落网络）。
  final DramaSiteContentClient? Function(String siteId)? clientForSite;

  @override
  State<UnifiedBrowseContentPage> createState() =>
      _UnifiedBrowseContentPageState();
}

/// 每批取的站数：并行取 4 站首页，够一屏内容，又不至于一次拉爆。
const int unifiedBrowseBatchSize = 4;

/// 一站取到的内容。
class _SiteSection {
  const _SiteSection({
    required this.siteId,
    required this.siteName,
    required this.items,
  });

  final String siteId;
  final String siteName;
  final List<DramaSiteItem> items;
}

String _siteDisplayName(String siteId) {
  for (final site in allDramaSites) {
    if (site.id == siteId) return site.name;
  }
  return siteId;
}

class _UnifiedBrowseContentPageState
    extends State<UnifiedBrowseContentPage> {
  final List<_SiteSection> _sections = [];
  int _fetched = 0;
  int _failed = 0;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;

  bool get _hasMoreSites => _fetched < widget.entries.length;

  @override
  void initState() {
    super.initState();
    _loadBatch();
  }

  DramaSiteContentClient? _clientFor(String siteId) =>
      widget.clientForSite?.call(siteId) ?? dramaSiteContentClient(siteId);

  Future<void> _loadBatch() async {
    if (_loading || _loadingMore || !_hasMoreSites) return;
    final isFirst = _fetched == 0;
    setState(() {
      if (isFirst) {
        _loading = true;
      } else {
        _loadingMore = true;
      }
      _error = null;
    });
    final batch = widget.entries.skip(_fetched).take(unifiedBrowseBatchSize);
    final results = await Future.wait([
      for (final entry in batch) _fetchOne(entry),
    ]);
    if (!mounted) return;
    final got = <_SiteSection>[];
    var failed = 0;
    for (final result in results) {
      if (result == null) {
        failed++;
      } else {
        got.add(result);
      }
    }
    setState(() {
      _sections.addAll(got);
      _fetched += batch.length;
      _failed += failed;
      _loading = false;
      _loadingMore = false;
      if (_sections.isEmpty && !_hasMoreSites) {
        _error = '这些站现在都打不开，稍后再试';
      }
    });
  }

  /// 取一站该分类/标签的首页；取不到返回 null（由调用方跳过计数）。
  Future<_SiteSection?> _fetchOne(UnifiedCategorySite entry) async {
    try {
      final client = _clientFor(entry.siteId);
      if (client == null) return null;
      final page = await client
          .catalog(entry.path, 1)
          .timeout(const Duration(seconds: 30));
      if (page.items.isEmpty) return null;
      return _SiteSection(
        siteId: entry.siteId,
        siteName: _siteDisplayName(entry.siteId),
        items: page.items,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: palette.canvas,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _sections.isEmpty
              ? Center(
                  child: HomeStateView(
                    icon: Icons.cloud_off,
                    title: _error!,
                    actionLabel: '重试',
                    onAction: _loadBatch,
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    const columns = 3;
                    final gridWidth = constraints.maxWidth - homeGutter * 2;
                    final cardWidth =
                        (gridWidth - (columns - 1) * homeGridGap) / columns;
                    final scaler = MediaQuery.textScalerOf(context);
                    return CustomScrollView(
                      slivers: [
                        for (final section in _sections) ...[
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                homeGutter,
                                20,
                                homeGutter,
                                8,
                              ),
                              child: Text(
                                '${section.siteName}（${section.items.length}）',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: homeGutter,
                            ),
                            sliver: SliverGrid(
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                crossAxisSpacing: homeGridGap,
                                mainAxisSpacing: 20,
                                mainAxisExtent: homeCardExtent(
                                  context,
                                  cardWidth,
                                  scaler,
                                ),
                              ),
                              delegate: SliverChildBuilderDelegate((
                                context,
                                index,
                              ) {
                                final item = section.items[index];
                                return HomeMediaCard(
                                  item: MediaItem(
                                    id: item.id,
                                    title: item.title,
                                    cover: item.cover,
                                    author: '',
                                    badge: '',
                                    ep: item.remark,
                                    kind: 'video',
                                  ),
                                  coverWidth: cardWidth,
                                  onTap: () => openDramaSiteItem(
                                    context,
                                    section.siteId,
                                    item,
                                  ),
                                );
                              }, childCount: section.items.length),
                            ),
                          ),
                        ],
                        if (_failed > 0)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                homeGutter,
                                16,
                                homeGutter,
                                0,
                              ),
                              child: Text(
                                '$_failed 个站取不到，已跳过',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: palette.muted,
                                ),
                              ),
                            ),
                          ),
                        if (_hasMoreSites)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: OutlinedButton(
                                key: const ValueKey(
                                  'unified_browse_load_more_sites',
                                ),
                                onPressed: _loadingMore ? null : _loadBatch,
                                child: Text(
                                  _loadingMore
                                      ? '加载中…'
                                      : '加载更多站点（还剩 ${widget.entries.length - _fetched} 站）',
                                ),
                              ),
                            ),
                          )
                        else
                          const SliverToBoxAdapter(
                            child: SizedBox(height: 24),
                          ),
                      ],
                    );
                  },
                ),
    );
  }
}
