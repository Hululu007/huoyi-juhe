// 演员库原生页（2026-11-26 用户改令：演员库区域的 UI 照魔蚁合并页
// 版式用原生控件重做，网页壳路线作废）。
//
// 版式（照合并页报告第三节）：顶部标题 + 搜索、一级页签、二级分类
// 条、卡片网格、底部源切换条（「女优库」本地源置首段、默认选中）。
// 四个源：
// - 女优库（本地）：走 ActressLibraryDbFallback 的只读查询 ops
//   （list / search / works / actresses / tags / detail），分类照
//   whos 官方五维（最新 / 排行榜 / 演员 / 标签 + 20 厂牌二级条）；
//   查询层已整体排除硬线类型，本页不另设口子、不直查数据库表。
// - who's（在线，源 id 'whos'，内置 py 源）：走 AppRepository
//   的 categories / catalog / detail，超时按其 py 取页设计放
//   宽到 75 秒，加载前先等种子补登记；失败落错误态并给「切
//   到本地女优库」兜底入口。
// - 123AV（'123av'）、PH（'pornhub'）：2026-11-27 起走 Dart
//   直连新链（actress_online_sources.dart，照魔蚁侧修正版逐
//   项对齐：123AV 内联 player JSON 取址 + /stream 换流、PH
//   flashvars 取流），不再走 jar 旧链（旧链取流无超时 = 无
//   限转圈实报）。两源本机出口未验通，源切换条上如实带
//   「未验」小标，不写成已验。
// - 作品卡点开一律进作品详情页（actress_work_detail_page
//   .dart，AvPlay 式版面 + 页内起播），不再直进播放器。
//
// 状态纪律：任何源加载失败 / 无库 / 无数据都出明确状态区（文案 +
// 重试或去管理钮），不白屏、不无限转圈（所有加载带超时，失败落
// 到错误态）。切源时各源已加载内容保留在各自状态里，切回不重载；
// 只有下拉/重试/管理弹层里的「重新加载数据库」才强制重载。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/source_registry.dart' show SourceRegistry;
import 'actress_adapter_models.dart';
import 'actress_adapter_repository.dart';
import 'actress_adapter_store.dart';
import 'actress_ios_import.dart';
import 'actress_library_db.dart';
import 'actress_list_page.dart';
import 'actress_mytv_bind.dart';
import 'actress_neon.dart';
import 'actress_nvku_page.dart';
import 'actress_online_parse.dart'
    show OnlineTabOption, OnlineVideoCard, av123CodeOf;
import 'actress_online_sources.dart';
import 'actress_work_detail_page.dart';

/// 本地源一级页签（照 whos 官方五维的前四维，厂牌是二级条）。
const _localTabs = ['最新', '排行榜', '演员', '标签'];

/// 最新页签下的二级厂牌条：全部 + 20 厂牌（展示名，检索前缀）。
/// 前缀口径照 whos 官方分类与库映射文档（SIRO 的前缀就是 sir、
/// STARS 是 sta，照实写、不猜）。
const _brands = <(String, String)>[
  ('全部', ''),
  ('FC2', 'fc2ppv'),
  ('SDAM', 'sdam'),
  ('SSIS', 'ssis'),
  ('IPZZ', 'ipzz'),
  ('IPZ', 'ipz'),
  ('IPX', 'ipx'),
  ('MIDV', 'midv'),
  ('MIDE', 'mide'),
  ('MIAA', 'miaa'),
  ('SONE', 'sone'),
  ('SOE', 'soe'),
  ('SIRO', 'sir'),
  ('CNT', 'cnt'),
  ('STARS', 'sta'),
  ('PRTD', 'prtd'),
  ('HNTD', 'hntd'),
  ('CJVR', 'cjvr'),
  ('DSVR', 'dsvr'),
  ('VVVD', 'vvvd'),
  ('JUQ', 'juq'),
];

/// 在线三源（顺序与统一搜索分段顺序一致）。
const _onlineSources = <(String, String)>[
  ('whos', "who's"),
  ('123av', '123AV'),
  ('pornhub', 'PH'),
];

/// 单次加载超时：挂住的查询也要落到错误态，不许无限转圈。
const _loadTimeout = Duration(seconds: 20);

/// who's 专用超时：其 py 蜘蛛取页是「45 秒单请求 × 多通道」
/// 设计、py 桥上限 70 秒，页级 20 秒必然先掐断（2026-11-27
/// 实报「who's 打不开」的直接原因之一）——who's 的分类/目
/// 录/搜索单独放宽到 75 秒，失败照样落错误态 + 本地兜底。
const _whosTimeout = Duration(seconds: 75);

class ActressLibraryNativePage extends StatefulWidget {
  const ActressLibraryNativePage({
    super.key,
    required this.repository,
    required this.store,
    this.fallback,
    this.bind,
    this.onlineFetch,
  });

  final AppRepository repository;
  final LocalStore store;

  /// 123AV / PH 的 Dart 直连取数（测试/预览注入假取数；
  /// 生产默认走 ActressOnlineClient）。
  final ActressOnlineFetch? onlineFetch;

  /// 本地库兜底查询：不传时现建一个新实例（默认路径解析走
  /// ActressMytvBind 绑定）。管理弹层「重新加载数据库」会换新实例。
  final ActressLibraryDbFallback? fallback;

  /// MYTV 绑定：不传时用 ActressMytvBind.instance。
  final ActressMytvBind? bind;

  @override
  State<ActressLibraryNativePage> createState() =>
      _ActressLibraryNativePageState();
}

/// 在线源的浏览态（每源一份，切源保留、切回不重载）。
/// who's 走仓储（categories/items）；123AV / PH 走 Dart 直
/// 连（cards + 页签 id），两套字段各用各的。
class _OnlineState {
  var categories = <CatalogCategory>[];
  var categoriesLoaded = false;
  var category = '';
  var items = <Drama>[];
  var cards = <OnlineVideoCard>[];
  var primaryId = '';
  var secondaryId = '';
  var page = 1;
  var hasMore = false;
  var loading = false;
  var loaded = false;
  String? error;
}

/// 统一搜索的一个分段（一个源一份结果，互不拖累）。
class _SearchSection {
  _SearchSection({required this.label, this.sourceId});

  final String label;

  /// null = 本地女优库段（items 是库行 Map）；非空 = 在线源段
  /// （dramas 是 Drama）。
  final String? sourceId;
  var localItems = <Map<String, dynamic>>[];
  var dramas = <Drama>[];
  var cards = <OnlineVideoCard>[];
  var loading = true;
  String? error;

  /// 123AV / PH 段走 Dart 直连（cards），who's 段走仓储
  /// （dramas），本地段走库（localItems）。
  bool get isDart => sourceId == '123av' || sourceId == 'pornhub';

  int get count =>
      sourceId == null ? localItems.length : (isDart ? cards.length : dramas.length);
}

class _ActressLibraryNativePageState extends State<ActressLibraryNativePage> {
  late ActressLibraryDbFallback _fallback =
      widget.fallback ?? ActressLibraryDbFallback();
  ActressMytvBind get _bind => widget.bind ?? ActressMytvBind.instance;

  late final ActressOnlineClient _onlineClient = ActressOnlineClient();
  ActressOnlineFetch get _onlineFetch =>
      widget.onlineFetch ?? _onlineClient.get;

  /// who's 的 py 种子靠启动时未等待的异步补登记，失败静默
  /// ——本页首次加载 who's 前先等它落完（仅真仓储时；测试
  /// 假仓储跳过），避免种子没登记好就判「站源不可用」。
  var _seedEnsured = false;

  Future<void> _ensureWhosSeed() async {
    if (_seedEnsured) return;
    _seedEnsured = true;
    if (widget.repository is! XiuxianAppRepository) return;
    try {
      await SourceRegistry.instance
          .ensureBuiltinImportedSites()
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      // 补登记失败不挡加载：仓储取不到客户端会落错误态。
    }
  }

  final _searchController = TextEditingController();

  /// 当前源：0 本地女优库（默认）、1 who's、2 123AV、3 PH。
  var _sourceIndex = 0;

  // ---- 本地源浏览态 ----
  var _localTab = 0;
  var _brand = '';
  var _localItems = <Map<String, dynamic>>[];
  var _localActresses = <Map<String, dynamic>>[];
  var _localTags = <Map<String, dynamic>>[];
  var _localPage = 1;
  var _localHasMore = false;
  var _localLoading = false;
  var _localLoaded = false;
  String? _localError;

  /// 作品下钻（点演员行 / 标签 chip 后）：非空时内容区改出 works
  /// 网格，顶部带回退 chip。两者只会有一个非空。
  String? _worksActress;
  String? _worksTag;

  // ---- 在线源浏览态 ----
  final _online = <String, _OnlineState>{
    for (final (id, _) in _onlineSources) id: _OnlineState(),
  };

  // ---- 搜索态 ----
  var _searching = false;
  var _searchSections = <_SearchSection>[];
  var _searchGeneration = 0;

  var _generation = 0;

  String get _onlineSourceId => _onlineSources[_sourceIndex - 1].$1;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLocal(reset: true));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ================= 本地源 =================

  bool get _inWorks =>
      _worksActress != null || _worksTag != null;

  /// 本地一页数据：按当前页签/下钻组 op。排行榜单页 50 条不分页；
  /// 其余带 page，返回不足一整页（24）即没有下一页。
  Future<void> _loadLocal({bool reset = false, bool more = false}) async {
    if (_localLoading) return;
    if (more && !_localHasMore) return;
    final generation = ++_generation;
    final page = more ? _localPage + 1 : 1;
    setState(() {
      _localLoading = true;
      if (reset) _localError = null;
    });
    try {
      Map<String, dynamic> result;
      if (_inWorks) {
        result = await _fallback
            .handle({
              'op': 'works',
              if (_worksActress != null) 'actress': _worksActress,
              if (_worksTag != null) 'tag': _worksTag,
              'page': page,
            })
            .timeout(_loadTimeout);
      } else if (_localTab == 1) {
        result = await _fallback
            .handle({'op': 'list', 'kind': 'rank'})
            .timeout(_loadTimeout);
      } else if (_localTab == 2) {
        result = await _fallback
            .handle({'op': 'actresses', 'page': page})
            .timeout(_loadTimeout);
      } else if (_localTab == 3) {
        result = await _fallback.handle({'op': 'tags'}).timeout(_loadTimeout);
      } else {
        result = await _fallback
            .handle({
              'op': 'list',
              'kind': 'latest',
              if (_brand.isNotEmpty) 'q': _brand,
              'page': page,
            })
            .timeout(_loadTimeout);
      }
      if (!mounted || generation != _generation) return;
      if (result['ok'] != true) {
        setState(() {
          _localLoading = false;
          _localLoaded = true;
          _localError = (result['error'] ?? '本地女优库不可用').toString();
        });
        return;
      }
      setState(() {
        _localLoading = false;
        _localLoaded = true;
        _localError = null;
        if (_localTab == 3 && !_inWorks) {
          _localTags = [
            for (final row in (result['tags'] as List? ?? const []))
              Map<String, dynamic>.from(row as Map),
          ];
          _localHasMore = false;
        } else if (_localTab == 2 && !_inWorks) {
          final rows = [
            for (final row in (result['actresses'] as List? ?? const []))
              Map<String, dynamic>.from(row as Map),
          ];
          _localActresses = more ? [..._localActresses, ...rows] : rows;
          _localPage = page;
          _localHasMore = rows.length >= 24;
        } else {
          final rows = [
            for (final row in (result['items'] as List? ?? const []))
              Map<String, dynamic>.from(row as Map),
          ];
          _localItems = more ? [..._localItems, ...rows] : rows;
          _localPage = page;
          // 排行榜固定 50 条单页，不分页。
          _localHasMore = _localTab == 1 ? false : rows.length >= 24;
        }
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _localLoading = false;
        _localLoaded = true;
        _localError = '本地女优库加载失败：${error.toString().split('\n').first}';
      });
    }
  }

  void _pickLocalTab(int tab) {
    if (_localTab == tab && !_inWorks) return;
    setState(() {
      _localTab = tab;
      _worksActress = null;
      _worksTag = null;
    });
    unawaited(_loadLocal(reset: true));
  }

  void _pickBrand(String prefix) {
    if (_brand == prefix) return;
    setState(() => _brand = prefix);
    unawaited(_loadLocal(reset: true));
  }

  void _openWorks({String? actress, String? tag}) {
    setState(() {
      _worksActress = actress;
      _worksTag = tag;
    });
    unawaited(_loadLocal(reset: true));
  }

  void _closeWorks() {
    setState(() {
      _worksActress = null;
      _worksTag = null;
    });
    unawaited(_loadLocal(reset: true));
  }

  // ================= 在线源 =================

  Future<void> _loadOnline(String sourceId, {bool more = false}) async {
    final state = _online[sourceId]!;
    if (state.loading) return;
    if (more && !state.hasMore) return;
    final page = more ? state.page + 1 : 1;
    setState(() => state.loading = true);
    try {
      if (sourceId == '123av' || sourceId == 'pornhub') {
        await _loadDartOnline(sourceId, state, page: page, more: more);
        return;
      }
      // who's：先等 py 种子补登记落完，超时按其取页设计放宽。
      await _ensureWhosSeed();
      if (!state.categoriesLoaded) {
        // 分类取不到是诚实错误态 + 重试，不拿空分类硬凑目录。
        state.categories = await widget.repository
            .categories(sourceId)
            .timeout(_whosTimeout);
        state.categoriesLoaded = true;
        if (state.category.isEmpty && state.categories.isNotEmpty) {
          state.category = state.categories.first.id;
        }
      }
      final result = await widget.repository
          .catalog(sourceId, page: page, category: state.category)
          .timeout(_whosTimeout);
      if (!mounted) return;
      setState(() {
        state.items = more ? [...state.items, ...result.items] : result.items;
        state.page = page;
        state.hasMore = result.hasMore;
        state.loading = false;
        state.loaded = true;
        state.error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        state.loading = false;
        state.loaded = true;
        state.error = '这个源暂时取不到内容：${error.toString().split('\n').first}';
      });
    }
  }

  /// 123AV / PH 的 Dart 直连加载（2026-11-27 照魔蚁修正版
  /// 移植的新链，替代 jar 旧链）：页签取卡、空页即止。
  Future<void> _loadDartOnline(
    String sourceId,
    _OnlineState state, {
    required int page,
    required bool more,
  }) async {
    final source = actressOnlineSourceById(sourceId)!;
    if (state.primaryId.isEmpty) {
      state.primaryId = source.defaultPrimaryId;
      state.secondaryId = source.defaultSecondaryId;
    }
    final cards = await source
        .fetchCards(
          primaryId: state.primaryId,
          secondaryId: state.secondaryId,
          query: '',
          page: page,
          fetch: _onlineFetch,
        )
        .timeout(const Duration(seconds: 30));
    if (!mounted) return;
    setState(() {
      state.cards = more ? [...state.cards, ...cards] : cards;
      state.page = page;
      // 空页 = 到底；满页可能还有下一页（到底时多探一次空页）。
      state.hasMore = cards.isNotEmpty;
      state.loading = false;
      state.loaded = true;
      state.error = null;
    });
  }

  void _pickOnlineCategory(String sourceId, String category) {
    final state = _online[sourceId]!;
    if (state.category == category && state.loaded) return;
    setState(() {
      state.category = category;
      state.loaded = false;
      state.items = [];
    });
    unawaited(_loadOnline(sourceId));
  }

  /// Dart 直连源的页签切换（一级/二级通用）：换页签重拉第一页。
  void _pickDartTab(String sourceId, {String? primary, String? secondary}) {
    final state = _online[sourceId]!;
    setState(() {
      if (primary != null) state.primaryId = primary;
      if (secondary != null) state.secondaryId = secondary;
      state.loaded = false;
      state.cards = [];
      state.page = 1;
      state.hasMore = false;
    });
    unawaited(_loadOnline(sourceId));
  }

  void _selectSource(int index) {
    if (_searching) _exitSearch();
    if (_sourceIndex == index) return;
    setState(() => _sourceIndex = index);
    if (index > 0) {
      final id = _onlineSourceId;
      if (!_online[id]!.loaded && !_online[id]!.loading) {
        unawaited(_loadOnline(id));
      }
    }
  }

  // ================= 统一搜索 =================

  Future<void> _submitSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    final generation = ++_searchGeneration;
    setState(() {
      _searching = true;
      _searchSections = [
        _SearchSection(label: '女优库'),
        for (final (id, label) in _onlineSources)
          _SearchSection(label: label, sourceId: id),
      ];
    });
    // 本地段：库内 search op。
    unawaited(() async {
      final section = _searchSections.first;
      try {
        final result = await _fallback
            .handle({'op': 'search', 'q': query, 'page': 1})
            .timeout(_loadTimeout);
        if (!mounted || generation != _searchGeneration) return;
        setState(() {
          section.loading = false;
          if (result['ok'] == true) {
            section.localItems = [
              for (final row in (result['items'] as List? ?? const []))
                Map<String, dynamic>.from(row as Map),
            ];
          } else {
            section.error = (result['error'] ?? '本地女优库不可用').toString();
          }
        });
      } catch (error) {
        if (!mounted || generation != _searchGeneration) return;
        setState(() {
          section.loading = false;
          section.error = '本地搜索失败：${error.toString().split('\n').first}';
        });
      }
    }());
    // who's 段：仓储跨源搜索（py 链），超时按其取页设计放宽。
    unawaited(() async {
      final section = _searchSections
          .where((row) => row.sourceId == 'whos')
          .firstOrNull;
      if (section == null) return;
      try {
        await _ensureWhosSeed();
        await widget.repository
            .searchAcrossProgressive(
              const ['whos'],
              query,
              onSite: (source, items) {
                if (!mounted || generation != _searchGeneration) return;
                setState(() {
                  section.loading = false;
                  section.dramas = items;
                });
              },
            )
            .timeout(_whosTimeout);
        if (!mounted || generation != _searchGeneration) return;
        setState(() => section.loading = false);
      } catch (error) {
        if (!mounted || generation != _searchGeneration) return;
        setState(() {
          section.loading = false;
          section.error = '搜索失败：${error.toString().split('\n').first}';
        });
      }
    }());
    // 123AV / PH 段：Dart 直连搜索，逐段填充、互不拖累。
    for (final (id, _) in _onlineSources) {
      if (id == 'whos') continue;
      unawaited(() async {
        final section = _searchSections
            .where((row) => row.sourceId == id)
            .firstOrNull;
        final source = actressOnlineSourceById(id);
        if (section == null || source == null) return;
        try {
          final cards = await source
              .fetchCards(
                primaryId: source.defaultPrimaryId,
                secondaryId: source.defaultSecondaryId,
                query: query,
                page: 1,
                fetch: _onlineFetch,
              )
              .timeout(const Duration(seconds: 30));
          if (!mounted || generation != _searchGeneration) return;
          setState(() {
            section.loading = false;
            section.cards = cards;
          });
        } catch (error) {
          if (!mounted || generation != _searchGeneration) return;
          setState(() {
            section.loading = false;
            section.error = '搜索失败：${error.toString().split('\n').first}';
          });
        }
      }());
    }
    // 在线段各自异步落地（见上），本函数不再等它们：每段自己
    // 把 loading 落下，站不可用的段由其回调/异常路径收尾。
  }

  void _exitSearch() {
    _searchGeneration++;
    setState(() {
      _searching = false;
      _searchSections = [];
    });
  }

  // ================= 播放 / 详情 =================

  /// 在线卡点开：进作品详情页（AvPlay 式版面 + 页内起播），
  /// 不再直进播放器（旧路 detail 无超时 + jar 取流无超时 =
  /// 无限「正在加载第 1 集」，2026-11-27 实报已废）。
  void _openOnlineDetail(Drama drama) {
    final source = actressOnlineSourceById(drama.source);
    if (source != null) {
      _openDartDetail(
        source,
        OnlineVideoCard(
          pageUrl: drama.id,
          title: drama.title,
          cover: drama.cover,
        ),
      );
      return;
    }
    // who's 卡：蜘蛛目录的 id 就是番号，详情页按番号开
    // （who's 线路走 py 链，其余源与本地库按番号追加）。
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ActressWorkDetailPage.byCode(
          code: drama.id,
          title: drama.title,
          poster: drama.cover,
          fallback: _fallback,
          repository: widget.repository,
          onlineFetch: widget.onlineFetch,
          onActress: _detailOnActress,
          onTag: _detailOnTag,
          onSearchCode: _detailOnSearchCode,
        ),
      ),
    );
  }

  void _openDartDetail(ActressOnlineSource source, OnlineVideoCard card) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ActressWorkDetailPage.online(
          source: source,
          card: card,
          fallback: _fallback,
          repository: widget.repository,
          onlineFetch: widget.onlineFetch,
          onActress: _detailOnActress,
          onTag: _detailOnTag,
          onSearchCode: _detailOnSearchCode,
        ),
      ),
    );
  }

  void _detailOnActress(String name) {
    Navigator.of(context).pop();
    _openWorks(actress: name);
  }

  void _detailOnTag(String tag) {
    Navigator.of(context).pop();
    _openWorks(tag: tag);
  }

  void _detailOnSearchCode(String code) {
    Navigator.of(context).pop();
    _searchController.text = code;
    unawaited(_submitSearch());
  }

  void _openLocalDetail(Map<String, dynamic> item) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ActressWorkDetailPage.local(
          vodId: (item['vodId'] ?? '').toString(),
          fallback: _fallback,
          repository: widget.repository,
          onlineFetch: widget.onlineFetch,
          onActress: _detailOnActress,
          onTag: _detailOnTag,
          onSearchCode: _detailOnSearchCode,
        ),
      ),
    );
  }

  // ================= 数据库管理弹层 =================

  Future<void> _reloadLocalSource() async {
    await _bind.ensureBound(refresh: true);
    if (!mounted) return;
    // 换新兜底实例：旧实例可能还握着旧库连接/旧文件戳。
    setState(() => _fallback = ActressLibraryDbFallback());
    if (_sourceIndex == 0) {
      await _loadLocal(reset: true);
    }
  }

  Future<void> _showManageSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Neon.surface,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    '数据库管理',
                    style: TextStyle(
                      color: Neon.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                FutureBuilder<MytvBindResult>(
                  future: _bind.ensureBound(),
                  builder: (context, snapshot) {
                    final bind = snapshot.data;
                    if (bind == null) {
                      return const ListTile(
                        title: Text(
                          '正在读取数据库状态…',
                          style: TextStyle(color: Neon.textDim),
                        ),
                      );
                    }
                    return ListTile(
                      leading: const Icon(
                        Icons.storage_rounded,
                        color: Neon.textDim,
                      ),
                      title: Text(
                        bind.displayPath,
                        style: const TextStyle(color: Neon.text, fontSize: 13),
                      ),
                      subtitle: Text(
                        bind.hasVideoDb
                            ? '数据库已绑定'
                            : (bind.note ?? '未绑定或无可用库'),
                        style: const TextStyle(
                          color: Neon.textDim,
                          fontSize: 12,
                        ),
                      ),
                    );
                  },
                ),
                ListTile(
                  key: const ValueKey('native-manage-reload'),
                  leading: const Icon(Icons.refresh_rounded, color: Neon.cyan),
                  title: const Text(
                    '重新加载数据库',
                    style: TextStyle(color: Neon.text),
                  ),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await _reloadLocalSource();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已重新加载数据库')),
                    );
                  },
                ),
                if (Platform.isAndroid) ...[
                  ListTile(
                    key: const ValueKey('native-manage-grant-folder'),
                    leading: const Icon(
                      Icons.folder_open_rounded,
                      color: Neon.cyan,
                    ),
                    title: const Text(
                      '授权文件夹读取',
                      style: TextStyle(color: Neon.text),
                    ),
                    onTap: () async {
                      final granted = await _bind.grantFolderAccess();
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            granted ? '已取得文件夹授权，正在重新加载' : '没有选择文件夹，或系统选择器打不开',
                          ),
                        ),
                      );
                      if (granted) await _reloadLocalSource();
                    },
                  ),
                  ListTile(
                    key: const ValueKey('native-manage-grant-file'),
                    leading: const Icon(
                      Icons.description_rounded,
                      color: Neon.cyan,
                    ),
                    title: const Text(
                      '授权单个数据库文件',
                      style: TextStyle(color: Neon.text),
                    ),
                    onTap: () async {
                      final granted = await _bind.grantFileAccess();
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            granted ? '已取得文件授权，正在重新加载' : '没有选择文件，或系统选择器打不开',
                          ),
                        ),
                      );
                      if (granted) await _reloadLocalSource();
                    },
                  ),
                  ListTile(
                    key: const ValueKey('native-manage-permission'),
                    leading: const Icon(
                      Icons.settings_rounded,
                      color: Neon.cyan,
                    ),
                    title: const Text(
                      '去设置授权',
                      style: TextStyle(color: Neon.text),
                    ),
                    onTap: () async {
                      final opened = await _bind.requestPermission();
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            opened
                                ? '已打开系统设置，授权后回来点“重新加载数据库”'
                                : '打不开系统设置页：请到系统设置的应用权限里给本应用开'
                                      '“全部文件访问”，或改用“授权文件夹读取”',
                          ),
                        ),
                      );
                    },
                  ),
                ],
                if (Platform.isIOS)
                  ActressIosImportTile(
                    onImported: () async {
                      Navigator.of(sheetContext).pop();
                      await _reloadLocalSource();
                    },
                  ),
                ListTile(
                  key: const ValueKey('native-manage-list-page'),
                  leading: const Icon(Icons.tune_rounded, color: Neon.cyan),
                  title: const Text(
                    '多库勾选 / 数据库字段',
                    style: TextStyle(color: Neon.text),
                  ),
                  subtitle: const Text(
                    '在演员列表页的设置里',
                    style: TextStyle(color: Neon.textDim, fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => ActressListPage(
                          repository: widget.repository,
                          store: widget.store,
                        ),
                      ),
                    );
                  },
                ),
                ListTile(
                  key: const ValueKey('native-manage-legacy-page'),
                  leading: const Icon(Icons.history_rounded, color: Neon.cyan),
                  title: const Text(
                    '旧版演员库页',
                    style: TextStyle(color: Neon.text),
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => ActressNvkuPage(
                          repository: widget.repository,
                          store: widget.store,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }

  // ================= 界面 =================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _topBar(),
            _searchRow(),
            if (_searching)
              Expanded(child: _searchBody())
            else ...[
              _categoryArea(),
              Expanded(child: _browseBody()),
            ],
          ],
        ),
      ),
      bottomNavigationBar: _sourceBar(),
    );
  }

  Widget _topBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      decoration: BoxDecoration(
        color: Neon.bg,
        border: Border(
          bottom: BorderSide(color: Neon.violet.withValues(alpha: .55)),
        ),
      ),
      child: Row(
        children: [
          const Text(
            '演员库',
            style: TextStyle(
              color: Neon.text,
              fontSize: 17,
              fontWeight: FontWeight.w800,
              letterSpacing: .5,
            ),
          ),
          const Spacer(),
          IconButton(
            key: const ValueKey('native-manage-button'),
            tooltip: '数据库管理',
            icon: const Icon(
              Icons.storage_rounded,
              color: Neon.textDim,
              size: 21,
            ),
            onPressed: () => unawaited(_showManageSheet()),
          ),
        ],
      ),
    );
  }

  Widget _searchRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('native-search-field'),
              controller: _searchController,
              onSubmitted: (_) => unawaited(_submitSearch()),
              textInputAction: TextInputAction.search,
              style: const TextStyle(color: Neon.text, fontSize: 15),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜番号 / 片名 / 女优',
                hintStyle: const TextStyle(color: Neon.textDim, fontSize: 14),
                prefixIcon: const Icon(
                  Icons.search,
                  color: Neon.textDim,
                  size: 20,
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
                  borderSide: const BorderSide(color: Neon.cyan),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ActressNeonPill(
            key: const ValueKey('native-search-button'),
            label: '搜索',
            selected: true,
            onTap: () => unawaited(_submitSearch()),
          ),
          if (_searching) ...[
            const SizedBox(width: 8),
            ActressNeonPill(
              key: const ValueKey('native-exit-search'),
              label: '退出搜索',
              selected: false,
              onTap: _exitSearch,
            ),
          ],
        ],
      ),
    );
  }

  /// 分类区（浏览态，随当前源变）：本地出一级页签 + 厂牌二级条
  /// （仅最新页签）/ 下钻回退 chip；在线出该源分类 chips。
  Widget _categoryArea() {
    if (_sourceIndex == 0) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 46,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              itemCount: _localTabs.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => Center(
                child: ActressNeonPill(
                  key: ValueKey('native-local-tab-$index'),
                  label: _localTabs[index],
                  selected: _localTab == index && !_inWorks,
                  onTap: () => _pickLocalTab(index),
                ),
              ),
            ),
          ),
          if (_inWorks)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: ActressNeonPill(
                key: const ValueKey('native-works-back'),
                label: _worksActress != null
                    ? '女优：$_worksActress ✕'
                    : '标签：$_worksTag ✕',
                selected: true,
                onTap: _closeWorks,
              ),
            )
          else if (_localTab == 0)
            SizedBox(
              height: 42,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                itemCount: _brands.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final (label, prefix) = _brands[index];
                  return Center(
                    child: ActressNeonPill(
                      key: ValueKey('native-brand-$prefix'),
                      label: label,
                      selected: _brand == prefix,
                      compact: true,
                      onTap: () => _pickBrand(prefix),
                    ),
                  );
                },
              ),
            ),
        ],
      );
    }
    final id = _onlineSourceId;
    if (id == '123av' || id == 'pornhub') {
      // Dart 直连源的页签行：123AV 一行栏目；PH 两行（排序 +
      // 分类）。选中态以 state 里的页签 id 为准（未加载时用
      // 源缺省页签）。
      final source = actressOnlineSourceById(id)!;
      final state = _online[id]!;
      final primary = state.primaryId.isEmpty
          ? source.defaultPrimaryId
          : state.primaryId;
      final secondary = state.secondaryId.isEmpty
          ? source.defaultSecondaryId
          : state.secondaryId;
      Widget tabRow(
        List<OnlineTabOption> tabs,
        String current,
        void Function(String tabId) onPick,
        String keyPrefix,
      ) {
        return SizedBox(
          height: 46,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            itemCount: tabs.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final tab = tabs[index];
              return Center(
                child: ActressNeonPill(
                  key: ValueKey('$keyPrefix-${tab.id}'),
                  label: tab.name,
                  selected: current == tab.id,
                  onTap: () => onPick(tab.id),
                ),
              );
            },
          ),
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          tabRow(
            source.primaryTabs,
            primary,
            (tabId) => _pickDartTab(id, primary: tabId),
            'native-dart-primary',
          ),
          if (source.secondaryTabs.isNotEmpty)
            tabRow(
              source.secondaryTabs,
              secondary,
              (tabId) => _pickDartTab(id, secondary: tabId),
              'native-dart-secondary',
            ),
        ],
      );
    }
    final state = _online[id]!;
    if (!state.categoriesLoaded || state.categories.isEmpty) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        itemCount: state.categories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final cat = state.categories[index];
          return Center(
            child: ActressNeonPill(
              key: ValueKey('native-cat-${state.category == cat.id}'),
              label: cat.name,
              selected: state.category == cat.id,
              onTap: () => _pickOnlineCategory(_onlineSourceId, cat.id),
            ),
          );
        },
      ),
    );
  }

  Widget _browseBody() {
    if (_sourceIndex == 0) return _localBody();
    final id = _onlineSourceId;
    final state = _online[id]!;
    final isDart = id == '123av' || id == 'pornhub';
    final count = isDart ? state.cards.length : state.items.length;
    if (state.loading && count == 0) {
      return const Center(child: CircularProgressIndicator(color: Neon.pink));
    }
    if (state.error != null && count == 0) {
      return _stateArea(
        message: state.error!,
        retryLabel: '重试',
        onRetry: () => unawaited(_loadOnline(id)),
        // who's 在线连不上时给本地兜底入口（不困在错误页）。
        manageLabel: id == 'whos' ? '切到本地女优库' : null,
        onManage: id == 'whos' ? () => _selectSource(0) : null,
      );
    }
    if (state.loaded && count == 0) {
      return _stateArea(message: '这个源暂时没有内容', retryLabel: '重试',
          onRetry: () => unawaited(_loadOnline(id)));
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (note) {
        if (note.metrics.pixels >= note.metrics.maxScrollExtent - 600) {
          unawaited(_loadOnline(id, more: true));
        }
        return false;
      },
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
        itemCount: count,
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 130,
          mainAxisSpacing: 12,
          crossAxisSpacing: 10,
          childAspectRatio: 0.56,
        ),
        itemBuilder: (context, index) => isDart
            ? _onlineCard(
                actressOnlineSourceById(id)!,
                state.cards[index],
                badge: null,
              )
            : _dramaCard(state.items[index], badge: null),
      ),
    );
  }

  Widget _localBody() {
    if (_localLoading && !_localLoaded) {
      return const Center(child: CircularProgressIndicator(color: Neon.pink));
    }
    if (_localError != null) {
      return _stateArea(
        message: _localError!,
        retryLabel: '重试',
        onRetry: () => unawaited(_loadLocal(reset: true)),
        manageLabel: '去授权 / 打开管理',
        onManage: () => unawaited(_showManageSheet()),
      );
    }
    if (_inWorks || _localTab == 0 || _localTab == 1) {
      if (_localLoaded && _localItems.isEmpty) {
        return _stateArea(
          message: '这里暂时没有作品',
          retryLabel: '重试',
          onRetry: () => unawaited(_loadLocal(reset: true)),
        );
      }
      return NotificationListener<ScrollNotification>(
        onNotification: (note) {
          if (note.metrics.pixels >= note.metrics.maxScrollExtent - 600) {
            unawaited(_loadLocal(more: true));
          }
          return false;
        },
        child: GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
          itemCount: _localItems.length + (_localLoading ? 1 : 0),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 130,
            mainAxisSpacing: 12,
            crossAxisSpacing: 10,
            childAspectRatio: 0.56,
          ),
          itemBuilder: (context, index) {
            if (index >= _localItems.length) {
              return const Center(
                child: CircularProgressIndicator(color: Neon.pink),
              );
            }
            return _localCard(_localItems[index], badge: null);
          },
        ),
      );
    }
    if (_localTab == 2) {
      if (_localLoaded && _localActresses.isEmpty) {
        return _stateArea(
          message: '本地库里暂时没有演员数据',
          retryLabel: '重试',
          onRetry: () => unawaited(_loadLocal(reset: true)),
        );
      }
      return NotificationListener<ScrollNotification>(
        onNotification: (note) {
          if (note.metrics.pixels >= note.metrics.maxScrollExtent - 600) {
            unawaited(_loadLocal(more: true));
          }
          return false;
        },
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
          itemCount: _localActresses.length,
          itemBuilder: (context, index) {
            final row = _localActresses[index];
            final name = (row['name'] ?? '').toString();
            final avatar = (row['avatar'] ?? '').toString();
            final count = row['count'];
            return ListTile(
              key: ValueKey('native-actress-$name'),
              leading: CircleAvatar(
                backgroundColor: Neon.surfaceHigh,
                backgroundImage: avatar.isEmpty ? null : NetworkImage(avatar),
                child: avatar.isEmpty
                    ? Text(
                        name.isEmpty ? '?' : name.characters.first,
                        style: const TextStyle(color: Neon.text),
                      )
                    : null,
              ),
              title: Text(name, style: const TextStyle(color: Neon.text)),
              subtitle: Text(
                '作品 $count 部',
                style: const TextStyle(color: Neon.textDim, fontSize: 12),
              ),
              trailing: const Icon(
                Icons.chevron_right_rounded,
                color: Neon.textDim,
              ),
              onTap: () => _openWorks(actress: name),
            );
          },
        ),
      );
    }
    // 标签页签：chips 云。
    if (_localLoaded && _localTags.isEmpty) {
      return _stateArea(
        message: '本地库里暂时没有标签数据',
        retryLabel: '重试',
        onRetry: () => unawaited(_loadLocal(reset: true)),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final row in _localTags)
            ActressNeonPill(
              key: ValueKey('native-tag-${row['name']}'),
              label: '${row['name']} · ${row['count']}',
              selected: false,
              onTap: () => _openWorks(tag: (row['name'] ?? '').toString()),
            ),
        ],
      ),
    );
  }

  Widget _searchBody() {
    // 分段一次性建出（不懒建）：段数固定四段、每段只出第一页结果，
    // 整列滚动即可，不用 ListView 的视口懒建（懒建时未滚到的段在
    // 树里不存在，状态核对与无障碍都够不着）。
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final section in _searchSections) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
            child: Text(
              section.loading
                  ? '${section.label} · 搜索中…'
                  : section.error != null
                  ? '${section.label} · 失败'
                  : '${section.label} · ${section.count}条',
              style: const TextStyle(
                color: Neon.text,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (section.loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(child: CircularProgressIndicator(color: Neon.pink)),
            )
          else if (section.error != null)
            Text(
              section.error!,
              style: const TextStyle(color: Neon.textDim, fontSize: 12),
            )
          else if (section.count == 0)
            const Text(
              '没有找到',
              style: TextStyle(color: Neon.textDim, fontSize: 12),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: section.count,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 130,
                mainAxisSpacing: 12,
                crossAxisSpacing: 10,
                childAspectRatio: 0.56,
              ),
              itemBuilder: (context, index) => section.sourceId == null
                  ? _localCard(section.localItems[index], badge: section.label)
                  : section.isDart
                  ? _onlineCard(
                      actressOnlineSourceById(section.sourceId!)!,
                      section.cards[index],
                      badge: section.label,
                    )
                  : _dramaCard(section.dramas[index], badge: section.label),
            ),
          ],
        ],
      ),
    );
  }

  /// 状态区：文案 + 重试（+ 可选管理入口）。白屏与无限转圈都不许有，
  /// 所有失败/空态都落到这里。
  Widget _stateArea({
    required String message,
    String? retryLabel,
    VoidCallback? onRetry,
    String? manageLabel,
    VoidCallback? onManage,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.video_library_outlined,
              size: 40,
              color: Neon.textDim,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Neon.textDim, fontSize: 13),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              children: [
                if (onRetry != null)
                  ActressNeonPill(
                    label: retryLabel ?? '重试',
                    selected: true,
                    onTap: onRetry,
                  ),
                if (onManage != null)
                  ActressNeonPill(
                    key: const ValueKey('native-state-manage'),
                    label: manageLabel ?? '打开管理',
                    selected: false,
                    onTap: onManage,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 作品卡（本地行）：封面 2:3、标题 2 行、副行番号/日期或女优名。
  Widget _localCard(Map<String, dynamic> item, {required String? badge}) {
    final vodId = (item['vodId'] ?? '').toString();
    final code = (item['code'] ?? '').toString();
    final date = (item['date'] ?? '').toString();
    final actress = (item['actress'] ?? '').toString();
    final subtitle = [
      if (code.isNotEmpty) code,
      if (date.isNotEmpty) date else if (actress.isNotEmpty) actress,
    ].join(' · ');
    return _posterCard(
      key: ValueKey('native-work-$vodId'),
      title: (item['title'] ?? '').toString(),
      pic: (item['pic'] ?? '').toString(),
      subtitle: subtitle,
      badge: badge,
      placeholder: code.isEmpty ? 'NV' : code,
      onTap: () => _openLocalDetail(item),
    );
  }

  /// 作品卡（在线 Drama）：副行取日期/分类，没有就取站名。
  Widget _dramaCard(Drama drama, {required String? badge}) {
    final subtitle = drama.onlineDate.isNotEmpty
        ? drama.onlineDate
        : (drama.tags.isNotEmpty
              ? drama.tags.first
              : (drama.category.isNotEmpty ? drama.category : drama.source));
    return _posterCard(
      key: ValueKey('native-work-${drama.source}-${drama.id}'),
      title: drama.title,
      pic: drama.cover,
      subtitle: subtitle,
      badge: badge,
      placeholder: 'NV',
      onTap: () => _openOnlineDetail(drama),
    );
  }

  /// 作品卡（Dart 直连源）：副行取时长，没有就取番号/站名；
  /// 点卡进作品详情页（页内起播），不直进播放器。
  Widget _onlineCard(
    ActressOnlineSource source,
    OnlineVideoCard card, {
    required String? badge,
  }) {
    final subtitle = card.duration.isNotEmpty
        ? card.duration
        : (source.id == '123av' ? av123CodeOf(card.pageUrl) : source.label);
    return _posterCard(
      key: ValueKey('native-work-${source.id}-${card.pageUrl}'),
      title: card.title,
      pic: card.cover,
      subtitle: subtitle,
      badge: badge,
      placeholder: 'NV',
      onTap: () => _openDartDetail(source, card),
    );
  }

  Widget _posterCard({
    required Key key,
    required String title,
    required String pic,
    required String subtitle,
    required String? badge,
    required String placeholder,
    required VoidCallback onTap,
  }) {
    return InkWell(
      key: key,
      onTap: onTap,
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
                  Container(
                    color: Neon.surface,
                    width: double.infinity,
                    height: double.infinity,
                    child: pic.isEmpty
                        ? Center(
                            child: Text(
                              placeholder,
                              style: const TextStyle(
                                color: Neon.textDim,
                                fontSize: 12,
                              ),
                            ),
                          )
                        : Image.network(
                            pic,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          ),
                  ),
                  if (badge != null)
                    Positioned(
                      left: 4,
                      top: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xCC000000),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          badge,
                          style: const TextStyle(
                            color: Neon.cyan,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
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
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Neon.text, fontSize: 12, height: 1.3),
          ),
          if (subtitle.isNotEmpty)
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Neon.textDim, fontSize: 10.5),
            ),
        ],
      ),
    );
  }

  /// 底部源切换条：四段——女优库（本地，默认）/ who's / 123AV /
  /// PH；123AV 与 PH 带「未验」小标（本机出口未验通，口径如实）。
  Widget _sourceBar() {
    const segments = <(String, String, bool)>[
      ('native-source-local', '女优库', false),
      ('native-source-whos', "who's", false),
      ('native-source-123av', '123AV', true),
      ('native-source-pornhub', 'PH', true),
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
            for (var i = 0; i < segments.length; i++)
              Expanded(
                child: InkWell(
                  key: ValueKey(segments[i].$1),
                  onTap: () => _selectSource(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          segments[i].$2,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: _sourceIndex == i
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: _sourceIndex == i
                                ? Neon.cyan
                                : Neon.textDim,
                          ),
                        ),
                        if (segments[i].$3) ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Neon.pink.withValues(alpha: .25),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              '未验',
                              style: TextStyle(
                                color: Neon.pink,
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
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
}
