import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'actress_database.dart';
import 'actress_db_fields_page.dart';
import 'actress_db_selection.dart';
import 'actress_detail_page.dart';
import 'actress_generic_database.dart';
import 'actress_generic_db.dart';
import 'actress_ios_import.dart';
import 'actress_json_fallback.dart';
import 'actress_models.dart';
import 'actress_multi_db_fallback.dart';
import 'actress_mytv_bind.dart';
import 'actress_neon.dart';
import 'actress_nvku_cache.dart';
import 'actress_ranking_page.dart';
import 'actress_tag_sheet.dart';
import 'actress_widgets.dart';
import 'actress_adapter_models.dart';
import 'whos_fallback.dart';
import 'whos_json_index.dart';
import 'actress_adapter_repository.dart';
import 'actress_adapter_store.dart';
import 'actress_adapter_player.dart';

/// 女优库浏览页：人物列表 + 搜索/性别筛选/排序。
///
/// 打开只读本地外置库（MYTV/db/女优库.db）+ 本地 json/m3u 兜底。
/// 2026-11-26 只读化（用户令）：同步/现爬/全站叠加/数据库镜像整套
/// 已删，库只读打开、不写任何东西，内容变更只经换库文件后手动
/// “重新加载数据库”；没有外置库时由内置 who's JSON 顶上演员库
/// 首页（按人归拢、可播），分类/标签 JSON 里没有的照旧空态。
/// 名单加载三条路统一带 try/catch + 超时 + 失败重试（照文件夹路
/// 口径），永不无限转圈；名单第一页进 NvkuEntryCache 名单槽，
/// 切区回来先上屏。排行榜入口在顶栏奖杯钮。
/// 站点筛选下拉选项（纯函数，供测试直接验）：全部 + mjv + whos +
/// 片库全部可见视频站（与叠加搜索 actressSearchSiteIds 同一口径：
/// store.visibleSources 里 isVideoSection、非 cloud:、siteVisible
/// 的站；跳过 mjv/whos/chaoliu——chaoliu 即 mjv，已有 mjv 项代表
/// 它；跳过 ZakaJavrate（鉴黄师，用户 2026-11-21 令：女优库里
/// 播不了，站点列表里不留它）；yikm 这类游戏站不在视频区登记里，
/// 进不了选项）。
List<ActressSiteFilter> actressSiteFilterOptions(LocalStore store) {
  final options = <ActressSiteFilter>[
    ActressSiteFilter.all,
    ActressSiteFilter.mjv,
    ActressSiteFilter.whos,
  ];
  final seen = <String>{'all', 'mjv', 'whos', 'chaoliu', 'ZakaJavrate'};
  for (final site in store.visibleSources) {
    if (!site.isVideoSection) continue;
    if (site.id.startsWith('cloud:')) continue;
    if (!store.siteVisible(site.id)) continue;
    if (!seen.add(site.id)) continue;
    options.add(ActressSiteFilter(site.id, site.name));
  }
  return options;
}

class ActressListPage extends StatefulWidget {
  const ActressListPage({
    super.key,
    required this.repository,
    required this.store,
    this.database,
    this.fallback,
    this.showTitle = true,
    this.externalSearch,
  });

  final AppRepository repository;
  final LocalStore store;

  /// 内嵌进区域/窗口/内层页签时宿主已有“女优库”标题，页内顶栏不再
  /// 重复标题字（只留人数），与 MiniAppHomePage 的做法同口径。
  final bool showTitle;

  /// 宿主已经有一条置顶搜索框时传进来（2026-11-21 用户令：搜索框
  /// 不许叠两个、顶栏不许叠两条）。传了就用宿主的输入框做搜索源，
  /// 本页不再画自己的搜索框，只留人数与右侧动作按钮。
  final TextEditingController? externalSearch;

  /// 测试/预览注入：不传时用 sqflite 真库。
  @visibleForTesting
  final ActressDatabase? database;

  /// 测试/预览注入：JSON 兜底；不传时现建。
  @visibleForTesting
  final ActressJsonFallback? fallback;

  /// 测试注入：把名单加载超时压短（生产恒为 null，用页面内常量
  /// 首屏 20 秒 / 翻页 15 秒）。
  @visibleForTesting
  static Duration? listTimeoutOverride;

  @override
  State<ActressListPage> createState() => _ActressListPageState();
}

/// 列表第一页缓存项（2026-11-24 切换不重载）：第一页人物 + hasMore
/// + 查库时的原始偏移（翻页用）+ 滚动偏移（切换回来恢复位置用）。
class _CachedListPage {
  _CachedListPage(this.persons, this.hasMore, this.rawOffset);

  final List<ActressPerson> persons;
  final bool hasMore;
  final int rawOffset;

  /// 切换前存的滚动偏移；恢复时等网格布局完再跳，越界时钳制。
  double scrollOffset = 0;
}

class _ActressListPageState extends State<ActressListPage> {
  static const _pageSize = 60;

  /// 名单加载超时（2026-11-26 照文件夹路口径）：首屏 20 秒、
  /// 翻页 15 秒，超时算失败出重试，永不无限转圈。
  static const _firstPageTimeout = Duration(seconds: 20);
  static const _nextPageTimeout = Duration(seconds: 15);

  Duration get _firstTimeout =>
      ActressListPage.listTimeoutOverride ?? _firstPageTimeout;
  Duration get _nextTimeout =>
      ActressListPage.listTimeoutOverride ?? _nextPageTimeout;

  late final ActressDatabase _db;
  late final ActressJsonFallback _fallback;

  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  Timer? _searchDebounce;

  /// 名单加载失败原因（非空且名单为空时显示失败态 + 重试钮）。
  String? _loadError;

  var _persons = <ActressPerson>[];
  var _loading = true;
  var _loadingMore = false;
  var _hasMore = true;

  /// 刷新中（筛选切换时）：旧列表留着当底，只在列表顶露一条细进度条，
  /// 不清列表、不转大圈，滚动位置天然保住。首屏第一次加载仍走
  /// _loading 大转圈（2026-11-24 切换不重载）。
  var _refreshing = false;

  /// 第一页缓存（2026-11-24 切换不重载）：key = 筛选条件全维度，
  /// 值 = 第一页人物 + hasMore + 查库时的原始偏移 + 滚动偏移。
  /// 只缓存第一页（60 条），上限 8 个 key（LRU）。失效：热换库、
  /// 手动刷新时全清（见 _clearListCaches）；另同步写一份到
  /// NvkuEntryCache 名单槽，页面 State 重建后也能先上屏。
  final _pageCache = <String, _CachedListPage>{};
  static const _pageCacheMaxKeys = 8;

  /// 外来库连接的文件指纹（打开时记的 mtime + 大小）：复用连接前先
  /// 比对，文件被用户在外面替换过就关掉重开，不能读旧文件句柄。
  final _extraDbFingerprints = <String, (DateTime, int)>{};

  /// 可播视频数缓存（2026-11-24）：按路径记（数量，mtime，大小）。
  /// 文件没变直接用缓存数，变了才重数；-1（打不开）不缓存，下次重试。
  final _playableCountCache = <String, (int, DateTime, int)>{};

  var _sex = ActressSexFilter.all;
  var _tagFilter = ActressTagFilter.all;
  var _sort = ActressSort.worksDesc;

  /// 作品标签筛选（2026-11-24 用户令：who's.json 分类是日本AV，
  /// 标签在数据库里，底部弹窗显示里面的标签）：默认全部；选标签
  /// 后列表只留有该标签作品的人（人物列表页的诚实语义：标签是按
  /// 作品的，人只按“有没有该标签的作品”留，不把人本身算成有标签）。
  /// 与分类是 AND 关系（既是该分类、又有该标签的作品才留人）。
  /// 标签列表只在打开弹窗时才查库（GROUP BY 一次），之后走缓存；
  /// 换库时清空（标签是旧库的数据），切分类/搜词/换排序时保留。
  var _videoTag = '';
  String? _dbTagsCacheKey;
  List<(String, int)>? _dbTagsCache;

  /// 通用模式标签筛选：与 [_videoTag] 同一口径，筛的是当前通用库
  /// 的作品；[_genericTagKey] 是筛选键（`video_tag.tag_name` 或
  /// 作品表里的标签列，见 GenericDbReader.tagFacet），空 = 该库
  /// 没有标签维度，弹窗如实显示“暂无标签”。
  var _genericTag = '';
  var _genericTagKey = '';

  var _query = '';
  var _generation = 0;

  /// 顶栏站点筛选：默认全部；选站后列表只留该站有 JSON 兜底条目的
  /// 人（按女优名或本地作品番号对），详情页兜底与现爬也只走该站。
  var _source = ActressSiteFilter.all;

  /// 站点筛选选项快照（只记 id 集合，进页时按活的站源注册表读
  /// 一次；选项本身不缓存，每次打开菜单时现算——
  /// actressSiteFilterOptions 读的就是活的 visibleSources）。
  /// 站源注册表再变时与它比对：有变才动（顶栏只重建、不在每次
  /// store 通知时都白刷一遍）。
  var _siteOptionIds = <String>{};

  /// 站点过滤时的原始偏移（过滤后页内人数会少于 60，翻页必须按
  /// 原始偏移走，不能按过滤后的人数走）。
  var _rawOffset = 0;

  /// 每人本地作品番号集合缓存（站点过滤用，按需取一次）。
  final _siteCodeKeys = <int, Set<String>>{};

  ActressSyncOverview? _overview;

  /// 2026-11-20 MYTV 绑定：绑定解析结果（库落点、是否已授权）。
  /// bootstrap 第一件事就是解析它——在第一次读库之前，库的落点
  /// （MYTV/db/女优库.db，或未找到外置库）与 json/m3u 目录都由它定。
  MytvBindResult? _mytvBind;

  /// 绑定行被用户点了“隐藏提示”后隐藏（本页内有效）。
  var _mytvRowDismissed = false;

  /// 没有外置数据库：绑定不到 MYTV/db/女优库.db，列表显示空态
  /// 提示（放库、重新加载），不回落任何内置库。
  var _noExternalDb = false;

  /// 兜底加载器是不是本页自己建的：是才按绑定结果改它的本地
  /// 目录；测试注入的实例不动（注入的假目录优先）。
  var _ownsFallback = true;

  /// 2026-11-20 热换库：最近一次重读失败的原因（显示在绑定行上）；
  /// 成功重读后清掉。没有外置数据库时这里就是“未找到外置数据库”。
  String? _mytvDbError;

  /// 手动“重新加载数据库”进行中（防重复点）。
  var _reloadingDb = false;

  /// 开库提示（见 openFallbackNote）：2026-11-22 起不再回退任何
  /// 内置库，恒为 null（显示分支保留）。
  String? _mytvOpenNote;

  /// 无库时 JSON 顶首页（2026-11-26 用户令）：没有外置 .db 时，
  /// 演员库首页由内置 who's JSON 顶上——名单按番号数归拢、点人
  /// 看其作品、点卡直链可播；分类/标签 JSON 里没有，照旧空态。
  /// 有库时完全走库，本模式不进。[_jsonWorksPerson] 非空时名单
  /// 换成该人的作品网格（页内模式，返回钮回名单）。
  var _jsonTopMode = false;
  WhosJsonIndex? _jsonIndex;
  String? _jsonWorksPerson;
  var _jsonWorks = <GenericDbWork>[];

  /// JSON 顶首页时当前筛选维度 JSON 支撑不了（男优/分类/标签）：
  /// 名单置空并用专门文案说明，不假装“暂无人物”。
  var _jsonFilterUnsupported = false;

  /// 2026-11-20 通用读库：当前库不是女优库结构时为 true，列表
  /// 改走通用作品模式（作品列表 + 点按直播），不走女优库的总览/
  /// 同步/自动生成。[_genericReader] 为空时不是通用模式。
  /// 2026-11-23 多库勾选：勾上的外来库（只读打开的严格视频库实例），
  /// 主库之外的库按这个读列表与分类；打不开/不是严格结构的库不进这里。
  /// 勾选集合本身存在 SharedPreferences（见 actress_db_selection），
  /// 设置弹窗里那份列表自己维护勾选状态，这里只留打开的实例。
  final _extraDbs = <String, ActressDatabase>{};

  /// 合并后的人名 → 该人作品所在的库：主库优先，只在主库没有这个人
  /// 时才指到外来库；点人进详情页时按这个库取作品。
  final _personHomeDb = <String, ActressDatabase>{};

  var _genericMode = false;

  GenericDbReader? _genericReader;

  /// 三库合并内置兜底（主库 + 其它 .db），本页自己建的时候持有，
  /// 退出时关掉连接。
  MultiDbFilmFallback? _multiDb;
  var _genericWorks = <GenericDbWork>[];
  var _genericTotal = 0;

  /// 通用模式分类（2026-11-22：外来库视频列表页顶部的分类行，
  /// 照活树改版）：从当前库自身的 video_category 表取
  /// （见 GenericDbReader.categories，按数量倒序）；没读完时
  /// 不占位，读完为空才如实显示“暂无分类”。
  var _genericCategories = <(String, int)>[];
  var _genericCategory = '';
  var _genericCategoriesLoaded = false;

  /// 只出作品的站源（nvku）：站上只有作品没有人物名册，选了它就切
  /// 到作品网格按站点分类翻页，不再按人物过滤（否则永远是「该站
  /// 暂无匹配人物」）。
  var _siteWorks = <Drama>[];
  var _siteWorksPage = 1;
  var _siteWorksCategory = '';
  var _siteCategories = <CatalogCategory>[];

  bool get _siteWorksMode => _source.siteId == nvkuSourceId;

  @override
  void initState() {
    super.initState();
    _db = widget.database ?? SqfliteActressDatabase.instance;
    _ownsFallback = widget.fallback == null;
    _fallback = widget.fallback ?? ActressJsonFallback();
    if (_ownsFallback) {
      // 2026-11-20 18:57 全部使用数据库兜底：兜底先查影视库 db
      // （MYTV/db/女优库.db），读不到回退 json/m3u。测试注入的
      // fallback 不接提供方，保持老行为。
      _fallback.filmDb = _multiDb = MultiDbFilmFallback(database: _db);
    }
    _scrollController.addListener(_onScroll);
    _searchController.addListener(_onSearchChanged);
    // 宿主搜索框（内嵌进女优库区域时）：同一个输入框驱动本页搜索，
    // 本页不再画第二个搜索框。
    widget.externalSearch?.addListener(_onSearchChanged);
    final initialSearch = widget.externalSearch?.text.trim() ?? '';
    if (initialSearch.isNotEmpty) _query = initialSearch;
    // 站点筛选选项进页时按活的站源注册表读一次（不是启动快照）；
    // 之后站源注册表再变（新站导入/站点摘掉/隐藏）走监听重建。
    _siteOptionIds = _siteFilterOptions().map((o) => o.siteId).toSet();
    widget.store.addListener(_onStoreChanged);
    _bootstrap();
  }

  @override
  void dispose() {
    _saveScrollOffsetForCache();
    for (final extra in _extraDbs.values) {
      unawaited(extra.close());
    }
    unawaited(_multiDb?.close());
    widget.store.removeListener(_onStoreChanged);
    _scrollController.dispose();
    widget.externalSearch?.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final generation = ++_generation;
    // 2026-11-20 MYTV 绑定：先解析绑定，再读库。绑定里建
    // MYTV/db 与 MYTV/m3u、迁移老数据（开库前做，库开着拷
    // 不干净）；没权限/外部存储不可用时降级回 documents，
    // 下面流程不变，女优库照常能用。测试环境没有平台通道，
    // 解析内部全包 try/catch，拿不到就降级，不抛错。
    final bind = await ActressMytvBind.instance.ensureBound();
    if (!mounted || generation != _generation) return;
    setState(() => _mytvBind = bind);
    // 2026-11-23 多库勾选：绑定结果出来后读一次勾选与可选库。
    // 这里等它开完（reload: false，不重读列表）再往下走，否则首屏
    // 列表可能在外来库就绪前按单库读完，勾选的库要下次重读才合并。
    await _loadDbSelection(reload: false);
    if (_ownsFallback) {
      _fallback.bindLocalDirs(
        jsonDir: bind.jsonDir,
        userM3uDir: bind.bound ? bind.m3uDir : null,
      );
    }
    // 2026-11-20 热换库：进模块先看库文件变了没有——变了就关旧连接
    // 重开再读（用户用文件管理器换了 db 不用重装）；重读失败留旧库
    // 并把原因记下来显示在绑定行上，不崩。没有外置库时这里就报
    // “未找到外置数据库”，下面开库再抛一次也接住走 JSON 顶首页。
    final reload = await _db.reloadIfChanged();
    if (!mounted || generation != _generation) return;
    if (reload.error != null) {
      setState(() => _mytvDbError = reload.error);
    }
    // 2026-11-20 通用读库：当前库不是女优库结构时走通用模式
    // （作品列表 + 点按直播），不走女优库的总览。
    // 没有外置数据库时开库抛 ActressNoExternalDbException：
    // 接住走 JSON 顶首页（2026-11-26 用户令），索引也空才落真空态。
    GenericDbReader? generic;
    try {
      generic = await _db.genericReader();
    } on ActressNoExternalDbException catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _noExternalDb = true;
        _mytvDbError = e.message;
      });
      await _enterJsonTopMode();
      return;
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _mytvDbError = '数据库打不开：${e.toString().split('\n').first}';
        _loading = false;
      });
      return;
    }
    if (!mounted || generation != _generation) return;
    if (generic != null) {
      setState(() {
        _genericReader = generic;
        _genericMode = true;
      });
      await _loadGenericCategories();
      await _loadPage(reset: true);
      return;
    }
    setState(() {
      _genericReader = null;
      _genericMode = false;
    });
    // 兜底后台读、不堵首屏：列表站点过滤要用它，但不能在首屏等它。
    unawaited(_fallback.load());
    // 2026-11-26 名单槽先上屏：NvkuEntryCache 里有本筛选的第一页
    // 就先摆出来（切区回来不再从头转圈查库）；新鲜（5 分钟内）
    // 直接用、连总览都只后台补；过期先上屏再后台刷新。
    final slot = NvkuEntryCache.personsFirstPage(
      _personsCacheKey(bind.dbPath),
    );
    if (slot != null) {
      setState(() {
        _persons = slot.persons;
        _hasMore = slot.hasMore;
        _rawOffset = slot.rawOffset;
        _loading = false;
      });
      _restoreScrollOffset(slot.scrollOffset, generation);
      unawaited(_refreshOverviewQuietly());
      if (slot.isFresh) return;
      await _loadPage(reset: true);
      return;
    }
    await _refreshOverviewQuietly();
    if (!mounted || generation != _generation) return;
    await _loadPage(reset: true);
  }

  /// 总览（顶栏计数）后台读：带超时与守卫，读不到不挡名单——
  /// 名单自己的失败态在 _loadPage 里出，这里绝不抛错。
  Future<void> _refreshOverviewQuietly() async {
    try {
      final overview = await _db.overview().timeout(_firstTimeout);
      if (!mounted) return;
      setState(() => _overview = overview);
    } catch (_) {
      // 计数读不到：顶栏只显示“演员库”，名单照常。
    }
  }

  /// 名单槽的 key：主库文件戳（路径+大小+mtime+-wal 大小，戳变
  /// 整槽作废）+ 筛选全维度（_pageCacheKey）。删光写路径后戳只
  /// 会被外部换库顶变，App 会话内自写已不存在。dbPath 为空只
  /// 发生在没绑到外置库时（名单查不出来、存不进槽）；测试注入
  /// 假库时路径同为空，改用库实例身份分键，免得多个假库串槽。
  String _personsCacheKey(String dbPath) =>
      '${dbPath.isEmpty ? 'mem${identityHashCode(_db)}' : NvkuEntryCache.dbStamp(dbPath)}|${_pageCacheKey()}';

  /// 恢复滚动偏移：等网格布局完再跳（post-frame），越界钳制。
  void _restoreScrollOffset(double offset, int generation) {
    if (offset <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      _scrollController.jumpTo(offset.clamp(0.0, max).toDouble());
    });
  }

  /// 名单第一页查成功后同步写名单槽（与页内 _pageCache 同一份
  /// 数据）：页面 State 重建（切区回来）时 bootstrap 先查槽上屏。
  void _storeNvkuPersons(
    List<ActressPerson> persons,
    bool hasMore,
    int rawOffset,
  ) {
    // dbPath 为空只发生在没有外置库时——那时名单根本查不出来，
    // 走不到这里；测试注入假库时路径为空、按空戳存即可（key 里
    // 还有筛选全维度，不会与真库的 key 相撞：真库戳非空）。
    NvkuEntryCache.putPersonsFirstPage(
      _personsCacheKey(_mytvBind?.dbPath ?? ''),
      persons: persons,
      hasMore: hasMore,
      rawOffset: rawOffset,
    );
  }

  /// 多库勾选：读可选库与已勾的库，只读打开勾上的外来库（有可播
  /// 视频的库都进列表合并：严格视频库走 SqfliteActressDatabase，
  /// 其它结构的库走通用读法 GenericActressDatabase；0 部可播视频
  /// 或打不开的库不进，播放兜底仍走老路）。勾选变化时由设置弹窗
  /// 调 [_applyDbSelection] 再走这里。
  /// [reload] 为 false 时只开库、不重读分类与列表（启动时用，
  /// 启动流程自己会读列表）。
  /// 读勾选失败（偏好存储不可用等）时单库继续：这里绝不能抛错，
  /// 否则启动流程（_bootstrap 在等它）会被打断、列表再也读不出来。
  Future<void> _loadDbSelection({bool reload = true}) async {
    try {
      await _loadDbSelectionUnsafe(reload: reload);
    } catch (_) {
      // 勾选读不到就单库继续，不挡列表。
    }
  }

  /// 外来库文件指纹（mtime + 大小）：复用连接/缓存可播数前先比对，
  /// 文件被用户在外面替换过就当没见过、重开重数。文件没了返回 null。
  (DateTime, int)? _dbFileFingerprint(String path) {
    try {
      final stat = File(path).statSync();
      return (stat.modified, stat.size);
    } catch (_) {
      return null;
    }
  }

  /// 外来库文件指纹字符串（分类缓存 key 用）：文件没了记 'missing'。
  String _dbFileFingerprintKey(String path) {
    final fp = _dbFileFingerprint(path);
    if (fp == null) return 'missing';
    return '${fp.$1.millisecondsSinceEpoch}|${fp.$2}';
  }

  /// 该库的可播视频数（带缓存）：文件没变直接用缓存数，变了才重数。
  /// -1（打不开）不缓存，下次重试。缓存只活在本页实例里，
  /// 文件变了（指纹变）自动失效。
  Future<int> _countPlayableVideosCached(String path) async {
    final fp = _dbFileFingerprint(path);
    final cached = _playableCountCache[path];
    if (cached != null &&
        fp != null &&
        cached.$2 == fp.$1 &&
        cached.$3 == fp.$2) {
      return cached.$1;
    }
    final count = await ActressDbSelection.countPlayableVideos(path);
    if (count >= 0 && fp != null) {
      _playableCountCache[path] = (count, fp.$1, fp.$2);
    }
    return count;
  }

  Future<void> _loadDbSelectionUnsafe({bool reload = true}) async {
    final bind = _mytvBind;
    if (bind == null || !bind.bound) return;
    final choices = ActressDbSelection.availableChoices(bind: bind);
    final selected = await ActressDbSelection.loadSelectedPaths(bind.dbPath);
    // 2026-11-24 切换不重载：按路径复用已打开的连接——只开新勾的、
    // 只关取消的；勾选没变的库直接复用旧连接，不重数、不重开。
    // 文件被用户在外面替换过（指纹变了）时旧连接读的是旧文件句柄，
    // 必须关掉重开（见诊断 §7 风险 5）。
    final keep = <String, ActressDatabase>{};
    for (final choice in choices) {
      if (choice.isMain || !selected.contains(choice.path)) continue;
      final existing = _extraDbs[choice.path];
      if (existing != null) {
        final oldFp = _extraDbFingerprints[choice.path];
        final newFp = _dbFileFingerprint(choice.path);
        if (oldFp != null &&
            newFp != null &&
            oldFp.$1 == newFp.$1 &&
            oldFp.$2 == newFp.$2) {
          keep[choice.path] = existing;
          continue;
        }
        // 文件变了或指纹丢了：关掉旧连接重开。
        unawaited(existing.close());
        _extraDbFingerprints.remove(choice.path);
      }
      // 2026-11-23 用户令：数据库全部支持勾选——有可播视频的库
      // 都进合并；0 部可播视频 / 打不开的才不进（界面已如实写原因）。
      final playable = await _countPlayableVideosCached(choice.path);
      if (playable <= 0) continue;
      if (await ActressDbSelection.isStrictVideoLibraryDbFile(choice.path)) {
        keep[choice.path] = SqfliteActressDatabase.forPath(choice.path);
        // 2026-11-26 只读化：外来库同样只读打开、不补索引（原先
        // 后台 CREATE INDEX 是往用户库里写，已删）；查询走库里
        // 现成索引，没有就全表扫，正确性不受影响。
        final fp = _dbFileFingerprint(choice.path);
        if (fp != null) _extraDbFingerprints[choice.path] = fp;
        continue;
      }
      // 非严格结构：通用读法进合并（按作品表女优列分组人物，
      // 见 GenericActressDatabase）；认不出作品表的库开不出来，
      // 跳过（界面上它仍显示可播数，播放池那条路还能用它）。
      final generic = await GenericActressDatabase.open(choice.path);
      if (generic != null) {
        keep[choice.path] = generic;
        final fp = _dbFileFingerprint(choice.path);
        if (fp != null) _extraDbFingerprints[choice.path] = fp;
      }
    }
    if (!mounted) return;
    final oldExtras = Map<String, ActressDatabase>.from(_extraDbs);
    // 2026-11-24 标签筛选：勾选的库变了，旧标签是旧库的数据，新库
    // 未必有——清空已选标签与标签缓存（切分类/搜词/换排序时保留，
    // 只在换库时清）。
    final selectionChanged =
        oldExtras.keys.toSet().difference(keep.keys.toSet()).isNotEmpty ||
        keep.keys.toSet().difference(oldExtras.keys.toSet()).isNotEmpty;
    setState(() {
      _extraDbs
        ..clear()
        ..addAll(keep);
      _personHomeDb.clear();
      if (selectionChanged) {
        _videoTag = '';
        _dbTagsCacheKey = null;
        _dbTagsCache = null;
      }
    });
    for (final entry in oldExtras.entries) {
      if (!keep.containsKey(entry.key)) unawaited(entry.value.close());
    }
    // 勾选变了（勾上或取消）都要重读分类与列表：取消最后一个外来库
    // 也要回单库。启动时 reload 为 false，启动流程自己读。
    if (reload) {
      unawaited(_loadPage(reset: true));
    }
  }

  /// 设置弹窗里勾选变化：存勾选、重开外来库、重读分类与列表。
  Future<void> _applyDbSelection(Set<String> selected) async {
    final bind = _mytvBind;
    if (bind == null) return;
    await ActressDbSelection.saveSelectedPaths(selected);
    await _loadDbSelection();
  }

  /// 勾上的库里有没有外来库：没有时列表/分类走老路，一字不动。
  bool get _hasExtraDbs => _extraDbs.isNotEmpty;

  /// 多库合并查一页人：主库 + 每个勾上的外来库各查一个窗口
  /// （offset 0、limit 已翻页数 + 一页），按人名归并（作品数相加、
  /// 头像取第一个非空、性别有男算男），再按当前排序排、切出本页。
  /// 最近更新排序在合并模式下没有跨库日期字段，退化为按作品数排。
  Future<List<ActressPerson>> _loadMergedPersons({
    required int offset,
    required int limit,
  }) async {
    final window = offset + limit;
    final rawLists = <(List<ActressPerson>, ActressDatabase)>[];
    var anyFullWindow = false;
    Future<List<ActressPerson>> queryDb(ActressDatabase db) => db.listPersons(
      sex: _sex,
      sort: _sort,
      query: _query,
      tag: _tagFilter.tagValue,
      videoTag: _videoTag,
      offset: 0,
      limit: window,
    );
    final mainRows = await queryDb(_db);
    rawLists.add((mainRows, _db));
    if (mainRows.length >= window) anyFullWindow = true;
    for (final extra in _extraDbs.values) {
      try {
        final rows = await queryDb(extra);
        rawLists.add((rows, extra));
        if (rows.length >= window) anyFullWindow = true;
      } catch (_) {
        // 外来库查失败（文件被删/被占）：跳过这个库，不堵列表。
      }
    }
    final merged = <String, ActressPerson>{};
    final homeDb = <String, ActressDatabase>{};
    // 2026-11-23 多库去重：三个库是同一套合库的副本，同一（番号，
    // 播放链接）在三个库里各有一份，相加会把 2437 计成 7368。
    // 记下每个人在每个库里的作品数（供下面按（番号，播放链接）
    // 并集去重；只在多个库出现的人才要去重）。
    final personDbs = <String, Map<ActressDatabase, int>>{};
    void addRows(List<ActressPerson> rows, ActressDatabase db) {
      for (final person in rows) {
        final key = person.displayName;
        personDbs.putIfAbsent(key, () => {})[db] = person.worksCount;
        final existing = merged[key];
        if (existing == null) {
          merged[key] = person;
          homeDb[key] = db;
          continue;
        }
        merged[key] = ActressPerson(
          localId: existing.localId,
          displayName: existing.displayName,
          aliases: existing.aliases,
          sex: existing.sex == 'male' || person.sex == 'male'
              ? 'male'
              : existing.sex,
          avatarUrl: preferLoadableAvatar(
            existing.avatarUrl,
            person.avatarUrl,
          ),
          tags: existing.tags,
          worksCount: existing.worksCount + person.worksCount,
          rosterWorks: existing.rosterWorks + person.rosterWorks,
          fromChaoliu: existing.fromChaoliu || person.fromChaoliu,
          fromWhos: existing.fromWhos || person.fromWhos,
          fromMissav: existing.fromMissav || person.fromMissav,
          chaoliuId: existing.chaoliuId,
          whosSlug: existing.whosSlug,
          missavPath: existing.missavPath,
          missavRank: existing.missavRank,
          recommended: existing.recommended || person.recommended,
          filmsSyncedAt: existing.filmsSyncedAt,
          enrichedAt: existing.enrichedAt,
          rating: existing.rating,
          exactWorks: existing.exactWorks + person.exactWorks,
          about: existing.about,
          whosRank: existing.whosRank,
        );
      }
    }

    addRows(mainRows, _db);
    for (final entry in rawLists.skip(1)) {
      addRows(entry.$1, entry.$2);
    }
    _personHomeDb
      ..clear()
      ..addAll(homeDb);
    // 多库勾选时按（番号，播放链接）并集去重，计数按去重后的实数算；
    // 单库时各库计数本身就是实数，不动。
    if (_hasExtraDbs) {
      await _dedupMergedWorksCounts(merged, personDbs);
    }
    final persons = merged.values.toList();
    switch (_sort) {
      case ActressSort.nameAsc:
        persons.sort((a, b) => a.displayName.compareTo(b.displayName));
      case ActressSort.worksDesc:
      case ActressSort.recentDesc:
        // 最近更新在合并模式下退化为按作品数排（跨库没有统一日期字段）。
        persons.sort((a, b) {
          final byWorks = b.worksCount.compareTo(a.worksCount);
          if (byWorks != 0) return byWorks;
          return a.displayName.compareTo(b.displayName);
        });
    }
    _mergedHasMore = persons.length > offset + limit || anyFullWindow;
    if (offset >= persons.length) return const [];
    final end = (offset + limit).clamp(0, persons.length);
    return persons.sublist(offset, end);
  }

  /// 多库合并去重：同一（番号，播放链接）只算一条，计数按去重后
  /// 的实数算（2026-11-20 合并规则：只有番号与播放链接完全一样
  /// 才过滤，同番号不同地址各留一条）。每个人在各库拉（番号，
  /// 播放链接）键集合求并集，计数 = 并集大小；作品数巨大的兜底名
  ///（如 素人 29 万部）不拉全量集合（内存顶不住），三个库是同一
  /// 套合库的副本，并集 ≈ 最大单库数，取最大库数。只在勾了外来库
  /// 时跑；单库时各库计数本身就是实数，不动。
  static const _mergedDedupKeyCap = 50000;

  Future<void> _dedupMergedWorksCounts(
    Map<String, ActressPerson> merged,
    Map<String, Map<ActressDatabase, int>> personDbs,
  ) async {
    final targets = <String, Map<ActressDatabase, int>>{};
    final capped = <String, int>{};
    for (final entry in personDbs.entries) {
      final name = entry.key;
      final perDb = entry.value;
      final person = merged[name];
      if (person == null || perDb.length < 2) continue;
      if (person.worksCount > _mergedDedupKeyCap) {
        capped[name] = perDb.values.reduce((a, b) => a > b ? a : b);
        continue;
      }
      targets[name] = perDb;
    }
    // 各库并行拉键集合（不同库是不同连接，互不堵；同一库内
    // sqflite 串行）。单个库查失败时按该库无此人处理，不堵整页。
    final unions = <String, Set<String>>{};
    await Future.wait([
      for (final entry in targets.entries)
        for (final db in entry.value.keys)
          db
              .distinctWorkKeysForName(entry.key)
              .then(
                (keys) => unions
                    .putIfAbsent(entry.key, () => <String>{})
                    .addAll(keys),
              )
              .catchError((_) {}),
    ]);
    for (final entry in merged.entries) {
      final name = entry.key;
      final union = unions[name];
      if (union != null) {
        merged[name] = entry.value.copyWith(
          worksCount: union.length,
          exactWorks: union.length,
        );
      } else if (capped.containsKey(name)) {
        merged[name] = entry.value.copyWith(
          worksCount: capped[name],
          exactWorks: capped[name],
        );
      }
    }
  }

  var _mergedHasMore = false;

  /// 顶部瓦片行：一级分类式的方块（名字 + 库图标），横向可滑。
  /// 内嵌进女优库外壳时（2026-11-21 用户令：顶区别占半屏）压成
  /// 一条横向小卡：去掉标题行、高度减到 30，功能不变。
 /// 没拿到“所有文件访问权限”时打开系统授权页（走平台通道，
  /// 照树里悬浮窗去设置的路子）。用户在设置里授权后回 App，
  /// 点绑定行上的“重新绑定”再切 MYTV；授权前女优库显示空态。
  /// 设置页打不开（鸿蒙容器无承接方等）时给明确文案：手动路径
  /// + 改走文件夹授权，不许点了没反应。
  Future<void> _requestMytvPermission() async {
    final opened = await ActressMytvBind.instance.requestPermission();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          opened
              ? '已打开系统设置，授权后点“重新绑定”'
              : '打不开系统设置页：请到系统设置的应用权限里给本应用开'
                  '“全部文件访问”，或改用“授权文件夹读取”',
        ),
      ),
    );
  }

  /// SAF 文件夹授权（首选路，不需要全部文件访问权限）：请用户
  /// 选 MYTV 文件夹，授权存档后自动重新绑定（绑定解析走镜像
  /// 路）。镜像第一次要拷整库，可能要等一会儿，绑定行会显示
  /// 准备中提示；没选/打不开给明确文案。
  Future<void> _grantMytvFolder() async {
    final granted = await ActressMytvBind.instance.grantFolderAccess();
    if (!mounted) return;
    if (!granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有选择文件夹，或系统选择器打不开')),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已取得文件夹授权，正在准备数据库')),
    );
    await _rebindMytv();
  }

  /// 授权后重新绑定：先关库（close 会清 _openFuture，下次开库
  /// 重新走绑定路径），再重新解析绑定、给 json/m3u 重新指目录、
  /// 重读总览与列表。重新绑定成功后清掉旧的重读报错。
  Future<void> _rebindMytv() async {
    await _db.close();
    final bind = await ActressMytvBind.instance.ensureBound(refresh: true);
    if (!mounted) return;
    setState(() {
      _mytvBind = bind;
      _mytvRowDismissed = false;
      _mytvDbError = null;
      _noExternalDb = false;
      // 重新绑定后可能有库了：退出 JSON 顶首页，回库路。
      _jsonTopMode = false;
      _jsonWorksPerson = null;
      // 2026-11-24 标签筛选：重新绑定可能换了库文件，旧标签作废。
      _videoTag = '';
      _genericTag = '';
      _dbTagsCacheKey = null;
      _dbTagsCache = null;
    });
    if (_ownsFallback) {
      _fallback.bindLocalDirs(
        jsonDir: bind.jsonDir,
        userM3uDir: bind.bound ? bind.m3uDir : null,
      );
    }
    await _reloadLibrary();
  }

  /// 手动“重新加载数据库”（2026-11-20 热换库）：不管文件指纹变
  /// 没变都重读一次当前文件（重解析绑定：新放进 MYTV/db 的
  /// 女优库.db 只有重解析才看得到）。重读后重新探结构（不要沿用
  /// 旧映射）：模式可能变了（女优库 ↔ 外来库），按新模式重读列表。
  /// 重读失败留旧库并报原因，不崩、不丢数据；没有外置库时报
  /// “未找到外置数据库”，不说“仍用旧库”（没有旧库可留）。
  Future<void> _manualReloadDb() async {
    if (_reloadingDb) return;
    _reloadingDb = true;
    try {
      final result = await _db.reloadIfChanged(force: true);
      if (!mounted) return;
      if (result.error != null) {
        final noDb = result.error!.startsWith('未找到外置数据库');
        setState(() {
          _mytvDbError = result.error;
          _noExternalDb = noDb;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          SnackBar(content: Text(actressReloadErrorText(result.error!))),
        );
        return;
      }
      // 重读成功：从单例重取绑定，显示行与实际落点一致；
      // 之前没库、现在放进来了，空态也清掉。库文件可能换了，
      // 旧缓存作废（下面非通用分支走 _reloadLibrary 也会清，
      // 通用分支不走那里，这里先清一次）。
      _clearListCaches();
      setState(() {
        _mytvDbError = null;
        _noExternalDb = false;
        // 库放进来了：退出 JSON 顶首页，回库路。
        _jsonTopMode = false;
        _jsonWorksPerson = null;
        _mytvBind = ActressMytvBind.instance.current ?? _mytvBind;
        // 2026-11-24 标签筛选：重读可能换了库文件，旧标签作废。
        _videoTag = '';
        _genericTag = '';
      });
      final generic = await _db.genericReader();
      if (!mounted) return;
      setState(() {
        _genericReader = generic;
        _genericMode = generic != null;
        // 重读可能换了库：旧分类作废，先清掉再按新库重读。
        _genericCategory = '';
        _genericCategories = [];
        _genericCategoriesLoaded = false;
      });
      if (_genericMode) {
        await _loadGenericCategories();
        await _loadPage(reset: true);
      } else {
        await _reloadLibrary();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.reloaded ? '已重新加载数据库' : '数据库没有变化')),
      );
    } finally {
      _reloadingDb = false;
    }
  }

  /// 手动刷新/重载后的统一收尾：清全部易变缓存（页内第一页 +
  /// NvkuEntryCache 含名单槽），带守卫重读总览与名单第一页。
  /// 顶栏刷新钮、重新绑定、手动重载数据库都走这里（2026-11-26
  /// 只读化后取代原 _refreshAfterSync：不再有“同步写了库”一说，
  /// 刷新就是重读当前库文件）。
  Future<void> _reloadLibrary() async {
    _clearListCaches();
    await _refreshOverviewQuietly();
    if (!mounted) return;
    await _loadPage(reset: true);
    if (!mounted) return;
  }

  void _onScroll() {
    // 2026-11-24：刷新中也不触底加载（_refreshing 时 _loading 为假，
    // 不加这道会在切换时误起翻页，代次守卫把它丢掉后 _loadingMore
    // 还可能卡住）。
    if (_loadingMore || !_hasMore || _loading || _refreshing) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      unawaited(_loadPage());
    }
  }

  /// 当前生效的搜索输入框：宿主给了就用宿主的（只有一条搜索框，
  /// 不会出现两个输入框各搜各的）。
  TextEditingController get _activeSearchController =>
      widget.externalSearch ?? _searchController;

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      final query = _activeSearchController.text.trim();
      if (query == _query) return;
      _saveScrollOffsetForCache();
      setState(() => _query = query);
      _reloadAfterFilterChange();
    });
  }

  /// 站源注册表变了（新站导入/站点摘掉/隐藏/显隐切换）：
  /// 选项集合没变就不动（store 的其他通知不触发重建）；选项
  /// 变了才重建顶栏——当前选中的站已不在选项里时回“全部”并
  /// 重读列表（否则列表会一直按一个已不存在的站过滤，只显示
  /// “该站暂无匹配人物”）；新站进来时菜单下次打开即有它
  /// （itemBuilder 每次打开都现算，不用等重建）。
  void _onStoreChanged() {
    if (!mounted) return;
    final options = _siteFilterOptions();
    final ids = options.map((o) => o.siteId).toSet();
    if (ids.length == _siteOptionIds.length &&
        ids.containsAll(_siteOptionIds)) {
      return;
    }
    _siteOptionIds = ids;
    if (_source != ActressSiteFilter.all && !ids.contains(_source.siteId)) {
      setState(() => _source = ActressSiteFilter.all);
      unawaited(_loadPage(reset: true));
      return;
    }
    setState(() {});
  }

  /// 站点筛选下拉选项：全部 + mjv + whos + 片库全部可见视频站
  /// （与叠加搜索 actressSearchSiteIds 同一口径：store.visibleSources
  /// 里 isVideoSection、非 cloud:、siteVisible 的站；跳过 mjv/whos/
  /// chaoliu——chaoliu 即 mjv，已有 mjv 项代表它；yikm 这类游戏站
  /// 不在视频区登记里，进不了选项）。
  List<ActressSiteFilter> _siteFilterOptions() =>
      actressSiteFilterOptions(widget.store);

  /// 切换站点筛选：只重读列表与分类。2026-11-23 用户令：女优库不要
  /// 全自动同步检查——切站不再自动现爬，想爬去设置页“任意站点爬取”
  /// 粘地址手动爬（2026-11-24 选站现爬已删）。
  void _setSiteFilter(ActressSiteFilter source) {
    if (source == _source) return;
    _saveScrollOffsetForCache();
    setState(() {
      _source = source;
      _siteWorks = [];
      _siteWorksPage = 1;
      _siteWorksCategory = '';
    });
    if (source.siteId == nvkuSourceId) {
      unawaited(_loadSiteCategories(source.siteId));
    }
    _reloadAfterFilterChange();
  }

  /// 站点自己的分类（nvku：最新/有码/无码/4K/其它，条数在名字里）。
  Future<void> _loadSiteCategories(String sourceId) async {
    try {
      final rows = await widget.repository.categories(sourceId);
      if (!mounted || _source.siteId != sourceId) return;
      setState(() {
        _siteCategories = rows;
        if (_siteWorksCategory.isEmpty && rows.isNotEmpty) {
          _siteWorksCategory = rows.first.id;
        }
      });
      if (_siteWorks.isEmpty) unawaited(_loadPage(reset: true));
    } catch (_) {
      // 站点暂时连不上：不阻塞页面，作品列表自己会走兜底/提示。
    }
  }

  /// 只出作品的站点分页：走站点蜘蛛的分类目录（封面/番号/播放地址
  /// 都是站点给的），失败时退到本地库兜底，不留白屏。
  Future<void> _loadSiteWorks({bool reset = false}) async {
    if (reset) {
      final generation = ++_generation;
      // 2026-11-24 切换不重载：同主列表，旧作品留着当底、只置细进度条。
      final keepOld = _siteWorks.isNotEmpty;
      setState(() {
        if (keepOld) {
          _refreshing = true;
        } else {
          _loading = true;
        }
        _loadingMore = false;
        _hasMore = true;
        _loadError = null;
      });
      try {
        final page = await widget.repository
            .catalog(
              nvkuSourceId,
              page: 1,
              query: _query,
              category: _siteWorksCategory,
            )
            .timeout(_firstTimeout);
        if (!mounted || generation != _generation) return;
        setState(() {
          _siteWorks = page.items;
          _siteWorksPage = 2;
          _hasMore = page.hasMore;
          _loading = false;
          _refreshing = false;
        });
      } catch (e) {
        _failLoad(generation, e);
      }
      return;
    }
    if (_loadingMore || !_hasMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.repository
          .catalog(
            nvkuSourceId,
            page: _siteWorksPage,
            query: _query,
            category: _siteWorksCategory,
          )
          .timeout(_nextTimeout);
      if (!mounted || generation != _generation) return;
      setState(() {
        _siteWorks = [..._siteWorks, ...page.items];
        _siteWorksPage += 1;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (e) {
      _failLoad(generation, e);
    }
  }

  void _setSiteWorksCategory(String id) {
    if (_siteWorksCategory == id) return;
    setState(() => _siteWorksCategory = id);
    unawaited(_loadPage(reset: true));
  }

  /// 站点作品点卡：取一次详情（一集正片）直接进播放器。
  Future<void> _playSiteWork(Drama drama) async {
    try {
      final detail = await widget.repository.detail(drama);
      if (!mounted) return;
      if (detail.episodes.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('这条没有可播地址')));
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
    if (mounted) setState(() {});
  }

  GenericDbWork _siteWorkCard(Drama drama) => GenericDbWork(
    id: drama.id,
    title: drama.title,
    coverUrl: drama.cover,
    playUrl: 'nvku://${drama.id}',
    code: drama.tags.isNotEmpty ? drama.tags.first : '',
    actress: '',
    date: drama.onlineDate,
  );

  Future<Set<String>> _codeKeysFor(ActressPerson person) async {
    final cached = _siteCodeKeys[person.localId];
    if (cached != null) return cached;
    final works = await _db.worksForPerson(
      person.localId,
      offset: 0,
      limit: 500,
    );
    final keys = {
      for (final work in works)
        if (work.codeKey.isNotEmpty) work.codeKey,
    };
    _siteCodeKeys[person.localId] = keys;
    return keys;
  }

  /// 站点过滤：只留该站有 JSON 兜底条目的人（按女优名或本地作品番号对）。
  /// 全部时不过滤。过滤后页内人数可能少于 60，翻页偏移另用 _rawOffset。
  Future<List<ActressPerson>> _applySiteFilter(
    List<ActressPerson> persons,
  ) async {
    if (_source == ActressSiteFilter.all) return persons;
    if (!_fallback.loaded) await _fallback.load();
    final kept = <ActressPerson>[];
    for (final person in persons) {
      final codeKeys = await _codeKeysFor(person);
      if (await _fallback.hasSiteEntriesForPersonAsync(
        names: [person.displayName, ...person.aliases],
        codeKeys: codeKeys,
        site: _source.siteId,
      )) {
        kept.add(person);
      }
    }
    return kept;
  }

  /// 名单加载失败收尾（三条路共用）：代次没被顶掉才动界面——
  /// 名单为空出失败态 + 重试；已有旧名单时保留旧名单、只报一句。
  /// 无论哪种，全部 loading 标志必清（永转圈绝迹的最后一道）。
  void _failLoad(int generation, Object error) {
    if (!mounted || generation != _generation) return;
    final message =
        '名单读不出来：${error.toString().split('\n').first}';
    setState(() {
      _loading = false;
      _refreshing = false;
      _loadingMore = false;
      if (_persons.isEmpty && _genericWorks.isEmpty && _siteWorks.isEmpty) {
        _loadError = message;
      }
    });
    if (_persons.isNotEmpty || _genericWorks.isNotEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('刷新失败，显示的是上次的名单')));
    }
  }

  Future<void> _loadPage({bool reset = false}) async {
    // 无库 JSON 顶首页：名单/作品都走内置索引，不碰数据库。
    if (_jsonTopMode) {
      await _loadJsonTopPage(reset: reset);
      return;
    }
    // 只有作品的站源（nvku）：作品网格 + 站点分类翻页。
    if (_siteWorksMode) {
      await _loadSiteWorks(reset: reset);
      return;
    }
    // 2026-11-20 通用读库：外来库走通用作品翻页（标题/番号 LIKE 搜）。
    if (_genericMode) {
      await _loadGenericPage(reset: reset);
      return;
    }
    if (reset) {
      final generation = ++_generation;
      // 2026-11-24 切换不重载：列表非空时是筛选切换，旧列表留着当底，
      // 只置细进度条（_refreshing），不清列表、不转大圈，滚动位置
      // 天然保住；首屏第一次加载（列表空）才走大转圈。_hasMore 在
      // 结果回来后再按新结果置；_loadingMore 一并清掉（重置使在途
      // 的翻页失效，不清会卡住触底加载）。
      final keepOld = _persons.isNotEmpty;
      setState(() {
        if (keepOld) {
          _refreshing = true;
        } else {
          _loading = true;
        }
        _loadingMore = false;
        _hasMore = true;
        _loadError = null;
      });
      _rawOffset = 0;
      try {
        // 2026-11-23 多库勾选：勾了外来库时按人名归并查（每库各取一个
        // 窗口再合并，见 _loadMergedPersons）；只勾主库走老路。
        if (_hasExtraDbs) {
          final merged = await _loadMergedPersons(offset: 0, limit: _pageSize)
              .timeout(_firstTimeout);
          final persons = await _applySiteFilter(merged);
          if (!mounted || generation != _generation) return;
          setState(() {
            _persons = persons;
            _hasMore = _mergedHasMore;
            _loading = false;
            _refreshing = false;
          });
          _storePageCache(persons, _mergedHasMore, _rawOffset);
          _storeNvkuPersons(persons, _mergedHasMore, _rawOffset);
          return;
        }
        final raw = await _db
            .listPersons(
              sex: _sex,
              sort: _sort,
              query: _query,
              tag: _tagFilter.tagValue,
              videoTag: _videoTag,
              offset: 0,
              limit: _pageSize,
            )
            .timeout(_firstTimeout);
        _rawOffset = raw.length;
        final persons = await _applySiteFilter(raw);
        if (!mounted || generation != _generation) return;
        setState(() {
          _persons = persons;
          _hasMore = raw.length >= _pageSize;
          _loading = false;
          _refreshing = false;
        });
        _storePageCache(persons, raw.length >= _pageSize, _rawOffset);
        _storeNvkuPersons(persons, raw.length >= _pageSize, _rawOffset);
      } catch (e) {
        _failLoad(generation, e);
      }
      return;
    }
    if (_loadingMore || !_hasMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      if (_hasExtraDbs) {
        final merged = await _loadMergedPersons(
          offset: _persons.length,
          limit: _pageSize,
        ).timeout(_nextTimeout);
        final persons = await _applySiteFilter(merged);
        if (!mounted || generation != _generation) return;
        setState(() {
          _persons = [..._persons, ...persons];
          _hasMore = _mergedHasMore;
          _loadingMore = false;
        });
        return;
      }
      final raw = await _db
          .listPersons(
            sex: _sex,
            sort: _sort,
            query: _query,
            tag: _tagFilter.tagValue,
            videoTag: _videoTag,
            offset: _rawOffset,
            limit: _pageSize,
          )
          .timeout(_nextTimeout);
      _rawOffset += raw.length;
      final persons = await _applySiteFilter(raw);
      if (!mounted || generation != _generation) return;
      setState(() {
        _persons = [..._persons, ...persons];
        _hasMore = raw.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (e) {
      _failLoad(generation, e);
    }
  }

  /// 第一页缓存的 key：筛选条件的全部维度 + 已勾选库路径（排好序）。
  /// 任一维度变了就是另一个 key；数据库勾选变化时库路径段变了，
  /// 旧 key 自然失效。只用于主模式（通用/站源模式各有自己的列表，
  /// 不走这份缓存）。
  String _pageCacheKey() {
    final dbs = _extraDbs.keys.toList()..sort();
    return [
      _sex.name,
      _videoTag,
      _tagFilter.name,
      _sort.name,
      _query,
      _source.siteId,
      ...dbs,
    ].join('|');
  }

  /// 把刚查回的第一页写进缓存（key 是当前筛选条件）。超过上限时
  /// 淘汰最久没用的 key（LinkedHashMap 按插入顺序，keys.first 是
  /// 最旧的）。只在 reset 分支的结果回来后调；代次守卫已保证
  /// 结果与当前筛选一致，key 不会写错。rawOffset 是缓存这页对
  /// 应的原始偏移（翻页用）：只存第一页时就是第一页的人数，
  /// 不能拿已加载的总页数来存，否则恢复后翻页会跳页。
  void _storePageCache(
    List<ActressPerson> persons,
    bool hasMore,
    int rawOffset,
  ) {
    final key = _pageCacheKey();
    _pageCache.remove(key);
    _pageCache[key] = _CachedListPage(persons, hasMore, rawOffset);
    while (_pageCache.length > _pageCacheMaxKeys) {
      _pageCache.remove(_pageCache.keys.first);
    }
  }

  /// 切换前把当前滚动偏移存进当前 key 的缓存项（有缓存项才存）。
  /// 只用于主模式（通用/站源模式不走这份缓存）。Nvku 名单槽里的
  /// 同一份第一页也同步存偏移，页面重建后 bootstrap 能恢复位置。
  void _saveScrollOffsetForCache() {
    if (_genericMode || _siteWorksMode) return;
    if (!_scrollController.hasClients) return;
    final cached = _pageCache[_pageCacheKey()];
    if (cached != null) {
      cached.scrollOffset = _scrollController.offset;
    }
    final slot = NvkuEntryCache.personsFirstPage(
      _personsCacheKey(_mytvBind?.dbPath ?? ''),
    );
    if (slot != null) {
      slot.scrollOffset = _scrollController.offset;
    }
  }

  /// 筛选值已变后的统一收尾（主模式）：先查缓存，命中直接恢复，
  /// 未命中走 _loadPage(reset: true) 查库。通用/站源模式不走缓存，
  /// 直接查库。
  void _reloadAfterFilterChange() {
    if (!_genericMode && !_siteWorksMode && _restorePageFromCache()) return;
    unawaited(_loadPage(reset: true));
  }

  /// 筛选切换时先查缓存：命中就直接恢复列表 + 滚动偏移，不碰数据库；
  /// 返回 true 表示已恢复、调用方不用再调 _loadPage。只用于主模式。
  /// 页内缓存没有再查 NvkuEntryCache 名单槽（页面 State 还在、
  /// 但筛选 key 是第一次切到的组合时，槽里可能有进页时存的那份）；
  /// 槽里那份过期了先上屏、再后台刷新一次。
  bool _restorePageFromCache() {
    final key = _pageCacheKey();
    final cached = _pageCache[key];
    if (cached == null) {
      final slot = NvkuEntryCache.personsFirstPage(
        _personsCacheKey(_mytvBind?.dbPath ?? ''),
      );
      if (slot == null) return false;
      final generation = ++_generation;
      setState(() {
        _persons = slot.persons;
        _hasMore = slot.hasMore;
        _rawOffset = slot.rawOffset;
        _loading = false;
        _refreshing = false;
        _loadingMore = false;
      });
      _restoreScrollOffset(slot.scrollOffset, generation);
      if (!slot.isFresh) unawaited(_loadPage(reset: true));
      return true;
    }
    final generation = ++_generation;
    setState(() {
      _persons = cached.persons;
      _hasMore = cached.hasMore;
      _rawOffset = cached.rawOffset;
      _loading = false;
      _refreshing = false;
      _loadingMore = false;
    });
    // 恢复滚动偏移：等网格布局完再跳（post-frame），偏移越界时钳制。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      final target = cached.scrollOffset.clamp(0.0, max).toDouble();
      if (target > 0) _scrollController.jumpTo(target);
    });
    return true;
  }

  /// 清掉全部易变缓存（列表第一页 + 分类 + 标签）：库内容变了就调——热换库、
  /// 手动刷新/重载。漏清会显示旧数据。只清缓存，不清
  /// 已选的标签（同库内容更新，标签筛选本身还有效）。
  /// 进库会话缓存（NvkuEntryCache，含 2026-11-26 新增的名单槽）
  /// 也在这里一起清：手动重读/刷新时，首页的进库缓存跟着作废，
  /// 下次进库重查。
  void _clearListCaches() {
    _pageCache.clear();
    _dbTagsCacheKey = null;
    _dbTagsCache = null;
    NvkuEntryCache.clear();
  }

  /// 通用模式的标签筛选条件（2026-11-24 标签筛选）：空 = 不筛；
  /// 否则按 tagFacet 给的键筛（`video_tag.tag_name` 或作品表标签列）。
  Map<String, List<String>> get _genericTagFilters =>
      _genericTag.isEmpty || _genericTagKey.isEmpty
      ? const {}
      : {_genericTagKey: [_genericTag]};

  /// 通用模式翻页：作品表按 rowid 顺序翻页，搜索走标题/番号 LIKE。
  Future<void> _loadGenericPage({bool reset = false}) async {
    final reader = _genericReader;
    if (reader == null) return;
    if (reset) {
      final generation = ++_generation;
      // 2026-11-24 切换不重载：同主列表，旧作品留着当底、只置细进度条。
      final keepOld = _genericWorks.isNotEmpty;
      setState(() {
        if (keepOld) {
          _refreshing = true;
        } else {
          _loading = true;
        }
        _loadingMore = false;
        _hasMore = true;
        _loadError = null;
      });
      try {
        final total = await reader
            .countWorks(
              query: _query,
              category: _genericCategory,
              filters: _genericTagFilters,
            )
            .timeout(_firstTimeout);
        final works = await reader
            .works(
              offset: 0,
              limit: _pageSize,
              query: _query,
              category: _genericCategory,
              filters: _genericTagFilters,
            )
            .timeout(_firstTimeout);
        if (!mounted || generation != _generation) return;
        setState(() {
          _genericWorks = works;
          _genericTotal = total;
          _hasMore = works.length >= _pageSize;
          _loading = false;
          _refreshing = false;
        });
      } catch (e) {
        _failLoad(generation, e);
      }
      return;
    }
    if (_loadingMore || !_hasMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final works = await reader
          .works(
            offset: _genericWorks.length,
            limit: _pageSize,
            query: _query,
            category: _genericCategory,
            filters: _genericTagFilters,
          )
          .timeout(_nextTimeout);
      if (!mounted || generation != _generation) return;
      setState(() {
        _genericWorks = [..._genericWorks, ...works];
        _hasMore = works.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (e) {
      _failLoad(generation, e);
    }
  }

  /// 无库时 JSON 顶首页入口（2026-11-26 用户令）：内置 who's
  /// 索引非空才进本模式；索引也空就落回真空态（_noExternalDb 的
  /// 放库提示）。顶栏计数用索引的演员数/视频数合成，不查库。
  Future<void> _enterJsonTopMode() async {
    WhosJsonIndex index;
    try {
      index = await WhosJsonIndex.instance;
    } catch (_) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (!mounted) return;
    if (index.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _jsonTopMode = true;
      _jsonIndex = index;
      _overview = ActressSyncOverview(
        persons: index.actorCount,
        personsWithWorks: index.actorCount,
        works: index.videoCount,
        sources: const {},
        lastUpdatedAt: 0,
      );
    });
    await _loadJsonTopPage(reset: true);
  }

  /// JSON 顶首页的名单分页：纯内存切片（数据全在索引里），没有
  /// IO 失败面，仍按统一口径包守卫，出错走 _failLoad。
  Future<void> _loadJsonTopPage({bool reset = false}) async {
    final index = _jsonIndex;
    if (index == null) return;
    // 作品模式（点了某个人）下名单翻页不适用：作品一次全给。
    if (_jsonWorksPerson != null) return;
    if (reset) {
      final generation = ++_generation;
      final keepOld = _persons.isNotEmpty;
      setState(() {
        if (keepOld) {
          _refreshing = true;
        } else {
          _loading = true;
        }
        _loadingMore = false;
        _loadError = null;
      });
      try {
        final filtered = _jsonFilteredActors(index);
        if (!mounted || generation != _generation) return;
        setState(() {
          _persons = filtered.take(_pageSize).toList();
          _hasMore = filtered.length > _pageSize;
          _rawOffset = _persons.length;
          _loading = false;
          _refreshing = false;
        });
      } catch (e) {
        _failLoad(generation, e);
      }
      return;
    }
    if (_loadingMore || !_hasMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final filtered = _jsonFilteredActors(index);
      if (!mounted || generation != _generation) return;
      final start = _rawOffset;
      final end = (start + _pageSize).clamp(0, filtered.length);
      setState(() {
        _persons = [..._persons, ...filtered.sublist(start, end)];
        _rawOffset = end;
        _hasMore = end < filtered.length;
        _loadingMore = false;
      });
    } catch (e) {
      _failLoad(generation, e);
    }
  }

  /// JSON 名单过滤：只有名字搜索与作品数/名字排序是 JSON 撑得起
  /// 的维度。男优（JSON 只有女优）、视频分类（三册）、作品标签
  /// 任一非默认 → 整表置空并亮专门文案（_jsonFilterUnsupported），
  /// 不假装“暂无人物”。recentDesc 没有日期数据，回落作品数序。
  List<ActressPerson> _jsonFilteredActors(WhosJsonIndex index) {
    final unsupported = _sex == ActressSexFilter.male ||
        _tagFilter != ActressTagFilter.all ||
        _videoTag.isNotEmpty;
    _jsonFilterUnsupported = unsupported;
    if (unsupported) return const [];
    var rows = index.actorsByWorks();
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      rows = [
        for (final r in rows)
          if (r.name.toLowerCase().contains(q)) r,
      ];
    }
    if (_sort == ActressSort.nameAsc) {
      rows = [...rows]..sort((a, b) => a.name.compareTo(b.name));
    }
    return [
      for (final r in rows)
        ActressPerson(
          displayName: r.name,
          sex: 'female',
          worksCount: r.works,
          exactWorks: r.works,
          fromWhos: true,
        ),
    ];
  }

  /// JSON 名单点人：页内切成她的作品网格（番号→视频行现取，
  /// 索引里没有视频行的番号不摆卡）。
  void _openJsonPerson(ActressPerson person) {
    final index = _jsonIndex;
    if (index == null) return;
    final works = <GenericDbWork>[];
    for (final code in index.codesForActor(person.displayName)) {
      final video = index.videoForCode(code);
      if (video == null) continue;
      works.add(
        GenericDbWork(
          id: video.code,
          title: video.title.isNotEmpty ? video.title : video.code,
          coverUrl: video.pic,
          playUrl: video.m3u8,
          code: video.code,
          actress: person.displayName,
          date: '',
        ),
      );
    }
    setState(() {
      _jsonWorksPerson = person.displayName;
      _jsonWorks = works;
    });
  }

  /// JSON 作品点卡播放：who's m3u8 直链（direct），走现成
  /// ActressJsonEntry.toDramaDetail 口径，不查库、不现爬。
  Future<void> _playJsonWork(GenericDbWork work) async {
    if (work.playUrl.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这条没有可播地址')));
      return;
    }
    final entry = ActressJsonEntry(
      site: 'whos',
      vodId: work.code,
      vodName: work.title,
      vodPic: work.coverUrl,
      vodActor: work.actress,
      vodDirector: '',
      vodRemarks: '',
      vodPubdate: work.date,
      vodArea: '',
      vodYear: '',
      vodContent: '',
      vodPlayFrom: 'whos',
      vodPlayUrl: work.playUrl,
      typeName: '日本AV',
      vodCode: work.code,
      vodActressPic: '',
      directPlay: true,
    );
    await pushPlayer<void>(
      context,
      detail: entry.toDramaDetail(),
      initialIndex: 0,
      repository: widget.repository,
      store: widget.store,
    );
    if (mounted) setState(() {});
  }

  /// JSON 顶首页的作品网格：返回钮回名单，卡片与通用模式同款。
  Widget _buildJsonWorksList(ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 12, 2),
          child: Row(
            children: [
              IconButton(
                key: const ValueKey('json-top-back'),
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回名单',
                onPressed: () => setState(() {
                  _jsonWorksPerson = null;
                  _jsonWorks = [];
                }),
              ),
              Expanded(
                child: Text(
                  '$_jsonWorksPerson · ${_jsonWorks.length} 部',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _jsonWorks.isEmpty
              ? Center(
                  child: Text(
                    '暂无作品',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                )
              : GridView.builder(
                  key: const ValueKey('actress-json-work-grid'),
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 160,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.58,
                      ),
                  itemCount: _jsonWorks.length,
                  itemBuilder: (context, index) {
                    final work = _jsonWorks[index];
                    return _GenericWorkCard(
                      key: ValueKey('json-work-${work.code}'),
                      work: work,
                      onTap: () => _playJsonWork(work),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 通用作品点按直播：转成兜底条目走现有播放链（站走 chaoliu
  /// 原始地址直通，parse=0），地址是播之前刚从当前库里取出来的，
  /// 不播缓存的旧地址；没有可播地址就提示，不硬播。
  Future<void> _playGenericWork(GenericDbWork work) async {
    final entry = work.toJsonEntry();
    if (!entry.playable) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这条没有可播地址')));
      return;
    }
    await pushPlayer<void>(
      context,
      detail: entry.toDramaDetail(),
      initialIndex: 0,
      repository: widget.repository,
      store: widget.store,
    );
    if (mounted) setState(() {});
  }

  /// 打开“数据库字段”页：映射改了就按新映射重读列表。
  Future<void> _openFieldsPage() async {
    final reader = _genericReader;
    if (reader == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ActressDbFieldsPage(reader: reader)),
    );
    if (changed != true || !mounted) return;
    await _loadPage(reset: true);
  }

  void _openPerson(ActressPerson person) {
    // 无库 JSON 顶首页：点人不进库详情页，页内切她的作品网格。
    if (_jsonTopMode) {
      _openJsonPerson(person);
      return;
    }
    // 2026-11-23 多库勾选：合并列表里的人按所在库进详情（主库优先，
    // 主库没有这个人才指外来库）；单库时 _personHomeDb 为空，走主库。
    // 2026-11-24 标签筛选：列表页选了标签时，详情页的作品列表也只
    // 留带该标签的作品（initialTag 传进去）。
    final homeDb = _personHomeDb[person.displayName] ?? _db;
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ActressDetailPage(
          localId: person.localId,
          repository: widget.repository,
          store: widget.store,
          database: homeDb,
          siteFilter: _source,
          initialTag: _videoTag,
          fallback: _fallback,
        ),
      ),
    );
  }

  void _openRanking() {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ActressRankingPage(
          repository: widget.repository,
          store: widget.store,
          database: _db,
        ),
      ),
    );
  }

  /// 设置弹窗（2026-11-21 用户令设，2026-11-26 只读化改版）：
  /// 同步/叠加/现爬/镜像整窗已删，只剩“数据库”一节（路径、错误、
  /// 重新加载数据库）与多库勾选——都是读功能。
  Future<void> _openSettingsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      builder: (_) => _ActressSettingsSheet(host: this),
    );
  }

  /// 演员筛选条（全部 / 女优 / 男优 + 排序）。
  /// 2026-11-22 用户令：这一排放页面最顶部，紧跟工具栏，演员列表
  /// 直接接在它下面。三枚 chips 照活树改版换成霓虹药丸钮。
  Widget _buildSexFilterRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Row(
        children: [
          ActressNeonPill(
            key: const ValueKey('actress-sex-all'),
            label: '全部',
            selected: _sex == ActressSexFilter.all,
            onTap: () => _setSex(ActressSexFilter.all),
          ),
          const SizedBox(width: 8),
          ActressNeonPill(
            key: const ValueKey('actress-sex-female'),
            label: '女优',
            selected: _sex == ActressSexFilter.female,
            onTap: () => _setSex(ActressSexFilter.female),
          ),
          const SizedBox(width: 8),
          ActressNeonPill(
            key: const ValueKey('actress-sex-male'),
            label: '男优',
            selected: _sex == ActressSexFilter.male,
            onTap: () => _setSex(ActressSexFilter.male),
          ),
          const Spacer(),
          PopupMenuButton<ActressSort>(
            key: const ValueKey('actress-sort-menu'),
            tooltip: '排序',
            initialValue: _sort,
            onSelected: (sort) {
              if (sort == _sort) return;
              _saveScrollOffsetForCache();
              setState(() => _sort = sort);
              _reloadAfterFilterChange();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: ActressSort.worksDesc,
                child: Text('按作品数'),
              ),
              PopupMenuItem(
                value: ActressSort.nameAsc,
                child: Text('按名字'),
              ),
              PopupMenuItem(
                value: ActressSort.recentDesc,
                child: Text('最近更新'),
              ),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.sort_rounded, size: 18),
                const SizedBox(width: 4),
                Text(_sort.label),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final overview = _overview;
    return Scaffold(
      // 2026-11-21 用户令：内嵌进女优库区域时宿主已有自己的顶栏，
      // 这里再渲染一个 AppBar 就是两条栏叠在一起（搜索框看着像压住了顶栏）。
      // 内嵌时改由 _buildEmbeddedToolbar 提供一条置顶工具栏。
      // 顶栏照活树改版走霓虹 AppBar（actressNeonAppBar）。
      appBar: !widget.showTitle
          ? null
          : actressNeonAppBar(
        toolbarHeight: 40,
        title: _genericMode
            ? const Text('演员库 · 外来数据库')
            : widget.showTitle
            ? Text(
                overview == null
                    ? '演员库'
                    // 头顶人数只算有入库作品的人（2026-11-20 用户令：
                    // 要入库才算），只有名册、还没入库作品的人不算。
                    : '演员库 ${overview.personsWithWorks} 位演员',
              )
            : overview == null
            ? null
            : Text('${overview.personsWithWorks} 位演员'),
        actions: _toolbarActions(),
      ),
      body: Column(
        children: [
          if (!widget.showTitle) _buildEmbeddedToolbar(colors),
          // 2026-11-22 用户令「把演员那一栏所有全部放最顶部」：全部/
          // 女优/男优 + 排序这一排提到最顶，紧跟工具栏；原先它压在
          // 绑定行、库瓦片、搜索框下面，要往下翻才够得着。
          _buildSexFilterRow(),
          // 数据库绑定行与外来库行属于库信息，留在页面顶部；
          // ⚙️ 设置弹窗只剩数据库一节（2026-11-26 只读化）。
          _buildMytvBindRow(colors),
          _buildGenericModeRow(colors),
          if (widget.showTitle)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
              child: _buildSearchField(),
            ),
          // 2026-11-24 第二排就是视频分类：三册全部/有码/无码/欧美/
          // 国产/4K/动漫/三级/其他，值取自数据库 video_category
          // 主分类（见 ActressTagFilter），接在欧美后面同一排平铺；
          // 9 个胶囊排不下就横向滑，不另起一排。
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final filter in ActressTagFilter.values) ...[
                    ChoiceChip(
                      label: Text(filter.label),
                      selected: _tagFilter == filter,
                      onSelected: (_) => _setTagFilter(filter),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ),
          // 通用模式分类（2026-11-22：外来库视频列表页顶部的分类行，
          // 照活树改版）：从当前库自身的 video_category 表取分类
          // （见 GenericDbReader.categories），点分类只筛当前这个
          // 库的视频；库里没有分类表 / 分类为空时如实显示“暂无分类”，
          // 不编。样式照本页分类行（霓虹药丸钮）。
          if (_genericMode && _genericCategoriesLoaded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: _genericCategories.isEmpty
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '暂无分类',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    )
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          ActressNeonPill(
                            key: const ValueKey(
                              'actress-generic-category-all',
                            ),
                            label: '全部',
                            selected: _genericCategory.isEmpty,
                            onTap: () => _setGenericCategory(''),
                          ),
                          const SizedBox(width: 8),
                          for (final category in _genericCategories) ...[
                            ActressNeonPill(
                              key: ValueKey(
                                'actress-generic-category-${category.$1}',
                              ),
                              label: '${category.$1}（${category.$2}）',
                              selected: _genericCategory == category.$1,
                              onTap: () =>
                                  _setGenericCategory(category.$1),
                            ),
                            const SizedBox(width: 8),
                          ],
                        ],
                      ),
                    ),
            ),
          // 2026-11-24 标签筛选：分类行下面独立一行放“标签”入口，
          // 不依赖分类行——库没有分类时入口也在；没选时只显示“标签”，
          // 选了显示“标签：<名>”高亮 + “清除”一键清掉。站源作品
          // 模式（nvku 作品网格）不走数据库筛选，不显示。
          if (!_siteWorksMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Row(
                children: _buildTagPills(
                  selected: _genericMode ? _genericTag : _videoTag,
                  onOpen: _openTagSheet,
                  onClear: _genericMode
                      ? () => _setGenericTag('')
                      : () => _setVideoTag(''),
                ),
              ),
            ),
          if (_siteWorksMode && _siteCategories.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final category in _siteCategories) ...[
                      ActressNeonPill(
                        key: ValueKey('site-category-${category.id}'),
                        label: category.name,
                        selected: _siteWorksCategory == category.id,
                        onTap: () =>
                            _setSiteWorksCategory(category.id),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                _buildList(colors),
                // 2026-11-24 切换不重载：筛选切换时旧列表留着当底，
                // 只在列表顶露一条细进度条（_refreshing）。
                if (_refreshing)
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }


  /// 顶栏动作：站点筛选 / 排行榜 / 刷新 / 设置。
  /// 抽出来是为了外层 AppBar 和内嵌时的置顶工具栏共用一份，
  /// 不出现「内嵌进女优库区域后这几个按钮消失」的问题。
  List<Widget> _toolbarActions() {
    return [            if (!_genericMode)
              PopupMenuButton<ActressSiteFilter>(
                key: const ValueKey('actress-site-filter'),
                tooltip: '站点筛选',
                initialValue: _source,
                onSelected: _setSiteFilter,
                itemBuilder: (_) => [
                  for (final filter in _siteFilterOptions())
                    PopupMenuItem(value: filter, child: Text(filter.label)),
                ],
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.public_outlined, size: 18),
                    const SizedBox(width: 2),
                    Text(_source.label),
                  ],
                ),
              ),
            if (!_genericMode)
              IconButton(
                key: const ValueKey('open-actress-ranking'),
                tooltip: '演员排行榜',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.emoji_events_outlined),
                onPressed: _openRanking,
              ),
            IconButton(
              key: const ValueKey('refresh-actress-library'),
              // 2026-11-20 热换库：通用模式下刷新按钮就是手动重载数据库；
              // 2026-11-26 只读化：普通模式下是重读当前库（清缓存重查），
              // 不再有“刷新同步”。
              tooltip: _genericMode ? '重新加载数据库' : '刷新',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _genericMode
                  ? _manualReloadDb
                  : () => unawaited(_reloadLibrary()),
            ),
            // 2026-11-21 用户令：右上角“影视库”按钮没用，删掉。
            // 设置齿轮（2026-11-21 用户令设，2026-11-26 只读化改版）：
            // 弹窗只剩数据库一节（路径/重新加载/多库勾选）。
            IconButton(
              key: const ValueKey('open-actress-settings'),
              tooltip: '设置',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.settings_outlined),
              onPressed: _openSettingsSheet,
            ),
    ];
  }

  /// 搜索框本体（外层顶栏下方和内嵌工具栏里共用同一份）。
  Widget _buildSearchField() {
    return TextField(
      key: const ValueKey('actress-search'),
      controller: _searchController,
      decoration: InputDecoration(
        hintText: _genericMode
            ? '搜标题或番号'
            : '搜名字或番号：中文 / 日文 / SSIS-123 都行',
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                tooltip: '清除搜索',
                icon: const Icon(Icons.clear_rounded),
                onPressed: () => _searchController.clear(),
              ),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  /// 内嵌进女优库区域时的置顶工具栏：人数 + 动作按钮同一行，
  /// 固定在列表上方不随滚动移动（2026-11-21 用户令）。
  /// 宿主传了外部搜索框时（女优库 nvku 外壳），搜索框只在宿主顶栏
  /// 留一个，这里不再重复画——原来两个搜索框看着就是叠在一起。
  Widget _buildEmbeddedToolbar(ColorScheme colors) {
    final external = widget.externalSearch != null;
    return Container(
      key: const ValueKey('actress-embedded-toolbar'),
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: EdgeInsets.fromLTRB(external ? 12 : 10, 6, 2, 0),
      child: Row(
        children: [
          if (!external) Expanded(child: _buildSearchField()),
          Text(
            _overview == null ? '演员库' : '${_overview!.personsWithWorks} 位演员',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
            ),
          ),
          ..._toolbarActions(),
        ],
      ),
    );
  }

  /// 列表/分类/标签缓存的 key：主库路径+指纹 + 各外来库路径+指纹；
  /// 文件没变就不跑 GROUP BY。库内容变了时 _clearListCaches 清掉
  /// 缓存，指纹只是第二道防线（防文件在外面被换了）。
  String _dbListCacheKey() {
    final keyParts = <String>[
      _dbFileFingerprintKey(_mytvBind?.dbPath ?? ''),
    ];
    final extraPaths = _extraDbs.keys.toList()..sort();
    for (final p in extraPaths) {
      keyParts.add('$p|${_dbFileFingerprintKey(p)}');
    }
    return keyParts.join(';');
  }

  /// 读数据库里的标签（video_tag.tag_name + 作品数，按作品数倒序）：
  /// 只在打开标签弹窗时调（懒加载），之后走缓存；多库勾选时取各库
  /// 并集（同一标签取最大单库数，与分类合并同一口径）。读不到
  /// （没有 video_tag 表的库）回空，弹窗如实显示“暂无标签”。
  Future<List<(String, int)>> _loadDbTags() async {
    final cacheKey = _dbListCacheKey();
    if (_dbTagsCacheKey == cacheKey && _dbTagsCache != null) {
      return _dbTagsCache!;
    }
    var tags = <(String, int)>[];
    try {
      tags = await _db.dbTags();
      if (_hasExtraDbs) {
        final counts = <String, int>{
          for (final t in tags) t.$1: t.$2,
        };
        for (final extra in _extraDbs.values) {
          try {
            for (final t in await extra.dbTags()) {
              final prev = counts[t.$1];
              if (prev == null || t.$2 > prev) counts[t.$1] = t.$2;
            }
          } catch (_) {}
        }
        final merged = counts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        tags = [for (final e in merged) (e.key, e.value)];
      }
    } catch (_) {
      tags = const [];
    }
    _dbTagsCacheKey = cacheKey;
    _dbTagsCache = tags;
    return tags;
  }

  /// 读通用库里的标签（见 GenericDbReader.tagFacet）：没有标签维度
  /// 时 key 为空、列表为空，弹窗如实显示“暂无标签”。
  Future<List<(String, int)>> _loadGenericTags() async {
    final reader = _genericReader;
    if (reader == null) return const [];
    try {
      final tag = await reader.tagFacet();
      if (!mounted) return const [];
      setState(() {
        _genericTagKey = tag.key;
      });
      return tag.values;
    } catch (_) {
      return const [];
    }
  }

  /// 打开标签筛选底部弹窗（2026-11-24 用户令）：列出数据库里的
  /// 全部标签（带作品数），点标签即筛，点“全部”即清空。弹窗打开
  /// 前先查好标签（首次查库，之后走缓存）；没有标签也照常打开，
  /// 如实显示“暂无标签”，不拦。
  Future<void> _openTagSheet() async {
    final tags = _genericMode ? await _loadGenericTags() : await _loadDbTags();
    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: ActressTagSheet(
          tags: tags,
          selected: _genericMode ? _genericTag : _videoTag,
          onSelected: (tag) => Navigator.of(sheetContext).pop(tag),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (_genericMode) {
      _setGenericTag(selected);
    } else {
      _setVideoTag(selected);
    }
  }

  void _setVideoTag(String tag) {
    if (tag == _videoTag) return;
    _saveScrollOffsetForCache();
    setState(() => _videoTag = tag);
    _reloadAfterFilterChange();
  }

  void _setGenericTag(String tag) {
    if (tag == _genericTag) return;
    setState(() => _genericTag = tag);
    unawaited(_loadPage(reset: true));
  }

  /// 通用模式分类：从当前库自身的 video_category 表读（见
  /// [GenericDbReader.categories]）；读失败也不崩、不影响列表，
  /// 只按“暂无分类”显示。切库/重读时由调用方先清掉旧分类再调。
  /// 2026-11-24 用户令：通用模式也不显示数据库名称分类——与第三行
  /// 同一条规则（库名取自当前已勾的 .db 文件名去后缀；外来库把库名
  /// 写成 video_category 主分类时这里滤掉，真分类原样保留）。
  Future<void> _loadGenericCategories() async {
    final reader = _genericReader;
    if (reader == null) return;
    try {
      var categories = await reader.categories();
      final libNames = <String>{
        for (final p in [_mytvBind?.dbPath ?? '', ..._extraDbs.keys])
          if (p.isNotEmpty) path.basenameWithoutExtension(p),
      };
      categories = filterLibraryNameCategories(categories, libNames);
      if (!mounted) return;
      setState(() {
        _genericCategories = categories;
        _genericCategoriesLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _genericCategoriesLoaded = true);
    }
  }

  void _setGenericCategory(String category) {
    if (category == _genericCategory) return;
    setState(() => _genericCategory = category);
    unawaited(_loadPage(reset: true));
  }

  void _setSex(ActressSexFilter sex) {
    if (sex == _sex) return;
    _saveScrollOffsetForCache();
    setState(() => _sex = sex);
    _reloadAfterFilterChange();
  }

  void _setTagFilter(ActressTagFilter filter) {
    if (filter == _tagFilter) return;
    _saveScrollOffsetForCache();
    setState(() => _tagFilter = filter);
    _reloadAfterFilterChange();
  }

  /// 标签入口药丸（2026-11-24 标签筛选）：分类行下面独立一行；
  /// 没选时只显示“标签”，点了开底部弹窗；选了显示“标签：<名>”高亮，
  /// 旁边再给一个“清除”一键清掉（页内可见、可一键清除）。
  List<Widget> _buildTagPills({
    required String selected,
    required VoidCallback onOpen,
    required VoidCallback onClear,
  }) {
    return [
      ActressNeonPill(
        key: const ValueKey('actress-tag-open'),
        label: selected.isEmpty ? '标签' : '标签：$selected',
        selected: selected.isNotEmpty,
        onTap: onOpen,
      ),
      const SizedBox(width: 8),
      if (selected.isNotEmpty) ...[
        ActressNeonPill(
          key: const ValueKey('actress-tag-clear'),
          label: '清除',
          selected: false,
          onTap: onClear,
        ),
        const SizedBox(width: 8),
      ],
    ];
  }

  /// 2026-11-20 MYTV 绑定：绑定路径行（用户一眼看到库落在哪）。
  /// 已绑定且有外置库：显示 `数据库：MYTV/db/女优库.db`。没找到
  /// 外置库：显示“未找到外置数据库”与放库提示。没绑定：给“去设置
  /// 授权”与“重新绑定”两个按钮，用户点了“隐藏提示”后本页内
  /// 隐藏（绝不挡路）。
  Widget _buildMytvBindRow(ColorScheme colors) {
    final bind = _mytvBind;
    if (bind == null || _mytvRowDismissed) {
      return const SizedBox.shrink();
    }
    final noteLines = <String>[];
    // 未绑定 / 未找到外置库的原因（绑定解析时写进 note）：绑定成功
    // 且库在时 note 为空，这行不出现。
    if (bind.note != null) {
      noteLines.add(bind.note!);
    }
    // 2026-11-20 热换库：最近一次重读失败的原因。没有外置库时
    // 不说“仍用旧库”（没有旧库可留），见 actressReloadErrorText。
    if (_mytvDbError != null) {
      noteLines.add(actressReloadErrorText(_mytvDbError!));
    }
    // 开库提示（2026-11-22 起恒为 null，分支保留）。
    if (_mytvOpenNote != null) {
      noteLines.add(_mytvOpenNote!);
    }
    // 内嵌进女优库外壳时（2026-11-21 用户令：顶部别叠一层又一层）：
    // 一切正常（已绑定、有外置库、无错误）就把这整块收起来，
    // 路径仍可从 ⚙️ 设置里看到；只有真出问题（未绑定/找不到库/
    // 打不开）才显示，免得把列表挤掉半屏。
    if (!widget.showTitle && noteLines.isEmpty && bind.bound) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      color: colors.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      // 按钮另起一行：四个按钮全挤在同一行会把文字列压到只剩一字宽
      // （桌面窗口里竖排显示，2026-11-21 用户截图）。文字行独占
      // 一行、按钮行靠右换行，窄屏也不会压坏文字。
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.folder_rounded, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '数据库：${bind.displayPath}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    for (final line in noteLines)
                      Text(
                        line,
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: [
              // 2026-11-20 热换库：手动“重新加载数据库”入口（两种模式都有）。
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: _manualReloadDb,
                child: const Text('重新加载数据库'),
              ),
              if (!bind.bound && !Platform.isIOS)
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: _grantMytvFolder,
                  child: const Text('授权文件夹读取'),
                ),
              // iOS 无库时给导入入口（设置弹窗里导，同一条链）。
              if (Platform.isIOS && !bind.hasVideoDb)
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: _openSettingsSheet,
                  child: const Text('导入数据库'),
                ),
              if (bind.needsPermission)
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: _requestMytvPermission,
                  child: const Text('去设置授权'),
                ),
              if (!bind.bound && !Platform.isIOS)
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: _rebindMytv,
                  child: const Text('重新绑定'),
                ),
              if (!bind.bound)
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => setState(() => _mytvRowDismissed = true),
                  child: const Text('隐藏提示'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGenericModeRow(ColorScheme colors) {
    if (!_genericMode) return const SizedBox.shrink();
    final reader = _genericReader;
    final table = reader?.schema.worksTable?.table ?? '';
    return Container(
      width: double.infinity,
      color: colors.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.storage_rounded, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '外来数据库 · 表 $table · $_genericTotal 条',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: _openFieldsPage,
            child: const Text('数据库字段'),
          ),
        ],
      ),
    );
  }

  /// 人物宫格布局：普通列表与姓名分组共用同一套格子尺寸。
  static const _gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: 3,
    mainAxisSpacing: 16,
    crossAxisSpacing: 8,
    // 人物卡内容高约 142（上下 padding 12 + 头像 84 + 间距 10 +
    // 两行字约 36）：0.88 时格高约 132，底部“约 N 部”一行溢出，
    // 预览图上能看到黄黑溢出条（真机 release 不画条但字会被裁）；
    // 0.78 时格高约 150，刚好装下。
    childAspectRatio: 0.78,
  );

  /// 名单加载失败态：原因 + 重试钮（点了走当前模式的第一页重读）。
  Widget _buildLoadError(ColorScheme colors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _loadError!,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('actress-list-retry'),
              onPressed: () => unawaited(_loadPage(reset: true)),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(ColorScheme colors) {
    // 无库 JSON 顶首页的作品模式：返回钮 + 该人作品网格。
    if (_jsonTopMode && _jsonWorksPerson != null) {
      return _buildJsonWorksList(colors);
    }
    // 只出作品的站源（nvku）：作品网格，点卡直发播放器。
    if (_siteWorksMode) return _buildSiteWorkList(colors);
    // 2026-11-20 通用读库：外来库是作品列表，不是人物宫格。
    if (_genericMode) return _buildGenericList(colors);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null && _persons.isEmpty) {
      return _buildLoadError(colors);
    }
    if (_persons.isEmpty) {
      // 空态分流：没有外置库就是没有库（放库、重新加载）；搜不到就是
      // 搜不到；选了站、该站没匹配上的人就说该站没有；确实一个人
      // 才是“暂无人物”——四种情况不混着说。JSON 顶首页时按它自己
      // 的口径说（筛选维度撑不起/搜不到）。
      final emptyText = _jsonTopMode
          ? _jsonFilterUnsupported
                ? '内置目录没有这项数据（无库时只有名单与作品）'
                : _query.isNotEmpty
                ? '没有找到“$_query”'
                : '暂无人物'
          : _noExternalDb
          ? '未找到外置数据库：请把 女优库.db 放进 MYTV/db/，再点“重新加载数据库”'
          : _query.isNotEmpty
          ? '没有找到“$_query”'
          : _source != ActressSiteFilter.all
          ? '该站暂无匹配人物'
          : '暂无人物';
      return Center(
        child: Text(
          emptyText,
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
      );
    }
    // 按名字排序时按姓名首字母分组显示（通讯录式）；按作品数时不变。
    if (_sort == ActressSort.nameAsc) return _buildGroupedList(colors);
    return GridView.builder(
      key: const ValueKey('actress-person-list'),
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      gridDelegate: _gridDelegate,
      itemCount: _persons.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _persons.length) {
          return const Center(child: CircularProgressIndicator());
        }
        final person = _persons[index];
        return _ActressGridCard(
          key: ValueKey('actress-person-${person.localId}'),
          person: person,
          onTap: () => _openPerson(person),
        );
      },
    );
  }

  /// 通用模式作品列表（2026-11-21 用户令：作品一律网格卡片，不再用
  /// 一行一条的列表）：封面 + 标题 + 番号/女优/日期，点卡直接播
  ///（parse=0），没有详情页。
  Widget _buildGenericList(ColorScheme colors) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null && _genericWorks.isEmpty) {
      return _buildLoadError(colors);
    }
    if (_genericWorks.isEmpty) {
      final emptyText = _query.isNotEmpty ? '没有找到“$_query”' : '这个库里没有作品';
      return Center(
        child: Text(
          emptyText,
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
      );
    }
    return GridView.builder(
      key: const ValueKey('actress-generic-grid'),
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.58,
      ),
      itemCount: _genericWorks.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _genericWorks.length) {
          return const Center(child: CircularProgressIndicator());
        }
        final work = _genericWorks[index];
        return _GenericWorkCard(
          key: ValueKey('generic-work-${work.id ?? work.title}'),
          work: work,
          onTap: () => _playGenericWork(work),
        );
      },
    );
  }

  /// 站点作品网格（nvku）：封面 + 标题 + 番号/年份，点卡直接播。
  Widget _buildSiteWorkList(ColorScheme colors) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null && _siteWorks.isEmpty) {
      return _buildLoadError(colors);
    }
    if (_siteWorks.isEmpty) {
      final emptyText = _query.isNotEmpty ? '没有找到“$_query”' : '这个站暂时取不到作品';
      return Center(
        child: Text(
          emptyText,
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
      );
    }
    return GridView.builder(
      key: const ValueKey('actress-site-work-grid'),
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.58,
      ),
      itemCount: _siteWorks.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _siteWorks.length) {
          return const Center(child: CircularProgressIndicator());
        }
        final drama = _siteWorks[index];
        return _GenericWorkCard(
          key: ValueKey('site-work-${drama.id}'),
          work: _siteWorkCard(drama),
          onTap: () => _playSiteWork(drama),
        );
      },
    );
  }

  /// 姓名分组列表：已加载的人按分组键顺序成段，每段一个字母头 +
  /// 一张宫格；翻页追加的人并入末段重算，不会把同一组拆成两段。
  Widget _buildGroupedList(ColorScheme colors) {
    final groups = <String, List<ActressPerson>>{};
    for (final person in _persons) {
      final key = actressGroupKey(person.displayName, person.aliases);
      (groups[key] ??= []).add(person);
    }
    return CustomScrollView(
      key: const ValueKey('actress-person-list'),
      controller: _scrollController,
      slivers: [
        for (final entry in groups.entries) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
              child: Text(
                entry.key,
                key: ValueKey('actress-group-${entry.key}'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            sliver: SliverGrid.builder(
              gridDelegate: _gridDelegate,
              itemCount: entry.value.length,
              itemBuilder: (context, index) {
                final person = entry.value[index];
                return _ActressGridCard(
                  key: ValueKey('actress-person-${person.localId}'),
                  person: person,
                  onTap: () => _openPerson(person),
                );
              },
            ),
          ),
        ],
        if (_hasMore)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }
}

/// 人物卡片：圆形大头像 + 名字 + “约 N 部”，照潮流女优库的样子。
class _ActressGridCard extends StatelessWidget {
  const _ActressGridCard({
    super.key,
    required this.person,
    required this.onTap,
  });

  final ActressPerson person;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: actressNeonCardDecoration(),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              ActressAvatar(
                avatarUrl: person.avatarUrl,
                name: person.displayName,
                radius: 42,
              ),
              const SizedBox(height: 8),
              Text(
                person.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: Neon.text),
              ),
              const SizedBox(height: 2),
              Text(
                '约 ${person.displayWorks} 部',
                maxLines: 1,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Neon.textDim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 通用模式作品行：封面缩略图 + 标题 + 副标题（日期/番号/分类），
/// 点按直接播；没有可播地址的行不显示播放钮。
/// 外来库作品卡（2026-11-21 用户令：作品一律网格卡片）：封面 + 标题
/// + 副标题（番号/日期 · 女优），点卡直播。
class _GenericWorkCard extends StatelessWidget {
  const _GenericWorkCard({super.key, required this.work, required this.onTap});

  final GenericDbWork work;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (work.displaySubtitle.isNotEmpty) work.displaySubtitle,
      if (work.actress.isNotEmpty) work.actress,
    ].join(' · ');
    return Container(
      decoration: actressNeonCardDecoration(radius: 10),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: ColoredBox(
                    color: Neon.surfaceHigh,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (work.coverUrl.isEmpty)
                          const Center(
                            child: Icon(
                              Icons.movie_outlined,
                              color: Neon.textDim,
                            ),
                          )
                        else
                          Image.network(
                            work.coverUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Center(
                              child: Icon(
                                Icons.movie_outlined,
                                color: Neon.textDim,
                              ),
                            ),
                          ),
                        if (work.playable)
                          const Positioned(
                            right: 4,
                            bottom: 4,
                            child: Icon(
                              Icons.play_circle_fill,
                              size: 18,
                              color: Neon.cyan,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                work.displayTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.25,
                  color: Neon.text,
                ),
              ),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: Neon.textDim),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 女优库设置弹窗（2026-11-21 用户令设，2026-11-26 只读化改版）：
/// 原先的“同步爬取”整窗（名册/作品同步、全站叠加、任意站点爬取、
/// 数据库镜像四节）已随同步/写入整套删除；只剩“数据库”一节——
/// 库路径、最近一次重读错误、重新加载数据库钮——与多库勾选，
/// 全是读功能。库只读：内容变更请换库文件后点“重新加载数据库”。
class _ActressSettingsSheet extends StatelessWidget {
  const _ActressSettingsSheet({required this.host});

  final _ActressListPageState host;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme;
    final bind = host._mytvBind;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.storage_rounded, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('数据库', style: textStyle.titleMedium),
                  ),
                ],
              ),
            ),
            if (bind != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(Icons.circle, size: 8),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('数据库', style: textStyle.titleSmall),
                          const SizedBox(height: 2),
                          Text(
                            '${bind.displayPath}\n'
                            '${host._mytvDbError != null ? '${actressReloadErrorText(host._mytvDbError!)}\n' : ''}'
                            '${host._mytvOpenNote ?? ''}',
                            style: textStyle.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: host._reloadingDb
                          ? null
                          : host._manualReloadDb,
                      child: const Text('重新加载数据库'),
                    ),
                  ],
                ),
              ),
            // iOS（2026-11-26 用户令）：演员库走 .sql 导入制，导入
            // 入口只在 iOS 出现；安卓不挂此节、行为零变化。
            if (Platform.isIOS)
              ActressIosImportTile(onImported: host._manualReloadDb),
            // 2026-11-23 多库勾选：勾上的库一起加载（列表按人名归并、
            // 分类取并集），默认只勾主库；主库永远勾着不可取消。
            // 多库勾选扫的是共享目录里的外来库，iOS 无此概念，不显示。
            if (!Platform.isIOS) _ActressDbChoiceList(host: host),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                Platform.isIOS
                    ? '数据库只读：内容变更请重新导入 .sql 文件。'
                    : '数据库只读：内容变更请换库文件后点“重新加载数据库”。',
                style: textStyle.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 设置弹窗“数据库”区下的多库勾选（2026-11-23 用户令）。
/// 勾上的库一起加载：列表按人名归并、分类取并集；默认只勾主库，
/// 主库永远勾着不可取消。有可播视频的库都能勾（严格视频库与
/// 通用库都进合并，见 GenericActressDatabase）；只有确实 0 部
/// 可播视频、或文件打不开的库才不让勾，副标题如实写原因
///（“0 部可播视频”/“读不出来”），不拿“不是视频库结构”一句话
/// 把有视频的库挡在外面。本 widget 自己读可选库与已勾集合（弹窗
/// 是独立路由，宿主 setState 不会重建它）；勾选变化时调宿主
/// [_ActressListPageState._applyDbSelection] 存勾选并重读列表
/// 与分类。
class _ActressDbChoiceList extends StatefulWidget {
  const _ActressDbChoiceList({required this.host});

  final _ActressListPageState host;

  @override
  State<_ActressDbChoiceList> createState() => _ActressDbChoiceListState();
}

class _ActressDbChoiceListState extends State<_ActressDbChoiceList> {
  var _choices = <ActressDbChoice>[];
  var _selected = <String>{};
  final _counts = <String, int>{};
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final bind = widget.host._mytvBind;
    if (bind == null || !bind.bound) {
      if (mounted) setState(() => _loaded = true);
      return;
    }
    final choices = ActressDbSelection.availableChoices(bind: bind);
    final selected = await ActressDbSelection.loadSelectedPaths(bind.dbPath);
    if (!mounted) return;
    setState(() {
      _choices = choices;
      _selected = selected;
      _loaded = true;
    });
    for (final choice in choices) {
      final count =
          await ActressDbSelection.countPlayableVideos(choice.path);
      if (!mounted) return;
      setState(() => _counts[choice.path] = count);
    }
    // 0 部可播视频 / 读不出来的勾选不参与合并：自动取消勾选并存回去。
    final pruned = Set<String>.from(_selected);
    var changed = false;
    for (final choice in _choices) {
      if (choice.isMain) continue;
      final count = _counts[choice.path];
      if (count != null && count <= 0 && pruned.remove(choice.path)) {
        changed = true;
      }
    }
    if (changed) {
      setState(() => _selected = pruned);
      await widget.host._applyDbSelection(pruned);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Text('正在读数据库列表…'),
      );
    }
    if (_choices.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Text('没找到可勾的数据库（先绑定 MYTV）。'),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final choice in _choices)
          CheckboxListTile(
            key: ValueKey('actress-db-choice-${choice.name}'),
            value: _selected.contains(choice.path),
            onChanged: choice.isMain ||
                    (_counts[choice.path] != null &&
                        _counts[choice.path]! <= 0)
                ? null
                : (value) async {
                    final next = Set<String>.from(_selected);
                    if (value == true) {
                      next.add(choice.path);
                    } else {
                      next.remove(choice.path);
                    }
                    setState(() => _selected = next);
                    await widget.host._applyDbSelection(next);
                  },
            title: Text(
              '${choice.name}${choice.isMain ? '（主库）' : ''}'
              '${choice.isSiteDb ? '（播放记录）' : ''}',
            ),
            subtitle: Text(
              _counts[choice.path] == null
                  ? '正在数…'
                  : _counts[choice.path]! < 0
                      ? '读不出来（打不开或不是数据库）'
                      : _counts[choice.path]! == 0
                          ? '0 部可播视频'
                          : '${_counts[choice.path]} 部视频',
            ),
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
          ),
      ],
    );
  }
}
