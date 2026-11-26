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
// - who's（在线，源 id 'whos'，内置 py 源）、123AV（'123av'）、
//   PH（'pornhub'）：走 AppRepository 的 categories / catalog /
//   detail。123AV 与 PH 本机出口未验通，源切换条上如实带「未验」
//   小标，不写成已验。
//
// 状态纪律：任何源加载失败 / 无库 / 无数据都出明确状态区（文案 +
// 重试或去管理钮），不白屏、不无限转圈（所有加载带超时，失败落
// 到错误态）。切源时各源已加载内容保留在各自状态里，切回不重载；
// 只有下拉/重试/管理弹层里的「重新加载数据库」才强制重载。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'actress_adapter_models.dart';
import 'actress_adapter_player.dart';
import 'actress_adapter_repository.dart';
import 'actress_adapter_store.dart';
import 'actress_ios_import.dart';
import 'actress_library_db.dart';
import 'actress_list_page.dart';
import 'actress_mytv_bind.dart';
import 'actress_neon.dart';
import 'actress_nvku_page.dart';
import 'whos_fallback.dart';
import 'whos_local_library.dart';

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

class ActressLibraryNativePage extends StatefulWidget {
  const ActressLibraryNativePage({
    super.key,
    required this.repository,
    required this.store,
    this.fallback,
    this.bind,
  });

  final AppRepository repository;
  final LocalStore store;

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
class _OnlineState {
  var categories = <CatalogCategory>[];
  var categoriesLoaded = false;
  var category = '';
  var items = <Drama>[];
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
  var loading = true;
  String? error;

  int get count => sourceId == null ? localItems.length : dramas.length;
}

class _ActressLibraryNativePageState extends State<ActressLibraryNativePage> {
  late ActressLibraryDbFallback _fallback =
      widget.fallback ?? ActressLibraryDbFallback();
  ActressMytvBind get _bind => widget.bind ?? ActressMytvBind.instance;

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
      if (!state.categoriesLoaded) {
        // 分类取不到是诚实错误态 + 重试，不拿空分类硬凑目录。
        state.categories = await widget.repository
            .categories(sourceId)
            .timeout(_loadTimeout);
        state.categoriesLoaded = true;
        if (state.category.isEmpty && state.categories.isNotEmpty) {
          state.category = state.categories.first.id;
        }
      }
      final result = await widget.repository
          .catalog(sourceId, page: page, category: state.category)
          .timeout(_loadTimeout);
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
    // 在线段：跨源流式搜索，逐段填充；整批抛错时还没落地的段各自
    // 记失败原因，不拖垮已经出结果的段。
    try {
      await widget.repository
          .searchAcrossProgressive(
            [for (final (id, _) in _onlineSources) id],
            query,
            onSite: (source, items) {
              if (!mounted || generation != _searchGeneration) return;
              final section = _searchSections
                  .where((row) => row.sourceId == source)
                  .firstOrNull;
              if (section == null) return;
              setState(() {
                section.loading = false;
                section.dramas = items;
              });
            },
          )
          .timeout(_loadTimeout);
    } catch (error) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        for (final section in _searchSections.skip(1)) {
          if (section.loading) {
            section.loading = false;
            section.error = '搜索失败：${error.toString().split('\n').first}';
          }
        }
      });
    }
    if (!mounted || generation != _searchGeneration) return;
    // 没回调到的源段（站不可用被聚合层跳过）：落成空结果，不留转圈。
    setState(() {
      for (final section in _searchSections.skip(1)) {
        section.loading = false;
      }
    });
  }

  void _exitSearch() {
    _searchGeneration++;
    setState(() {
      _searching = false;
      _searchSections = [];
    });
  }

  // ================= 播放 / 详情 =================

  Future<void> _playOnline(Drama drama) async {
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

  void _openLocalDetail(Map<String, dynamic> item) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _LocalWorkDetailPage(
          vodId: (item['vodId'] ?? '').toString(),
          fallback: _fallback,
          repository: widget.repository,
          store: widget.store,
          onActress: (name) {
            Navigator.of(context).pop();
            _openWorks(actress: name);
          },
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
    final state = _online[_onlineSourceId]!;
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
    if (state.loading && state.items.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: Neon.pink));
    }
    if (state.error != null && state.items.isEmpty) {
      return _stateArea(
        message: state.error!,
        retryLabel: '重试',
        onRetry: () => unawaited(_loadOnline(id)),
      );
    }
    if (state.loaded && state.items.isEmpty) {
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
        itemCount: state.items.length,
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 130,
          mainAxisSpacing: 12,
          crossAxisSpacing: 10,
          childAspectRatio: 0.56,
        ),
        itemBuilder: (context, index) =>
            _dramaCard(state.items[index], badge: null),
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
      onTap: () => unawaited(_playOnline(drama)),
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

/// 本地作品详情页（本模块内原生页）：大海报、标题、番号/女优/日期/
/// 类型、播放线路钮组、相关作品网格。数据走 detail op。
class _LocalWorkDetailPage extends StatefulWidget {
  const _LocalWorkDetailPage({
    required this.vodId,
    required this.fallback,
    required this.repository,
    required this.store,
    required this.onActress,
  });

  final String vodId;
  final ActressLibraryDbFallback fallback;
  final AppRepository repository;
  final LocalStore store;
  final void Function(String name) onActress;

  @override
  State<_LocalWorkDetailPage> createState() => _LocalWorkDetailPageState();
}

class _LocalWorkDetailPageState extends State<_LocalWorkDetailPage> {
  Map<String, dynamic>? _item;
  String? _error;
  var _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final result = await widget.fallback
          .handle({'op': 'detail', 'vodId': widget.vodId})
          .timeout(_loadTimeout);
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (result['ok'] == true && result['item'] is Map) {
          _item = Map<String, dynamic>.from(result['item'] as Map);
        } else {
          _error = (result['error'] ?? '本地库无此番号').toString();
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '详情加载失败：${error.toString().split('\n').first}';
      });
    }
  }

  Future<void> _playLine(int index, List<String> playUrls) async {
    final item = _item!;
    final vodId = (item['vodId'] ?? widget.vodId).toString();
    final title = (item['title'] ?? '').toString();
    final pic = (item['pic'] ?? '').toString();
    final drama = Drama(
      id: whosLocalId(vodId),
      source: whosSourceId,
      sourceId: whosLocalId(vodId),
      title: title,
      cover: pic,
    );
    // 集形态照 whosLocalDetail：一条直链集，播放只走库里地址。
    final detail = whosLocalDetail(
      drama,
      WhosLocalWork(
        id: vodId,
        title: title,
        cover: pic,
        playUrl: playUrls[index],
        code: vodId,
      ),
    );
    if (detail.episodes.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这条线路没有可播地址')));
      return;
    }
    await pushPlayer<void>(
      context,
      detail: detail,
      initialIndex: 0,
      repository: widget.repository,
      store: widget.store,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: actressNeonAppBar(
        title: const Text('作品详情', style: TextStyle(fontSize: 16)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Neon.pink))
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!, style: const TextStyle(color: Neon.textDim)),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _loading = true;
                        _error = null;
                      });
                      unawaited(_load());
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
            )
          : _body(),
    );
  }

  Widget _body() {
    final item = _item!;
    final title = (item['title'] ?? '').toString();
    final pic = (item['pic'] ?? '').toString();
    final code = (item['code'] ?? item['vodId'] ?? '').toString();
    final date = (item['date'] ?? '').toString();
    final typeName = (item['typeName'] ?? '').toString();
    final actresses = [
      for (final row in (item['actresses'] as List? ?? const []))
        row.toString(),
    ];
    final tags = [
      for (final row in (item['tags'] as List? ?? const [])) row.toString(),
    ];
    final playUrls = [
      for (final row in (item['playUrls'] as List? ?? const []))
        row.toString(),
    ];
    final related = [
      for (final row in (item['related'] as List? ?? const []))
        Map<String, dynamic>.from(row as Map),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Center(
          child: Container(
            width: 180,
            height: 270,
            decoration: actressNeonCardDecoration(radius: 12),
            clipBehavior: Clip.antiAlias,
            child: pic.isEmpty
                ? Center(
                    child: Text(
                      code,
                      style: const TextStyle(color: Neon.textDim),
                    ),
                  )
                : Image.network(
                    pic,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          title,
          style: const TextStyle(
            color: Neon.text,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 8),
        if (code.isNotEmpty)
          Text('番号：$code', style: const TextStyle(color: Neon.textDim)),
        if (date.isNotEmpty)
          Text('日期：$date', style: const TextStyle(color: Neon.textDim)),
        if (typeName.isNotEmpty)
          Text('类型：$typeName', style: const TextStyle(color: Neon.textDim)),
        if (actresses.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text(
            '女优',
            style: TextStyle(color: Neon.text, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final name in actresses)
                ActressNeonPill(
                  label: name,
                  selected: false,
                  onTap: () => widget.onActress(name),
                ),
            ],
          ),
        ],
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tag in tags)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Neon.surface,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    tag,
                    style: const TextStyle(color: Neon.textDim, fontSize: 11),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        const Text(
          '播放线路',
          style: TextStyle(color: Neon.text, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        if (playUrls.isEmpty)
          const Text(
            '本地库里没有这部的播放地址',
            style: TextStyle(color: Neon.textDim),
          )
        else
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < playUrls.length; i++)
                ActressNeonPill(
                  key: ValueKey('native-line-$i'),
                  label: '线路${i + 1}',
                  selected: i == 0,
                  onTap: () => unawaited(_playLine(i, playUrls)),
                ),
            ],
          ),
        if (related.isNotEmpty) ...[
          const SizedBox(height: 20),
          const Text(
            '相关作品',
            style: TextStyle(color: Neon.text, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: related.length,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 130,
              mainAxisSpacing: 12,
              crossAxisSpacing: 10,
              childAspectRatio: 0.56,
            ),
            itemBuilder: (context, index) {
              final row = related[index];
              final relatedId = (row['vodId'] ?? '').toString();
              return InkWell(
                onTap: () => Navigator.of(context).pushReplacement<void, void>(
                  MaterialPageRoute(
                    builder: (_) => _LocalWorkDetailPage(
                      vodId: relatedId,
                      fallback: widget.fallback,
                      repository: widget.repository,
                      store: widget.store,
                      onActress: widget.onActress,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Container(
                        decoration: actressNeonCardDecoration(radius: 10),
                        clipBehavior: Clip.antiAlias,
                        child: (row['pic'] ?? '').toString().isEmpty
                            ? const SizedBox.shrink()
                            : Image.network(
                                (row['pic'] ?? '').toString(),
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    const SizedBox.shrink(),
                              ),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      (row['title'] ?? '').toString(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Neon.text, fontSize: 12),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}
