import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/home_cell.dart';
import '../models/media_item.dart';
import '../models/search_discovery.dart';
import '../services/api_client.dart';
import '../services/app_log.dart';
import '../services/book_open_preferences.dart';
import '../services/chapter_cache_store.dart';
import '../services/core_novel_categories.dart';
import '../services/cultivation.dart';
import '../services/desktop_platform.dart';
import '../services/drama_site_content.dart';
import '../services/drama_site_play.dart';
import '../services/drama_sites.dart';
import '../services/source_registry.dart';
import '../services/home_continue_preferences.dart';
import '../services/home_page_affinity.dart';
import '../services/library_store.dart';
import '../services/video_category_tags.dart';
import '../widgets/home/drama_site_grid.dart';
import '../widgets/home/home_film_zone.dart';
import '../widgets/home/home_moyi_card.dart';
import '../widgets/home/home_moyi_carousel.dart';
import '../widgets/home/home_moyi_style.dart';
import '../widgets/site_grid_dialog.dart';
import '../widgets/home/home_cell_blocks.dart';
import '../widgets/home/home_cell_renderers.dart';
import '../widgets/home/home_design.dart';
import '../widgets/series_detail/moyi_detail_theme.dart';
import '../widgets/home/home_feed_states.dart';
import '../widgets/home/home_hero.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_reading_row.dart';
import '../widgets/home/home_shelf.dart';
import '../widgets/home/home_skeleton.dart';
import '../widgets/home/home_tab_bar.dart';
import '../widgets/tab_swipe_area.dart';
import 'adult_novels_page.dart';
import 'cached_book_reader.dart';
import 'category_page.dart';
import 'core_novel_category_page.dart';
import 'detail_page.dart';
import 'rank_page.dart';
import 'search_page.dart';
import 'home_provider.dart';
import 'home_tab_switch.dart';
import 'video_page.dart';

/// 书城首页：以书为主的书架。
///
/// 版式（用户 2026-10-26 起的设计方向）：
///
/// ```
/// 搜索行
/// 分类条（吸顶）
/// 继续阅读          ← 只有「推荐」且有阅读史：一行字，无封面无卡面
/// 排行榜            ← 上游 RankCellV3，横滑大封面 + 名次
/// 为你推荐 / 分类名  ← 统一的书籍网格
/// 流尾 / 加载中 / 重试
/// ```
///
/// 「推荐」只画书：上游的卡片流是混排（短剧、漫剧、听书都夹在里面），这里按
/// 当前分类的种类过滤，其余媒介留在各自分类里。上游的其余区块仍然按
/// `show_type` 分发（见 [HomeCellRenderers]），没登记的类型不会让页面变空。
///
/// 推荐页版式按魔蚁box首页重做：顶部品牌行 + 大轮播 + 「热播推荐 / 猜你想看」
/// 两段 3 列卡片（见 [_moyiSections]、[MoyiHeroCarousel]）；其它分类仍是
/// 原来的书架网格。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({
    super.key,
    this.cacheStore,
    this.readerStore,
    this.scrollController,
    this.cueLoader,
  });

  final ChapterCache? cacheStore;
  final ReaderStore? readerStore;

  /// 首页 feed 的滚动控制器，由壳层持有。
  ///
  /// 官方「重复点击底部书城 tab 回顶部」发生在底部栏
  /// （`onBottomTabRepeatClick` → `scrollToPosition(0)`），不在首页内部，
  /// 所以控制器要能被外面拿到。为 null 时首页自建并自行释放，测试与独立
  /// 使用不受影响。
  final ScrollController? scrollController;

  /// 搜索框热搜词来源，由壳层注入（生产接 `ApiClient.searchCue`）。
  ///
  /// 注入而不是页内直连，与 [SearchPage] 的 `hotSearchLoader` 同一规矩：
  /// 页面测试不落网络（ApiClient 的超时是 20s Timer，挂进测试必炸）。
  final Future<SearchCue> Function()? cueLoader;

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  late final ScrollController _scroll =
      widget.scrollController ?? ScrollController();

  /// 分类条吸顶的位置靠它量：搜索行的高度就是内容区的第一行。
  final GlobalKey _heroKey = GlobalKey();
  late final _homeTabs = HomeTabSwitch(_scroll, ref, _heroKey);

  /// 当前短剧站点：只在短剧分类下显示为搜索行左侧的药丸。
  /// 有取数客户端的站切站即换内容，未接通的站照旧走原站流。
  String _dramaSiteId = DramaSitePreferences.selectedId;

  /// 当前短剧站点的分类：随站点变化，换站时回到该站第一个分类。
  String _dramaCategoryId = dramaSiteById(
    DramaSitePreferences.selectedId,
  ).categories.first.id;

  /// 当前影视站点：只在影视分类下显示为搜索行左侧的药丸。
  /// 与底部导航影视区共用同一把选择（`video_zone_site_id`），
  /// 两边切站互相记得；短剧的选择另记（`drama_site_id`），各记各的。
  String? _filmSiteId;
  bool _filmSiteLoading = true;

  /// 当前影视站点的分类：随站点变化，换站时回到该站第一个真实分类。
  String _filmCategoryId = 'all';

  /// 影视站的真实分类：客户端分类优先（导入站的
  /// 真实分类都在这里），取不到时退回站点登记的分类；取到后分类条
  /// 用它，不再只显示全部。
  List<DramaSiteCategory>? _filmCategories;
  String _filmCategoriesSiteId = '';

  /// 引擎导入站的真实分类：从蜘蛛 homeContent 的 class 列表取，
  /// 取到后分类条用它，不再只显示全部；取不到时退回站点登记的分类。
  List<DramaSiteCategory>? _engineCategories;
  String _engineCategoriesSiteId = '';

  /// 小说区合并分类：一般小说核心站（去成人站）的分类按名合并，
  /// 只在小说分类下取一次，取到后分类条用它；取不到时分类条不出现。
  List<MergedNovelCategory>? _novelCategories;
  var _loadingNovelCategories = false;

  Future<void> _refreshEngineCategories(String siteId) async {
    final custom = SourceRegistry.instance.customById(siteId);
    if (custom == null ||
        (custom.kind != SourceKind.pyImport &&
            custom.kind != SourceKind.jarImport &&
            custom.kind != SourceKind.jsImport)) {
      if (mounted && _engineCategories != null) {
        setState(() {
          _engineCategories = null;
          _engineCategoriesSiteId = '';
        });
      }
      return;
    }
    if (_engineCategoriesSiteId == siteId) return;
    _engineCategoriesSiteId = siteId;
    try {
      final client = await SourceRegistry.instance.clientFor(siteId);
      if (!mounted || _dramaSiteId != siteId || client == null) return;
      final categories = await client.categories();
      if (!mounted || _dramaSiteId != siteId) return;
      setState(() {
        _engineCategories = categories;
        _dramaCategoryId = categories.first.id;
      });
    } catch (_) {}
  }

  Future<void> _refreshNovelCategories() async {
    if (_novelCategories != null || _loadingNovelCategories) return;
    _loadingNovelCategories = true;
    try {
      final categories = await loadCoreNovelCategories();
      if (!mounted) return;
      setState(() {
        _novelCategories = categories;
        _loadingNovelCategories = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingNovelCategories = false;
      });
    }
  }

  /// 影视站选择：与底部导航影视区同一把选择（`video_zone_site_id`），
  /// 站表走影视区现有的统一表（`visibleVideoZoneSites`，含午夜区站，
  /// 按修为分档过滤，未解锁的站完全不出现）。保存过的选择若不在已解锁
  /// 表里，回落到第一个已解锁站；一个已解锁站都没有时保持空，影视
  /// tab 显示空态。登记表读不到也不让首页崩：失败就当没有站。
  Future<void> _loadFilmSite() async {
    String? picked;
    try {
      await SourceRegistry.instance.load();
      final saved = await currentVideoZoneSiteId();
      final xp = CultivationService.instance.snapshot.totalXp;
      final sites = visibleVideoZoneSites(SourceRegistry.instance.custom, xp);
      picked = sites.any((site) => site.id == saved)
          ? saved
          : (sites.isEmpty ? null : sites.first.id);
    } catch (_) {
      picked = null;
    }
    if (!mounted) return;
    setState(() {
      _filmSiteId = picked;
      _filmSiteLoading = false;
    });
    if (picked != null) _refreshFilmCategories(picked);
  }

  /// 当前影视站的显示名：导入站读登记名，核心站读站表名。
  String? get _filmSiteName {
    final id = _filmSiteId;
    if (id == null) return null;
    return SourceRegistry.instance.customById(id)?.name ??
        dramaSiteById(id).name;
  }

  /// 影视站切换：点药丸弹居中弹窗，站点四列网格，点一项即切换并持久化
  /// （与影视区共用同一把选择，两边互相记得）。
  Future<void> _openFilmSiteList() async {
    await SourceRegistry.instance.load();
    if (!mounted) return;
    final xp = CultivationService.instance.snapshot.totalXp;
    final sites = visibleVideoZoneSites(SourceRegistry.instance.custom, xp);
    final picked = await showSiteGridDialog(
      context: context,
      sites: sites,
      selectedId: _filmSiteId,
    );
    if (picked == null || !mounted) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(videoZoneSitePreferenceKey, picked);
    } catch (_) {}
    if (mounted) {
      setState(() {
        _filmSiteId = picked;
        _filmCategoryId = 'all';
        _filmCategories = null;
        _filmCategoriesSiteId = '';
      });
      _refreshFilmCategories(picked);
    }
  }

  /// 影视站的真实分类：客户端分类优先，取不到退回站点登记的分类。
  /// 核心站登记里只有「全部」兜底，`catalog('all')` 对多数站是空的，
  /// 所以初始分类取第一个真实分类（非 'all'），取不到才回落 'all'。
  /// 换站后旧站的结果不落地（站号守）。
  Future<void> _refreshFilmCategories(String siteId) async {
    if (_filmCategoriesSiteId == siteId && _filmCategories != null) return;
    _filmCategoriesSiteId = siteId;
    List<DramaSiteCategory>? categories;
    if (allDramaSites.any((site) => site.id == siteId)) {
      categories = dramaSiteById(siteId).categories;
    }
    try {
      final client =
          dramaSiteContentClient(siteId) ??
          await SourceRegistry.instance.clientFor(siteId);
      if (client != null) {
        final fetched = await client.categories();
        if (fetched.isNotEmpty) categories = fetched;
      }
    } catch (_) {}
    if (!mounted || _filmSiteId != siteId) return;
    final usable = (categories ?? const <DramaSiteCategory>[])
        .where((c) => c.id.isNotEmpty)
        .toList();
    final firstReal = usable.where((c) => c.id != 'all').firstOrNull;
    setState(() {
      _filmCategories = usable.isEmpty ? null : usable;
      _filmCategoryId = usable.isEmpty ? 'all' : (firstReal ?? usable.first).id;
    });
  }

  /// 进过一次内容之后就是「切分类」，不再是冷启动：前者不能铺整页骨架。
  bool _hadContent = false;

  /// 各分类上一次渲染出的内容 slivers：横滑时直接拿它铺「正在进来」那一侧。
  ///
  /// 只缓存进过的分类；没进过的退回骨架。宽度或字号变了就整份丢掉——这些
  /// sliver 是按当时的栅格宽度建好的，换个尺寸复用会把旧版式画进新窗口。
  final Map<int, List<Widget>> _previewBodies = {};
  double? _previewGridWidth;
  double? _previewTextScale;

  Timer? _loadMoreTimer;
  bool _visible = false;

  /// Item keys whose entrance animation already played. A sliver disposes the
  /// children that leave its cache extent, so without this each scroll back up
  /// the feed replays a fade layer for every card it re-mounts.
  final _entered = <String>{};

  /// The fallback grid, reused while it still describes the same feed.
  Widget? _gridSliver;
  List<MediaItem>? _gridItems;
  int? _gridTabIndex;
  double? _gridWidth;
  double? _gridTitleScale;
  double? _gridMetaScale;

  /// The block pipeline's content slivers, given the same reuse contract.
  ///
  /// Without this cache, every state publish during pagination — `isLoadMore`
  /// turning on and back off — rebuilt the whole block list with fresh grid
  /// slivers and child delegates, and `SliverChildBuilderDelegate
  /// .shouldRebuild` is always true, so every mounted card rebuilt twice per
  /// page load. `cellsForView()` mints a new list whenever a page appends, so
  /// the identity check below is also exactly the invalidation signal.
  List<Widget>? _blocksBody;
  List<HomeCell>? _blocksCells;
  int? _blocksTabIndex;
  String? _blocksLeadKey;
  double? _blocksWidth;
  double? _blocksTitleScale;
  double? _blocksMetaScale;

  /// 魔蚁式两段网格（热播推荐 / 猜你想看）的缓存，与 [_gridSliver] 同一规矩：
  /// 只在同一份推荐流、同一 tab、同一宽度与字号下复用。
  List<Widget>? _moyiSlivers;

  /// Last logged render shape; keeps the diagnostic to one line per change.
  String? _loggedShape;

  /// 阅读史存在 Hive 里，不经过 provider；「继续阅读」那一行要跟着阅读
  /// 进度换书，所以页面自己订阅盒子的变更。
  Listenable? _historyListenable;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    final store = LibraryStore.instance;
    if (store.isInitialized) {
      _historyListenable = store.historyListenable
        ..addListener(_onLocalDataChanged);
    }
    // 关闭「继续阅读」是个持久化开关，加载完成后要重画这一行。
    HomeContinuePreferences.instance.dismissedId.addListener(
      _onLocalDataChanged,
    );
    unawaited(HomeContinuePreferences.instance.load());
    unawaited(
      DramaSitePreferences.load().then((_) async {
        if (!mounted) return;
        // 以前短剧药丸混着影视站，存过的选择可能是影视站：不在
        // 短剧表里就回落到第一个短剧站并持久化，短剧区不再接着
        // 播影视站的内容。
        await SourceRegistry.instance.load();
        if (!mounted) return;
        final sites = SourceRegistry.instance.visibleShortDramaSites(
          types: {ContentType.video, ContentType.mixed},
        );
        final picked = DramaSitePreferences.selectedId;
        if (sites.any((site) => site.id == picked)) {
          setState(() => _dramaSiteId = picked);
          return;
        }
        final fallback = sites.isEmpty ? 'original' : sites.first.id;
        // 短剧表空了（全部被关掉/删掉）时只在内存里回落到 original
        // 当展示兜底，不持久化：否则每次启动都会把一个不在可见表里
        // 的站写回偏好，禁用的站照样显示、回落逻辑下次还得再跑一遍。
        if (sites.isNotEmpty) await DramaSitePreferences.save(fallback);
        if (!mounted) return;
        setState(() {
          _dramaSiteId = fallback;
          _dramaCategoryId = dramaSiteById(fallback).categories.first.id;
          _engineCategories = null;
          _engineCategoriesSiteId = '';
        });
      }),
    );
    unawaited(_loadFilmSite());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(homeProvider.notifier).load();
    });
  }

  void _onLocalDataChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (_visible == visible) return;
    _visible = visible;
    // Muting tickers does not stop this page's pagination timer.
    // Note: .agents/notes/implemented/bug-fix/2026-09-17-persistent-data-and-web-cancellation.md
    if (!_visible) {
      _loadMoreTimer?.cancel();
      _loadMoreTimer = null;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
    }
  }

  @override
  void dispose() {
    _loadMoreTimer?.cancel();
    _historyListenable?.removeListener(_onLocalDataChanged);
    HomeContinuePreferences.instance.dismissedId.removeListener(
      _onLocalDataChanged,
    );
    // 外部传入的控制器归壳层所有，这里不能释放。
    if (widget.scrollController == null) _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!mounted || !_visible) return;
    if (!_scroll.hasClients) {
      final state = ref.read(homeProvider);
      if (state.error == null && _visibleItems(state).isEmpty) _maybeLoadMore();
      return;
    }
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - 600) _maybeLoadMore();
  }

  /// Short and empty pages must continue even without a user scroll event.
  void _maybeLoadMore() {
    if (!mounted || !_visible || _loadMoreTimer != null) return;
    final state = ref.read(homeProvider);
    if (state.isLoading || state.isLoadMore || !state.hasMore) return;
    _loadMoreTimer = Timer(const Duration(milliseconds: 500), () {
      _loadMoreTimer = null;
      if (mounted) _onScroll();
    });
    ref.read(homeProvider.notifier).loadMore();
  }

  /// 下拉与冷启动错误里的「重试」都走手动刷新：手动刷新会跳过续接快照，
  /// 用服务端的第一页整体替换列表（官方 `SaasClientReqType.Refresh`）。
  Future<void> _refresh() =>
      ref.read(homeProvider.notifier).load(manualRefresh: true);

  /// 追加失败后 footer 的重试：`loadMore` 失败会把 `hasMore` 置 false，必须
  /// 让 notifier 先把游标恢复，否则重试会被「已经没有下一页」挡住。
  Future<void> _retryLoadMore() =>
      ref.read(homeProvider.notifier).retryLoadMore();

  /// 当前分类的种类：「推荐」与「全部」都会落到 `book`。
  String _kindOf(HomeState state) =>
      ref.read(homeProvider.notifier).identityOf(state.tabIndex).kind;

  List<MediaItem> _visibleItems(HomeState state) {
    final kind = _kindOf(state);
    return [
      for (final item in state.items)
        if (item.kind == kind) item,
    ];
  }

  /// 当前分类的区块，或空表示这份 `cells` 不属于这里。
  ///
  /// 归属由数据自己声明（[HomeState.cellsTabIndex]），不再靠页面猜：上游曾把
  /// `tab_index` 写死成 0 返回推荐流，于是「听书」里画出了推荐榜。请求侧已经
  /// 修好，这里再兜一道——不属于当前分类的区块一律不画，别把别人的内容
  /// 当成自己这份。
  List<HomeCell> _cellsOfCurrentTab(HomeState state) {
    final cells = state.cells;
    if (cells.isEmpty) return const [];
    final owner = state.cellsTabIndex;
    if (owner == null) return cells;
    return owner == state.tabIndex ? cells : const [];
  }

  /// 顶栏分类：固定用本地七分类（推荐/小说/短剧/影视/漫剧/漫画/听书）。
  ///
  /// 2026-10-24 用户决定回退服务端 11 项方案——服务端表没有「短剧/漫剧」，
  /// 跨媒介入口只能本地给；点击身份由 `homeProvider` 的 `usesLocalTabs`
  /// 本地表驱动，与这里的下标一一对应。
  List<HomeCategory> _categoriesOf(HomeState state) => homeCategories;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeProvider);
    final palette = HomePalette.of(context);
    final categories = _categoriesOf(state);
    final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
    // 全页强制深紫蓝渐变底（魔蚁主题）：内层组件靠深色主题取浅色字（与
    // 影视详情魔蚁区同款做法），墨水屏不强制、保持黑白。
    final darkPage = !palette.eink;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: MoyiPageBackground(
        child: Theme(
          data: Theme.of(
            context,
          ).copyWith(brightness: darkPage ? Brightness.dark : Brightness.light),
          child: Align(
            alignment: Alignment.topCenter,
            // 阅读宽度：手机/平板压 840（一屏三到五列，再宽眼睛就散）。
            //
            // 桌面不吃固定 1440：2560 的窗口里只占一半多，两侧各空 560dp。
            // 宽度交给窗口后，列数由 homeShelfColumns 按「一格 190dp，钳 6–9 列」
            // 反推（见 `widgets/home/home_shelf.dart`）：默认六列、全屏九列，
            // 窗口再宽只把卡片放大，不会往格子里塞更多小封面。
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth:
                    isWindowsDesktop || MediaQuery.sizeOf(context).width >= 840
                    ? double.infinity
                    : 840,
              ),
              child: SafeArea(
                bottom: false,
                // 冷启动失败不再整页替换：搜索行与分类条留在原位，错误信息进
                // feed 里滚动，用户换个分类或下拉都能继续用。
                child: RefreshIndicator(
                  color: HomePalette.accent,
                  backgroundColor: moyiSheetFill,
                  onRefresh: _refresh,
                  // The grid is measured once here, outside the sliver: a sliver's
                  // constraints carry the scroll offset, so measuring inside one
                  // re-ran the builder and rebuilt every visible card per frame.
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final gridWidth = constraints.maxWidth - homeGutter * 2;
                      final content = _contentSlivers(state, gridWidth);
                      // 魔蚁式大轮播的片源：推荐页取推荐流前 6 张有封面的，
                      // 其它分类不出现（那几页画自己的站目录/书架）。
                      final carouselItems = state.tabIndex == 0
                          ? moyiCarouselItems(_visibleItems(state))
                          : const <MediaItem>[];
                      _rememberPreviewBody(
                        state.tabIndex,
                        content,
                        gridWidth,
                        textScale,
                      );
                      return TabSwipeArea(
                        index: state.tabIndex,
                        count: categories.length,
                        onSelect: _homeTabs.select,
                        // 拖动时把邻页真正画出来：缓存过的分类直接复用上次的
                        // sliver 树，没进过的铺骨架。没有它，移开的那一侧只能
                        // 露页面底色——深色主题下就是一块黑面板。
                        previewBuilder: (target) =>
                            _buildTabPreview(target, textScale: textScale),
                        // 顶栏靠反向位移钉住，重绘边界会把它的右半截裁掉。
                        isolateChild: false,
                        child: CustomScrollView(
                          key: const Key('home_feed'),
                          controller: _scroll,
                          // 顶栏用反向位移钉在屏幕上（SwipeStationary），会被画到
                          // 视口之外。视口默认 Clip.hardEdge 只认自己的 bounds，会把
                          // 搜索行右半截和末位标签裁掉；裁剪统一交给 TabSwipeArea
                          // 外层的 ClipRect。
                          clipBehavior: Clip.none,
                          physics: const BouncingScrollPhysics(
                            parent: AlwaysScrollableScrollPhysics(),
                          ),
                          slivers: [
                            _heroSliver(state.tabIndex),
                            SliverPersistentHeader(
                              pinned: true,
                              delegate: HomeTabBarDelegate(
                                selectedIndex: state.tabIndex,
                                onSelect: _homeTabs.select,
                                categories: categories,
                                extent: HomeTabBarDelegate.extentFor(textScale),
                                dark: true,
                                eink: palette.eink,
                                oled: palette.oled,
                              ),
                            ),
                            if (state.tabIndex >= 0 &&
                                state.tabIndex < homeCategories.length &&
                                homeCategories[state.tabIndex].label == '短剧')
                              _dramaCategoryStrip(),
                            if (state.tabIndex >= 0 &&
                                state.tabIndex < homeCategories.length &&
                                homeCategories[state.tabIndex].label == '影视')
                              _filmCategoryStrip(),
                            if (state.tabIndex >= 0 &&
                                state.tabIndex < homeCategories.length &&
                                homeCategories[state.tabIndex].label == '小说')
                              _novelCategoryStrip(),
                            // 第 20 轮改版：原来三 tab 顶部那张「成人小说 / 漫画 /
                            // 听书」大卡片已删，改成排行榜式卡片轨道（封面 +
                            // TOP 角标 + 标题 + 热度行，点卡直达、右端「更多」
                            // 进聚合页）。聚合页本身保留。
                            if (state.tabIndex >= 0 &&
                                state.tabIndex < homeCategories.length &&
                                homeCategories[state.tabIndex].label == '小说')
                              const AdultCardRailSliver(),
                            if (state.tabIndex >= 0 &&
                                state.tabIndex < homeCategories.length &&
                                homeCategories[state.tabIndex].label == '漫画')
                              const AdultCardRailSliver(
                                type: ContentType.comic,
                              ),
                            if (state.tabIndex >= 0 &&
                                state.tabIndex < homeCategories.length &&
                                homeCategories[state.tabIndex].label == '听书')
                              const AdultCardRailSliver(
                                type: ContentType.audio,
                              ),
                            // 魔蚁式大轮播：推荐页分类条下方、内容区上方，
                            // 点卡片或「马上看」都进当前 hero 的详情/播放。
                            if (state.tabIndex == 0 && carouselItems.isNotEmpty)
                              SliverToBoxAdapter(
                                child: MoyiHeroCarousel(
                                  items: carouselItems,
                                  onOpen: _openItem,
                                ),
                              ),
                            // 全局「影视」区（用户 2026-11-05 令）：只在推荐页
                            // 顶部出现，核心里所有站点的视频、小说、漫画、听书
                            // 都在这里；成人站按修仙境界解锁，未解锁的不显示。
                            // 放在内容区之外（不进 _contentSlivers 的缓存），
                            // 跟搜索行、分类条一样属于页面级区块。
                            if (state.tabIndex == 0)
                              HomeFilmZone(gridWidth: gridWidth),
                            ...content,
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 搜索行。横滑切分类时它不跟着走：它属于「页面」，不属于「内容」。
  /// 短剧分类下搜索行左侧是短剧站点药丸，影视分类下是影视站点药丸
  /// （走影视区站表，点它切影视站）；其余分类保持原版式。
  SliverToBoxAdapter _heroSliver(int tabIndex) {
    final label = tabIndex >= 0 && tabIndex < homeCategories.length
        ? homeCategories[tabIndex].label
        : null;
    return SliverToBoxAdapter(
      child: SwipeStationary(
        child: HomeHero(
          key: _heroKey,
          onSearch: _openSearch,
          onRefresh: _refresh,
          onCategory: _openCategory,
          brandSubtitle: label == '短剧'
              ? dramaSiteById(_dramaSiteId).name
              : label == '影视'
              ? _filmSiteName
              : label,
          siteName: label == '短剧'
              ? dramaSiteById(_dramaSiteId).name
              : label == '影视'
              ? _filmSiteName
              : null,
          onSiteTap: label == '影视' ? _openFilmSiteList : _openSiteList,
          cueLoader: widget.cueLoader,
        ),
      ),
    );
  }

  /// 短剧站点列表：只列短剧站，影视站不进（`visibleShortDramaSites`）。
  /// 点药丸弹居中弹窗，站点四列网格，点一项即切换药丸并持久化。
  Future<void> _openSiteList() async {
    await SourceRegistry.instance.load();
    if (!mounted) return;
    final sites = SourceRegistry.instance
        .visibleShortDramaSites(types: {ContentType.video, ContentType.mixed})
        .where((site) {
          final entry = SourceRegistry.instance.customById(site.id);
          if (entry?.kind != SourceKind.legadoImport) return true;
          return entry!.extra['hasExplore'] == true;
        })
        .toList();
    final picked = await showSiteGridDialog(
      context: context,
      sites: [for (final site in sites) (id: site.id, name: site.name)],
      selectedId: _dramaSiteId,
    );
    if (picked == null || !mounted) return;
    await DramaSitePreferences.save(picked);
    if (mounted) {
      setState(() {
        _dramaSiteId = picked;
        _dramaCategoryId = dramaSiteById(picked).categories.first.id;
        _engineCategories = null;
        _engineCategoriesSiteId = '';
      });
    }
  }

  /// 短剧站点的分类条：放在分类条下方、内容上方，只在短剧分类下出现。
  /// 分类随站点变化：原站是番茄频道，红果、HGTV、红果镜像用各自的实测分类，
  /// 其余站的分类尚未实测映射前只显示全部，不编造。
  /// 引擎导入站的分类从蜘蛛 class 列表动态取，取到后替换全部。
  Widget _dramaCategoryStrip() {
    final site = dramaSiteById(_dramaSiteId);
    if (_engineCategoriesSiteId != _dramaSiteId) {
      _refreshEngineCategories(_dramaSiteId);
    }
    final categories =
        (_engineCategories != null && _engineCategoriesSiteId == _dramaSiteId)
        ? _engineCategories!
        : site.categories;
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            for (final category in categories)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => setState(() => _dramaCategoryId = category.id),
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      gradient: category.id == _dramaCategoryId
                          ? moyiSelectedGradient
                          : null,
                      color: category.id == _dramaCategoryId
                          ? null
                          : moyiDarkCardFill,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      category.displayName,
                      style: TextStyle(
                        fontSize: 13,
                        color: category.id == _dramaCategoryId
                            ? Colors.white
                            : moyiBodyOnDark,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 影视站点的分类条：放在分类条下方、内容上方，只在影视分类下出现。
  /// 分类随站点变化（客户端分类优先，取不到退回站点登记的分类）；
  /// 点一项切分类，网格即换内容。分类还在取时先占 40 高防版式跳动。
  Widget _filmCategoryStrip() {
    final siteId = _filmSiteId;
    if (siteId == null) return const SliverToBoxAdapter();
    if (_filmCategoriesSiteId != siteId) {
      _refreshFilmCategories(siteId);
    }
    final categories = _filmCategories;
    if (categories == null) {
      return const SliverToBoxAdapter(child: SizedBox(height: 40));
    }
    if (categories.isEmpty) return const SliverToBoxAdapter();
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            for (final category in categories)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => setState(() => _filmCategoryId = category.id),
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      gradient: category.id == _filmCategoryId
                          ? moyiSelectedGradient
                          : null,
                      color: category.id == _filmCategoryId
                          ? null
                          : moyiDarkCardFill,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      category.displayName,
                      style: TextStyle(
                        fontSize: 13,
                        color: category.id == _filmCategoryId
                            ? Colors.white
                            : moyiBodyOnDark,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 小说区合并分类条：放在分类条下方、内容上方，只在小说分类下出现。
  /// 分类是一般小说核心站按名合并的（与短剧条同款式，点一项进混排目录页，
  /// 不在原地过滤）；取不到时不出现，加载中先占 40 高防版式跳动。
  Widget _novelCategoryStrip() {
    if (_novelCategories == null) {
      unawaited(_refreshNovelCategories());
      return const SliverToBoxAdapter(child: SizedBox(height: 40));
    }
    final categories = _novelCategories!;
    if (categories.isEmpty) return const SliverToBoxAdapter();
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            for (final category in categories)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => CoreNovelCategoryPage(category: category),
                    ),
                  ),
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: moyiDarkCardFill,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      category.name,
                      style: const TextStyle(
                        fontSize: 13,
                        color: moyiBodyOnDark,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 记下当前分类这一帧的内容 slivers，供横滑时预渲染邻页。
  void _rememberPreviewBody(
    int tabIndex,
    List<Widget> slivers,
    double gridWidth,
    double textScale,
  ) {
    if (_previewGridWidth != gridWidth || _previewTextScale != textScale) {
      _previewBodies.clear();
      _previewGridWidth = gridWidth;
      _previewTextScale = textScale;
    }
    _previewBodies[tabIndex] = slivers;
  }

  /// 横滑时「正在进来」的那一页。
  ///
  /// 只铺内容区（搜索行、分类条由当前页的 [SwipeStationary] 钉住），并用
  /// [_previewContentTop] 对齐到切换后内容所在的第一行——新分类从自己的
  /// 第一行开始显示，与 [HomeTabSwitch] 的落点一致。没进过的分类铺骨架，
  /// 至少不是一块底色。
  Widget _buildTabPreview(int target, {required double textScale}) {
    if (target < 0 || target >= homeCategories.length) {
      return const SizedBox.shrink();
    }
    final body = _previewBodies[target];
    return MoyiPageBackground(
      child: CustomScrollView(
        physics: const NeverScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(height: _previewContentTop(textScale)),
          ),
          if (body != null)
            ...body
          else
            const SliverToBoxAdapter(child: HomeSkeleton()),
        ],
      ),
    );
  }

  /// 切到邻页后，内容区第一行在屏幕上的 y。
  ///
  /// 搜索行高度 + 分类条高度 - 落点。落点与 [HomeTabSwitch] 一致：滚过搜索行
  /// 就停在搜索行高度（分类条吸顶），否则原地不动。
  double _previewContentTop(double textScale) {
    final hero = _heroKey.currentContext?.size?.height ?? 0;
    final bar = HomeTabBarDelegate.extentFor(textScale);
    final pixels = _scroll.hasClients ? _scroll.position.pixels : 0.0;
    final landing = pixels > hero ? hero : pixels;
    return math.max(bar, hero + bar - landing);
  }

  List<Widget> _contentSlivers(HomeState state, double gridWidth) {
    // 选了有取数客户端的外站时，短剧页不再画原站首页流，改画该站列表；
    // 原站与未接通的站照旧走下面的原站流。
    if (state.tabIndex >= 0 &&
        state.tabIndex < homeCategories.length &&
        homeCategories[state.tabIndex].label == '短剧' &&
        SourceRegistry.instance.hasDramaContentClient(_dramaSiteId)) {
      return [
        DramaSiteGrid(
          key: ValueKey('drama-site-$_dramaSiteId-$_dramaCategoryId'),
          siteId: _dramaSiteId,
          categoryId: _dramaCategoryId,
          gridWidth: gridWidth,
        ),
        _bottomSpacer(context),
      ];
    }
    // 影视页：不画书城流，改画当前影视站的目录网格（与底部导航影视区
    // 同一路：站表、分类、卡片点开都走现有影视详情链路）。站选择还在
    // 读时先给加载态；一个已解锁站都没有时给空态（去站源管理加站）。
    if (state.tabIndex >= 0 &&
        state.tabIndex < homeCategories.length &&
        homeCategories[state.tabIndex].label == '影视') {
      if (_filmSiteLoading) {
        return const [SliverToBoxAdapter(child: HomeFeedLoading())];
      }
      final filmSiteId = _filmSiteId;
      if (filmSiteId == null) {
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: HomeFeedEmpty(
              title: '暂无影视站源',
              message:
                  '核心影视站见影视区；要加站去站源管理添加 MacCMS 站点，'
                  '或导入 Python / Jar / JS 蜘蛛。',
              actionLabel: '重新加载',
              onRefresh: () => _loadFilmSite(),
            ),
          ),
        ];
      }
      return [
        DramaSiteGrid(
          key: ValueKey('film-site-$filmSiteId-$_filmCategoryId'),
          siteId: filmSiteId,
          categoryId: _filmCategoryId,
          gridWidth: gridWidth,
        ),
        _bottomSpacer(context),
      ];
    }
    if (state.error != null &&
        state.items.isEmpty &&
        _cellsOfCurrentTab(state).isEmpty) {
      return [
        SliverToBoxAdapter(
          child: HomeFeedError(
            headline: '故事还在路上',
            message: '暂时无法加载推荐，稍后再试一次。',
            detail: state.error!,
            onRetry: _refresh,
          ),
        ),
      ];
    }

    final items = _visibleItems(state);
    if (items.isNotEmpty) _hadContent = true;
    final now = _readingNow(state);
    final lead = now?.item;
    final blockBody = _blockBodySlivers(
      state,
      gridWidth,
      kind: _kindOf(state),
      lead: lead,
    );
    _logShape(state, blockBody != null);

    // 短页要能自己续上：没有滚动事件时，也让页面在布局后检查一次是否
    // 已经到底（内容不足一屏时 `maxScrollExtent` 为 0）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onScroll();
    });
    if (blockBody != null) {
      return [
        if (now != null) _continueRow(now),
        ...blockBody,
        _footer(state),
        _bottomSpacer(context),
      ];
    }
    if (items.isNotEmpty) {
      return [
        if (now != null) _continueRow(now),
        ..._fallbackGrid(state, items, gridWidth, lead: lead),
        _footer(state),
        _bottomSpacer(context),
      ];
    }
    if (state.isLoading || state.hasMore) {
      if (!state.isLoading) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
      }
      // `alx.xml` points its `SkeletonLayout` at `cmc`, so a cold first load
      // paints the skeleton rather than a spinner. 切分类不是冷启动：满屏脉冲
      // 骨架 + 搜索行被带回来，正是「整页重新加载」的观感，用轻量提示代替。
      if (_hadContent) {
        return const [SliverToBoxAdapter(child: HomeFeedLoading())];
      }
      return const [SliverToBoxAdapter(child: HomeSkeleton())];
    }
    return [
      SliverFillRemaining(
        hasScrollBody: false,
        child: HomeFeedEmpty(
          title: '暂无内容',
          message: '换个分类，或刷新发现新故事',
          actionLabel: '刷新推荐',
          onRefresh: _refresh,
        ),
      ),
    ];
  }

  /// 「继续阅读」显示哪一本：只在推荐页、有阅读史、且这一本没被关掉时出现。
  ReadingNow? _readingNow(HomeState state) {
    if (state.tabIndex != 0) return null;
    final now = latestReadingNow();
    if (now == null) return null;
    return HomeContinuePreferences.instance.isDismissed(now.item) ? null : now;
  }

  Widget _continueRow(ReadingNow now) => SliverToBoxAdapter(
    child: HomeContinueRow(
      now: now,
      onOpen: () => _resumeItem(now.item),
      onDismiss: () => HomeContinuePreferences.instance.dismiss(now.item),
    ),
  );

  void _logShape(HomeState state, bool blocks) {
    // 设备日志：分类页到底画的是区块还是卡片网格、画了多少张。听书出问题时
    // 这一行直接说明它被画成了哪一种版式。
    final shape = blocks
        ? 'blocks tab=${state.tabIndex} '
              'cells=${describeHomeCells(_cellsOfCurrentTab(state))}'
        : 'grid tab=${state.tabIndex} items=${_visibleItems(state).length}';
    if (shape == _loggedShape) return;
    _loggedShape = shape;
    AppLog.d('home', '渲染 $shape');
  }

  /// The block pipeline's content slivers, reused verbatim while they still
  /// describe the same cells, width, text scale and lead book.
  List<Widget>? _blockBodySlivers(
    HomeState state,
    double gridWidth, {
    required String kind,
    required MediaItem? lead,
  }) {
    // 每个书城分类都渲染自己那份 `cell_data`（官方 `m0` 对 `tab_type` 一视
    // 同仁地建区块），所以这里不再只放行「推荐」。没带区块的分类照旧落到
    // 下面的兜底网格，不会被空掉。
    final cells = _cellsOfCurrentTab(state);
    if (cells.isEmpty) return null;
    registerDefaultHomeCells(
      onOpenRankBoard: _openRanks,
      loadBoard: _loadRankPreview,
    );

    final scaler = MediaQuery.textScalerOf(context);
    final titleScale = scaler.scale(15);
    final metaScale = scaler.scale(11);
    final leadKey = lead == null ? null : '${lead.kind}:${lead.id}';
    final cached = _blocksBody;
    if (cached != null &&
        identical(_blocksCells, cells) &&
        _blocksTabIndex == state.tabIndex &&
        _blocksLeadKey == leadKey &&
        _blocksWidth == gridWidth &&
        _blocksTitleScale == titleScale &&
        _blocksMetaScale == metaScale) {
      return cached;
    }
    _blocksCells = cells;
    _blocksTabIndex = state.tabIndex;
    _blocksLeadKey = leadKey;
    _blocksWidth = gridWidth;
    _blocksTitleScale = titleScale;
    _blocksMetaScale = metaScale;

    final slivers = <Widget>[];
    final entries = <MediaItem>[];
    final seen = <String>{};
    var rendered = false;
    for (final cell in cells) {
      // 只有真拿到 widget 才算处理过。handles() 为真但 build() 返回 null 时
      // 要落到 card 分支，否则这个块会被静默跳过。
      final custom = HomeCellRenderers.handles(cell.showType)
          ? HomeCellRenderers.build(context, cell, onOpen: _openItem)
          : null;
      if (custom != null) {
        slivers.add(SliverToBoxAdapter(child: custom));
        rendered = true;
        continue;
      }
      if (!isHomeGridBlock(cell)) continue;
      for (final item in homeCellEntries(cell)) {
        // 以书为主：推荐页的卡片流里混着短剧、漫画和听书，这里只留当前
        // 分类的书；其余媒介在自己的分类里出现。
        if (item.kind != kind) continue;
        final key = '${item.kind}:${item.id}';
        // 主视觉已经在上面独占一张卡，网格里不再重复。
        if (key == leadKey || !seen.add(key)) continue;
        entries.add(item);
      }
    }
    if (entries.isNotEmpty) {
      // 多个卡片流合并成一个网格：推荐页按魔蚁式拆成「热播推荐 / 猜你想看」
      // 两段（前 6 张热播、其余猜你想看），其它分类仍是一个以分类名命名的
      // 段落；块与块之间的边界对读书的人没有意义。
      if (state.tabIndex == 0) {
        slivers.addAll(_moyiSections(entries, gridWidth));
      } else {
        slivers.add(
          SliverToBoxAdapter(
            child: HomeSectionHeader(title: _gridTitle(state)),
          ),
        );
        slivers.add(_gridBody(entries, gridWidth));
      }
      rendered = true;
    }
    if (!rendered) {
      // 这份 `cells` 一个块都没画出来（听书的 337、老后端的未知类型…）：
      // **必须把缓存清掉**。`_blocksCells` 已经在上面改成了这份列表，
      // 若把 `_blocksBody`（上上个分类建的那套 widget）留着，下一次带着
      // **同一份列表实例**的重建就会命中缓存、把上一个分类的排行榜画到
      // 当前分类上——真机上「听书第二次加载变成推荐」就是这么来的。
      _blocksBody = null;
      _blocksCells = null;
      _blocksTabIndex = null;
      _blocksLeadKey = null;
      _blocksWidth = null;
      _blocksTitleScale = null;
      _blocksMetaScale = null;
      return null;
    }
    return _blocksBody = slivers;
  }

  /// 兜底：上游没给区块时，把当前分类的条目排成同一个书架网格。
  List<Widget> _fallbackGrid(
    HomeState state,
    List<MediaItem> items,
    double gridWidth, {
    required MediaItem? lead,
  }) {
    final leadKey = lead == null ? null : '${lead.kind}:${lead.id}';
    final entries = [
      for (final item in items)
        if ('${item.kind}:${item.id}' != leadKey) item,
    ];
    if (entries.isEmpty) return const [];
    final scaler = MediaQuery.textScalerOf(context);
    final titleScale = scaler.scale(15);
    final metaScale = scaler.scale(11);
    // 推荐页的兜底网格同样走魔蚁式两段（热播推荐 / 猜你想看），
    // 缓存与普通网格同一套失效条件。
    if (state.tabIndex == 0) {
      final cached = _moyiSlivers;
      if (cached != null &&
          identical(_gridItems, state.items) &&
          _gridTabIndex == state.tabIndex &&
          _gridWidth == gridWidth &&
          _gridTitleScale == titleScale &&
          _gridMetaScale == metaScale) {
        return cached;
      }
      _gridItems = state.items;
      _gridTabIndex = state.tabIndex;
      _gridWidth = gridWidth;
      _gridTitleScale = titleScale;
      _gridMetaScale = metaScale;
      return _moyiSlivers = _moyiSections(entries, gridWidth);
    }
    final cached = _gridSliver;
    if (cached != null &&
        identical(_gridItems, state.items) &&
        _gridTabIndex == state.tabIndex &&
        _gridWidth == gridWidth &&
        _gridTitleScale == titleScale &&
        _gridMetaScale == metaScale) {
      return [
        SliverToBoxAdapter(child: HomeSectionHeader(title: _gridTitle(state))),
        cached,
      ];
    }
    _gridItems = state.items;
    _gridTabIndex = state.tabIndex;
    _gridWidth = gridWidth;
    _gridTitleScale = titleScale;
    _gridMetaScale = metaScale;
    final sliver = _gridBody(entries, gridWidth);
    return [
      SliverToBoxAdapter(child: HomeSectionHeader(title: _gridTitle(state))),
      _gridSliver = sliver,
    ];
  }

  /// One book grid: cover, title, one meta line, nothing else.
  Widget _gridBody(List<MediaItem> entries, double gridWidth) {
    final cardWidth = homeShelfCardWidth(context, gridWidth);
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: homeGutter),
      sliver: SliverGrid(
        gridDelegate: homeShelfDelegate(context, gridWidth),
        delegate: SliverChildBuilderDelegate((context, index) {
          final item = entries[index];
          final key = '${item.kind}:${item.id}';
          return HomeEntrance(
            key: ValueKey(key),
            index: index,
            // Only the first appearance of an item animates; see HomeEntrance.
            animate: _entered.add(key),
            child: HomeMediaCard(
              item: item,
              coverWidth: cardWidth,
              onTap: () => _openItem(item),
            ),
          );
        }, childCount: entries.length),
      ),
    );
  }

  /// 魔蚁式两段网格（推荐页专用）：「热播推荐」取推荐流前
  /// [moyiHotSectionCount] 张、段头右端「全部 >」进频道分类页；
  /// 「猜你想看」取其余，余下不足一张时该段不出现。
  /// 数据仍是推荐流本身，不编假数据、不换一批乱序。
  List<Widget> _moyiSections(List<MediaItem> entries, double gridWidth) {
    final hot = entries.take(moyiHotSectionCount).toList();
    final rest = entries.skip(moyiHotSectionCount).toList();
    return [
      SliverToBoxAdapter(
        child: MoyiSectionHeader(
          title: '热播推荐',
          actionLabel: '全部',
          onAction: _openCategory,
        ),
      ),
      _moyiGrid(hot, gridWidth),
      if (rest.isNotEmpty) ...[
        const SliverToBoxAdapter(child: MoyiSectionHeader(title: '猜你想看')),
        _moyiGrid(rest, gridWidth),
      ],
    ];
  }

  /// 魔蚁式 3 列卡片网格：圆角 + 紫色描边 + 有 HD 才标的角标
  /// （见 [MoyiMediaCard]），标题叠在封面底部。
  Widget _moyiGrid(List<MediaItem> entries, double gridWidth) {
    final cardWidth = homeShelfCardWidth(context, gridWidth);
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: homeGutter),
      sliver: SliverGrid(
        gridDelegate: moyiGridDelegate(context, gridWidth),
        delegate: SliverChildBuilderDelegate((context, index) {
          final item = entries[index];
          final key = '${item.kind}:${item.id}';
          return HomeEntrance(
            key: ValueKey(key),
            index: index,
            // Only the first appearance of an item animates; see HomeEntrance.
            animate: _entered.add(key),
            child: MoyiMediaCard(
              item: item,
              coverWidth: cardWidth,
              onTap: () => _openItem(item),
            ),
          );
        }, childCount: entries.length),
      ),
    );
  }

  /// 非推荐页的段落名就是分类名；推荐页不用它，推荐页是魔蚁式
  /// 「热播推荐 / 猜你想看」两段（见 [_moyiSections]）。
  String _gridTitle(HomeState state) {
    return ref.read(homeProvider.notifier).identityOf(state.tabIndex).name;
  }

  /// 流尾三态：加载中 / 追加失败可重试 / 已到底。
  Widget _footer(HomeState state) {
    if (state.isLoadMore) {
      return SliverToBoxAdapter(
        child: HomeStreamFooter.loading(onRetry: _retryLoadMore),
      );
    }
    if (state.error != null) {
      return SliverToBoxAdapter(
        child: HomeStreamFooter.retry(onRetry: _retryLoadMore),
      );
    }
    if (!state.hasMore) {
      return const SliverToBoxAdapter(child: HomeStreamFooter.done());
    }
    return const SliverToBoxAdapter(child: SizedBox.shrink());
  }

  SliverToBoxAdapter _bottomSpacer(BuildContext context) =>
      SliverToBoxAdapter(child: SizedBox(height: homeBottomClearance(context)));

  /// 官方搜索行右上角的「分类」入口（`alx.xml` `i_y`）。官方点它走
  /// `turnToCategoryTab` → `//category` 路由（`BookCategoryActivity` →
  /// `KmpCategoryFragment`）；这里打开同结构的分类页。
  void _openCategory() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CategoryPage()),
    );
  }

  void _openSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SearchPage()),
    );
  }

  /// The rank board. Its catalogue (and the rank id the entries endpoint needs)
  /// only exist inside the novel homepage response the app already fetches.
  ///
  /// Note: 榜单目录与 rank_id 的来源 — 见
  /// .agents/notes/implemented/feature/2026-09-11-discovery-pages.md
  void _openRanks() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RankPage()),
    );
  }

  /// Reloads the homepage rank preview for one board.
  ///
  /// Official flow: `RankMixContentHolder.K7` fetches the picked board through
  /// the same rank endpoint and swaps the preview in place, so the page stays
  /// put. Only the first page is needed — the rail scrolls the rest.
  Future<List<MediaItem>> _loadRankPreview(String rankId, int algo) async {
    final board = await ApiClient.instance.rankBoard(
      rankId: rankId,
      algo: algo,
    );
    return [
      for (final entry in board.entries)
        if (entry.id.isNotEmpty) entry.toMediaItem(),
    ];
  }

  void _openItem(MediaItem item) {
    // 成人推荐卡（source 带 engine: 前缀）：走站内详情链路，不进番茄详情页
    //（番茄详情拿这个 id 查不到书）；番茄与书旗卡保持原路由。
    if (item.source.startsWith('engine:')) {
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
      return;
    }
    openBookDetail(context, item);
  }

  Future<void> _resumeItem(MediaItem item) async {
    if (await openRecentBook(
      context,
      item,
      cache: widget.cacheStore,
      readerStore: widget.readerStore,
    )) {
      return;
    }
    if (!mounted) return;
    await openBookDetail(context, item, entry: BookOpenEntry.shelf);
  }
}
