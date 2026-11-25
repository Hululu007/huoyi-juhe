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
import '../../services/site_health_tracking_client.dart';
import '../../services/xbpq_content.dart';
import '../../services/source_registry.dart';
import '../series_detail/moyi_detail_theme.dart';
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

  /// 已展示视频的 id：翻页追加时按 id 去重，同一条视频不重复出卡。
  /// 切站点/切分类时 [_loadFirst] 重置。
  final Set<String> _seenIds = <String>{};
  int _page = 1;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingMore = false;

  /// 本次加载下一页是不是失败了：失败时哨兵停住不再自动重试，
  /// 底部改摆「加载失败，点我重试」，点后才继续。
  bool _loadMoreFailed = false;
  String? _error;

  /// 本次加载失败是不是超时：超时与回空/解析失败是两回事，超时
  /// 显示「加载超时，请重试」，回空显示「暂无内容」。
  bool _errorIsTimeout = false;
  bool _gateBlocked = false;
  List<XbpqFilterGroup> _filterGroups = [];
  Map<String, String> _filters = {};

  /// 本网格卡片的 kind：短剧站 'video'（下标「短剧」），影视站
  /// 'film'（下标「影视」）。站名先问登记表（jar/py 内置站），再问
  /// 短剧站表；两边都没有时按影视站算，不拿首站名字冒充。
  String get _cardKind {
    final id = widget.siteId;
    final name =
        SourceRegistry.instance.customById(id)?.name ??
        dramaSiteNameOrNull(id) ??
        '';
    return videoCardKindForSite(id, name);
  }

  void _onGateChanged() {
    if (!mounted) return;
    _loadFirst();
  }

  /// 浏览自动存库：fire-and-forget，不等结果、不挡界面，
  /// 写库失败由 helper 内部静默。
  void _autoSave(List<DramaSiteItem> items) {
    final dbSink = widget.dbSink;
    if (!widget.autoSaveToDb || dbSink == null || items.isEmpty) return;
    final category =
        widget.browseCategory ??
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
    final xbpq = _xbpqOf(client);
    if (xbpq != null && _filters.isNotEmpty) {
      return xbpq.catalogFiltered(categoryId, page, _filters);
    }
    return client.catalog(categoryId, page);
  }

  /// XBPQ 扩展 API 要真客户端：健康记录包装层（clientFor 出口）
  /// 先拆包再判类型，其余调用走包装层原样。
  XbpqContentClient? _xbpqOf(DramaSiteContentClient client) {
    final raw = unwrapSiteClient(client);
    return raw is XbpqContentClient ? raw : null;
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
                            _filters = {..._filters, group.key: option.value};
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
    if (!MidnightGate.activated.value && MidnightGate.isAdultName(siteName)) {
      setState(() {
        _loading = false;
        _error = null;
        _items = [];
        _gateBlocked = true;
      });
      return;
    }
    final client =
        widget.client ?? await SourceRegistry.instance.clientFor(widget.siteId);
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
      _loadMoreFailed = false;
      _prefetchedPage = null;
      _prefetchedForPage = 0;
      _filterGroups =
          _xbpqOf(client)?.filterGroups(widget.categoryId) ??
          <XbpqFilterGroup>[];
    });
    try {
      final page = await _catalog(client, widget.categoryId, 1);
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _seenIds
          ..clear()
          ..addAll(page.items.map((item) => item.id));
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
      final fresh = _dedupe(prefetched.items);
      setState(() {
        _items = [..._items, ...fresh];
        _page += 1;
        _hasMore = prefetched.hasMore;
        _loadMoreFailed = false;
        _prefetchedPage = null;
        _prefetchedForPage = 0;
      });
      _autoSave(fresh);
      if (prefetched.hasMore) _prefetchNext(_page + 1);
      return;
    }
    setState(() {
      _loadingMore = true;
      _loadMoreFailed = false;
    });
    try {
      final page = await _catalog(client, widget.categoryId, _page + 1);
      if (!mounted) return;
      final fresh = _dedupe(page.items);
      setState(() {
        _items = [..._items, ...fresh];
        _page += 1;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
      _autoSave(fresh);
      if (page.hasMore) _prefetchNext(_page + 1);
    } catch (_) {
      if (!mounted) return;
      // 加载下一页失败：不吞掉状态——哨兵靠 [_loadMoreFailed]
      // 停住不再自动重试，底部摆重试按钮，点后才继续；列表本身
      // 不卡死，已加载的卡片照常能点。
      setState(() {
        _loadingMore = false;
        _loadMoreFailed = true;
      });
    }
  }

  /// 追加页去重：只留没展示过的 id，已展示过的同一条不重复出卡。
  List<DramaSiteItem> _dedupe(List<DramaSiteItem> items) {
    return [
      for (final item in items)
        if (_seenIds.add(item.id)) item,
    ];
  }

  /// 加载下一页失败后的手动重试：清失败标记再取同一页。
  Future<void> _retryLoadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadMoreFailed = false);
    await _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SliverToBoxAdapter(child: HomeFeedLoading());
    }
    if (_gateBlocked) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            children: [
              Text(
                '该站属于午夜区，午夜区未开启时不显示',
                style: TextStyle(color: moyiBodyOnDark),
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
          // 超时单独说「加载超时，请重试」：超时是兜底健壮性问题，
          // 不是站解析失效，别跟回空/解析失败混成一句。
          message: _errorIsTimeout ? '加载超时，请重试。' : '暂时无法加载该站点，稍后再试一次。',
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
                  kind: _cardKind,
                ),
                coverWidth: cardWidth,
                onTap: () => openDramaSiteItem(context, widget.siteId, item),
              );
            }, childCount: _items.length),
          ),
        ),
        if (_loadingMore)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('加载中…', style: TextStyle(color: moyiBodyOnDark)),
                ],
              ),
            ),
          )
        else if (_loadMoreFailed)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: OutlinedButton(
                key: const ValueKey('drama_site_grid_retry'),
                onPressed: _retryLoadMore,
                child: const Text('加载失败，点我重试'),
              ),
            ),
          )
        else if (_hasMore)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: OutlinedButton(
                onPressed: _loadMore,
                child: const Text('加载更多'),
              ),
            ),
          )
        else
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Center(
                child: Text(
                  '没有更多了',
                  style: TextStyle(fontSize: 12, color: moyiMutedOnDark),
                ),
              ),
            ),
          ),
        // 触底自动加载哨兵：滑到底自动取下一页；加载中/失败/
        // 到底时不触发。内容不满一屏时哨兵不触发，短列表仍由
        // 上面的「加载更多」按钮翻页。
        SliverToBoxAdapter(
          child: _AutoLoadSentinel(
            enabled: _hasMore && !_loadingMore && !_loadMoreFailed,
            onNearBottom: _loadMore,
          ),
        ),
      ],
    );
  }
}

/// 触底自动加载哨兵：放在列表末尾的零高组件，监听外层滚动位置，
/// 滑到底（剩余内容不足 400）就调 [onNearBottom]。
///
/// 列表本身是 sliver、没有自己的 ScrollController，所以不用
/// NotificationListener，改在哨兵里拿 `Scrollable.of(context)`
/// 的 position 监听；哨兵只有滑进视口附近才会被建出来，平时
/// 不触发。连续自动加载超过 5 次还没填满视口就停住（防站方
/// 小页 endless），剩下的由底部「加载更多」按钮接手；用户一滚
/// 动、或一次加载成功后仍有剩余内容，计数清零。
class _AutoLoadSentinel extends StatefulWidget {
  const _AutoLoadSentinel({required this.enabled, required this.onNearBottom});

  /// 能不能触发：有下一页、没在加载、没失败时才为真。
  final bool enabled;

  /// 滑到底时的回调（一般是取下一页）。
  final VoidCallback onNearBottom;

  @override
  State<_AutoLoadSentinel> createState() => _AutoLoadSentinelState();
}

class _AutoLoadSentinelState extends State<_AutoLoadSentinel> {
  static const _nearBottomThreshold = 400.0;
  static const _maxChainedLoads = 5;

  ScrollPosition? _position;
  var _chained = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.of(context).position;
    if (position != _position) {
      _position?.removeListener(_check);
      _position = position;
      _position?.addListener(_check);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void didUpdateWidget(_AutoLoadSentinel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 失败重试/切页后重新可用：连锁计数清零，允许再次自动加载。
    if (!oldWidget.enabled && widget.enabled) _chained = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _position?.removeListener(_check);
    super.dispose();
  }

  void _check() {
    if (!widget.enabled || !mounted) return;
    final position = _position;
    if (position == null || !position.hasContentDimensions) return;
    // 内容不满一屏：滑不动，没有“底”可言，不自动加载。
    if (position.maxScrollExtent <= 0) return;
    if (position.extentAfter >= _nearBottomThreshold) {
      _chained = 0;
      return;
    }
    if (_chained >= _maxChainedLoads) return;
    _chained++;
    widget.onNearBottom();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
