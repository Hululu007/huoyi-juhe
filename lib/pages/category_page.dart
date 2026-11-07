import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/category_front.dart';
import '../services/api_client.dart';
import '../services/desktop_platform.dart';
import '../services/drama_site_content.dart';
import '../services/drama_site_search.dart';
import '../services/unified_video_categories.dart';
import '../services/user_facing_error.dart';
import '../services/video_category_tags.dart';
import '../widgets/category/category_dim_rail.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_feed_states.dart';
import 'search_page.dart';
import 'unified_browse_content_page.dart';

/// 官方分类页（`BookCategoryActivity`，7.0.9.32 实测形态）：
///
/// * 顶部横向频道 tab（男生/女生/有声书/出版/短剧/漫画；选中黑加粗，未选灰
///   #8C8C8C），左端返回、右端搜索；
/// * 左侧 88dp 维度栏（热门标签/主题/角色/情节），项高 50dp、14sp 居中，
///   **选中橙字、未选黑字**（真机像素取证，无指示条、无底色变化）；
/// * 右侧 12dp 圆角内容区：**所有分组纵向堆叠**（官方
///   `TabPageRightContent` 遍历 cells，每组一个组头 + `chunked(3)` 网格行；
///   老身份只回平铺数据，这里按「热门标签=全量 + 其余 dim 各一组」重建）。
///   组头 12sp 灰 #969696、行高 24dp，>30 的组在组头右端出「展开/收起」；
///   chip 为**等宽网格**（官方每颗 `weight(1f)`，尾行补 Spacer）：定高
///   30dp、圆角 6dp、底 #ECECEC、上6下4行距、7dp 列距、14sp 黑字居中，
///   热门项左侧 16dp 近黑火苗。官方在手机上固定三列；桌面窗口宽，这里按
///   [_chipTargetWidth] 加列（手机仍夹在三列），否则 chip 会被拉成横条。
/// * 左栏点击 → 滚动定位到对应分组（官方 `TabPageScrollEffect`），滚动
///   反向同步左栏高亮（官方 `c1` 按 firstVisibleItem 反查）。
///
/// 数据一次 GET 一个频道（`category_tab` 不同瓦片不同）。
///
/// 另有一个本地「影视」频道（tab value 为 `video`，不走服务端接口）：
/// 默认是统一模式——200 核心视频站的静态分类按名归并（热门分类/全部
/// 两组，点 chip 进多站内容汇总）；切到「本站」后回到单站模式——
/// 内容随当前视频站变化（本站分类 + 提取的标签/主题/角色/情节，
/// 成人站的热门标签里追加「熟女」），点 chip 进视频搜索。
/// 影视页右上角分类按钮直接以该频道打开本页。
/// 标签部分：统一数据里 `tags` 到了就多一组「标签」，点标签
/// 走站源搜索——但只搜该标签名下的站（`tagSitesFor` 给出的站 id，
/// 不是 200 多站全量扇出：全量扇出时请求在 RequestGate 16 并发后
/// 排队，站表尾部的站 45 秒预算耗在排队上就超时回空，页上什么都
/// 没有），搜索词去掉资产里带的站方计数后缀（如 okxxx 的 ` (896)`）。
/// 只收 browsable 为真的标签。
class CategoryPage extends StatefulWidget {
  const CategoryPage({
    super.key,
    this.loader,
    this.videoSiteId,
    this.openVideoTab = false,
    this.videoLoader,
    this.unifiedLoader,
    this.unifiedClientForSite,
  });

  /// 数据源注入（生产默认 [ApiClient.categoryFront]；测试替换，同
  /// [SearchPage] 的 loader 规矩——页测不落网络）。
  final Future<CategoryFront> Function({int tab})? loader;

  /// 影视频道要展示的视频站 id；为空时按影视页持久化的当前站找。
  final String? videoSiteId;

  /// 打开即落在影视频道（影视页分类按钮用）。
  final bool openVideoTab;

  /// 影视频道数据源注入（生产默认 [loadVideoCategoryData]；测试替换）。
  final Future<VideoCategoryData> Function(String siteId)? videoLoader;

  /// 统一分类数据源注入（生产默认 [loadUnifiedVideoCategories]；
  /// 测试替换，页测不落网络、不读真实资产）。
  final Future<UnifiedVideoCategories> Function()? unifiedLoader;

  /// 统一内容页取数客户端注入（生产默认 [dramaSiteContentClient]；
  /// 测试替换，点 chip 后的汇总页不落网络）。
  final DramaSiteContentClient? Function(String siteId)? unifiedClientForSite;

  @override
  State<CategoryPage> createState() => _CategoryPageState();
}

/// 右侧内容区的一个分组（官方 `CategoryCellItem` 的老 schema 重建）。
class _Section {
  const _Section(this.title, this.tiles);

  final String title;
  final List<CategoryTile> tiles;
}

/// 官方收起态每组只显示前 30 颗（`CollectionsKt.take(_, 30)`）。
const _collapsedCount = 30;

/// 桌面下每颗 chip 的目标宽度。
///
/// 官方在手机上把内容区 `chunked(3)` 三等分，375dp 屏上每颗约 80dp。桌面
/// 窗口宽得多，若仍死守三列，1280dp 下每颗会被拉到 350dp——一排三条 12:1
/// 的横条，中间大片空白。这里改成「内容区够宽就加列」：手机上仍夹在官方
/// 那 3 列（255 / 170 = 1.5），1280dp 下是 6 列（每颗约 187dp）。
const double _chipTargetWidth = 170;

/// 列数夹取区间：下限固定为官方的三列，上限防超宽屏（5K 全屏 2483dp）
/// 排出十几列后每颗又变得过窄。
const int _chipMinColumns = 3;
const int _chipMaxColumns = 10;

/// 按内容区可用宽度（已扣掉左右 padding）算列数。
int _chipColumnsFor(double contentWidth) => (contentWidth / _chipTargetWidth)
    .floor()
    .clamp(_chipMinColumns, _chipMaxColumns);

/// 服务端未返回频道表时影视频道顶栏的兜底频道（男生/女生/有声书/
/// 出版/短剧/漫画，value 与服务端口径一致；仅在影视频道首开、
/// 服务端频道表尚未拿到时展示，正常频道仍以服务端返回为准）。
const _fallbackTabs = [
  CategoryTab(name: '男生', value: '1'),
  CategoryTab(name: '女生', value: '2'),
  CategoryTab(name: '有声书', value: '3'),
  CategoryTab(name: '出版', value: '4'),
  CategoryTab(name: '短剧', value: '5'),
  CategoryTab(name: '漫画', value: '6'),
];

/// 影视频道的频道项（value 不是数字，绝不发给服务端接口）。
const _videoTab = CategoryTab(name: '影视', value: 'video');

class _CategoryPageState extends State<CategoryPage> {
  CategoryFront? _front;
  String? _error;
  String _tabValue = '1';
  int _selected = 0;
  bool _loading = false;

  /// 当前是否落在本地影视频道（不走服务端接口，分组直接按
  /// 热门标签/主题/角色/情节四组建，不过滤空组）。
  bool _isVideoTab = false;

  /// 影视频道是否在统一模式（默认）：全部站点的分类归并；
  /// 切到 false 为单站模式（本站四组）。
  bool _unifiedMode = true;

  /// 统一分类数据（首开影视频道时取一次，切模式/切频道复用缓存）。
  UnifiedVideoCategories? _unifiedData;

  /// 单站模式数据（切到「本站」时取一次，复用缓存）。
  VideoCategoryData? _singleData;

  /// 影视频道当前站 id（单站模式用；统一模式不需要站）。
  String? _videoSiteId;

  /// 统一模式页内搜索：输入框是否展开、当前过滤词。
  bool _unifiedSearching = false;
  String _unifiedQuery = '';
  final _unifiedSearchController = TextEditingController();

  /// 影视 tab 的 key：首开影视时把它滚进顶栏视野（手机上频道一排
  /// 放不下，影视在末尾，不滚用户看不到选中态）。
  final _videoTabKey = GlobalKey();

  /// 每次 [_load] 自增。请求回来时只有最新一代能落地：加载期间再切频道
  /// 不会被丢掉，先发后到的旧频道响应也不会覆盖新频道的内容。
  int _loadGeneration = 0;

  List<_Section> _sections = const [];
  final Set<int> _expanded = <int>{};
  final ScrollController _scroll = ScrollController();
  bool _programmaticScroll = false;

  /// 当前列数，由 [build] 里的 `LayoutBuilder` 按实际宽度写回。
  ///
  /// 滚动定位用的是「组高前缀和」，而行数按列数算，两者必须用同一个值；
  /// 列数只在布局阶段变化，所以这里存成普通字段而不是 `setState`——它不
  /// 影响已经渲染的内容，只在下一帧的 `_sectionHeight` 里被读到。
  int _columns = _chipMinColumns;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    if (widget.openVideoTab) {
      _loadVideo();
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _unifiedSearchController.dispose();
    super.dispose();
  }

  Future<CategoryFront> _fetch({required int tab}) =>
      widget.loader?.call(tab: tab) ??
      ApiClient.instance.categoryFront(tab: tab);

  Future<void> _load({String? tab}) async {
    final target = tab ?? _tabValue;
    if (target == _videoTab.value) return _loadVideo();
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
      _isVideoTab = false;
    });
    try {
      final front = await _fetch(tab: int.tryParse(target) ?? 1);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _tabValue = target;
        _front = front;
        _error = front.isEmpty ? '分类暂时没有内容，稍后再试' : null;
        _sections = front.isEmpty ? const <_Section>[] : _sectionsFor(front);
        _selected = 0;
        _expanded.clear();
      });
      // 频道重取后回到顶部（控制器复用，extent 已变，须等布局落地）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(0);
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _error = userFacingError(error));
    } finally {
      // 失败也要复位：否则转圈永远挡在重试前面，重试会被 `_loading` 吞掉。
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  /// 影视频道加载：默认统一模式（全部站点分类归并），不走服务端接口。
  /// 统一数据取一次后缓存，切模式/切频道复用；统一数据为空（资产
  /// 缺失）时退回单站模式。单站模式仍按站号取本站数据。
  Future<void> _loadVideo() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
      _isVideoTab = true;
    });
    try {
      _videoSiteId ??= widget.videoSiteId ?? await currentVideoZoneSiteId();
      _unifiedData ??= widget.unifiedLoader != null
          ? await widget.unifiedLoader!()
          : await loadUnifiedVideoCategories();
      if (!mounted || generation != _loadGeneration) return;
      final data = _unifiedData!;
      if (data.categories.isEmpty) {
        // 统一资产为空：退回单站模式（老行为），不留白页。
        await _loadSingleSite(generation: generation);
        return;
      }
      setState(() {
        _tabValue = _videoTab.value;
        _error = null;
        _unifiedMode = true;
        _unifiedSearching = false;
        _unifiedQuery = '';
        _unifiedSearchController.clear();
        _rebuildVideoSections();
      });
      _scrollVideoTabIntoView();
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _error = userFacingError(error));
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  /// 单站模式加载：本站四组（热门标签/主题/角色/情节），没数据的组
  /// 只留组头位置，不跳过——左栏四项始终齐全。切站后从影视页带新站号
  /// 打开本页，影视 tab 即显示新站的标签；无站号时按影视页持久化的
  /// 当前站找。数据取一次后缓存。
  Future<void> _loadSingleSite({int? generation}) async {
    final gen = generation ?? ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
      _isVideoTab = true;
    });
    try {
      final siteId =
          _videoSiteId ??= widget.videoSiteId ?? await currentVideoZoneSiteId();
      if (siteId == null || siteId.isEmpty) {
        throw StateError('请先在影视页选择站点');
      }
      _singleData ??= widget.videoLoader != null
          ? await widget.videoLoader!(siteId)
          : await loadVideoCategoryData(siteId);
      if (!mounted || gen != _loadGeneration) return;
      final data = _singleData!;
      List<CategoryTile> tiles(
        String section,
        List<String> names, {
        bool hot = false,
      }) => [
        for (var i = 0; i < names.length; i++)
          CategoryTile(
            name: names[i],
            dim: section,
            id: 'video_${section}_$i',
            hot: hot,
          ),
      ];
      setState(() {
        _tabValue = _videoTab.value;
        _error = null;
        _unifiedMode = false;
        _unifiedSearching = false;
        _unifiedQuery = '';
        _unifiedSearchController.clear();
        _sections = [
          _Section('热门标签', tiles('hot', data.hotTags, hot: true)),
          _Section('主题', tiles('theme', data.themes)),
          _Section('角色', tiles('role', data.roles)),
          _Section('情节', tiles('plot', data.plots)),
        ];
        _selected = 0;
        _expanded.clear();
      });
      _scrollVideoTabIntoView();
    } catch (error) {
      if (!mounted || gen != _loadGeneration) return;
      setState(() => _error = userFacingError(error));
    } finally {
      if (mounted && gen == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  void _scrollVideoTabIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
      final tabContext = _videoTabKey.currentContext;
      if (tabContext != null) {
        Scrollable.ensureVisible(
          tabContext,
          alignment: 1,
          duration: const Duration(milliseconds: 300),
        );
      }
    });
  }

  /// 影视频道模式切换：统一（全部站点）与单站之间切，数据用缓存，
  /// 不重复取；切回统一时清空页内搜索。
  void _setVideoMode(bool unified) {
    if (_loading || unified == _unifiedMode) return;
    if (unified) {
      if (_unifiedData == null) {
        unawaited(_loadVideo());
        return;
      }
      setState(() {
        _unifiedMode = true;
        _unifiedSearching = false;
        _unifiedQuery = '';
        _unifiedSearchController.clear();
        _rebuildVideoSections();
      });
    } else {
      if (_singleData == null) {
        unawaited(_loadSingleSite());
        return;
      }
      setState(() {
        _unifiedMode = false;
        _unifiedSearching = false;
        _unifiedQuery = '';
        _unifiedSearchController.clear();
        _rebuildVideoSections();
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  /// 按当前影视频道模式 + 页内搜索词重建分组（不取数）。
  ///
  /// 统一模式只有两组（热门分类/全部；视频分类没有主题/角色/情节
  /// 这种分法，不硬套小说那四组、不编假分组）。标签数据到了再多
  /// 一组「标签」（只含 browsable 为真的标签）。搜索词过滤 chip，
  /// 空组不显示。单站模式沿用老四组。
  void _rebuildVideoSections() {
    if (_unifiedMode) {
      final data = _unifiedData;
      if (data == null) {
        _sections = const [];
        _selected = 0;
        _expanded.clear();
        return;
      }
      bool matches(String name) => _unifiedQuery.isEmpty ||
          name.toLowerCase().contains(_unifiedQuery.toLowerCase());
      CategoryTile catTile(String name, {required bool hot}) =>
          CategoryTile(
            name: name,
            dim: 'unified_cat',
            id: 'unified_cat',
            hot: hot,
          );
      CategoryTile tagTile(String name) => CategoryTile(
        name: name,
        dim: 'unified_tag',
        id: 'unified_tag',
      );
      final sections = <_Section>[];
      final hot = [
        for (final name in data.hotNames)
          if (matches(name)) catTile(name, hot: true),
      ];
      if (hot.isNotEmpty) sections.add(_Section('热门分类', hot));
      final all = [
        for (final name in data.allNames)
          if (matches(name)) catTile(name, hot: false),
      ];
      if (all.isNotEmpty) sections.add(_Section('全部', all));
      final tags = [
        for (final name in data.tagNames)
          if (matches(name)) tagTile(name),
      ];
      if (tags.isNotEmpty) sections.add(_Section('标签', tags));
      _sections = sections;
    } else {
      final data = _singleData;
      if (data == null) {
        _sections = const [];
        _selected = 0;
        _expanded.clear();
        return;
      }
      List<CategoryTile> tiles(
        String section,
        List<String> names, {
        bool hot = false,
      }) => [
        for (var i = 0; i < names.length; i++)
          CategoryTile(
            name: names[i],
            dim: section,
            id: 'video_${section}_$i',
            hot: hot,
          ),
      ];
      _sections = [
        _Section('热门标签', tiles('hot', data.hotTags, hot: true)),
        _Section('主题', tiles('theme', data.themes)),
        _Section('角色', tiles('role', data.roles)),
        _Section('情节', tiles('plot', data.plots)),
      ];
    }
    _selected = 0;
    _expanded.clear();
  }

  /// 分组重建：首组「热门标签」= 全量瓦片（老 schema 的 dim=0 不下瓦片，
  /// 官方该组是跨 dim 精选，数据不可得，用全量保内容），其余 dim 各一组，
  /// 空组跳过。游离 dim 的瓦片只出现在首组。
  static List<_Section> _sectionsFor(CategoryFront front) {
    final out = <_Section>[_Section('热门标签', front.tiles)];
    for (final dim in front.dims) {
      if (dim.value == '0') continue;
      final tiles = front.tiles.where((t) => t.dim == dim.value).toList();
      if (tiles.isNotEmpty) out.add(_Section(dim.name, tiles));
    }
    return out;
  }

  // —— 滚动 ↔ 左栏联动（官方 R0 前缀和定位 + c1 反查）——
  // 所有行高都是定值：组头上距 16 + 组头 24 + 每网格行 40（上6+30+下4）；
  // 行数按当前列数 [_columns] 算，与 `_SectionView` 的换行步长同源。
  double _sectionHeight(int index) {
    final section = _sections[index];
    final visible = _expanded.contains(index)
        ? section.tiles.length
        : (section.tiles.length > _collapsedCount
              ? _collapsedCount
              : section.tiles.length);
    final rows = (visible / _columns).ceil();
    return 16 + 24 + rows * 40.0;
  }

  double _sectionOffset(int index) {
    var offset = 0.0;
    for (var i = 0; i < index; i++) {
      offset += _sectionHeight(i);
    }
    return offset;
  }

  void _onScroll() {
    if (_programmaticScroll) return;
    var selected = 0;
    for (var i = 0; i < _sections.length; i++) {
      if (_sectionOffset(i) <= _scroll.offset + 1) selected = i;
    }
    if (selected != _selected) setState(() => _selected = selected);
  }

  void _scrollToSection(int index) {
    if (!_scroll.hasClients) return;
    setState(() => _selected = index);
    final target = _sectionOffset(
      index,
    ).clamp(0.0, _scroll.position.maxScrollExtent).toDouble();
    _programmaticScroll = true;
    _scroll
        .animateTo(
          target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.ease,
        )
        .whenComplete(() {
          _programmaticScroll = false;
          if (mounted && _selected != index) {
            setState(() => _selected = index);
          }
        });
  }

  void _toggle(int index) {
    setState(() {
      if (!_expanded.remove(index)) _expanded.add(index);
    });
  }

  /// 顶部搜索图标：统一模式下展开页内搜索框（搜分类名/标签名过滤
  /// chip，不跳搜索页）；其余频道沿用老行为（跳搜索页）。
  void _onTopSearchTap() {
    if (_isVideoTab && _unifiedMode) {
      setState(() {
        _unifiedSearching = !_unifiedSearching;
        if (!_unifiedSearching) {
          _unifiedQuery = '';
          _unifiedSearchController.clear();
          _rebuildVideoSections();
        }
      });
      return;
    }
    _openSearch();
  }

  /// chip 点击分发：统一模式的分类 chip 进多站内容汇总页；
  /// 统一模式的标签 chip 与本站模式的 chip 进站源搜索（标签词
  /// 当关键词搜）；其余 chip（小说频道等）沿用老行为，进视频/
  /// 图书搜索。
  void _onTileTap(CategoryTile tile) {
    if (_isVideoTab && _unifiedMode) {
      final data = _unifiedData;
      if (tile.dim == 'unified_cat' && data != null) {
        final entries = data.sitesFor(tile.name);
        if (entries.isEmpty) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => UnifiedBrowseContentPage(
              title: tile.name,
              entries: entries,
              clientForSite: widget.unifiedClientForSite,
            ),
          ),
        );
        return;
      }
      if (tile.dim == 'unified_tag' && data != null) {
        // 标签不走多站汇总页：核心 catalog() 只认分类 id，标签的
        // 完整站内链接当分类 id 传过去拼不出地址（各站 catalog 对
        // 任意链接的认法还不一样，99jj/xojav/hl365 等会拼错地址或
        // 回空）；改走站源搜索，但只搜该标签名下的站。
        final tagSites = data.tagSitesFor(tile.name);
        if (tagSites.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('该标签下暂无可搜的站点')),
          );
          return;
        }
        _openSiteSearch(
          tile.name,
          siteIds: {for (final s in tagSites) s.siteId},
        );
        return;
      }
    }
    if (_isVideoTab && !_unifiedMode) {
      // 本站模式的标签也不走番茄搜索：番茄后端只有短剧数据，
      // 电影/剧集类标签词在那里搜不到（原始短剧搜得到、电影搜
      // 不到就是这么来的）；改走站源搜索，只搜本站，不向全站扇出。
      _openSiteSearch(
        tile.name,
        siteIds: _videoSiteId == null ? null : {_videoSiteId!},
      );
      return;
    }
    _openSearch(query: tile.name);
  }

  /// 标签点开走站源搜索（[SearchCategory.sites]）：只搜 [siteIds]
  /// 给出的站（统一标签是该标签名下的站，本站模式是本站），标签词
  /// 当关键词搜（去计数后缀，如 okxxx 的 ` (896)`），有结果的站才
  /// 列出来。`siteIds` 为空时搜全部可见站（老行为）。
  void _openSiteSearch(String query, {Set<String>? siteIds}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SearchPage(
          initialQuery: tagSearchQuery(query),
          initialCategory: SearchCategory.sites,
          initialSiteIds: siteIds,
        ),
      ),
    );
  }

  void _openSearch({String? query}) {
    final category = switch (_tabValue) {
      '3' => SearchCategory.audio,
      '5' => SearchCategory.manga,
      '6' || 'video' => SearchCategory.video,
      _ => SearchCategory.book,
    };
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            SearchPage(initialQuery: query, initialCategory: category),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final front = _front;
    return Scaffold(
      backgroundColor: palette.canvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(
              // 顶部频道：服务端频道表 + 本地影视频道；服务端表未拿到
              // 且落在影视频道时用兜底频道表，免得顶栏空着。
              tabs: [
                if (front != null && front.tabs.isNotEmpty)
                  ...front.tabs
                else if (_isVideoTab)
                  ..._fallbackTabs,
                _videoTab,
              ],
              selected: _tabValue,
              onSelect: (v) => _load(tab: v),
              onSearch: _onTopSearchTap,
              videoTabKey: _videoTabKey,
            ),
            if (_loading)
              Padding(
                padding: const EdgeInsets.only(top: 120),
                child: CircularProgressIndicator(color: HomePalette.accent),
              )
            else if (_error != null)
              Expanded(
                child: Center(
                  child: HomeStateView(
                    key: const Key('category_retry'),
                    icon: LucideIcons.cloud_off,
                    title: _error!,
                    actionLabel: '重试',
                    actionIcon: LucideIcons.refresh_cw,
                    onAction: () => _load(tab: _tabValue),
                  ),
                ),
              )
            else if (front != null || _isVideoTab)
              Expanded(
                // 列数按实际内容区宽度算：手机仍是官方三列，桌面按 170dp
                // 一颗的目标宽度加列，免得 chip 被拉成细长横条。
                child: Column(
                  children: [
                    if (_isVideoTab) _VideoModeRow(
                      unifiedMode: _unifiedMode,
                      loading: _loading,
                      onSelect: _setVideoMode,
                    ),
                    if (_isVideoTab && _unifiedMode && _unifiedSearching)
                      _UnifiedSearchRow(
                        controller: _unifiedSearchController,
                        onChanged: (value) {
                          setState(() {
                            _unifiedQuery = value;
                            _rebuildVideoSections();
                          });
                        },
                        onClose: () {
                          setState(() {
                            _unifiedSearching = false;
                            _unifiedQuery = '';
                            _unifiedSearchController.clear();
                            _rebuildVideoSections();
                          });
                        },
                      ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final columns = _chipColumnsFor(
                            constraints.maxWidth - categoryDimRailWidth - 32,
                          );
                          _columns = columns;
                          return Row(
                            children: [
                              CategoryDimRail(
                                titles: [
                                  for (final section in _sections)
                                    section.title,
                                ],
                                selectedIndex: _selected,
                                onSelect: _scrollToSection,
                              ),
                              Expanded(
                                child: _SectionList(
                                  state: this,
                                  columns: columns,
                                  onTileTap: _onTileTap,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 影视频道模式切换行：统一（全部站点）与单站两颗药丸，选中态明显
/// （选中 accent 底白字，未选描边灰字），只在影视频道出现。
class _VideoModeRow extends StatelessWidget {
  const _VideoModeRow({
    required this.unifiedMode,
    required this.loading,
    required this.onSelect,
  });

  final bool unifiedMode;
  final bool loading;
  final ValueChanged<bool> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    Widget pill(String label, bool selected, bool value) {
      return ChoiceChip(
        key: ValueKey(
          value ? 'unified_mode_all' : 'unified_mode_single',
        ),
        label: Text(label),
        selected: selected,
        onSelected: loading ? null : (_) => onSelect(value),
        selectedColor: HomePalette.accent,
        labelStyle: TextStyle(
          fontSize: 13,
          color: selected ? Colors.white : palette.ink,
        ),
        backgroundColor: palette.soft,
        side: BorderSide(
          color: selected ? HomePalette.accent : palette.line,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          pill('全部站点', unifiedMode, true),
          const SizedBox(width: 8),
          pill('本站', !unifiedMode, false),
        ],
      ),
    );
  }
}

/// 统一模式页内搜索行：搜分类名/标签名，输入即过滤右侧 chip；
/// 右端 X 关掉搜索框并清空过滤。
class _UnifiedSearchRow extends StatelessWidget {
  const _UnifiedSearchRow({
    required this.controller,
    required this.onChanged,
    required this.onClose,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('unified_category_search'),
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '搜分类名',
                prefixIcon: Icon(
                  LucideIcons.search,
                  size: 18,
                  color: palette.muted,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide(color: palette.line),
                ),
              ),
              onChanged: onChanged,
            ),
          ),
          IconButton(
            key: const ValueKey('unified_category_search_close'),
            icon: Icon(LucideIcons.x, size: 20, color: palette.ink),
            tooltip: '关闭搜索',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// 顶栏：返回 + 横向频道 tab + 搜索。
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.tabs,
    required this.selected,
    required this.onSelect,
    required this.onSearch,
    this.videoTabKey,
  });

  final List<CategoryTab> tabs;
  final String selected;
  final ValueChanged<String> onSelect;
  final VoidCallback onSearch;

  /// 影视 tab 的 key：首开影视时靠它把 tab 滚进视野。
  final Key? videoTabKey;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          // 桌面壳层顶栏已经有「← 火蚁聚合」，这里再放一个返回键就是两个
          // 箭头上下叠着。手机上保留官方形态。
          if (isWindowsDesktop)
            const SizedBox(width: 16)
          else
            IconButton(
              key: const Key('category_back'),
              icon: Icon(
                LucideIcons.chevron_left,
                size: 24,
                color: palette.ink,
              ),
              onPressed: () => Navigator.maybePop(context),
            ),
          Expanded(
            child: tabs.isEmpty
                ? const SizedBox.shrink()
                // 频道数少（≤8），不用懒加载列表：Row 全量构建，末尾的
                // 影视 tab 也有 context，首开影视时才能把它滚进视野。
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(right: 8),
                    child: Row(
                      children: [
                        for (var i = 0; i < tabs.length; i++) ...[
                          if (i > 0) const SizedBox(width: 24),
                          Builder(
                            builder: (context) {
                              final tab = tabs[i];
                              final isSelected = tab.value == selected;
                              return GestureDetector(
                                key: tab.value == _videoTab.value &&
                                        videoTabKey != null
                                    ? videoTabKey
                                    : ValueKey(
                                        'category_tab_${tab.value}',
                                      ),
                                behavior: HitTestBehavior.opaque,
                                onTap: () => onSelect(tab.value),
                                child: Center(
                                  child: Text(
                                    tab.name,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: isSelected
                                          ? FontWeight.w700
                                          : FontWeight.w400,
                                      color: isSelected
                                          ? palette.ink
                                          : (palette.eink
                                                ? palette.ink
                                                : const Color(0xFF8C8C8C)),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
          IconButton(
            key: const Key('category_search'),
            icon: Icon(LucideIcons.search, size: 20, color: palette.ink),
            tooltip: '搜索',
            onPressed: onSearch,
          ),
        ],
      ),
    );
  }
}

/// 右侧内容区：官方是 12dp 圆角画布 + `contentPadding(横16, 底16)` 的
/// LazyColumn，每组「组头 + chunked(3) 网格行」两个 item；此处一组一个
/// item（组头 + Column(网格行)），行高全是定值，滚动定位用前缀和。
class _SectionList extends StatelessWidget {
  const _SectionList({
    required this.state,
    required this.columns,
    required this.onTileTap,
  });

  final _CategoryPageState state;
  final int columns;
  final ValueChanged<CategoryTile> onTileTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.canvas,
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.builder(
        key: const ValueKey('category_tile_list'),
        controller: state._scroll,
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        itemCount: state._sections.length,
        itemBuilder: (context, index) => _SectionView(
          state: state,
          index: index,
          section: state._sections[index],
          columns: columns,
          onTileTap: onTileTap,
        ),
      ),
    );
  }
}

class _SectionView extends StatelessWidget {
  const _SectionView({
    required this.state,
    required this.index,
    required this.section,
    required this.columns,
    required this.onTileTap,
  });

  final _CategoryPageState state;
  final int index;
  final _Section section;
  final int columns;
  final ValueChanged<CategoryTile> onTileTap;

  @override
  Widget build(BuildContext context) {
    final collapsible = section.tiles.length > _collapsedCount;
    final visible = collapsible && !state._expanded.contains(index)
        ? section.tiles.take(_collapsedCount).toList()
        : section.tiles;

    return Column(
      children: [
        _SectionHeader(
          keyIndex: index,
          title: section.title,
          collapsible: collapsible,
          expanded: state._expanded.contains(index),
          onToggle: () => state._toggle(index),
        ),
        for (var i = 0; i < visible.length; i += columns)
          _ChipRow(
            tiles: visible.sublist(i, (i + columns).clamp(0, visible.length)),
            columns: columns,
            onTileTap: onTileTap,
          ),
      ],
    );
  }
}

/// 组头行：上距 16、行高 24；左端组名（12sp 灰），>30 的组右端挂
/// 「展开/收起」（12sp + 12dp 箭头，官方 `CategoryLayoutKt` 766-786）。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.keyIndex,
    required this.title,
    required this.collapsible,
    required this.expanded,
    required this.onToggle,
  });

  final int keyIndex;
  final String title;
  final bool collapsible;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final gray = palette.dark || palette.eink
        ? palette.muted
        : const Color(0xFF969696);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: SizedBox(
        height: 24,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: TextStyle(fontSize: 12, color: gray)),
            if (collapsible)
              GestureDetector(
                key: ValueKey('category_expand_toggle_$keyIndex'),
                behavior: HitTestBehavior.opaque,
                onTap: onToggle,
                child: Row(
                  children: [
                    Text(
                      expanded ? '收起' : '展开',
                      style: TextStyle(fontSize: 12, color: gray),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      expanded
                          ? LucideIcons.chevron_up
                          : LucideIcons.chevron_down,
                      size: 12,
                      color: gray,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 一行 [columns] 颗等宽 chip（官方 `chunked(3)` + 每颗 `weight(1f)`，手机上
/// 就是三列；桌面按宽度加列）。不足 [columns] 颗的尾行用同权 Spacer 补位，
/// 保持前几颗不抢宽。列距 7dp。
class _ChipRow extends StatelessWidget {
  const _ChipRow({
    required this.tiles,
    required this.columns,
    required this.onTileTap,
  });

  final List<CategoryTile> tiles;
  final int columns;
  final ValueChanged<CategoryTile> onTileTap;

  @override
  Widget build(BuildContext context) {
    final cells = <Widget>[];
    for (var i = 0; i < columns; i++) {
      if (i > 0) cells.add(const SizedBox(width: 7));
      cells.add(
        Expanded(
          child: i < tiles.length
              ? _CategoryChip(
                  tile: tiles[i],
                  onTap: () => onTileTap(tiles[i]),
                )
              : const SizedBox(),
        ),
      );
    }
    return Row(children: cells);
  }
}

/// 一颗分类 chip：定宽（由 `_ChipRow` 的 Expanded 决定）、定高 30dp、
/// 圆角 6dp、底 #ECECEC、上下边距 6/4；内容水平居中，热门项左侧 16dp
/// 近黑火苗（真机像素取证：官方火苗非橙，与文字同色系）。
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.tile, required this.onTap});

  final CategoryTile tile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: HomePressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        semanticLabel: '搜索${tile.name}分类',
        child: Container(
          key: ValueKey('category_tile_${tile.id}_${tile.name}'),
          height: 30,
          decoration: BoxDecoration(
            color: palette.eink
                ? Colors.white
                : (palette.dark ? palette.soft : const Color(0xFFECECEC)),
            borderRadius: BorderRadius.circular(6),
            border: palette.eink ? Border.all(color: palette.line) : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (tile.hot) ...[
                Icon(LucideIcons.flame, size: 16, color: palette.ink),
                const SizedBox(width: 2),
              ],
              Text(
                tile.name,
                style: TextStyle(fontSize: 14, color: palette.ink),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
