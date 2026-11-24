import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'actress_adapter_repository.dart';
import 'actress_adapter_store.dart';
import 'actress_adapter_models.dart';
import 'actress_adapter_player.dart';
import 'actress_database.dart';
import 'actress_film_library.dart';
import 'actress_list_page.dart';
import 'actress_neon.dart';
import 'whos_fallback.dart';
import 'whos_local_library.dart';

/// 女优库（2026-11-21 用户令：模块区域 UI 改用 nvku 那套网页的样式，
/// 在线站与本地数据库同一套分类与标签索引）。
///
/// 版式照 nvku-8m2c 的网页来：深色底 + 顶栏品牌/条数徽标 + 搜索框 +
/// 底部四个页签（首页 / 分类 / 女优 / 收藏）。数据两条腿：
/// - 在线：nvku 内置源（32 万条、有码/无码/4K/其它），分类与条数取自
///   站点自己的 meta；
/// - 本地：用户本地 whos 库 + 用户视频库（MYTV/db），分类/厂牌标签与
///   数据库同一口径，在线取不到内容时自动降级到本地，不留白屏。
/// 「女优」页签就是原来的女优库列表页（本地库名册 + 站点筛选 +
/// 同步/现爬都在那边），这里只换外壳，不重做数据层。
class ActressNvkuPage extends StatefulWidget {
  const ActressNvkuPage({
    super.key,
    required this.repository,
    required this.store,
    this.database,
    this.showTitle = true,
  });

  final AppRepository repository;
  final LocalStore store;
  final ActressDatabase? database;
  final bool showTitle;

  @override
  State<ActressNvkuPage> createState() => _ActressNvkuPageState();
}

// nvku 网页配色（style.css 的 :root）：霓虹化后正文/卡面/线条
// 走 Neon 常量，只剩品牌粉 _pk 还用在加载圈上。
const _pk = Color(0xFFFF2F6D);

const _favKey = 'actress_nvku_fav';

/// 分类名去尾数：“有码 · 251867”→“有码”；没尾数原样返回。
/// 尾数不是数字时也原样返回（名字里本来就带“ · ”的不误伤）。
String cleanNvkuCategoryName(String name) {
  final index = name.lastIndexOf(' · ');
  if (index <= 0) return name.trim();
  final tail = name.substring(index + 3).trim();
  if (tail.isEmpty || int.tryParse(tail) == null) return name.trim();
  return name.substring(0, index).trim();
}

/// 选中分类 → 视频主分类名（供本地兜底按主分类筛库）：
/// 站点分类 c0/c1… 的名字就是主分类名（去尾数后），主分类标签
/// main:xxx 直接取冒号后的名字；最新/排行/厂牌不过滤（回空）。
String nvkuVideoCategoryFor(
  String category,
  List<CatalogCategory> siteCategories,
) {
  if (category.startsWith('main:')) {
    return category.substring('main:'.length).trim();
  }
  if (category == 'new' ||
      category == 'rank' ||
      category.startsWith('brand:')) {
    return '';
  }
  for (final site in siteCategories) {
    if (site.id != category) continue;
    return cleanNvkuCategoryName(site.name);
  }
  return '';
}

/// 全部可点标签：站点分类打头，本地分类（最新/排行/厂牌）随后，
/// 库里主分类补在最后——站点已有的主分类（同名）不重复摆，
/// 站被挡时主分类标签照样全在。
List<CatalogCategory> nvkuAllCategories(
  List<CatalogCategory> siteCategories,
  List<CatalogCategory> localCategories,
  List<CatalogCategory> mainCategories,
) {
  final covered = <String>{
    for (final site in siteCategories) cleanNvkuCategoryName(site.name),
  };
  return [
    ...siteCategories,
    ...localCategories.where(
      (row) => !siteCategories.any((site) => site.id == row.id),
    ),
    ...mainCategories.where(
      (row) => !covered.contains(cleanNvkuCategoryName(row.name)),
    ),
  ];
}

class _ActressNvkuPageState extends State<ActressNvkuPage> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  var _tab = 0;
  var _query = '';

  var _siteCategories = <CatalogCategory>[];
  var _localCategories = <CatalogCategory>[];
  var _mainCategories = <CatalogCategory>[];
  var _category = 'new';
  var _works = <Drama>[];
  var _page = 1;
  var _hasMore = true;
  var _loading = false;
  var _loadingMore = false;
  var _offline = false;
  var _favorites = <_FavItem>[];
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_boot());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    await _loadFavorites();
    await _loadCategories();
    await _loadWorks(reset: true);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 600) {
      unawaited(_loadWorks());
    }
  }

  Future<void> _loadCategories() async {
    var online = const <CatalogCategory>[];
    var offline = false;
    try {
      online = await widget.repository.categories(nvkuSourceId);
    } catch (_) {
      offline = true;
    }
    final library = WhosLocalLibrary.shared;
    final loaded = await library.ensureLoaded();
    final local = loaded
        ? await whosLocalCategoriesAsync(library)
        : const <CatalogCategory>[];
    // 库里视频主分类（有码/无码/国产/4K…）：站点分类取不到时（站被挡）
    // 也能摆出全部主分类标签；站点已有的主分类不重复摆。
    final mains = loaded
        ? await library.mainCategoriesAsync()
        : const <({String name, int count})>[];
    if (!mounted) return;
    setState(() {
      _siteCategories = online;
      _localCategories = local;
      _mainCategories = [
        for (final row in mains)
          CatalogCategory('main:${row.name}', '${row.name} · ${row.count}'),
      ];
      _offline = offline || online.isEmpty;
      if (_category.isEmpty ||
          ![
            'new',
            ...online.map((c) => c.id),
            ...local.map((c) => c.id),
            ..._mainCategories.map((c) => c.id),
          ].contains(_category)) {
        _category = 'new';
      }
    });
  }

  /// 作品分页：在线优先，站挂了/取不到就换本地库（分类 id 在两边的
  /// 命名一致：new / rank / brand:xxx，站点分类是 c0/c1/c2/c7）。
  Future<void> _loadWorks({bool reset = false}) async {
    if (reset) {
      final generation = ++_generation;
      setState(() {
        _loading = true;
        _works = [];
        _page = 1;
        _hasMore = true;
      });
      final rows = await _fetchPage(1);
      if (!mounted || generation != _generation) return;
      setState(() {
        _works = rows;
        _page = 2;
        _hasMore = rows.length >= _pageSize;
        _loading = false;
      });
      return;
    }
    if (_loadingMore || !_hasMore || _loading) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    final rows = await _fetchPage(_page);
    if (!mounted || generation != _generation) return;
    setState(() {
      _works = [..._works, ...rows];
      _page += 1;
      _hasMore = rows.length >= _pageSize;
      _loadingMore = false;
    });
  }

  static const _pageSize = 30;

  Future<List<Drama>> _fetchPage(int page) async {
    try {
      final result = await widget.repository.catalog(
        nvkuSourceId,
        page: page,
        query: _query,
        category: _category,
      );
      if (result.items.isNotEmpty) return result.items;
      if (_query.isNotEmpty || page > 1) return result.items;
    } catch (_) {
      if (mounted && !_offline) setState(() => _offline = true);
    }
    // 本地兜底：站被挡/取不到时用本地 whos 库与视频库顶上，分类照旧可用。
    final library = WhosLocalLibrary.shared;
    if (!await library.ensureLoaded()) return const [];
    final rows = await library.pageAsync(
      category: _localCategoryFor(_category),
      videoCategory: _videoCategoryFor(_category),
      query: _query,
      page: page,
      pageSize: _pageSize,
    );
    return [
      for (final work in rows) whosLocalToDrama(work, source: nvkuSourceId),
    ];
  }

  /// 站点分类 → 本地库分类：站点分类（c0/c1/c2/c7）库里没有对应
  /// 维度，落回「最新」；其余 new/rank/brand: 两边同名直接用。
  String _localCategoryFor(String category) {
    if (category.startsWith('brand:') ||
        category == 'rank' ||
        category == 'new') {
      return category;
    }
    return 'new';
  }

  /// 选中分类 → 视频主分类名（供本地兜底按主分类筛库）：
  /// 站点分类 c0/c1… 的名字就是主分类名（“有码 · 251867”去尾数），
  /// 主分类标签 main:xxx 直接取冒号后的名字；最新/排行/厂牌不过滤。
  String _videoCategoryFor(String category) =>
      nvkuVideoCategoryFor(category, _siteCategories);

  /// 分类名去尾数：“有码 · 251867”→“有码”；没尾数原样返回。
  static String _cleanCategoryName(String name) =>
      cleanNvkuCategoryName(name);

  /// 全部可点标签（首页与分类页共用）：站点分类打头，本地分类
  /// （最新/排行/厂牌）随后，库里主分类补在最后——站点已有的
  /// 主分类（同名）不重复摆，站被挡时主分类标签照样全在。
  List<CatalogCategory> _allCategories() => nvkuAllCategories(
    _siteCategories,
    _localCategories,
    _mainCategories,
  );

  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_favKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((row) => _FavItem.fromJson(Map<String, dynamic>.from(row)))
          .toList();
      if (!mounted) return;
      setState(() => _favorites = list);
    } catch (_) {
      // 坏数据不影响页面。
    }
  }

  Future<void> _toggleFavorite(Drama drama) async {
    final hit = _favorites.indexWhere((row) => row.id == drama.id);
    final next = List<_FavItem>.of(_favorites);
    if (hit >= 0) {
      next.removeAt(hit);
    } else {
      next.insert(
        0,
        _FavItem(
          id: drama.id,
          source: drama.source,
          title: drama.title,
          cover: drama.cover,
          code: drama.tags.isNotEmpty ? drama.tags.first : '',
        ),
      );
    }
    setState(() => _favorites = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _favKey,
      jsonEncode([for (final row in next) row.toJson()]),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(hit >= 0 ? '已取消收藏' : '已收藏')));
  }

  bool _isFavorite(String id) => _favorites.any((row) => row.id == id);

  Future<void> _play(Drama drama) async {
    try {
      final detail = await widget.repository.detail(drama);
      if (!mounted) return;
      if (detail.episodes.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('这条暂时没有可播地址')));
        return;
      }
      await pushPlayer<void>(
        context,
        detail: detail,
        initialIndex: 0,
        repository: widget.repository,
        store: widget.store,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这条暂时取不到播放地址')));
    }
  }

  void _submitSearch(String value) {
    final next = value.trim();
    // 女优页签（2026-11-21）：这条搜索框由演员列表页接管（同一个
    // controller，列表自己 debounce 搜索），这里不再拿它搜作品，
    // 免得把「首页」那套作品列表也一起刷一遍。
    if (_tab == 2) {
      setState(() {});
      return;
    }
    if (next == _query) return;
    setState(() => _query = next);
    unawaited(_loadWorks(reset: true));
  }

  void _pickCategory(String id) {
    if (_category == id) return;
    setState(() => _category = id);
    unawaited(_loadWorks(reset: true));
  }

  /// 影片库入口（2026-11-22：主树此前没有通往 FilmLibraryPage 的
  /// 入口——列表页右上角的按钮 2026-11-21 按用户令删掉了；活树是靠
  /// 底部五页签胶囊栏进，本页保留四页签不接五页签，入口改放在
  /// 顶栏搜索框旁的霓虹药丸钮上，独立/内嵌两种模式都看得见。
  /// 排行榜入口不动：女优页签内嵌工具栏里的奖杯钮（列表页
  /// _toolbarActions 的 open-actress-ranking）。
  void _openFilmLibrary() {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => FilmLibraryPage(
          database: widget.database ?? SqfliteActressDatabase.instance,
          repository: widget.repository,
          store: widget.store,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _topBar(),
            Expanded(
              child: switch (_tab) {
                1 => _categoryTab(),
                2 => _actressTab(),
                3 => _favoriteTab(),
                _ => _homeTab(),
              },
            ),
          ],
        ),
      ),
      bottomNavigationBar: _bottomTabs(),
    );
  }

  /// 顶栏（2026-11-22 霓虹化：照活树改版走霓虹配色——深紫底 +
  /// 紫底边，与 actressNeonAppBar 同一套色；不改成真 AppBar，
  /// 搜索框本来就嵌在顶栏里、showTitle=false 内嵌时宿主已有
  /// 自己的顶栏，再套一层 AppBar 会叠两条栏）。
  Widget _topBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
      decoration: BoxDecoration(
        color: Neon.bg,
        border: Border(
          bottom: BorderSide(color: Neon.violet.withValues(alpha: .55)),
        ),
      ),
      child: Column(
        children: [
          // 2026-11-22 用户令（顶栏合并全部在顶部）：这一页嵌在片库顶栏
          // 里时（showTitle=false），外层已经有品牌条了，这里不能再出
          // 一条“女优库 + 本地库 + 刷新”，只留搜索框，避免两条顶栏。
          if (widget.showTitle) ...[
            Row(
            children: [
              Text(
                widget.showTitle ? '女优库' : '女优库',
                style: const TextStyle(
                  color: Neon.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .5,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: Neon.surface,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _offline ? '本地库' : '在线 + 本地',
                  style: const TextStyle(
                    color: Neon.textDim,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '刷新',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh_rounded, color: Neon.textDim, size: 20),
                onPressed: () => unawaited(_boot()),
              ),
            ],
          ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('nvku-search'),
                  controller: _search,
                  onSubmitted: _submitSearch,
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(color: Neon.text, fontSize: 15),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: _tab == 2 ? '搜女优名 / 番号' : '搜番号 / 片名 / 女优',
                    hintStyle: const TextStyle(color: Neon.textDim, fontSize: 14),
                    prefixIcon: const Icon(Icons.search, color: Neon.textDim, size: 20),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, color: Neon.textDim, size: 18),
                            onPressed: () {
                              _search.clear();
                              if (_tab == 2) {
                                setState(() {});
                              } else {
                                _submitSearch('');
                              }
                            },
                          ),
                    filled: true,
                    fillColor: Neon.surface,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Neon.violet.withValues(alpha: .55),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Neon.cyan),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ActressNeonPill(
                key: const ValueKey('nvku-open-film-library'),
                label: '影片库',
                selected: false,
                compact: true,
                onTap: _openFilmLibrary,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 底部四页签（2026-11-22：保留主树首页 / 分类 / 女优 / 收藏
  /// 四页签，不换成活树的五页签胶囊栏；只做霓虹样式适配——深紫底
  /// + 紫顶边，选中态走霓虹青、未选中走次字色）。
  Widget _bottomTabs() {
    const items = [
      (Icons.grid_view_rounded, '首页'),
      (Icons.category_outlined, '分类'),
      (Icons.face_retouching_natural, '女优'),
      (Icons.star_border_rounded, '收藏'),
    ];
    return Container(
      decoration: BoxDecoration(
        color: Neon.bg.withValues(alpha: .95),
        border: Border(
          top: BorderSide(color: Neon.violet.withValues(alpha: .5)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: InkWell(
                  onTap: () => setState(() => _tab = i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          items[i].$1,
                          size: 21,
                          color: _tab == i ? Neon.cyan : Neon.textDim,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          items[i].$2,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: _tab == i
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: _tab == i ? Neon.cyan : Neon.textDim,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title, String note) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 16, 2, 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Neon.text,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          Text(note, style: const TextStyle(color: Neon.textDim, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _homeTab() {
    final cats = _allCategories();
    return RefreshIndicator(
      color: _pk,
      backgroundColor: Neon.surface,
      onRefresh: _boot,
      child: ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          // 2026-11-22 用户令「分类不是卡片」：分类改成一条横向胶囊
          // 标签，置顶放在作品前面（原来是排在作品下面的两列卡片
          // 网格，既占地方又不像分类）。
          if (cats.isNotEmpty && _query.isEmpty)
            _categoryChips(
              cats,
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
            ),
          _sectionTitle(
            _query.isEmpty ? _currentCategoryLabel() : '搜索结果',
            _query.isEmpty ? '按发行日期' : _query,
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator(color: _pk)),
            )
          else if (_works.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  _query.isEmpty ? '暂时取不到作品' : '没有找到“$_query”',
                  style: const TextStyle(color: Neon.textDim),
                ),
              ),
            )
          else
            _workGrid(_works, height: null),
          if (_loadingMore)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator(color: _pk)),
            ),
        ],
      ),
    );
  }

  /// 当前选中分类的展示名：最新上架是“最新上架”，其余取标签的干净名
  /// （站点分类去尾数、主分类标签取冒号后、厂牌取展示名）。
  String _currentCategoryLabel() {
    if (_category == 'new') return '最新上架';
    if (_category.startsWith('main:')) {
      return _category.substring('main:'.length).trim();
    }
    for (final cat in _allCategories()) {
      if (cat.id == _category) return _cleanCategoryName(cat.name);
    }
    return '最新上架';
  }

  /// 分类胶囊条（首页与分类页共用）：横向滚动的一排霓虹药丸钮，
  /// 选中项用紫→青渐变 + 辉光，不占版面、不像卡片。
  /// （2026-11-22 照活树改版：ChoiceChip 换成 ActressNeonPill；
  /// 横向 ListView 里药丸钮会被拉满 46 高，外面套 Center 定高。）
  Widget _categoryChips(
    List<CatalogCategory> cats, {
    EdgeInsets padding = const EdgeInsets.fromLTRB(12, 8, 12, 6),
  }) {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: cats.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final cat = cats[index];
          final on = _category == cat.id;
          return Center(
            child: ActressNeonPill(
              key: ValueKey('nvku-chip-${cat.id}'),
              label: cat.name,
              selected: on,
              onTap: () => _pickCategory(cat.id),
            ),
          );
        },
      ),
    );
  }

  Widget _categoryTab() {
    final cats = _allCategories();
    return Column(
      children: [
        if (cats.isNotEmpty) _categoryChips(cats),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: _pk))
              : _works.isEmpty
              ? Center(
                  child: Text(
                    _query.isEmpty ? '这个分类暂时取不到作品' : '没有找到“$_query”',
                    style: const TextStyle(color: Neon.textDim),
                  ),
                )
              : GridView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
                  itemCount: _works.length + (_hasMore ? 1 : 0),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 130,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.56,
                  ),
                  itemBuilder: (context, index) {
                    if (index >= _works.length) {
                      return const Center(
                        child: CircularProgressIndicator(color: _pk),
                      );
                    }
                    return _workCard(_works[index]);
                  },
                ),
        ),
      ],
    );
  }

  Widget _workGrid(List<Drama> works, {double? height}) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: works.length,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        mainAxisSpacing: 12,
        crossAxisSpacing: 10,
        childAspectRatio: 0.56,
      ),
      itemBuilder: (context, index) => _workCard(works[index]),
    );
  }

  Widget _workCard(Drama drama) {
    final code = drama.tags.isNotEmpty ? drama.tags.first : '';
    final fav = _isFavorite(drama.id);
    return InkWell(
      key: ValueKey('nvku-work-${drama.id}'),
      onTap: () => unawaited(_play(drama)),
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: actressNeonCardDecoration(radius: 10),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      color: Neon.surface,
                      width: double.infinity,
                      height: double.infinity,
                      child: drama.cover.isEmpty
                          ? Center(
                              child: Text(
                                code.isEmpty ? 'NV' : code,
                                style: const TextStyle(
                                  color: Neon.textDim,
                                  fontSize: 12,
                                ),
                              ),
                            )
                          : Image.network(
                              drama.cover,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  const SizedBox.shrink(),
                            ),
                    ),
                  ),
                  Positioned(
                    right: 2,
                    top: 2,
                    child: GestureDetector(
                      onTap: () => unawaited(_toggleFavorite(drama)),
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(
                          color: Color(0xCC000000),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          fav ? Icons.star : Icons.star_border,
                          size: 15,
                          color: fav ? Neon.pink : Neon.textDim,
                        ),
                      ),
                    ),
                  ),
                  if (drama.onlineDate.isNotEmpty)
                    Positioned(
                      left: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xB3000000),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          drama.onlineDate,
                          style: const TextStyle(
                            color: Neon.text,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            drama.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Neon.text,
              fontSize: 12,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actressTab() {
    return ActressListPage(
      key: const ValueKey('nvku-actress-list'),
      repository: widget.repository,
      store: widget.store,
      database: widget.database,
      showTitle: false,
      // 2026-11-21 用户令：女优页签里不许再冒第二个搜索框——搜索只用
      // 顶栏那一条，本页监听同一个输入框（搜索框置顶、不随列表滚）。
      externalSearch: _search,
    );
  }

  Widget _favoriteTab() {
    if (_favorites.isEmpty) {
      return const Center(
        child: Text(
          '还没有收藏，点卡片右上角的星',
          style: TextStyle(color: Neon.textDim),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: _favorites.length,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        mainAxisSpacing: 12,
        crossAxisSpacing: 10,
        childAspectRatio: 0.56,
      ),
      itemBuilder: (context, index) {
        final row = _favorites[index];
        return _workCard(
          Drama(
            id: row.id,
            source: row.source,
            sourceId: row.id,
            title: row.title,
            cover: row.cover,
            tags: [if (row.code.isNotEmpty) row.code],
          ),
        );
      },
    );
  }
}

/// 收藏项：只留卡片和播放要用的字段（不存整条 Drama）。
class _FavItem {
  const _FavItem({
    required this.id,
    required this.source,
    required this.title,
    this.cover = '',
    this.code = '',
  });

  final String id;
  final String source;
  final String title;
  final String cover;
  final String code;

  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source,
    'title': title,
    'cover': cover,
    'code': code,
  };

  factory _FavItem.fromJson(Map<String, dynamic> json) => _FavItem(
    id: json['id'] as String? ?? '',
    source: json['source'] as String? ?? '',
    title: json['title'] as String? ?? '',
    cover: json['cover'] as String? ?? '',
    code: json['code'] as String? ?? '',
  );
}
