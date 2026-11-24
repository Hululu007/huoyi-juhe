import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'actress_database.dart';
import 'actress_db_fields_page.dart';
import 'actress_db_mirror.dart';
import 'actress_db_selection.dart';
import 'actress_detail_page.dart';
import 'actress_film_library.dart';
import 'actress_generic_database.dart';
import 'actress_generic_db.dart';
import 'actress_json_fallback.dart';
import 'actress_models.dart';
import 'actress_multi_db_fallback.dart';
import 'actress_mytv_bind.dart';
import 'actress_neon.dart';
import 'actress_ranking_page.dart';
import 'actress_roster_sources.dart';
import 'actress_search.dart';
import 'actress_site_crawl.dart';
import 'actress_stacking.dart';
import 'actress_sync.dart';
import 'actress_widgets.dart';
import 'actress_adapter_http.dart';
import 'actress_adapter_models.dart';
import 'whos_fallback.dart';
import 'actress_adapter_repository.dart';
import 'actress_adapter_store.dart';
import 'actress_adapter_player.dart';
import 'video_db_normalize.dart';

/// 女优库浏览页：人物列表 + 搜索/性别筛选/排序 + 同步横幅。
///
/// 打开只读本地外置库（MYTV/db/女优库.db）+ 本地 json/m3u 兜底，
/// 不自动爬取网站、不后台自动续爬、不自动生成（2026-11-20 用户令：
/// 不自动爬取；2026-11-22 用户令最终口径：没有外置库就是空库，
/// 不灌内置 json 种子、不走互联网同步）；同步只在用户点了刷新/
/// 重试时跑一次，跑完不自动再续。排行榜入口在顶栏奖杯钮。
/// 全站叠加入口在同步横幅下方：手动开始/继续，按番号把各站作品
/// 叠加进库，断点续跑，不自动跑、不与名册同步抢着跑。
/// 同步/现爬进行中、列表还空时，每 8 秒节流刷新一次列表（有人
/// 出现即停），爬到的条目写盘后进库镜像，列表陆续出人。
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
    this.syncService,
    this.stackingService,
    this.fallback,
    this.crawlService,
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

  /// 测试/预览注入：不传时用 sqflite 真库 + 默认三家名册源。
  @visibleForTesting
  final ActressDatabase? database;
  @visibleForTesting
  final ActressSyncService? syncService;

  /// 测试/预览注入：不传时用默认叠加服务（与详情页同一套补全）。
  @visibleForTesting
  final ActressStackingService? stackingService;

  /// 测试/预览注入：JSON 兜底与现爬服务；不传时现建。
  @visibleForTesting
  final ActressJsonFallback? fallback;
  @visibleForTesting
  final ActressSiteCrawlService? crawlService;

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
  // 进行中刷新节流：同步/现爬跑着、列表还空时，最多每 8 秒刷新
  // 一次列表（有人出现即停）；总览（库里作品数）最多每 5 秒读
  // 一次，不拿 COUNT(*) 高频刷库。
  static const _progressListRefreshInterval = Duration(seconds: 8);
  static const _overviewRefreshInterval = Duration(seconds: 5);

  late final ActressDatabase _db;
  late final ActressSyncService _sync;
  late final ActressStackingService _stacking;
  late final ActressJsonFallback _fallback;
  late final ActressSiteCrawlService _crawl;
  ContentHttp? _http;
  StreamSubscription<ActressSyncProgress>? _progressSub;
  StreamSubscription<ActressStackingProgress>? _stackingSub;
  StreamSubscription<ActressSiteCrawlProgress>? _crawlSub;

  final _scrollController = ScrollController();
  final _searchController = TextEditingController();

  /// 任意站点现爬的地址输入（2026-11-21）：粘一个列表页/分类页地址，
  /// 自动认列表结构与翻页规律，不认识站点名也照爬。
  final _genericUrlController = TextEditingController();
  Timer? _searchDebounce;

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
  /// 同步/现爬/叠加/镜像完成、手动刷新时全清（见 _clearListCaches）。
  final _pageCache = <String, _CachedListPage>{};
  static const _pageCacheMaxKeys = 8;

  /// 分类结果缓存（2026-11-24）：key = 主库路径+指纹 + 各外来库
  /// 路径+指纹，值 = 合并后的分类列表。文件没变就不跑 GROUP BY。
  String? _dbCategoriesCacheKey;
  List<(String, int)>? _dbCategoriesCache;

  /// 外来库连接的文件指纹（打开时记的 mtime + 大小）：复用连接前先
  /// 比对，文件被用户在外面替换过就关掉重开，不能读旧文件句柄。
  final _extraDbFingerprints = <String, (DateTime, int)>{};

  /// 可播视频数缓存（2026-11-24）：按路径记（数量，mtime，大小）。
  /// 文件没变直接用缓存数，变了才重数；-1（打不开）不缓存，下次重试。
  final _playableCountCache = <String, (int, DateTime, int)>{};

  /// 本会话已补过索引的外来库路径（ensureVideoDbIndexes 是
  /// CREATE INDEX IF NOT EXISTS，重复调只是浪费一次开库 IO）。
  final _indexedDbPaths = <String>{};
  var _sex = ActressSexFilter.all;
  var _tagFilter = ActressTagFilter.all;
  var _sort = ActressSort.worksDesc;

  /// 数据库分类筛选：默认全部；选分类后列表只留该分类里有作品的
  /// 人。分类来自用户库 video_category 主分类（FilmLibraryService
  /// .categories，带作品数）；没接上库、没有分类时这行不显示。
  var _category = '';
  var _dbCategories = <(String, int)>[];
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

  ActressSyncProgress _progress = ActressSyncProgress.idle;
  ActressStackingProgress _stackingProgress = ActressStackingProgress.idle;
  ActressSiteCrawlProgress _crawlProgress = const ActressSiteCrawlProgress();
  ActressSyncOverview? _overview;
  var _lastSyncFailed = false;

  /// 本轮开始时库里作品数（同步/现爬跑起来时记一次）：横幅用它算
  /// “本轮 +N”，爬一页涨多少一眼能看到；跑完清掉。
  int? _worksAtRunStart;

  /// 进行中刷新节流的上次时间。
  DateTime _lastProgressListRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastOverviewRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  /// 导出合并 JSON 进行中（防重复点）。
  var _exportingJson = false;

  /// 2026-11-20 MYTV 绑定：绑定解析结果（库落点、是否已授权）。
  /// bootstrap 第一件事就是解析它——在第一次读库之前，库的落点
  /// （MYTV/db/女优库.db，或未找到外置库）与 json/m3u 目录都由它定。
  MytvBindResult? _mytvBind;

  /// 绑定行被用户点了“隐藏提示”后隐藏（本页内有效）。
  var _mytvRowDismissed = false;

  /// 没有外置数据库：绑定不到 MYTV/db/女优库.db，列表显示空态
  /// 提示（放库、重新加载），不回落任何内置库。
  var _noExternalDb = false;

  /// 兜底加载器与现爬服务是不是本页自己建的：是才按绑定结果
  /// 改它们的本地目录；测试注入的实例不动（注入的假目录优先）。
  var _ownsFallback = true;
  var _ownsCrawl = true;

  /// 2026-11-20 热换库：最近一次重读失败的原因（显示在绑定行上）；
  /// 成功重读后清掉。没有外置数据库时这里就是“未找到外置数据库”。
  String? _mytvDbError;

  /// 手动“重新加载数据库”进行中（防重复点）。
  var _reloadingDb = false;

  /// 开库提示（见 openFallbackNote）：2026-11-22 起不再回退任何
  /// 内置库，恒为 null（显示分支保留）。
  String? _mytvOpenNote;

  /// 2026-11-20 数据库镜像：主目录与补充目录里其他 .db 文件的追加
  /// 进行中、已追加数、已处理行数、总行数、正在追加的文件名、失败
  /// 原因。已处理数每批都涨（新增数在源库内容已入库时可以是 0，
  /// 只看新增数会以为卡住）；列表与总览刷新节流用。
  var _mirrorRunning = false;
  var _mirrorAppended = 0;
  var _mirrorProcessed = 0;
  var _mirrorTotal = 0;
  var _mirrorFile = '';
  String? _mirrorError;
  var _lastMirrorRefresh = DateTime.fromMillisecondsSinceEpoch(0);

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

  /// 视频库模式：当前库是用户视频库（MYTV/db/女优库.db，
  /// actresses/videos/video_actress/video_category 四张表）时为
  /// true。主名册就是 actresses 表（本地库是主库，不是兜底）；
  /// 名册同步照常跑（往本地库补新人/补视频），自动生成/
  /// 全站叠加/数据库镜像/新 json 同步禁掉（它们写 persons/works）。
  var _videoLibraryMode = false;
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
    // 先建兜底加载器与现爬服务：同步服务默认要接爬虫腿（潮流源
    // 作品阶段改走爬虫逻辑），构造顺序不能反。
    _ownsFallback = widget.fallback == null;
    _ownsCrawl = widget.crawlService == null;
    _fallback = widget.fallback ?? ActressJsonFallback();
    if (_ownsFallback) {
      // 2026-11-20 18:57 全部使用数据库兜底：兜底先查影视库 db
      // （MYTV/db/女优库.db），读不到回退 json/m3u。测试注入的
      // fallback 不接提供方，保持老行为。
      _fallback.filmDb = _multiDb = MultiDbFilmFallback(database: _db);
    }
    _crawl =
        widget.crawlService ??
        ActressSiteCrawlService(repository: widget.repository, db: _db);
    _crawlSub = _crawl.progress.listen(_onCrawlProgress);
    if (widget.syncService != null) {
      _sync = widget.syncService!;
    } else {
      _http = ContentHttp();
      _sync = ActressSyncService(
        db: _db,
        sources: [
          ChaoliuRosterSource(),
          // 2026-11-21 用户令：MissAV 从同步移除，不再拉取
          // （视频站、jar、名册显示与枚举都不动）；排行主链改走
          // whos 日榜，enableRanking 开关已开。
          WhosRosterSource(enableRanking: true),
        ],
        fetch: actressDefaultFetch(_http!),
        crawlService: _crawl,
      );
    }
    _progressSub = _sync.progress.listen(_onProgress);
    if (widget.stackingService != null) {
      _stacking = widget.stackingService!;
    } else {
      _stacking = ActressStackingService(
        db: _db,
        enrichment: ActressEnrichment(
          repository: widget.repository,
          store: widget.store,
          db: _db,
        ),
      );
    }
    _stackingSub = _stacking.progress.listen(_onStackingProgress);
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
    for (final extra in _extraDbs.values) {
      unawaited(extra.close());
    }
    unawaited(_multiDb?.close());
    widget.store.removeListener(_onStoreChanged);
    _progressSub?.cancel();
    _stackingSub?.cancel();
    _crawlSub?.cancel();
    _crawl.cancel();
    _crawl.dispose();
    _scrollController.dispose();
    widget.externalSearch?.removeListener(_onSearchChanged);
    _searchController.dispose();
    _genericUrlController.dispose();
    _searchDebounce?.cancel();
    _sync.cancel();
    _sync.dispose();
    _stacking.cancel();
    _stacking.dispose();
    _http?.close();
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
    if (_ownsCrawl) _crawl.bindLocalDir(bind.jsonDir);
    // 2026-11-20 热换库：进模块先看库文件变了没有——变了就关旧连接
    // 重开再读（用户用文件管理器换了 db 不用重装）；重读失败留旧库
    // 并把原因记下来显示在绑定行上，不崩。没有外置库时这里就报
    // “未找到外置数据库”，下面开库再抛一次也接住显示空态。
    final reload = await _db.reloadIfChanged();
    if (!mounted || generation != _generation) return;
    if (reload.error != null) {
      setState(() => _mytvDbError = reload.error);
    }
    // 2026-11-20 通用读库：当前库不是女优库结构时走通用模式
    // （作品列表 + 点按直播），不走女优库的总览/同步。
    // 没有外置数据库时开库抛 ActressNoExternalDbException：
    // 接住显示空态提示（放库、重新加载），不崩、不回落。
    GenericDbReader? generic;
    try {
      generic = await _db.genericReader();
    } on ActressNoExternalDbException catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _noExternalDb = true;
        _mytvDbError = e.message;
        _loading = false;
      });
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
        _videoLibraryMode = false;
      });
      await _loadGenericCategories();
      await _loadPage(reset: true);
      return;
    }
    setState(() {
      _genericReader = null;
      _genericMode = false;
      // genericReader() 已开过库，isVideoLibrary 的标志已算好。
      _videoLibraryMode = _db.isVideoLibrary;
    });
    // 兜底后台读、不堵首屏：列表站点过滤要用它，但不能在首屏等它。
    unawaited(_fallback.load());
    final overview = await _db.overview();
    if (!mounted || generation != _generation) return;
    setState(() => _overview = overview);
    // 2026-11-22 用户令最终口径：库缺失/空库不再自动生成（不灌
    // 内置 json 种子、不走互联网同步），空态如实提示放库、重新加载。
    // 叠加只读一次断点作横幅状态，绝不自动跑。
    final stacking = await _stacking.snapshot();
    if (!mounted || generation != _generation) return;
    setState(() => _stackingProgress = stacking);
    // _loadPage(reset) 会推进代次，这里只判 mounted，不再比代次。
    await _loadPage(reset: true);
    if (!mounted) return;
    // 数据库里的分类读一次挂上行：同步跑完分类变了走
    // _refreshAfterSync 再刷。
    unawaited(_loadDbCategories());
    // 不自动爬取（2026-11-20 用户令）：打开只读本地，不自动起爬、
    // 不后台自动续爬、不自动生成；只等用户手动点刷新/重试/同步。
    // 2026-11-20 数据库镜像：主目录与补充目录里其他 .db 文件有作品就
    // 递增追加进库（后台跑，列表数边涨边看）。
    unawaited(_maybeStartDbMirror());
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

  /// 外来库补索引（本会话每个路径只补一次）：ensureVideoDbIndexes
  /// 是 CREATE INDEX IF NOT EXISTS，重复调只是浪费一次开库 IO。
  void _ensureVideoDbIndexesOnce(String path) {
    if (!_indexedDbPaths.add(path)) return;
    unawaited(ensureVideoDbIndexes(path));
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
        // 2026-11-23 转圈根因之三：外来库只读打开、不补索引，点人
        // ORDER BY vod_pubdate、分类 GROUP BY 都走全表扫；和
        // MultiDbFilmFallback 同口径，后台给外来库补同一套索引
        //（只加索引、不动任何一行数据；建不了就跳过，查询照样跑）。
        // 本会话每个路径只补一次（见 _ensureVideoDbIndexesOnce）。
        _ensureVideoDbIndexesOnce(choice.path);
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
    setState(() {
      _extraDbs
        ..clear()
        ..addAll(keep);
      _personHomeDb.clear();
    });
    for (final entry in oldExtras.entries) {
      if (!keep.containsKey(entry.key)) unawaited(entry.value.close());
    }
    // 勾选变了（勾上或取消）都要重读分类与列表：取消最后一个外来库
    // 也要回单库。启动时 reload 为 false，启动流程自己读。
    if (reload) {
      unawaited(_loadDbCategories());
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
      category: _category,
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
          avatarUrl: existing.avatarUrl.isNotEmpty
              ? existing.avatarUrl
              : person.avatarUrl,
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
  Future<void> _requestMytvPermission() async {
    await ActressMytvBind.instance.requestPermission();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已打开系统设置，授权后点“重新绑定”')));
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
    });
    if (_ownsFallback) {
      _fallback.bindLocalDirs(
        jsonDir: bind.jsonDir,
        userM3uDir: bind.bound ? bind.m3uDir : null,
      );
    }
    if (_ownsCrawl) _crawl.bindLocalDir(bind.jsonDir);
    await _refreshAfterSync();
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
      // 旧缓存作废（下面非通用分支走 _refreshAfterSync 也会清，
      // 通用分支不走那里，这里先清一次）。
      _clearListCaches();
      setState(() {
        _mytvDbError = null;
        _noExternalDb = false;
        _mytvBind = ActressMytvBind.instance.current ?? _mytvBind;
      });
      final generic = await _db.genericReader();
      if (!mounted) return;
      setState(() {
        _genericReader = generic;
        _genericMode = generic != null;
        // genericReader() 已开过库，isVideoLibrary 的标志已算好。
        _videoLibraryMode = generic == null && _db.isVideoLibrary;
        // 重读可能换了库：旧分类作废，先清掉再按新库重读。
        _genericCategory = '';
        _genericCategories = [];
        _genericCategoriesLoaded = false;
      });
      if (_genericMode) {
        await _loadGenericCategories();
        await _loadPage(reset: true);
      } else {
        await _refreshAfterSync();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.reloaded ? '已重新加载数据库' : '数据库没有变化')),
      );
      // 重读后库安静了：主目录与补充目录里其他 .db 文件有作品就递增追加。
      unawaited(_maybeStartDbMirror());
    } finally {
      _reloadingDb = false;
    }
  }

  /// 数据库镜像（2026-11-20 用户令“读取数据库要把作品数量
  /// 递增追加上去”，2026-11-21 用户令按 py 的涩库引擎逻辑改路
  /// 径）：扫主目录 MYTV/db（只扫一层）与补充目录（纯福利/db、
  /// 女优库、私藏视频、lz/db，递归扫）下除当前库文件外的 *.db，
  /// 逐个只读打开、分批（200 条）按合并规则追加进当前库。
  /// 触发点：bootstrap 末尾、手动重读成功后。
  /// 护栏：通用模式（当前库本身是外来库）不跑；视频库模式不跑
  /// （镜像写 persons/works，那两张表这个库里没有；视频靠现爬/
  /// 名册同步补）；没有外置库不跑；同步时不跑（等下次安静时再试）；
  /// 正在跑时不重复起；同一文件指纹未变时跳过（镜像记录在
  /// 镜像记录.json 里）。追加失败记错不崩，已有数据不受影响。
  Future<void> _maybeStartDbMirror() async {
    if (_genericMode) return;
    // 视频库模式不跑数据库镜像（镜像写 persons/works，那两张表
    // 这个库里没有；视频靠现爬/名册同步补）。
    if (_videoLibraryMode) return;
    if (_mirrorRunning) return;
    if (_sync.isRunning) return;
    final bind = _mytvBind;
    if (bind == null || !bind.bound) return;
    // 没有外置库：没有可追加进的库，不跑（否则逐人写库全抛错）。
    if (bind.dbPath.isEmpty) return;
    // 补充目录（py 的 SikuEngine.DB_DIRS 同款）从外部存储根
    // 目录拼；没根目录时只扫主目录。
    final externalRoot = bind.externalRoot;
    final extraDirs = externalRoot == null
        ? const <Directory>[]
        : [
            for (final rel in sikuDbScanDirs)
              Directory(path.join(externalRoot.path, rel)),
          ];
    final targets = collectDbMirrorTargets(
      dbDir: bind.dbDir,
      libraryPath: bind.dbPath,
      extraDirs: extraDirs,
    );
    if (targets.isEmpty) return;
    setState(() {
      _mirrorRunning = true;
      _mirrorFile = targets.map((f) => path.basename(f.path)).join('、');
      _mirrorAppended = 0;
      _mirrorProcessed = 0;
      _mirrorTotal = 0;
      _mirrorError = null;
    });
    for (final target in targets) {
      if (!mounted) return;
      final result = await const ActressDbMirror().mirrorFile(
        sourcePath: target.path,
        library: _db,
        libraryPath: bind.dbPath,
        onProgress: (appended, processed, total) {
          if (!mounted) return;
          setState(() {
            _mirrorAppended = appended;
            _mirrorProcessed = processed;
            _mirrorTotal = total;
          });
          // 每批都刷列表与总览会把数据库队列与界面刷爆（每批 200 行，
          // 323798 行就是 1619 次）：数字每批照刷，最多每 5 秒才刷
          // 一次列表与总览，追加过程列表照样能看到数在涨。
          final now = DateTime.now();
          if (now.difference(_lastMirrorRefresh) < const Duration(seconds: 5)) {
            return;
          }
          _lastMirrorRefresh = now;
          unawaited(_refreshVisiblePersons());
          unawaited(
            _db.overview().then((overview) {
              if (mounted) setState(() => _overview = overview);
            }),
          );
        },
      );
      if (!mounted) return;
      if (result.error != null) {
        setState(
          () => _mirrorError = '${path.basename(target.path)}：${result.error}',
        );
      } else if (result.appended > 0 || result.updated > 0) {
        // 追加完刷新一次可见列表与总览（数涨上去），不重置滚动。
        unawaited(_refreshVisiblePersons());
        unawaited(
          _db.overview().then((overview) {
            if (mounted) setState(() => _overview = overview);
          }),
        );
      }
    }
    if (mounted) {
      setState(() => _mirrorRunning = false);
    }
  }

  void _onProgress(ActressSyncProgress progress) {
    if (!mounted) return;
    setState(() => _progress = progress);
    if (progress.running) {
      // 本轮起点：第一次跑起来时记一次库里作品数，横幅算“本轮 +N”。
      _worksAtRunStart ??= _overview?.works ?? 0;
      _maybeRefreshOverview();
      _maybeRefreshListWhileRunning();
      return;
    }
    _clearWorksStartIfIdle();
    if (progress.phase == 'done') {
      unawaited(_refreshAfterSync());
    }
  }

  /// 同步与现爬都停了才清本轮起点（两路可能同时跑，清早了横幅
  /// 的“本轮 +N”就断了）。
  void _clearWorksStartIfIdle() {
    if (!_progress.running && !_crawlProgress.running) {
      _worksAtRunStart = null;
    }
  }

  /// 进行中总览节流刷新（最多每 5 秒读一次库里作品数）：横幅的
  /// “库里作品 X 部（本轮 +N）”靠它长，跑完才刷一次看不见增长。
  void _maybeRefreshOverview() {
    final now = DateTime.now();
    if (now.difference(_lastOverviewRefresh) < _overviewRefreshInterval) {
      return;
    }
    _lastOverviewRefresh = now;
    unawaited(
      _db.overview().then((overview) {
        if (mounted) setState(() => _overview = overview);
      }),
    );
  }

  /// 进行中刷新（最多每 8 秒一次）：同步/现爬跑着时重读列表，
  /// 卡片数随入库增长陆续更新——列表空时整页重读（有人出现即
  /// 停），列表非空时只原地替换当前已加载页的卡片数据（不动
  /// 加载态、不动滚动位置）。旧版只在列表空时刷，非空列表在
  /// 同步进行中永远停在进页那一刻的数（2026-11-20 计数修复：
  /// 列表 54 部、详情 992 部就是这么来的）。
  void _maybeRefreshListWhileRunning() {
    final now = DateTime.now();
    if (now.difference(_lastProgressListRefresh) <
        _progressListRefreshInterval) {
      return;
    }
    _lastProgressListRefresh = now;
    if (_persons.isEmpty) {
      unawaited(_loadPage(reset: true));
      return;
    }
    unawaited(_refreshVisiblePersons());
  }

  /// 进行中轻量刷新：只重读当前已加载的原始页（offset 0、
  /// limit=_rawOffset），原地替换卡片数据；不碰 _loading、
  /// 不碰 _generation（不打断在途的整页加载）、不动滚动位置。
  Future<void> _refreshVisiblePersons() async {
    final generation = _generation;
    final limit = _rawOffset <= 0 ? _pageSize : _rawOffset;
    final raw = await _db.listPersons(
      sex: _sex,
      sort: _sort,
      query: _query,
      tag: _tagFilter.tagValue,
      category: _category,
      offset: 0,
      limit: limit,
    );
    final persons = await _applySiteFilter(raw);
    if (!mounted || generation != _generation) return;
    setState(() {
      _persons = persons;
      _hasMore = raw.length >= _pageSize;
    });
    // 进行中刷新也写透缓存：否则缓存里还是同步前的旧第一页，
    // 切换回来会显示旧数据（同步完成时 _refreshAfterSync 会全清，
    // 这里写透是让同步进行中切换也不显示旧数据）。只存第一页；
    // 只在主模式写（站源/通用模式各有自己的列表，不走这份缓存）。
    // rawOffset 存缓存这页的人数（第一页），不能存已加载的总页数，
    // 否则恢复后翻页会跳页。
    if (!_genericMode && !_siteWorksMode) {
      final firstPage = persons.length > _pageSize
          ? persons.sublist(0, _pageSize)
          : persons;
      _storePageCache(firstPage, raw.length >= _pageSize, firstPage.length);
    }
  }

  /// 本轮入库增长文案（2026-11-20 用户令：增长要看得见，按
  /// “要入库才算”只算库里实际有的）：库里作品总数 + 本轮新增。
  String _worksGrowthText() {
    final overview = _overview;
    if (overview == null) return '';
    final start = _worksAtRunStart;
    if (start == null) return '库里作品 ${overview.works} 部';
    final delta = overview.works - start;
    return '库里作品 ${overview.works} 部（本轮 +$delta）';
  }

  void _onStackingProgress(ActressStackingProgress progress) {
    if (!mounted) return;
    setState(() => _stackingProgress = progress);
    if (progress.running) {
      // 叠加也在写库：进行中同样节流刷卡片数（与同步同一节流）。
      _maybeRefreshListWhileRunning();
      return;
    }
    // 叠加写库刷新了 works_count：总览与列表都要重读才显示真数。
    unawaited(_refreshAfterSync());
  }

  /// 手动开始/继续叠加：名册同步跑着时不启动（两路同时写库抢带宽，
  /// 等同步停了再点）；叠加服务内部断点续跑，本处只管触发一次。
  Future<void> _runStacking() async {
    // 视频库模式不跑全站叠加（叠加写 persons/works，那两张表
    // 这个库里没有；跨站叠加由现爬/名册同步的合并规则覆盖）。
    if (_videoLibraryMode) return;
    if (_stacking.isRunning || _progress.running) return;
    await _stacking.run();
  }

  Future<void> _refreshAfterSync() async {
    // 同步/现爬/叠加写了库：旧缓存作废，先清再重读（漏清会显示旧数据）。
    // 所有完成路径都走这里（同步 done、叠加 done、现爬 done、重绑、
    // 手动重载），一处清就全覆盖。
    _clearListCaches();
    final overview = await _db.overview();
    if (!mounted) return;
    setState(() => _overview = overview);
    await _loadPage(reset: true);
    if (!mounted) return;
    unawaited(_loadDbCategories());
  }

  /// 只断点续跑：永远不从头重拉（refresh 恒为 false）。手动点一次
  /// 跑一次，跑完不自动再续（2026-11-20 用户令：不自动爬取）；
  /// 没跑完下次手动点继续补。跑之前记一次库里作品数，横幅算
  /// “本轮 +N”。
  Future<void> _runSync() async {
    // 2026-11-20 通用读库：外来库不走女优库同步。
    if (_genericMode) return;
    // 视频库模式不禁名册同步（2026-11-21 用户令）：它现在是往
    // 本地 actresses 表补新人（upsertRosterPerson 走视频库分支），
    // 再由作品阶段把她的作品写进 videos；检查点不记，同步每次按
    // 名册全量比对、只补没有的。
    if (_sync.isRunning) return;
    _worksAtRunStart = _overview?.works ?? 0;
    setState(() => _lastSyncFailed = false);
    final result = await _sync.run(refresh: false);
    if (!mounted) return;
    setState(() => _lastSyncFailed = result.hasFailures);
    final overview = await _db.overview();
    if (!mounted) return;
    setState(() => _overview = overview);
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

  void _onCrawlProgress(ActressSiteCrawlProgress progress) {
    if (!mounted) return;
    setState(() => _crawlProgress = progress);
    if (progress.running) {
      _worksAtRunStart ??= _overview?.works ?? 0;
      _maybeRefreshOverview();
      _maybeRefreshListWhileRunning();
      return;
    }
    _clearWorksStartIfIdle();
    if (!progress.done) return;
    // 现爬写了新的本地 JSON：重读兜底再刷新列表，爬到的条目立刻可见。
    unawaited(
      _fallback.load().then((_) {
        if (mounted) unawaited(_loadPage(reset: true));
      }),
    );
  }

  /// 导出合并 JSON：本地全部行按更新规则合并后的全文，走系统保存
  /// 对话框存成 mjv011.json（已绑定时直接写 MYTV/mjv011.json），
  /// 用户拷走即用。
  Future<void> _exportMergedJson() async {
    if (_exportingJson) return;
    setState(() => _exportingJson = true);
    try {
      if (!_fallback.loaded) await _fallback.load();
      final doc = _fallback.mergedDocument();
      final text = const JsonEncoder.withIndent('  ').convert(doc);
      // 2026-11-20 MYTV 绑定：已绑定时直接写到 MYTV/mjv011.json
      // （根目录，不碰 MYTV/db 里正在用的影子文件），用户用文件
      // 管理器拷走即用；未绑定时走原来的选位置保存。
      final bind = _mytvBind;
      if (bind != null && bind.bound) {
        await File(bind.mergedJsonExportPath).writeAsString(text);
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已导出到 MYTV/mjv011.json')));
        return;
      }
      final bytes = Uint8List.fromList(utf8.encode(text));
      // 修仙版没有 file_picker（只在魔蚁侧有）：改用修仙版已有的
      // file_selector 选保存位置，再把字节写过去。安卓上选位置
      // 不支持时抛错，外层 catch 报“导出失败”，不静默假装导出。
      final location = await getSaveLocation(
        suggestedName: ActressJsonFallback.localFileName,
      );
      String? savedPath;
      if (location != null) {
        await XFile.fromData(
          bytes,
          mimeType: 'application/json',
          name: ActressJsonFallback.localFileName,
        ).saveTo(location.path);
        savedPath = location.path;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(savedPath == null ? '已取消导出' : '已导出合并 JSON，可拷进树里内置文件'),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('导出失败')));
      }
    } finally {
      if (mounted) setState(() => _exportingJson = false);
    }
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

  /// 任意站点现爬（2026-11-21 用户令）：粘一个站点列表页/分类页地址就爬。
  /// 不认站点名：列表结构、翻页规律、详情字段全部按页面实测识别。
  Future<void> _runGenericCrawl() async {
    if (_crawl.running) return;
    final url = _genericUrlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('先填一个站点地址（列表页或分类页）')));
      return;
    }
    if (_source != ActressSiteFilter.all) {
      setState(() => _source = ActressSiteFilter.all);
    }
    await _crawl.startGenericSite(url);
    if (!mounted) return;
    await _refreshAfterSync();
  }

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
      });
      final page = await widget.repository.catalog(
        nvkuSourceId,
        page: 1,
        query: _query,
        category: _siteWorksCategory,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _siteWorks = page.items;
        _siteWorksPage = 2;
        _hasMore = page.hasMore;
        _loading = false;
        _refreshing = false;
      });
      return;
    }
    if (_loadingMore || !_hasMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    final page = await widget.repository.catalog(
      nvkuSourceId,
      page: _siteWorksPage,
      query: _query,
      category: _siteWorksCategory,
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _siteWorks = [..._siteWorks, ...page.items];
      _siteWorksPage += 1;
      _hasMore = page.hasMore;
      _loadingMore = false;
    });
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

  Future<void> _loadPage({bool reset = false}) async {
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
      });
      _rawOffset = 0;
      // 2026-11-23 多库勾选：勾了外来库时按人名归并查（每库各取一个
      // 窗口再合并，见 _loadMergedPersons）；只勾主库走老路。
      if (_hasExtraDbs) {
        final merged = await _loadMergedPersons(offset: 0, limit: _pageSize);
        final persons = await _applySiteFilter(merged);
        if (!mounted || generation != _generation) return;
        setState(() {
          _persons = persons;
          _hasMore = _mergedHasMore;
          _loading = false;
          _refreshing = false;
        });
        _storePageCache(persons, _mergedHasMore, _rawOffset);
        return;
      }
      final raw = await _db.listPersons(
        sex: _sex,
        sort: _sort,
        query: _query,
        tag: _tagFilter.tagValue,
        category: _category,
        offset: 0,
        limit: _pageSize,
      );
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
      return;
    }
    if (_loadingMore || !_hasMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    if (_hasExtraDbs) {
      final merged = await _loadMergedPersons(
        offset: _persons.length,
        limit: _pageSize,
      );
      final persons = await _applySiteFilter(merged);
      if (!mounted || generation != _generation) return;
      setState(() {
        _persons = [..._persons, ...persons];
        _hasMore = _mergedHasMore;
        _loadingMore = false;
      });
      return;
    }
    final raw = await _db.listPersons(
      sex: _sex,
      sort: _sort,
      query: _query,
      tag: _tagFilter.tagValue,
      category: _category,
      offset: _rawOffset,
      limit: _pageSize,
    );
    _rawOffset += raw.length;
    final persons = await _applySiteFilter(raw);
    if (!mounted || generation != _generation) return;
    setState(() {
      _persons = [..._persons, ...persons];
      _hasMore = raw.length >= _pageSize;
      _loadingMore = false;
    });
  }

  /// 第一页缓存的 key：筛选条件的全部维度 + 已勾选库路径（排好序）。
  /// 任一维度变了就是另一个 key；数据库勾选变化时库路径段变了，
  /// 旧 key 自然失效。只用于主模式（通用/站源模式各有自己的列表，
  /// 不走这份缓存）。
  String _pageCacheKey() {
    final dbs = _extraDbs.keys.toList()..sort();
    return [
      _sex.name,
      _category,
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
  /// 只用于主模式（通用/站源模式不走这份缓存）。
  void _saveScrollOffsetForCache() {
    if (_genericMode || _siteWorksMode) return;
    if (!_scrollController.hasClients) return;
    final cached = _pageCache[_pageCacheKey()];
    if (cached != null) {
      cached.scrollOffset = _scrollController.offset;
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
  bool _restorePageFromCache() {
    final key = _pageCacheKey();
    final cached = _pageCache[key];
    if (cached == null) return false;
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

  /// 清掉全部易变缓存（列表第一页 + 分类）：库内容变了就调——热换库、
  /// 同步/现爬/叠加完成、手动刷新。漏清会显示旧数据。
  void _clearListCaches() {
    _pageCache.clear();
    _dbCategoriesCacheKey = null;
    _dbCategoriesCache = null;
  }

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
      });
      final total = await reader.countWorks(
        query: _query,
        category: _genericCategory,
      );
      final works = await reader.works(
        offset: 0,
        limit: _pageSize,
        query: _query,
        category: _genericCategory,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _genericWorks = works;
        _genericTotal = total;
        _hasMore = works.length >= _pageSize;
        _loading = false;
        _refreshing = false;
      });
      return;
    }
    if (_loadingMore || !_hasMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    final works = await reader.works(
      offset: _genericWorks.length,
      limit: _pageSize,
      query: _query,
      category: _genericCategory,
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _genericWorks = [..._genericWorks, ...works];
      _hasMore = works.length >= _pageSize;
      _loadingMore = false;
    });
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
    // 2026-11-23 多库勾选：合并列表里的人按所在库进详情（主库优先，
    // 主库没有这个人才指外来库）；单库时 _personHomeDb 为空，走主库。
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

  /// 有任一路在跑（名册同步、全站叠加、任意站点爬取、数据库镜像）：
  /// 齿轮图标换成小转圈，顶栏不占位也能看出在动。
  bool get _anyRunning =>
      _progress.running ||
      _stackingProgress.running ||
      _crawlProgress.running ||
      _mirrorRunning;

  /// 设置弹窗（2026-11-21 用户令）：把原来排在顶栏的同步横幅、全站
  /// 叠加横幅、现爬横幅、数据库镜像横幅全收进这一个 ⚙️ 弹窗；
  /// 弹窗里的“同步爬取”小窗点标题即可收起（收回），只留一行摘要。
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
          // 2026-11-21 用户令：同步/叠加/现爬/数据库镜像不再在顶栏排
          // 一排横幅，全部收进右上角 ⚙️ 设置弹窗（弹窗里的“同步爬取”
          // 小窗可随手收回，见 _openSettingsSheet）。数据库绑定行与
          // 外来库行属于库信息，继续留在页面顶部。
          _buildMytvBindRow(colors),
          _buildGenericModeRow(colors),
          if (widget.showTitle)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
              child: _buildSearchField(),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
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
          // 数据库里的分类（video_category 主分类）：横向滑，点分类
          // 只留该分类里有作品的人；无分类时不占地方。
          // chips 照活树改版换成霓虹药丸钮。
          if (_dbCategories.isNotEmpty && !_genericMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    ActressNeonPill(
                      key: const ValueKey('actress-category-all'),
                      label: '全部',
                      selected: _category.isEmpty,
                      onTap: () => _setCategory(''),
                    ),
                    const SizedBox(width: 8),
                    for (final category in _dbCategories) ...[
                      ActressNeonPill(
                        key: ValueKey('actress-category-${category.$1}'),
                        label: '${category.$1}（${category.$2}）',
                        selected: _category == category.$1,
                        onTap: () => _setCategory(category.$1),
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
              // 2026-11-20 热换库：通用模式下刷新按钮就是手动重载数据库。
              tooltip: _genericMode ? '重新加载数据库' : '刷新同步',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _genericMode
                  ? _manualReloadDb
                  : _progress.running
                  ? null
                  : () => _runSync(),
            ),
            // 2026-11-21 用户令：右上角“影视库”按钮没用，删掉。
            // 设置齿轮（2026-11-21 用户令）：同步/叠加/现爬/镜像全部
            // 收进这个弹窗，顶栏不再排一列横幅。
            IconButton(
              key: const ValueKey('open-actress-settings'),
              tooltip: '设置',
              visualDensity: VisualDensity.compact,
              icon: _anyRunning
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.settings_outlined),
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

  /// 读数据库里的分类（video_category 主分类 + 作品数）：影视库
  /// 没接上、没分类时返回空，这行不显示；读失败也不崩、不影响列表。
  Future<void> _loadDbCategories() async {
    final provider = _fallback.filmDb;
    final FilmLibraryService? service = switch (provider) {
      FilmLibraryService p => p,
      MultiDbFilmFallback p => p.primary,
      _ => null,
    };
    if (service == null) return;
    // 2026-11-24 切换不重载：分类结果缓存——key = 主库路径+指纹 +
    // 各外来库路径+指纹；文件没变就不跑 GROUP BY。库内容变了时
    // _clearListCaches 会清掉这份缓存（热换/同步/现爬/手动刷新），
    // 所以 key 里的指纹只是第二道防线（防文件在外面被换了）。
    final keyParts = <String>[
      _dbFileFingerprintKey(_mytvBind?.dbPath ?? ''),
    ];
    final extraPaths = _extraDbs.keys.toList()..sort();
    for (final p in extraPaths) {
      keyParts.add('$p|${_dbFileFingerprintKey(p)}');
    }
    final cacheKey = keyParts.join(';');
    if (_dbCategoriesCacheKey == cacheKey && _dbCategoriesCache != null) {
      if (!mounted) return;
      setState(() => _dbCategories = _dbCategoriesCache!);
      return;
    }
    try {
      var categories = await service.categories();
      // 2026-11-23 多库去重：三个库是同一套合库的副本，分类数相加
      // 会翻倍（有码 22 万计成 44 万）。分类的精确并集要拉全库
      //（番号，播放链接）集合，太贵；取最大单库数——并集 ≈ 最大库数
      //（副本之间几乎全重叠），误差 <1%。人物计数走精确并集，见
      // _dedupMergedWorksCounts。
      if (_hasExtraDbs) {
        final counts = <String, int>{
          for (final c in categories) c.$1: c.$2,
        };
        for (final extra in _extraDbs.values) {
          try {
            for (final c in await extra.dbCategories()) {
              final prev = counts[c.$1];
              if (prev == null || c.$2 > prev) counts[c.$1] = c.$2;
            }
          } catch (_) {}
        }
        final merged = counts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        categories = [for (final e in merged) (e.key, e.value)];
      }
      // 2026-11-24 用户令：第三行不显示数据库名称分类——外来库把库名
      // 写成了 video_category 的主分类，合并后滤掉（库名取自当前已勾
      // 的 .db 文件名去后缀；真分类不在库名集合里，原样保留）。
      final libNames = <String>{
        for (final p in [_mytvBind?.dbPath ?? '', ..._extraDbs.keys])
          if (p.isNotEmpty) path.basenameWithoutExtension(p),
      };
      categories = filterLibraryNameCategories(categories, libNames);
      if (!mounted) return;
      _dbCategoriesCacheKey = cacheKey;
      _dbCategoriesCache = categories;
      setState(() => _dbCategories = categories);
    } catch (_) {
      // 读不到分类就不显示这行，不影响列表。
    }
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

  void _setCategory(String category) {
    if (category == _category) return;
    _saveScrollOffsetForCache();
    setState(() => _category = category);
    _reloadAfterFilterChange();
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
              if (!bind.bound)
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

  Widget _buildList(ColorScheme colors) {
    // 只出作品的站源（nvku）：作品网格，点卡直发播放器。
    if (_siteWorksMode) return _buildSiteWorkList(colors);
    // 2026-11-20 通用读库：外来库是作品列表，不是人物宫格。
    if (_genericMode) return _buildGenericList(colors);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_persons.isEmpty) {
      // 空态分流：没有外置库就是没有库（放库、重新加载）；搜不到就是
      // 搜不到；选了站、该站没匹配上的人就说该站没有；确实一个人
      // 才是“暂无人物”——四种情况不混着说。
      final emptyText = _noExternalDb
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

/// 女优库设置弹窗（2026-11-21 用户令）：原来排在顶栏的同步、全站叠加、
/// 数据库镜像四块状态与操作全收进这里；弹窗内的“同步爬取”
/// 小窗点标题即可收起（收回），只留一行摘要，随时再展开。
class _ActressSettingsSheet extends StatefulWidget {
  const _ActressSettingsSheet({required this.host});

  final _ActressListPageState host;

  @override
  State<_ActressSettingsSheet> createState() => _ActressSettingsSheetState();
}

class _ActressSettingsSheetState extends State<_ActressSettingsSheet> {
  /// 同步爬取小窗是否展开（收起后只剩一行摘要）。
  var _expanded = true;

  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // 进度都在页面 State 里：弹窗每 600ms 取一次最新值，跑起来时
    // 数字会走；不额外订阅进度流，关掉弹窗就停，不留监听。
    _ticker = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  _ActressListPageState get _host => widget.host;

  /// 同步一行文案：跑着报阶段 + 进度 + 失败数，停下报总数，空库报
  /// 还没数据。与原来横幅同一口径，只是搬了位置。
  String _syncText() {
    final host = _host;
    final progress = host._progress;
    if (progress.running) {
      final detail = progress.detail.isNotEmpty
          ? progress.detail
          : progress.total > 0
          ? '${progress.done}/${progress.total}'
          : '第 ${progress.done} 页';
      final failed = progress.failed > 0 ? ' · 失败 ${progress.failed}' : '';
      return '${progress.phaseLabel}（${progress.sourceIndex}/${progress.sourceCount}）· $detail$failed';
    }
    final overview = host._overview;
    if (overview == null) return '还没读到库';
    if (overview.persons == 0) return '还没有数据，点下面开始同步演员库';
    if (host._lastSyncFailed || !overview.allDone) {
      return '已同步 ${overview.persons} 人 · ${overview.works} 部作品，部分还没同步完';
    }
    return '已同步 ${overview.persons} 人 · ${overview.works} 部作品';
  }

  String _stackingText() {
    final stacking = _host._stackingProgress;
    if (stacking.running) {
      return '全站叠加中 · 已叠加 ${stacking.done}/${stacking.total} 人'
          ' · 本轮新增 ${stacking.worksAdded} 部作品';
    }
    if (stacking.finished) {
      return '全站叠加已完成：${stacking.done} 人作品已按番号叠加';
    }
    if (stacking.done > 0) {
      return '已叠加 ${stacking.done}/${stacking.total} 人，继续按番号补全各站作品';
    }
    return '按番号把各站作品叠加到每个人名下，断点续跑，不用一次跑完';
  }

  String _mirrorText() {
    final host = _host;
    if (host._mirrorRunning) {
      return '正在追加数据库 ${host._mirrorFile}…已处理 ${host._mirrorProcessed}'
          ' / 共 ${host._mirrorTotal > 0 ? host._mirrorTotal : '…'} 条'
          '（新增 ${host._mirrorAppended} 部）';
    }
    if (host._mirrorError != null) {
      return '追加数据库失败：${host._mirrorError}（已有数据不受影响）';
    }
    return 'MYTV/db 与补充目录里其它 .db 会自动按番号补进来';
  }

  /// 收起时的一行摘要：跑着的路数 + 关键数字。
  String _summary() {
    final host = _host;
    final running = <String>[];
    if (host._progress.running) running.add('同步');
    if (host._stackingProgress.running) running.add('叠加');
    if (host._crawlProgress.running) running.add('现爬');
    if (host._mirrorRunning) running.add('追加库');
    final overview = host._overview;
    final tail = overview == null
        ? ''
        : ' · ${overview.persons} 人 / ${overview.works} 部';
    if (running.isEmpty) return '空闲$tail';
    return '正在${running.join('、')}$tail';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final host = _host;
    final busy = host._anyRunning;
    final textStyle = Theme.of(context).textTheme;

    Widget button(String label, VoidCallback? onPressed, {Key? key}) =>
        TextButton(
          key: key,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(0, 30),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: onPressed,
          child: Text(label),
        );

    Widget section({
      required String title,
      required String body,
      required List<Widget> actions,
      bool spinning = false,
    }) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: spinning
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.circle, size: 8),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: textStyle.titleSmall),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: textStyle.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (actions.isNotEmpty)
            Wrap(alignment: WrapAlignment.end, children: actions),
        ],
      ),
    );

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标题行：点右侧箭头收起/展开整个“同步爬取”小窗。
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.sync_rounded, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _expanded ? '同步爬取' : '同步爬取（已收起）',
                      style: textStyle.titleMedium,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('toggle-actress-settings-body'),
                    tooltip: _expanded ? '收起' : '展开',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                    ),
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
                ],
              ),
            ),
            if (!_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  _summary(),
                  key: const ValueKey('actress-settings-summary'),
                  style: textStyle.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              )
            else ...[
              section(
                title: '名册 / 作品同步',
                body: [
                  host._worksGrowthText(),
                  _syncText(),
                ].where((t) => t.isNotEmpty).join('\n'),
                spinning: host._progress.running,
                actions: [
                  if (host._progress.running)
                    button('取消', host._sync.cancel)
                  else
                    button(
                      host._overview == null || host._overview!.persons == 0
                          ? '开始同步'
                          : (host._lastSyncFailed || !host._overview!.allDone
                                ? '继续同步'
                                : '再同步一次'),
                      host._progress.running
                          ? null
                          : () => host._runSync(),
                    ),
                ],
              ),
              section(
                title: '全站叠加',
                body: _stackingText(),
                spinning: host._stackingProgress.running,
                actions: [
                  if (host._stackingProgress.running)
                    button('取消', host._stacking.cancel)
                  else
                    button(
                      host._stackingProgress.done > 0 ? '继续叠加' : '开始叠加',
                      host._progress.running ||
                              host._overview == null ||
                              host._overview!.persons == 0
                          ? null
                          : () => host._runStacking(),
                    ),
                ],
              ),
              // 2026-11-24 用户令：选站现爬已删（详情页自动写入站点库
              // 已能回写数据库，不用再现爬补库）；任意站点爬取留着。
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 3),
                      child: Icon(Icons.public, size: 14),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('任意站点爬取', style: textStyle.titleSmall),
                          const SizedBox(height: 2),
                          Text(
                            '粘一个列表页/分类页地址：自动认列表结构、翻页规律、'
                            '女优与番号，不用先把站加进列表。',
                            style: textStyle.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 6),
                          TextField(
                            key: const ValueKey('generic-crawl-url'),
                            controller: host._genericUrlController,
                            enabled: !host._crawlProgress.running,
                            keyboardType: TextInputType.url,
                            style: textStyle.bodySmall,
                            onSubmitted: (_) => host._runGenericCrawl(),
                            decoration: const InputDecoration(
                              isDense: true,
                              hintText: 'https://站点.com/videos',
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 10,
                              ),
                            ),
                          ),
                          // 现爬进度行（原在“选站现爬”区，2026-11-24
                          // 删区后挪到这里）：跑着显示进度 + 取消，
                          // 跑完显示导出合并 JSON。
                          if (host._crawlProgress.running ||
                              host._crawlProgress.done)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Row(
                                children: [
                                  if (host._crawlProgress.running)
                                    const Padding(
                                      padding: EdgeInsets.only(right: 8),
                                      child: SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    ),
                                  Expanded(
                                    child: Text(
                                      host._crawlProgress.label,
                                      style: textStyle.bodySmall,
                                    ),
                                  ),
                                  if (host._crawlProgress.running)
                                    button('取消', host._crawl.cancel)
                                  else if (host._crawlProgress.done)
                                    button(
                                      '导出合并 JSON',
                                      host._exportingJson
                                          ? null
                                          : host._exportMergedJson,
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                    button(
                      '开始爬',
                      host._crawlProgress.running
                          ? null
                          : host._runGenericCrawl,
                    ),
                  ],
                ),
              ),
              section(
                title: '数据库镜像（其它 .db 追加）',
                body: _mirrorText(),
                spinning: host._mirrorRunning,
                actions: const [],
              ),
              if (host._mytvBind != null)
                section(
                  title: '数据库',
                  body:
                      '${host._mytvBind!.displayPath}\n'
                      '${host._mytvDbError != null ? '${actressReloadErrorText(host._mytvDbError!)}\n' : ''}'
                      '${host._mytvOpenNote ?? ''}',
                  actions: [
                    button(
                      '重新加载数据库',
                      host._reloadingDb ? null : host._manualReloadDb,
                    ),
                  ],
                ),
              // 2026-11-23 多库勾选：勾上的库一起加载（列表按人名归并、
              // 分类取并集），默认只勾主库；主库永远勾着不可取消。
              _ActressDbChoiceList(host: host),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  busy ? '有任务在跑，关掉这个窗也会继续跑；随时点齿轮看进度。' : '全部任务都没在跑。',
                  style: textStyle.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
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
