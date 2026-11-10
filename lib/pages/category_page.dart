import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/category_front.dart';
import '../services/api_client.dart';
import '../services/desktop_platform.dart';
import '../services/drama_site_content.dart';
import '../services/drama_site_play.dart';
import '../services/drama_site_search.dart';
import '../services/drama_sites.dart';
import '../services/source_registry.dart';
import '../services/unified_video_categories.dart';
import '../services/user_facing_error.dart';
import '../services/video_category_tags.dart';
import '../widgets/category/category_dim_rail.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_feed_states.dart';
import '../widgets/home/moyi_channel_card.dart';
import 'rank_page.dart';
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

  /// 魔蚁风频道分类页的状态（只影视频道用，阅读模式不动）：
  /// 左栏选中的分类（「热门」「全部」是伪分类，见 [_moyiSourcesFor]）、
  /// 筛选行排序/状态、类型下拉、取到的作品与取数代际。
  String _moyiSelected = '热门';
  String _moyiSort = 'hot';
  String _moyiType = 'all';
  List<MoyiChannelWork> _moyiWorks = const [];
  bool _moyiWorksLoading = false;
  String? _moyiWorksError;
  int _moyiWorksGeneration = 0;

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
        _moyiSelected = '热门';
      });
      unawaited(_loadMoyiWorks());
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
        _moyiSelected = '热门';
      });
      unawaited(_loadMoyiWorks());
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
        _moyiSelected = '热门';
      });
      unawaited(_loadMoyiWorks());
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
        _moyiSelected = '热门';
      });
      unawaited(_loadMoyiWorks());
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

  // —— 魔蚁风频道分类页（只影视频道用）——
  //
  // 版式对照图 1/图 2：顶部「频道分类」大标题 + 搜索/奖杯圆钮；
  // 筛选行「全部类型（下拉）/热门/最新/完结」；左栏是本站真实内容
  // 分类（统一模式是统一分类 + 可浏览标签前 40，本站模式是本站
  // 分类 + 主题/角色/情节），选中蓝色高亮 pill；右侧 2 列大卡
  // （左高右矮，见 MoyiChannelWorksGrid），点卡走原站详情链路
  // （openDramaSiteItem，与多站内容汇总页同路，不新写播放）。
  //
  // 取数与统一内容汇总页同路：一个分类名下取前 4 站的 catalog(path, 1)
  // 并行取，取不到的站跳过；「热门」取热门分类前 3 名各首站，
  // 「全部」取全部分类前 4 名各首站。单站模式没有分类路径，
  // 先调客户端 categories() 按名找 id 再 catalog(id, 1)。
  // 作品只取一次，筛选行在本地列表上排/滤，不重复发请求。
  //
  // 排序/状态用的都是站方备注里的真实信号（见 moyi_channel_card.dart）：
  // 热门 = 所属分类站数多在前、站内原顺序；最新 = 备注日期新在前，
  // 没日期的按「更新至 N 集」集数排、再没信号的保持原顺序；
  // 完结 = 只留备注写着完结/全集/大结局的。全部类型下拉不过滤时
  // 左栏分类 + 标签都显示；选「分类」只留分类，选「标签」只留标签。

  /// 左栏一项：分类名 + 种类（分类/标签，类型下拉靠它过滤）。
  List<_MoyiLeftEntry> get _moyiLeftEntries {
    final query = _unifiedQuery.trim().toLowerCase();
    bool matches(String name) =>
        query.isEmpty || name.toLowerCase().contains(query);
    final entries = <_MoyiLeftEntry>[
      const _MoyiLeftEntry('热门', 'cat'),
      const _MoyiLeftEntry('全部', 'cat'),
    ];
    final seen = {'热门', '全部'};
    void add(String name, String kind) {
      if (name.isEmpty || !seen.add(name) || !matches(name)) return;
      entries.add(_MoyiLeftEntry(name, kind));
    }

    if (_unifiedMode) {
      final data = _unifiedData;
      if (data != null) {
        if (_moyiType != 'tag') {
          for (final name in data.allNames) {
            add(name, 'cat');
          }
        }
        if (_moyiType != 'cat') {
          for (final name in data.tagNames.take(40)) {
            add(name, 'tag');
          }
        }
      }
    } else {
      final data = _singleData;
      if (data != null) {
        if (_moyiType != 'tag') {
          for (final name in data.hotTags) {
            add(name, 'cat');
          }
        }
        if (_moyiType != 'cat') {
          for (final name in [
            ...data.themes,
            ...data.roles,
            ...data.plots,
          ]) {
            add(name, 'tag');
          }
        }
      }
    }
    return entries;
  }

  /// 左栏选中项被类型下拉/页内搜索滤掉时，回到「热门」并重取作品。
  void _ensureMoyiSelectionValid() {
    if (_moyiLeftEntries.any((e) => e.name == _moyiSelected)) return;
    setState(() => _moyiSelected = '热门');
    unawaited(_loadMoyiWorks());
  }

  void _selectMoyiCategory(String name) {
    if (name == _moyiSelected) return;
    setState(() => _moyiSelected = name);
    unawaited(_loadMoyiWorks());
  }

  void _setMoyiSort(String sort) {
    if (sort == _moyiSort) return;
    setState(() => _moyiSort = sort);
  }

  void _setMoyiType(String type) {
    if (type == _moyiType) return;
    setState(() => _moyiType = type);
    _ensureMoyiSelectionValid();
  }

  Future<DramaSiteContentClient?> _moyiClientFor(String siteId) async =>
      widget.unifiedClientForSite?.call(siteId) ??
      dramaSiteContentClient(siteId) ??
      await SourceRegistry.instance.clientFor(siteId);

  /// 选中分类对应的取数源（站 + 目录路径/分类 id + 分类名 + 分类站数）。
  Future<List<_MoyiSource>> _moyiSourcesFor(String name) async {
    if (_unifiedMode) {
      final data = _unifiedData;
      if (data == null) return const [];
      if (name == '热门') {
        return [
          for (final cat in data.hotNames.take(3))
            for (final entry in data.sitesFor(cat).take(1))
              _MoyiSource(
                entry.siteId,
                entry.path,
                cat,
                data.siteCountFor(cat),
              ),
        ];
      }
      if (name == '全部') {
        return [
          for (final cat in data.allNames.take(4))
            for (final entry in data.sitesFor(cat).take(1))
              _MoyiSource(
                entry.siteId,
                entry.path,
                cat,
                data.siteCountFor(cat),
              ),
        ];
      }
      final cats = data.sitesFor(name);
      if (cats.isNotEmpty) {
        return [
          for (final entry in cats.take(4))
            _MoyiSource(
              entry.siteId,
              entry.path,
              name,
              data.siteCountFor(name),
            ),
        ];
      }
      final tags = data.tagSitesFor(name);
      return [
        for (final tag in tags.take(4))
          _MoyiSource(tag.siteId, tag.url, name, tags.length),
      ];
    }
    final siteId = _videoSiteId;
    if (siteId == null || siteId.isEmpty) return const [];
    final client = await _moyiClientFor(siteId);
    if (client == null) return const [];
    late final List<DramaSiteCategory> cats;
    try {
      cats = await client.categories().timeout(
        const Duration(seconds: 30),
      );
    } catch (_) {
      return const [];
    }
    String? idFor(String categoryName) {
      for (final cat in cats) {
        if (cat.name.trim() == categoryName) return cat.id;
      }
      return null;
    }

    final names = switch (name) {
      '热门' => (_singleData?.hotTags ?? []).take(3).toList(),
      '全部' => (_singleData?.hotTags ?? []).take(4).toList(),
      _ => [name],
    };
    return [
      for (final cat in names)
        if (idFor(cat) case final String id
            when id.isNotEmpty && id != 'all')
          _MoyiSource(siteId, id, cat, 0),
    ];
  }

  /// 取选中分类的作品：前 4 源并行 catalog(path, 1)，一站取不到跳过，
  /// 最多留 24 部。代际 guard：切分类/切模式后先到的旧响应不落地。
  Future<void> _loadMoyiWorks() async {
    final generation = ++_moyiWorksGeneration;
    setState(() {
      _moyiWorksLoading = true;
      _moyiWorksError = null;
    });
    final sources = await _moyiSourcesFor(_moyiSelected);
    if (!mounted || generation != _moyiWorksGeneration) return;
    if (sources.isEmpty) {
      setState(() {
        _moyiWorks = const [];
        _moyiWorksLoading = false;
        _moyiWorksError = null;
      });
      return;
    }
    final results = await Future.wait([
      for (final source in sources) _fetchMoyiSource(source),
    ]);
    if (!mounted || generation != _moyiWorksGeneration) return;
    final works = <MoyiChannelWork>[];
    final seen = <String>{};
    for (final batch in results) {
      for (final work in batch) {
        // 同一站同一作品（多分类/多源重叠）只留一部，不然同列会
        // 出现重复 key。
        if (seen.add('${work.siteId}_${work.item.id}')) {
          works.add(work);
        }
      }
    }
    setState(() {
      _moyiWorks = works.take(24).toList();
      _moyiWorksLoading = false;
      _moyiWorksError = works.isEmpty ? '这些站现在都打不开，稍后再试' : null;
    });
  }

  Future<List<MoyiChannelWork>> _fetchMoyiSource(
    _MoyiSource source,
  ) async {
    try {
      final client = await _moyiClientFor(source.siteId);
      if (client == null) return const [];
      final page = await client.catalog(source.path, 1).timeout(
        ApiClient.dramaCatalogTimeout + const Duration(seconds: 5),
      );
      return [
        for (var i = 0; i < page.items.length; i++)
          MoyiChannelWork(
            item: page.items[i],
            siteId: source.siteId,
            siteName: _moyiSiteDisplayName(source.siteId),
            category: source.category,
            categorySiteCount: source.siteCount,
            index: i,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  String _moyiSiteDisplayName(String siteId) {
    for (final site in allDramaSites) {
      if (site.id == siteId) return site.name;
    }
    return siteId;
  }

  /// 筛选行在已取到的作品上排/滤（不重发请求）。
  List<MoyiChannelWork> get _moyiVisibleWorks {
    final list = List<MoyiChannelWork>.of(_moyiWorks);
    if (_moyiSort == 'finished') {
      list.retainWhere((work) => work.isFinished);
    } else if (_moyiSort == 'latest') {
      list.sort((a, b) {
        final aDate = a.remarkDate;
        final bDate = b.remarkDate;
        if (aDate != null && bDate != null) {
          final byDate = bDate.compareTo(aDate);
          if (byDate != 0) return byDate;
        } else if (aDate != null) {
          return -1;
        } else if (bDate != null) {
          return 1;
        }
        final aEp = a.episodeNumber;
        final bEp = b.episodeNumber;
        if (aEp != null && bEp != null) {
          final byEp = bEp.compareTo(aEp);
          if (byEp != 0) return byEp;
        } else if (aEp != null) {
          return -1;
        } else if (bEp != null) {
          return 1;
        }
        return a.index.compareTo(b.index);
      });
      return list;
    }
    list.sort((a, b) {
      final byCount = b.categorySiteCount.compareTo(a.categorySiteCount);
      return byCount != 0 ? byCount : a.index.compareTo(b.index);
    });
    return list;
  }

  /// 卡片点开走原站详情链路（与多站内容汇总页同路，不新写播放）。
  void _onMoyiWorkTap(MoyiChannelWork work) {
    unawaited(openDramaSiteItem(context, work.siteId, work.item));
  }

  void _openMoyiRank() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const RankPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 影视频道走魔蚁风：深紫蓝渐变底 + 大标题 + 筛选行 + 左栏分类 +
    // 右侧 2 列大卡；阅读模式（图书分类）仍走下面的官方风老布局。
    if (_isVideoTab) {
      return Scaffold(
        backgroundColor: const Color(0xFF1E1445),
        body: _buildMoyiVideo(context),
      );
    }
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

  /// 魔蚁风影视频道整页：深紫蓝渐变底，头 + 筛选行 + 模式行 +
  /// （左栏分类 | 右侧作品网格）。数据未到时网格区转圈/报错，
  /// 不整页白屏。
  Widget _buildMoyiVideo(BuildContext context) {
    final entries = _moyiLeftEntries;
    final visible = _moyiVisibleWorks;
    final showSearch = _unifiedMode && _unifiedSearching;
    Widget gridBody;
    if ((_loading && _unifiedData == null && _singleData == null) ||
        _moyiWorksLoading) {
      gridBody = const Center(
        child: CircularProgressIndicator(color: Color(0xFF29B6F6)),
      );
    } else if (_error != null &&
        _unifiedData == null &&
        _singleData == null) {
      gridBody = Center(
        child: HomeStateView(
          key: const Key('category_retry'),
          icon: LucideIcons.cloud_off,
          title: _error!,
          actionLabel: '重试',
          actionIcon: LucideIcons.refresh_cw,
          onAction: () => _load(tab: _tabValue),
        ),
      );
    } else if (_moyiWorksError != null) {
      gridBody = Center(
        child: HomeStateView(
          icon: LucideIcons.cloud_off,
          title: _moyiWorksError!,
          actionLabel: '重试',
          actionIcon: LucideIcons.refresh_cw,
          onAction: () => unawaited(_loadMoyiWorks()),
        ),
      );
    } else if (visible.isEmpty) {
      gridBody = Center(
        child: Text(
          _moyiSort == 'finished'
              ? '该分类下暂无完结作品'
              : _moyiWorks.isEmpty
                  ? '该分类下暂无作品'
                  : '没有符合筛选的作品',
          style: const TextStyle(fontSize: 14, color: Color(0xFFB9B2D6)),
        ),
      );
    } else {
      gridBody = MoyiChannelWorksGrid(
        works: visible,
        onTap: _onMoyiWorkTap,
      );
    }
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF3D1E7A),
            Color(0xFF1E1445),
            Color(0xFF120A2E),
          ],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _MoyiHeader(
              onBack: () => Navigator.maybePop(context),
              onHome: () =>
                  Navigator.of(context).popUntil((route) => route.isFirst),
              onSearch: _onTopSearchTap,
              onRank: _openMoyiRank,
            ),
            _MoyiFilterRow(
              type: _moyiType,
              sort: _moyiSort,
              onHome: () =>
                  Navigator.of(context).popUntil((route) => route.isFirst),
              onType: _setMoyiType,
              onSort: _setMoyiSort,
            ),
            _VideoModeRow(
              unifiedMode: _unifiedMode,
              loading: _loading,
              onSelect: _setVideoMode,
            ),
            if (showSearch)
              _UnifiedSearchRow(
                controller: _unifiedSearchController,
                onChanged: (value) {
                  setState(() {
                    _unifiedQuery = value;
                    _rebuildVideoSections();
                  });
                  _ensureMoyiSelectionValid();
                },
                onClose: () {
                  setState(() {
                    _unifiedSearching = false;
                    _unifiedQuery = '';
                    _unifiedSearchController.clear();
                    _rebuildVideoSections();
                  });
                  _ensureMoyiSelectionValid();
                },
              ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _MoyiLeftRail(
                    entries: entries,
                    selected: _moyiSelected,
                    onSelect: _selectMoyiCategory,
                  ),
                  Expanded(child: gridBody),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 魔蚁风频道分类页顶栏（图 1/图 2）：粉紫渐变返回圆钮 + 「频道分类」
/// 大标题 + 搜索/奖杯圆钮（深色描边圆，搜索进页内筛选、奖杯进榜单页）。
class _MoyiHeader extends StatelessWidget {
  const _MoyiHeader({
    required this.onBack,
    required this.onHome,
    required this.onSearch,
    required this.onRank,
  });

  final VoidCallback onBack;
  final VoidCallback onHome;
  final VoidCallback onSearch;
  final VoidCallback onRank;

  @override
  Widget build(BuildContext context) {
    Widget circle({
      required Widget child,
      required VoidCallback onTap,
      Key? key,
      bool gradient = false,
    }) {
      return GestureDetector(
        key: key,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: gradient
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFF061FF), Color(0xFF7C3AED)],
                  )
                : null,
            color: gradient ? null : Colors.white.withValues(alpha: 0.08),
            border: gradient
                ? null
                : Border.all(color: Colors.white.withValues(alpha: 0.16)),
          ),
          child: Center(child: child),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          circle(
            key: const Key('category_back'),
            gradient: true,
            onTap: onBack,
            child: const Icon(
              LucideIcons.chevron_left,
              size: 26,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          const Text(
            '频道分类',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const Spacer(),
          circle(
            key: const Key('category_search'),
            onTap: onSearch,
            child: const Icon(
              LucideIcons.search,
              size: 20,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 10),
          circle(
            key: const ValueKey('moyi_rank'),
            onTap: onRank,
            child: const Icon(
              LucideIcons.trophy,
              size: 20,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// 魔蚁风筛选行（图 1/图 2）：粉紫主页圆钮 + 「全部类型」下拉
/// + 「热门/最新/完结」三颗 pill，选中是亮蓝渐变 pill 黑字。
class _MoyiFilterRow extends StatelessWidget {
  const _MoyiFilterRow({
    required this.type,
    required this.sort,
    required this.onHome,
    required this.onType,
    required this.onSort,
  });

  final String type;
  final String sort;
  final VoidCallback onHome;
  final ValueChanged<String> onType;
  final ValueChanged<String> onSort;

  @override
  Widget build(BuildContext context) {
    const selectedGradient = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [Color(0xFF4FC3F7), Color(0xFF1E88E5)],
    );
    Widget pill({
      required String label,
      required bool selected,
      required VoidCallback onTap,
      Key? key,
      IconData? icon,
    }) {
      return GestureDetector(
        key: key,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: selected ? selectedGradient : null,
            color: selected ? null : Colors.white.withValues(alpha: 0.08),
            border: selected
                ? null
                : Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 15,
                  color: selected ? Colors.black87 : const Color(0xFFD8D2EE),
                ),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                  color: selected ? Colors.black87 : const Color(0xFFD8D2EE),
                ),
              ),
            ],
          ),
        ),
      );
    }

    String typeLabel(String value) => switch (value) {
      'cat' => '分类',
      'tag' => '标签',
      _ => '全部类型',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            GestureDetector(
              key: const ValueKey('moyi_home'),
              behavior: HitTestBehavior.opaque,
              onTap: onHome,
              child: Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFF061FF), Color(0xFF7C3AED)],
                  ),
                ),
                child: const Center(
                  child: Icon(
                    LucideIcons.house,
                    size: 20,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            PopupMenuButton<String>(
              key: const ValueKey('moyi_type_filter'),
              tooltip: '类型',
              color: const Color(0xFF2A2150),
              onSelected: onType,
              itemBuilder: (_) => [
                for (final entry in const [
                  ('all', '全部类型'),
                  ('cat', '分类'),
                  ('tag', '标签'),
                ])
                  PopupMenuItem<String>(
                    key: ValueKey('moyi_type_${entry.$1}'),
                    value: entry.$1,
                    child: Row(
                      children: [
                        Text(
                          entry.$2,
                          style: const TextStyle(color: Colors.white),
                        ),
                        const Spacer(),
                        if (type == entry.$1)
                          const Icon(
                            LucideIcons.check,
                            size: 16,
                            color: Color(0xFF4FC3F7),
                          ),
                      ],
                    ),
                  ),
              ],
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: Colors.white.withValues(alpha: 0.08),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.14),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      LucideIcons.chevron_down,
                      size: 15,
                      color: Color(0xFFD8D2EE),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      typeLabel(type),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFFD8D2EE),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            pill(
              key: const ValueKey('moyi_filter_hot'),
              label: '热门',
              selected: sort == 'hot',
              onTap: () => onSort('hot'),
            ),
            const SizedBox(width: 8),
            pill(
              key: const ValueKey('moyi_filter_latest'),
              label: '最新',
              selected: sort == 'latest',
              onTap: () => onSort('latest'),
            ),
            const SizedBox(width: 8),
            pill(
              key: const ValueKey('moyi_filter_finished'),
              label: '完结',
              selected: sort == 'finished',
              onTap: () => onSort('finished'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 魔蚁风左栏（图 1/图 2）：一长串内容分类纵向排，选中是亮蓝渐变
/// pill 黑字，未选是淡紫灰字；「热门」带火苗、「全部」带格子图标，
/// 其余带场记板图标。宽 96，可纵向滚动。
class _MoyiLeftRail extends StatelessWidget {
  const _MoyiLeftRail({
    required this.entries,
    required this.selected,
    required this.onSelect,
  });

  final List<_MoyiLeftEntry> entries;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 96,
      child: ListView.builder(
        key: const ValueKey('moyi_left_rail'),
        padding: const EdgeInsets.fromLTRB(8, 6, 4, 16),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          final isSelected = entry.name == selected;
          final icon = switch (entry.name) {
            '热门' => LucideIcons.flame,
            '全部' => LucideIcons.layout_grid,
            _ => LucideIcons.clapperboard,
          };
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: GestureDetector(
              key: ValueKey('moyi_left_${entry.name}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelect(entry.name),
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: isSelected
                      ? const LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [Color(0xFF4FC3F7), Color(0xFF1E88E5)],
                        )
                      : null,
                ),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 15,
                      color: isSelected
                          ? Colors.black87
                          : const Color(0xFFB9B2D6),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: isSelected
                              ? FontWeight.w800
                              : FontWeight.w500,
                          color: isSelected
                              ? Colors.black87
                              : const Color(0xFFB9B2D6),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 左栏一项：分类名 + 种类（`cat` 分类 / `tag` 标签）。
class _MoyiLeftEntry {
  const _MoyiLeftEntry(this.name, this.kind);

  final String name;
  final String kind;
}

/// 一个取数源：站 id + 目录路径（统一分类是 CATS path、标签是标签链接、
/// 本站模式是客户端 categories() 的 id）+ 分类名 + 分类站数。
class _MoyiSource {
  const _MoyiSource(this.siteId, this.path, this.category, this.siteCount);

  final String siteId;
  final String path;
  final String category;
  final int siteCount;
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
    Widget pill(String label, bool selected, bool value) {
      return ChoiceChip(
        key: ValueKey(
          value ? 'unified_mode_all' : 'unified_mode_single',
        ),
        label: Text(label),
        selected: selected,
        onSelected: loading ? null : (_) => onSelect(value),
        selectedColor: const Color(0xFF29B6F6),
        labelStyle: TextStyle(
          fontSize: 13,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? Colors.black87 : const Color(0xFFD8D2EE),
        ),
        backgroundColor: Colors.white.withValues(alpha: 0.08),
        side: BorderSide(
          color: selected
              ? Colors.transparent
              : Colors.white.withValues(alpha: 0.14),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
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

/// 统一模式页内搜索行：搜分类名/标签名，输入即过滤左侧分类；
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('unified_category_search'),
              controller: controller,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: '搜分类名',
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                ),
                prefixIcon: Icon(
                  LucideIcons.search,
                  size: 18,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.08),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide(
                    color: Colors.white.withValues(alpha: 0.14),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide(
                    color: Colors.white.withValues(alpha: 0.14),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: const BorderSide(color: Color(0xFF4FC3F7)),
                ),
              ),
              onChanged: onChanged,
            ),
          ),
          IconButton(
            key: const ValueKey('unified_category_search_close'),
            icon: const Icon(LucideIcons.x, size: 20, color: Colors.white),
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
