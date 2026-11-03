import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import '../../pages/midnight_page.dart';
import '../../services/drama_site_content.dart';
import '../../services/drama_site_play.dart';
import '../../services/drama_sites.dart';
import '../../services/midnight_gate.dart';
import '../../services/xbpq_content.dart';
import '../../services/source_registry.dart';
import 'home_feed_states.dart';
import 'home_media_card.dart';
import 'home_shelf.dart';

/// 外站短剧列表：只在选了有取数客户端的站时出现，替掉原站首页流。
/// 卡片点开走原始详情页与播放页，翻页用底部按钮，不走原站分页。
class DramaSiteGrid extends StatefulWidget {
  const DramaSiteGrid({
    super.key,
    required this.siteId,
    required this.categoryId,
    required this.gridWidth,
  });

  final String siteId;
  final String categoryId;
  final double gridWidth;

  @override
  State<DramaSiteGrid> createState() => _DramaSiteGridState();
}

class _DramaSiteGridState extends State<DramaSiteGrid> {
  DramaSiteContentClient? _client;
  List<DramaSiteItem> _items = [];
  int _page = 1;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  bool _gateBlocked = false;
  List<XbpqFilterGroup> _filterGroups = [];
  Map<String, String> _filters = {};

  void _onGateChanged() {
    if (!mounted) return;
    _loadFirst();
  }

  Future<DramaSiteCatalogPage> _catalog(
    DramaSiteContentClient client,
    String categoryId,
    int page,
  ) {
    if (client is XbpqContentClient && _filters.isNotEmpty) {
      return client.catalogFiltered(categoryId, page, _filters);
    }
    return client.catalog(categoryId, page);
  }

  Widget _filterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(homeGutter, 0, homeGutter, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final group in _filterGroups)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final option in group.options)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(option.name),
                        selected: (_filters[group.key] ?? '') == option.value,
                        onSelected: (_) {
                          setState(() {
                            _filters = {
                              ..._filters,
                              group.key: option.value,
                            };
                          });
                          _loadFirst(keepItems: true);
                        },
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 下一页预加载：首页加载完就后台取下一页，点「加载更多」时
  /// 直接拼上，不再等一次接口；预取失败不报错，下次点按钮再取。
  DramaSiteCatalogPage? _prefetchedPage;
  int _prefetchedForPage = 0;

  void _prefetchNext(int nextPage) {
    final client = _client;
    if (client == null || !_hasMore || _prefetchedForPage == nextPage) return;
    _prefetchedForPage = nextPage;
    _catalog(client, widget.categoryId, nextPage)
        .then((page) {
          if (mounted && _page + 1 == nextPage) {
            _prefetchedPage = page;
          }
        })
        .catchError((_) {});
  }

  @override
  void initState() {
    super.initState();
    MidnightGate.activated.addListener(_onGateChanged);
    _loadFirst();
  }

  @override
  void dispose() {
    MidnightGate.activated.removeListener(_onGateChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(DramaSiteGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.siteId != widget.siteId ||
        oldWidget.categoryId != widget.categoryId) {
      _client = null;
      _prefetchedPage = null;
      _prefetchedForPage = 0;
      _filterGroups = [];
      _filters = {};
      _loadFirst();
    }
  }

  Future<void> _loadFirst({bool keepItems = false}) async {
    await MidnightGate.ensureLoaded();
    if (!mounted) return;
    final siteName =
        SourceRegistry.instance.customById(widget.siteId)?.name ??
            dramaSiteById(widget.siteId).name;
    if (!MidnightGate.activated.value &&
        MidnightGate.isAdultName(siteName)) {
      setState(() {
        _loading = false;
        _error = null;
        _items = [];
        _gateBlocked = true;
      });
      return;
    }
    final client =
        await SourceRegistry.instance.clientFor(widget.siteId);
    if (!mounted) return;
    _client = client;
    if (client == null) {
      setState(() {
        _loading = false;
        _error = '该站源当前不可用';
      });
      return;
    }
    setState(() {
      _loading = !keepItems;
      _error = null;
      _gateBlocked = false;
      _prefetchedPage = null;
      _prefetchedForPage = 0;
      _filterGroups = client is XbpqContentClient
          ? client.filterGroups(widget.categoryId)
          : <XbpqFilterGroup>[];
    });
    try {
      final page = await _catalog(client, widget.categoryId, 1);
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _page = 1;
        _hasMore = page.hasMore;
        _loading = false;
      });
      if (page.hasMore) _prefetchNext(2);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadMore() async {
    final client = _client;
    if (client == null || _loadingMore || !_hasMore) return;
    final prefetched = _prefetchedPage;
    if (prefetched != null && _prefetchedForPage == _page + 1) {
      setState(() {
        _items = [..._items, ...prefetched.items];
        _page += 1;
        _hasMore = prefetched.hasMore;
        _prefetchedPage = null;
        _prefetchedForPage = 0;
      });
      if (prefetched.hasMore) _prefetchNext(_page + 1);
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final page = await _catalog(client, widget.categoryId, _page + 1);
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...page.items];
        _page += 1;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
      if (page.hasMore) _prefetchNext(_page + 1);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SliverToBoxAdapter(child: HomeFeedLoading());
    }
    if (_gateBlocked) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Text('该站属于午夜区，午夜区未开启时不显示'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const MidnightPage()),
                ),
                child: const Text('打开午夜区'),
              ),
            ],
          ),
        ),
      );
    }
    if (_error != null && _items.isEmpty) {
      return SliverToBoxAdapter(
        child: HomeFeedError(
          headline: '故事还在路上',
          message: '暂时无法加载该站点，稍后再试一次。',
          detail: _error!,
          onRetry: _loadFirst,
        ),
      );
    }
    if (_items.isEmpty) {
      return SliverMainAxisGroup(
        slivers: [
          if (_filterGroups.isNotEmpty)
            SliverToBoxAdapter(child: _filterBar()),
          SliverToBoxAdapter(
            child: HomeFeedEmpty(
              title: '暂无内容',
              message: '换个分类，或刷新发现新故事',
              actionLabel: '刷新推荐',
              onRefresh: _loadFirst,
            ),
          ),
        ],
      );
    }
    final cardWidth = homeShelfCardWidth(context, widget.gridWidth);
    return SliverMainAxisGroup(
      slivers: [
        if (_filterGroups.isNotEmpty)
          SliverToBoxAdapter(child: _filterBar()),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          sliver: SliverGrid(
            gridDelegate: homeShelfDelegate(context, widget.gridWidth),
            delegate: SliverChildBuilderDelegate((context, index) {
              final item = _items[index];
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
                onTap: () => openDramaSiteItem(context, widget.siteId, item),
              );
            }, childCount: _items.length),
          ),
        ),
        if (_hasMore)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: OutlinedButton(
                onPressed: _loadingMore ? null : _loadMore,
                child: Text(_loadingMore ? '加载中…' : '加载更多'),
              ),
            ),
          ),
      ],
    );
  }
}
