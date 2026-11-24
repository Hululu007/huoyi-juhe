import 'dart:async';

import 'package:flutter/material.dart';

import '../services/native_player.dart' show NativePlayer;
import 'actress_database.dart';
import 'actress_film_library.dart';
import 'actress_multi_db_fallback.dart';
import 'actress_json_fallback.dart';
import 'actress_models.dart';
import 'actress_neon.dart';
import 'actress_widgets.dart';
import 'actress_adapter_http.dart';
import 'actress_adapter_models.dart';
import 'actress_adapter_player.dart';
import 'actress_adapter_repository.dart';
import 'actress_adapter_store.dart';
import 'actress_adapter_widgets.dart';
import 'whos_json_index.dart';

/// 人物详情页：头像、名、标签、作品数 + 作品卡片网格。
///
/// - 作品一律视频卡片（DramaTile，与站内卡片同一形态）：有封面显示
///   封面 + 标题/番号，无封面用占位卡片 + 番号，点卡片才播；
/// - 作品的播放链接全部以数据库里为准（2026-11-22 用户令：女优库
///   全部播放只走数据库里的数据）：只读库，不走跨站现取、不走
///   json/m3u 兜底做展示——m3u hash 图贴封面与跨站搜索补封面
///   （双键合流）都已停掉，库里没有封面就如实显示占位卡片，不编
///   地址；点卡只试库里存的地址（按番号匹配、同番号多条逐条
///   resolve + 验活，最多 3 条，首条活的进详情页播），库里没有
///   可播地址就报“库里暂无播放地址”，不落回内置兜底、不跨站探活、
///   不弹去搜索；
/// - 分类 chips 与顶栏走霓虹样式（见 actress_neon.dart）。
class ActressDetailPage extends StatefulWidget {
  const ActressDetailPage({
    super.key,
    required this.localId,
    required this.repository,
    required this.store,
    required this.database,
    this.siteFilter = ActressSiteFilter.all,
    this.fallback,
    this.filmDb,
    this.verifyFetch,
    this.playerFactory,
  });

  final int localId;
  final AppRepository repository;
  final LocalStore store;
  final ActressDatabase database;

  /// 列表页传来的站点筛选：兜底区只显示该站的条目（默认全部）。
  final ActressSiteFilter siteFilter;

  /// 测试注入：DB 行加载器；不传时现建。
  @visibleForTesting
  final ActressJsonFallback? fallback;

  /// 测试注入：影视库 db 兜底提供方（唯一一档）；不传时按列表页同一
  /// 接法现建 MultiDbFilmFallback（测试注入的 fallback 不接提供方，
  /// 保持老行为）。
  @visibleForTesting
  final FilmDbFallbackProvider? filmDb;

  /// 测试注入：存的地址验活探针；不传时用 [probeStreamHead]。
  @visibleForTesting
  final FeedProbeFetch? verifyFetch;

  /// 测试注入：点卡进播放页时用的播放器实现；不传时走真
  /// NativePlayer（见 actress_adapter_player.dart 的同名字段）。
  @visibleForTesting
  final NativePlayer Function()? playerFactory;

  @override
  State<ActressDetailPage> createState() => _ActressDetailPageState();
}

class _ActressDetailPageState extends State<ActressDetailPage> {
  static const _pageSize = 60;

  final _scrollController = ScrollController();
  ActressPerson? _person;
  var _works = <ActressWork>[];
  var _loading = true;
  var _loadingMore = false;
  var _hasMore = true;
  var _generation = 0;
  var _playGeneration = 0;
  var _findingSource = false;

  /// 已加载的数据库作品数（翻页 offset 用它，不用 _works.length——
  /// _works 里还混着 json 补的作品，用它当 offset 会跳过数据库作品）。
  var _dbWorksCount = 0;

  /// json 补的作品数（只在无分类筛选时补，见 _supplementJsonWorks）。
  var _jsonWorksCount = 0;

  /// 头顶“作品 N 部”显示的总数：数据库入库数 + json 补的数（无筛选时）。
  /// 选了分类也不变（只算入库总数，不受筛选影响）；json 没补上之前
  /// 先显示数据库数，补上后再加。0 表示还没算出来，用人物行的数兜底。
  var _headerTotal = 0;

  /// 分类筛选：null = 全部；其余为该女优作品里实际存在的分类名。
  /// 头顶“作品 N 部”总数不受筛选影响；进出详情页即重置（状态只
  /// 活在本页实例里）。与头顶“无码”“推荐”人物标签无关，另起一行。
  String? _selectedCategory;
  var _categories = <({String name, int count})>[];

  /// 当前筛选下的作品数（翻页用）；头顶总数由人物行的 displayWorks
  /// 显示（只算入库总数，不受筛选影响），不在这里另记。
  var _filteredTotal = 0;

  /// 库里存的播放地址（2026-11-22 用户令：女优库全部播放只走数据
  /// 库里的数据）：只含本地 db 行（多 .db 合并，按女优名 / 番号从
  /// 影视库 db 取回），不含内置 json/m3u 行；点播只试这些
  /// （见 _playWork）。兜底区不渲染，只供点播用。
  var _fallbackEntries = <ActressJsonEntry>[];

  /// 地址池正在建的 Future（_bootstrap 末尾起，不堵首屏）：
  /// 点卡时池子没建好最多等 2 秒（2026-11-24 秒进改法；原来等
  /// 15 秒），等不到按当前池子走，不在点播里卡住。
  Future<void>? _fallbackLoad;

  /// 没有外置数据库：详情页显示空态提示，不显示“人物不存在”。
  var _noDatabase = false;

  /// DB 服务：只建一次，复用同一条 DB 连接（进详情页多次不重开）。
  /// 多 .db 合并（主库 + 其它 .db）：本页自己建的时候持有。
  /// 多 .db 合并仍是数据库，不是 json/m3u 兜底，保留。
  MultiDbFilmFallback? _multiDb;

  FeedProbeFetch get _verifyFetch => widget.verifyFetch ?? probeStreamHead;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _bootstrap();
  }

  @override
  void dispose() {
    _generation++;
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final generation = ++_generation;
    // 2026-11-20 热换库：进详情页先看库文件变了没有——变了就关旧
    // 连接重开再读；重读失败留旧库并报原因，不崩。没有外置库时
    // 显示空态提示，不说“仍用旧库”（没有旧库可留）。
    final reload = await widget.database.reloadIfChanged();
    if (!mounted || generation != _generation) return;
    if (reload.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(actressReloadErrorText(reload.error!))),
      );
    }
    ActressPerson? person;
    try {
      person = await widget.database.personById(widget.localId);
    } on ActressNoExternalDbException catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _person = null;
        _loading = false;
        _noDatabase = true;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (!mounted || generation != _generation) return;
    if (person == null) {
      setState(() {
        _person = null;
        _loading = false;
      });
      return;
    }
    setState(() => _person = person);
    // 2026-11-22 加载优化：分类与首屏作品并行取——分类查询原来
    // 0.9~6.3 秒，串行等它完了才取作品，首屏一直转圈；并行后
    // 作品到了就撤转圈出网格，分类 chips 到了再补。
    await Future.wait([_loadCategories(), _loadPage(reset: true)]);
    if (!mounted || generation != _generation) return;
    // 地址池后台建、不堵首屏；点卡时 _playWork 会等它建好。
    _fallbackLoad = _loadFallback();
    await _fallbackLoad;
  }

  /// 该女优作品里实际存在的分类（只含非空分类，按作品数排）：
  /// 空分类的作品不产生标签；分类随同步/镜像补记而变，刷新作品
  /// 时重取。
  Future<void> _loadCategories() async {
    final person = _person;
    if (person == null) return;
    final generation = _generation;
    final categories = await widget.database.workCategories(person.localId);
    if (!mounted || generation != _generation) return;
    setState(() => _categories = categories);
  }

  /// 批量按番号取库里条目（2026-11-22 女优库加载优化）：
  /// 真实提供方（MultiDbFilmFallback / FilmLibraryService）一次
  /// 主键 IN 取回全部番号，不再逐条 LIKE 扫表；其它实现（含测试
  /// 替身）逐条回落。批量方法没放进 FilmDbFallbackProvider 接口
  ///（测试替身都是 implements，接口多方法就编不过），所以这里
  /// 按运行时类型分发。
  Future<List<ActressJsonEntry>> _dbEntriesForCodes(
    ActressJsonFallback fallback,
    List<String> codeKeys, {
    String? site,
  }) async {
    if (codeKeys.isEmpty) return const [];
    final provider = fallback.filmDb;
    if (provider == null) return const [];
    try {
      if (provider is MultiDbFilmFallback) {
        return await provider.entriesForCodes(codeKeys, site: site);
      }
      if (provider is FilmLibraryService) {
        return await provider.entriesForCodes(codeKeys, site: site);
      }
      final out = <ActressJsonEntry>[];
      for (final codeKey in codeKeys) {
        out.addAll(await fallback.dbEntriesForCode(codeKey, site: site));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 库里存的播放地址池（只供点播用，从不渲染）：按女优名 + 已加载
  /// 作品番号，只从本地 db（MYTV/db/ 下多 .db 合并，见
  /// MultiDbFilmFallback）取行；同番号的条目必须留在池里——
  /// _playWork 按番号匹配存的地址播（2026-11-22 用户令：女优库
  /// 全部播放只走数据库里的数据，不读内置 json/m3u、不跨站现取）。
  /// 不调 fallback.load()：那是读本地 json 文件的，DB 行不
  /// 依赖它（活树留了这行调用，这里是死负担，去掉）。
  Future<void> _loadFallback() async {
    final person = _person;
    if (person == null) return;
    final fallback = widget.fallback ?? ActressJsonFallback();
    // DB 提供方接法（与列表页同一接法）：测试注入的 filmDb 优先；
    // 测试注入的 fallback 不接提供方，保持老行为。列表页传来的
    // fallback 自带 filmDb，这里不动它。
    final injectedFilmDb = widget.filmDb;
    if (injectedFilmDb != null) {
      fallback.filmDb = injectedFilmDb;
    } else if (widget.fallback == null) {
      fallback.filmDb ??= _multiDb ??= MultiDbFilmFallback(
        database: widget.database,
      );
    }
    final site = widget.siteFilter == ActressSiteFilter.all
        ? null
        : widget.siteFilter.siteId;
    final localCodes = {
      for (final work in _works)
        if (work.codeKey.isNotEmpty) work.codeKey,
    };
    final seen = <String>{};
    final merged = <ActressJsonEntry>[];
    void addAll(List<ActressJsonEntry> rows) {
      for (final entry in rows) {
        final dedup = '${entry.site}|${entry.mergeKey}';
        if (seen.contains(dedup)) continue;
        seen.add(dedup);
        merged.add(entry);
      }
    }

    // 2026-11-23 v58 验机修复：地址池分两段上屏——第一段只走主库
    // （FilmLibraryService，IN 主键取，毫秒级），建好立刻 setState，
    // 点卡不再干等；第二段再走多库合并（外来 .db 是全表 LIKE 扫，
    // 库大时要几分钟），补进来再 setState 一次。原来两段串行完才
    // 一次 setState，池子建得慢时 _playWork 的 15 秒超时一到就按
    // 空池子报“库里暂无播放地址”，其实地址都在库里。
    final provider = fallback.filmDb;
    final FilmLibraryService? primary;
    if (provider is MultiDbFilmFallback) {
      primary = provider.primary;
    } else if (provider is FilmLibraryService) {
      primary = provider;
    } else {
      primary = null;
    }
    if (primary != null) {
      try {
        for (final name in [person.displayName, ...person.aliases]) {
          addAll(await primary.entriesForActress(name, site: site));
        }
        final codes = localCodes.toList();
        if (codes.isNotEmpty) {
          addAll(await primary.entriesForCodes(codes, site: site));
        }
      } catch (_) {
        // 主库这段失败不堵第二段（多库合并里还会再试主库一次）。
      }
      if (mounted && merged.isNotEmpty) {
        setState(() => _fallbackEntries = merged);
      }
    }

    // 第二段：多库合并（主库 + MYTV/db/ 下其它 .db），补进来再上屏。
    try {
      for (final name in [person.displayName, ...person.aliases]) {
        addAll(await fallback.dbEntriesForActress(name, site: site));
      }
      final codes = localCodes.toList();
      if (codes.isNotEmpty) {
        addAll(await _dbEntriesForCodes(fallback, codes, site: site));
      }
    } catch (_) {
      // 第二段失败不丢第一段的池子。
    }
    // （修仙版口径：只走数据库——魔蚁 v63 第三段“who's.json 索引补
    // 直链”不在这里合：库里没有的番号不补在线地址，见 REPORT。）
    if (!mounted) return;
    setState(() => _fallbackEntries = merged);
    // 数据库封面兜底（2026-11-21，DB 行不是 json/m3u）：无封面作品
    // 按番号去库里（主库 + 其它 .db）要一次封面——用户库里本来就
    // 存着这张剧照，没必要留灰块。只贴本页已加载的作品，来源记 'db'。
    await _attachDbCovers(fallback);
  }

  /// 数据库封面兜底（2026-11-21）：按番号去库里（主库 + 其它 .db）
  /// 要一次封面——用户库里本来就存着这张剧照，没必要留灰块。只贴
  /// 本页已加载的作品，来源记 'db'。
  Future<void> _attachDbCovers(ActressJsonFallback fallback) async {
    final person = _person;
    final provider = fallback.filmDb;
    if (person == null || provider == null) return;
    // 2026-11-22 加载优化：无封面作品的番号一次批量取封面，
    // 不再逐部调 entriesForCode 全表扫（见 _loadFallback）。
    final uncovered = <ActressWork>[
      for (final work in _works)
        if (!work.hasCover && work.codeKey.isNotEmpty) work,
    ];
    if (uncovered.isEmpty) return;
    List<ActressJsonEntry> rows;
    try {
      rows = await _dbEntriesForCodes(fallback, [
        for (final work in uncovered) work.codeKey,
      ]);
    } catch (_) {
      return;
    }
    final picByCode = <String, String>{};
    for (final entry in rows) {
      if (entry.vodPic.isEmpty) continue;
      picByCode.putIfAbsent(entry.codeKey, () => entry.vodPic);
    }
    var attached = false;
    for (final work in uncovered) {
      final pic = picByCode[normalizeAvCode(work.codeKey)];
      if (pic == null) continue;
      await widget.database.attachCover(
        personId: person.localId,
        codeKey: work.codeKey,
        titleKey: work.titleKey,
        coverSource: 'db',
        coverDramaId: '',
        coverUrl: pic,
        insertIfMissing: false,
        site: 'db',
      );
      attached = true;
    }
    if (attached && mounted) await _reloadWorks();
  }

  /// 原地刷新已加载的作品（封面补上后网格实时更新，不动滚动位置）。
  Future<void> _reloadWorks() async {
    final person = _person;
    if (person == null) return;
    final generation = _generation;
    final count = _dbWorksCount;
    if (count == 0 && _works.isEmpty) return;
    final works = await widget.database.worksForPerson(
      person.localId,
      offset: 0,
      limit: count,
      category: _selectedCategory,
    );
    final filteredTotal = await widget.database.countWorks(
      person.localId,
      category: _selectedCategory,
    );
    final freshPerson = await widget.database.personById(person.localId);
    if (!mounted || generation != _generation) return;
    setState(() {
      _works = works;
      _dbWorksCount = works.length;
      _jsonWorksCount = 0;
      _filteredTotal = filteredTotal;
      _hasMore = works.length < filteredTotal;
      if (freshPerson != null) _person = freshPerson;
    });
    await _loadCategories();
    // json 补的作品重新补（封面刷新不丢 json 行）。
    unawaited(_supplementJsonWorks());
  }

  void _onScroll() {
    if (_loadingMore || !_hasMore || _loading) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 600) {
      unawaited(_loadPage());
    }
  }

  Future<void> _loadPage({bool reset = false}) async {
    final person = _person;
    if (person == null) return;
    if (reset) {
      final generation = _generation;
      // 首次进页显示全屏转圈；切换分类时保留旧网格，等新数据到了
      // 再换，不闪“暂无作品”。
      final firstLoad = _works.isEmpty && _loading;
      if (firstLoad) {
        setState(() {
          _loading = true;
          _works = [];
          _hasMore = true;
        });
      }
      final works = await widget.database.worksForPerson(
        person.localId,
        offset: 0,
        limit: _pageSize,
        category: _selectedCategory,
      );
      final filteredTotal = await widget.database.countWorks(
        person.localId,
        category: _selectedCategory,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _works = works;
        _dbWorksCount = works.length;
        _jsonWorksCount = 0;
        _filteredTotal = filteredTotal;
        // 无筛选时头顶总数就是数据库总数（json 补上后在 _supplementJsonWorks
        // 里再加）；选了分类不改头顶总数。
        if (_selectedCategory == null) _headerTotal = filteredTotal;
        _hasMore = works.length < filteredTotal;
        _loading = false;
      });
      // 首屏先出数据库作品，json 补的作品后台接上（不 await，不堵首屏）。
      unawaited(_supplementJsonWorks());
      return;
    }
    if (_loadingMore || !_hasMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    final works = await widget.database.worksForPerson(
      person.localId,
      offset: _dbWorksCount,
      limit: _pageSize,
      category: _selectedCategory,
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _works = [..._works, ...works];
      _dbWorksCount += works.length;
      _hasMore = _works.length < _filteredTotal;
      _loadingMore = false;
    });
  }

  /// who's.json 内置索引补作品（用户 2026-11-23 21:50 令：女优用 json+db，
  /// 修仙版收窄为只补库里行：索引只当番号发现器，补进来的作品一律
  /// 是按番号在本地库里查到的行；库里没有的番号不补在线作品）：
  /// 首屏先显示数据库作品，索引在后台建好后把 json 里有、库里没有的
  /// 番号对应的本地库行补到列表末尾（json 没有日期，排在数据库作品后面）。
  /// 只在无分类筛选时补——json 视频没有分类（type_name 全是日本AV），
  /// 选了分类时只显示数据库里有真实分类的作品，不硬凑。
  /// 不堵首屏：调用方先 setState 显示数据库作品，再调这里（不 await），
  /// 索引建好后补进来再 setState 一次。
  Future<void> _supplementJsonWorks() async {
    final person = _person;
    if (person == null) return;
    // 选了分类不补；已补过不再补（翻页不重复）。
    if (_selectedCategory != null || _jsonWorksCount > 0) return;
    final generation = _generation;
    WhosJsonIndex index;
    try {
      index = await WhosJsonIndex.instance;
    } catch (_) {
      return;
    }
    if (!mounted || generation != _generation) return;
    if (index.isEmpty) return;
    // 该演员在索引里的全部番号（人名 + 别名都查，合并去重）。
    final codes = <String>{};
    for (final name in [person.displayName, ...person.aliases]) {
      codes.addAll(index.codesForActor(name));
    }
    if (codes.isEmpty) return;
    // 库里已有的番号不重复补（按归一化番号比）。
    final inDb = <String>{
      for (final work in _works)
        if (work.codeKey.isNotEmpty) normalizeAvCode(work.codeKey),
    };
    final missing = <String>[
      for (final code in codes)
        if (!inDb.contains(normalizeAvCode(code))) code,
    ];
    if (missing.isEmpty) return;
    // 先按 JSON 番号查本地库（2026-11-24 用户令：内置 JSON 索引本地库，
    // 不同步也能出片播放）：库里有行就按本地库行出片（本地封面/分类/
    // 播放地址），库里没有的行不补（修仙版口径：只走数据库）。素人标签下有番号的
    // 作品已按番号归到真女优名下（合并映射），这里按番号取库行时只认
    // 番号、不认 video_actress 的素人标签。分批查（每批 100 个番号），
    // 避免一次 IN 太大撞上 SQLite 变量上限。
    final extra = <ActressWork>[];
    final resolved = <String>{};
    try {
      final fallback = widget.fallback ?? ActressJsonFallback();
      final injectedFilmDb = widget.filmDb;
      if (injectedFilmDb != null) {
        fallback.filmDb = injectedFilmDb;
      } else if (widget.fallback == null) {
        fallback.filmDb ??=
            _multiDb ??= MultiDbFilmFallback(database: widget.database);
      }
      final site = widget.siteFilter == ActressSiteFilter.all
          ? null
          : widget.siteFilter.siteId;
      final entries = <ActressJsonEntry>[];
      for (var i = 0; i < missing.length; i += 100) {
        final end = (i + 100).clamp(0, missing.length);
        entries.addAll(
          await _dbEntriesForCodes(
            fallback,
            missing.sublist(i, end),
            site: site,
          ),
        );
      }
      final seenKeys = <String>{};
      for (final entry in entries) {
        final key = normalizeAvCode(entry.vodId);
        if (key.isEmpty) continue;
        // 同番号两站各留一条（与列表去重口径一致）；同一站内只留一条。
        if (!seenKeys.add('${entry.site}|$key')) continue;
        resolved.add(key);
        extra.add(_dbEntryToWork(entry, person.localId));
      }
    } catch (_) {
      // 本地库查不到就不再补（修仙版口径：只走数据库——魔蚁 v63
      // “库里没有的行走 who's 在线目录”那段不在这里合，见 REPORT）。
    }
    if (extra.isEmpty) return;
    if (!mounted || generation != _generation) return;
    // 再确认一次筛选没变（用户可能在索引加载时切了分类）。
    if (_selectedCategory != null) return;
    setState(() {
      _works = [..._works, ...extra];
      _jsonWorksCount = extra.length;
      _filteredTotal += extra.length;
      _headerTotal = _filteredTotal;
      _hasMore = _works.length < _filteredTotal;
    });
  }

  /// 本地库行（按 JSON 番号查到）转作品卡片（对照 videoLibraryWorkFromRow）：
  /// id 留 0（不是人物关联表的行，热换库时 _refetchWork 直接留原样）；
  /// 封面/分类/日期都取本地库行，不走 who's 目录。
  ActressWork _dbEntryToWork(ActressJsonEntry entry, int personId) {
    final code = entry.vodId;
    return ActressWork(
      id: 0,
      personId: personId,
      codeKey: code,
      titleKey: code,
      site: entry.site,
      codeDisplay: code,
      title: entry.vodName,
      date: entry.vodPubdate,
      coverSource: entry.site,
      coverDramaId: code,
      coverUrl: entry.vodPic,
      category: entry.typeName,
    );
  }

  /// 按 id 在当前库里重取一部作品（热换库后用）：新库里没有了返回 null。
  /// id 为 0 的作品都来自 JSON 补充（按 JSON 番号查到的本地库行），
  /// 直接返回原作品，不按“新库里没有了”处理。
  Future<ActressWork?> _refetchWork(ActressWork work) async {
    // id 为 0 的作品都来自 JSON 补充（按 JSON 番号查到的本地库行）：
    // 它们不在人物关联表里，按人重取查不到，留原样；
    // 播放地址由重建的地址池按番号兜底，不在这里丢掉。
    if (work.id == 0) return work;
    final person = _person;
    if (person == null) return null;
    final works = await widget.database.worksForPerson(
      person.localId,
      offset: 0,
      limit: _works.length + 60,
      category: _selectedCategory,
    );
    for (final candidate in works) {
      if (work.id != 0 && candidate.id == work.id) return candidate;
      if (work.id == 0 &&
          candidate.codeKey == work.codeKey &&
          candidate.titleKey == work.titleKey) {
        return candidate;
      }
    }
    return null;
  }

  /// 点卡进播放页（只走数据库，2026-11-22 用户令）：
  /// 点卡只试库里存的地址（按番号匹配、同番号多条逐条 resolve +
  /// 验活，最多 3 条，首条活的进详情页播）；探活全失败也拿库里
  /// 第一条进播放页（探针 403/405 不等于播不了）；库里没有这个
  /// 番号、或库里一条地址都没有，才报“库里暂无播放地址”。
  /// 不跨站现取、不竞速、不落回内置 json/m3u。池子没建好时
  /// 最多等 2 秒（2026-11-24 秒进改法；原来等 15 秒）。
  Future<void> _playWork(ActressWork work) async {
    if (_findingSource) return;
    // 2026-11-20 热换库：播之前先看库文件变了没有——变了就关旧连接
    // 重开，再按当前库重取这部作品与兜底条目，不播缓存的旧地址。
    // 重读失败留旧库并报原因，不崩；作品在新库里没有了就提示并
    // 刷新列表，不硬播。
    var currentWork = work;
    final reload = await widget.database.reloadIfChanged();
    if (reload.error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(actressReloadErrorText(reload.error!))),
      );
    }
    if (reload.reloaded && mounted) {
      final fresh = await _refetchWork(work);
      if (!mounted) return;
      if (fresh == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('这部作品在新库里没有了')));
        await _loadPage(reset: true);
        return;
      }
      currentWork = fresh;
      _fallbackLoad = _loadFallback();
      await _fallbackLoad;
      if (!mounted) return;
    }
    // 取地址：池子第一段（主库 IN 主键取，毫秒级）建好就立刻
    // setState 进 _fallbackEntries，进页后点卡时基本已在。
    // 池子还没建好（刚进页就点卡）最多等 2 秒，不再等整个池子
    // （第二段多库 LIKE 扫要几分钟；原来等 15 秒）。
    // 2026-11-22 用户令（只走数据库）：点卡只试库里存的地址，不再
    // 往下探内置 json/m3u、也不再跨站探活；库里没有这个番号、或库里
    // 的地址全都验不活，就报“库里暂无播放地址”。
    final playGeneration = ++_playGeneration;
    final cancel = Completer<void>();
    setState(() {
      _findingSource = true;
    });
    // 库里这个人名下、番号相同的地址行（_fallbackEntries 现在只有 DB 行）。
    // 2026-11-22 修复：作品侧 codeKey 是库里的 vod_id 原样（rki-6042），
    // 兜底条目的 codeKey 是归一化番号（RKI6042）——直接比字符串永远
    // 不相等，导致库里 32 万条直链一条都取不到、点播放只能去跨站爬。
    // 统一归一化比较，见 jsonEntriesForWorkCode。
    List<ActressJsonEntry> dbRows = jsonEntriesForWorkCode(
      _fallbackEntries,
      currentWork.codeKey,
    );
    // 通用库作品没有番号（codeKey 为空、标题里才有番号）时按标题
    // 匹配池子条目：池子里的同一条作品就是从通用库读出来的，
    // 标题相同；标题归一化后为空时不匹配（见 jsonEntriesForWorkTitle）。
    if (dbRows.isEmpty && currentWork.codeKey.trim().isEmpty) {
      dbRows = jsonEntriesForWorkTitle(
        _fallbackEntries,
        currentWork.displayTitle,
      );
    }
    if (dbRows.isEmpty) {
      final poolLoad = _fallbackLoad;
      if (poolLoad != null) {
        try {
          await poolLoad.timeout(const Duration(seconds: 2));
        } catch (_) {
          // 超时：按当前池子走，不在点播里卡住。
        }
        if (!mounted) return;
        dbRows = jsonEntriesForWorkCode(
          _fallbackEntries,
          currentWork.codeKey,
        );
        if (dbRows.isEmpty && currentWork.codeKey.trim().isEmpty) {
          dbRows = jsonEntriesForWorkTitle(
            _fallbackEntries,
            currentWork.displayTitle,
          );
        }
      }
    }
    if (dbRows.isEmpty) {
      // 库里没有可播地址（没有这部、没有直链）：只报这一句，
      // 不落回内置、不探活、不弹去搜索。不进详情页。
      // 2026-11-23：但视频库模式下本页明明有作品（_works 非空）却一条
      // 地址都没取到时，不是“库里没地址”，是影视库那路没打开/没查到
      // ——报实情，别让用户以为库是空的。
      if (!mounted) return;
      final noAddressMessage =
          widget.database.isVideoLibrary && _works.isNotEmpty
          ? '库里没读出这部作品的地址（先检查 MYTV/db/ 下的库文件）'
          : '库里暂无播放地址';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(noAddressMessage)));
      // 早退不走下面的 try/finally：这里把找源中的标记复位，否则
      // 下一次点卡会被开头的 _findingSource 守卫直接挡掉。
      if (mounted && playGeneration == _playGeneration) {
        setState(() {
          _findingSource = false;
        });
      }
      return;
    }
    DramaDetail? storedDetail;
    try {
      // 只试库里存的地址：逐条 resolve + 验活，首条活的直接进详情页播
      //（来源就是条目自己的站，parse=0 直链 + 该站的头）；最多试 3 条，
      // 点取消立即停。
      for (final entry in dbRows.take(3)) {
        if (cancel.isCompleted || playGeneration != _playGeneration) break;
        final detail = entry.toDramaDetail();
        try {
          final plan = await widget.repository
              .resolve(detail.drama, detail.episodes.first)
              .timeout(const Duration(seconds: 8));
          if (cancel.isCompleted || playGeneration != _playGeneration) break;
          // 解析型计划验不了活：不冒进，算这条库里地址不可直播。
          if (plan.needsParse) continue;
          final uri = Uri.tryParse(plan.url.trim());
          if (uri == null ||
              !(uri.scheme == 'http' || uri.scheme == 'https') ||
              uri.host.isEmpty) {
            continue;
          }
          final response = await _verifyFetch(
            plan.url,
            plan.headers,
            const Duration(seconds: 5),
          );
          if (!feedProbePlayable(uri, response)) continue;
          storedDetail = detail;
          break;
        } catch (_) {
          // 这条死了：换库里下一条地址。
          continue;
        }
      }
    } finally {
      if (mounted && playGeneration == _playGeneration) {
        setState(() {
          _findingSource = false;
        });
      }
    }
    if (!mounted || cancel.isCompleted || playGeneration != _playGeneration) {
      return;
    }
    if (storedDetail != null) {
      await _openDetail(storedDetail);
      return;
    }
    // 2026-11-22 主树修法（保留）：探活全失败也拿库里第一条进播放页。
    // 不少流媒体站只认播放器头、探针拿 403/405，但播放器能播；
    // 探活不过不等于播不了。仍是只走数据库（第一条就是库里地址），
    // 不落回内置、不跨站。只当第一条真有地址才进（playUrl 为空
    // 说明这行根本没地址，进播放页也没用）；库里一条地址都没有
    // 才报暂无。
    if (dbRows.isNotEmpty && dbRows.first.playUrl.isNotEmpty) {
      await _openDetail(dbRows.first.toDramaDetail());
      return;
    }
    // 库里没有可播地址（没有这部、没有直链、或存的地址全死）：
    // 只报这一句，不落回内置、不探活、不弹去搜索。
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('库里暂无播放地址')),
    );
  }

  /// 库里地址直进播放页：首选线路进页即播（contentLoader 直接回库里
  /// 的直链，不再经站详情）。不接探活链——无链可续，播耗尽时播放器
  /// 只按自身线路走。
  ///
  /// 修仙版没有魔蚁的 DetailScreen（详情页 + 站内播放器一体页）：
  /// 这里直接推修仙版 PlayerPage（见 actress_adapter_player.dart），
  /// 集表就是库里这条详情的集（单集“正片”），取流走仓储 resolve。
  Future<void> _openDetail(DramaDetail detail) async {
    await pushPlayer<void>(
      context,
      detail: detail,
      initialIndex: 0,
      repository: widget.repository,
      store: widget.store,
      playerFactory: widget.playerFactory,
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final person = _person;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: actressNeonAppBar(title: Text(person?.displayName ?? '女优详情')),
      body: Stack(
        children: [
          _loading
              ? const Center(child: CircularProgressIndicator())
              : person == null
              ? Center(
                  child: Text(
                    _noDatabase
                        ? '未找到外置数据库：请把 女优库.db 放进 MYTV/db/，再点“重新加载数据库”'
                        : '人物不存在',
                  ),
                )
              : CustomScrollView(
                  controller: _scrollController,
                  slivers: [
                    SliverToBoxAdapter(child: _buildHeader(person, colors)),
                    // 分类标签筛选（2026-11-20 用户令新增）：另起一行，
                    // 与头顶“无码”“推荐”人物标签无关。只显示该女优
                    // 作品里实际存在的分类；无分类的作品只在“全部”
                    // 里，不产生标签。
                    if (_works.isNotEmpty && _categories.isNotEmpty)
                      SliverToBoxAdapter(child: _buildCategoryFilter()),
                    // 播放地址池一直不显示（2026-11-20 用户定：内置
                    // 播放源不能让别人看出来），只做后台点播用（只读
                    // 女优库.db，见 _playWork）。本地零作品时只显示
                    // “暂无作品”，不再为地址池留位置。
                    if (_works.isEmpty)
                      const SliverFillRemaining(
                        child: Center(child: Text('暂无作品')),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        sliver: SliverGrid(
                          gridDelegate: dramaGridDelegate(
                            context,
                            MediaQuery.sizeOf(context).width - 24,
                          ),
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            if (index >= _works.length) {
                              return const Center(
                                child: CircularProgressIndicator(),
                              );
                            }
                            final work = _works[index];
                            return DramaTile(
                              key: ValueKey('actress-work-${work.id}'),
                              drama: actressWorkDrama(work),
                              repository: widget.repository,
                              subtitle: actressWorkSubtitle(work),
                              onTap: () => _playWork(work),
                            );
                          }, childCount: _works.length + (_hasMore ? 1 : 0)),
                        ),
                      ),
                  ],
                ),
        ],
      ),
    );
  }

  Widget _buildHeader(ActressPerson person, ColorScheme colors) {
    final sexLabel = actressSexLabel(person.sex);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ActressAvatar(
            avatarUrl: person.avatarUrl,
            name: person.displayName,
            radius: 36,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  person.displayName,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  '作品 ${_headerTotal > 0 ? _headerTotal : person.displayWorks} 部'
                  '${sexLabel.isEmpty ? '' : ' · $sexLabel'}',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
                if (person.aliases.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '别名：${person.aliases.join(' / ')}',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
                if (person.tags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tag in person.tags)
                        Chip(
                          label: Text(tag),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 分类标签筛选行：横向滑动；第一个是“全部”，后面是该女优作品里
  /// 实际存在的分类（带部数，0 部的分类不出现）。点中只筛当前这个
  /// 女优的作品列表，头顶总数不动。
  Widget _buildCategoryFilter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _categoryChip(
              label: '全部',
              selected: _selectedCategory == null,
              onTap: () => _selectCategory(null),
            ),
            for (final category in _categories)
              _categoryChip(
                label: '${category.name}（${category.count}）',
                selected: _selectedCategory == category.name,
                onTap: () => _selectCategory(category.name),
              ),
          ],
        ),
      ),
    );
  }

  Widget _categoryChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActressNeonPill(
        key: ValueKey('actress-category-$label'),
        label: label,
        selected: selected,
        onTap: onTap,
      ),
    );
  }

  Future<void> _selectCategory(String? category) async {
    if (_selectedCategory == category) return;
    setState(() => _selectedCategory = category);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    await _loadPage(reset: true);
  }
}
