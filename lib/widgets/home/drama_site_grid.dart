import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import '../../services/backend_transport.dart';
import '../../services/drama_site_content.dart';
import '../../services/drama_site_play.dart';
import '../../services/drama_sites.dart';
import '../../services/m3u_export.dart';
import '../../services/m3u_export_db.dart';
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
    this.client,
    this.showFilterBar = true,
    this.autoSaveToDb = false,
    this.browseCategory,
    this.dbSink,
    this.columns = 3,
  });

  final String siteId;
  final String categoryId;
  final double gridWidth;

  /// 网格列数：默认 3 列（短剧区、浏览页沿用）；影视页两网格传 4 列。
  final int columns;

  /// 测试注入的客户端；为空时走登记表取客户端。
  final DramaSiteContentClient? client;

  /// 卡片上方筛选行开关：影视页午夜区按原始版不放这一排，
  /// 分类走右上角分类按钮；其余页默认开。
  final bool showFilterBar;

  /// 浏览自动爬取开关：只在浏览页打开，首页/影视/午夜网格默认不开。
  /// 开启时每页取到的视频列表存进本地库（只插新条，见
  /// saveBrowsedCatalogToDb）；dbSink 为空时不存。
  final bool autoSaveToDb;

  /// 当前分类对象（名、路径、父级），存库时用；为空时以 categoryId
  /// 充当分类名。
  final DramaSiteCategory? browseCategory;

  /// 存库目标；为空时不存，避免测试与未传库的页面触到真实 Hive。
  final M3uExportDbSink? dbSink;

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

  /// 本次加载失败是不是超时：超时与回空/解析失败是两回事，超时
  /// 显示「加载超时，请重试」，回空显示「暂无内容」。
  bool _errorIsTimeout = false;
  bool _gateBlocked = false;
  List<XbpqFilterGroup> _filterGroups = [];
  Map<String, String> _filters = {};

  void _onGateChanged() {
    if (!mounted) return;
    _loadFirst();
  }

  /// 浏览自动存库：fire-and-forget，不等结果、不挡界面，
  /// 写库失败由 helper 内部静默。
  void _autoSave(List<DramaSiteItem> items) {
    final dbSink = widget.dbSink;
    if (!widget.autoSaveToDb || dbSink == null || items.isEmpty) return;
    final category = widget.browseCategory ??
        DramaSiteCategory(widget.categoryId, widget.categoryId);
    final siteName =
        SourceRegistry.instance.customById(widget.siteId)?.name ??
            dramaSiteById(widget.siteId).name;
    unawaited(
      saveBrowsedCatalogToDb(
        siteId: widget.siteId,
        siteName: siteName,
        category: category,
        items: items,
        dbSink: dbSink,
      ),
    );
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

  /// 是不是超时错：ApiClient 的 [BackendRequestAborted]（timedOut）
  /// 与 widget 层 `.timeout()` 的 [TimeoutException] 都算；取消
  /// （timedOut 为 false）不算。
  static bool _isTimeoutError(Object error) =>
      error is TimeoutException ||
      (error is BackendRequestAborted && error.timedOut);

  /// 加载失败文案：超时只留一句「加载超时，请重试」，不把
  /// `TimeoutException after 0:00:45…` 这类英文原文贴出来；
  /// 证书过期（站方证书到期）不把原始握手报错整段贴出来，只留
  /// 一句人话，标出这是坏站问题、不是应用问题；其余错误仍如实
  /// 显示原文。
  static String _friendlyLoadError(Object error) {
    if (_isTimeoutError(error)) return '加载超时，请重试';
    final text = error.toString();
    if (text.contains('CERTIFICATE_VERIFY_FAILED') ||
        text.contains('certificate has expired')) {
      return '该站证书已过期（站方证书到期，需站方续期），换个站看看。';
    }
    return text;
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
    final client = widget.client ??
        await SourceRegistry.instance.clientFor(widget.siteId);
    if (!mounted) return;
    _client = client;
    if (client == null) {
      setState(() {
        _loading = false;
        _error = '该站源当前不可用';
        _errorIsTimeout = false;
      });
      return;
    }
    setState(() {
      _loading = !keepItems;
      _error = null;
      _errorIsTimeout = false;
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
      _autoSave(page.items);
      if (page.hasMore) _prefetchNext(2);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _friendlyLoadError(e);
        _errorIsTimeout = _isTimeoutError(e);
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
      _autoSave(prefetched.items);
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
      _autoSave(page.items);
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
            ],
          ),
        ),
      );
    }
    if (_error != null && _items.isEmpty) {
      return SliverToBoxAdapter(
        child: HomeFeedError(
          headline: '故事还在路上',
          // 超时单独说「加载超时，请重试」：超时是兜底健壮性问题，
          // 不是站解析失效，别跟回空/解析失败混成一句。
          message: _errorIsTimeout
              ? '加载超时，请重试。'
              : '暂时无法加载该站点，稍后再试一次。',
          detail: _error!,
          onRetry: _loadFirst,
        ),
      );
    }
    if (_items.isEmpty) {
      return SliverMainAxisGroup(
        slivers: [
          if (widget.showFilterBar && _filterGroups.isNotEmpty)
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
    // 视频卡片列数固定，不跟随书架的响应列数（窄屏/大字号会掉到
    // 两列、宽屏会到四列以上）：默认三列（短剧区），影视页传 4 列。
    final dramaGridColumns = widget.columns;
    final cardWidth =
        (widget.gridWidth - (dramaGridColumns - 1) * homeGridGap) /
        dramaGridColumns;
    final scaler = MediaQuery.textScalerOf(context);
    return SliverMainAxisGroup(
      slivers: [
        if (widget.showFilterBar && _filterGroups.isNotEmpty)
          SliverToBoxAdapter(child: _filterBar()),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: dramaGridColumns,
              crossAxisSpacing: homeGridGap,
              mainAxisSpacing: 20,
              mainAxisExtent: homeCardExtent(context, cardWidth, scaler),
            ),
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
