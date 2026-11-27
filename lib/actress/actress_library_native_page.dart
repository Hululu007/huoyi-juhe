// 演员库原生页（2026-11-26 用户改令：演员库区域的 UI 照魔蚁合并页
// 版式用原生控件重做，网页壳路线作废）。
//
// 版式：最顶导航栏一带平铺（页首「演员库」标题 + 六个站名
// 平铺成排 + 数据库管理钮，同处一行，2026-11-27 11:17 用户
// 令站名与页首平铺、不再单独占标题下方一行）+ 搜索、一级
// 页签、二级分类条、卡片网格。
// 三个源（2026-11-27 用户令：演员库模块删除 who's 在线源）：
// - 女优库（本地，默认）：走 ActressLibraryDbFallback 的只读
//   查询 ops（list / search / works / actresses / tags /
//   detail），分类照 whos 官方五维（最新 / 排行榜 / 演员 /
//   标签 + 20 厂牌二级条）；查询层已整体排除硬线类型，本页
//   不另设口子、不直查数据库表。
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

import 'actress_adapter_repository.dart';
import 'actress_db_manage_page.dart';
import 'actress_adapter_store.dart';
import 'actress_avatar.dart';
import 'actress_javdb_api.dart' show JavdbApiClient;
import 'actress_error_text.dart';
import 'actress_ios_import.dart';
import 'actress_library_db.dart';
import 'actress_list_page.dart';
import 'actress_magnet_state.dart';
import 'actress_models.dart' show actressNameKey;
import 'actress_mytv_bind.dart';
import 'actress_neon.dart';
import 'actress_nvku_page.dart';
import 'actress_online_parse.dart'
    show OnlineTabOption, OnlineVideoCard, av123CodeOf;
import 'actress_online_sources.dart';
import 'actress_py_lines.dart';
import 'actress_site_bridge.dart';
import 'actress_work_detail_page.dart';

/// 本地源一级页签（照 whos 官方五维的前四维，厂牌是二级条）。
const _localTabs = ['最新', '排行榜', '演员', '标签'];

/// 磁力三态徽标配色（照魔蚁口径）：网盘可播绿 / 离线中橙 /
/// 未下载灰。
Color _magnetStateColor(MagnetDriveState state) => switch (state) {
  MagnetDriveState.drivePlayable => const Color(0xFF55B16C),
  MagnetDriveState.offlineRunning => const Color(0xFFE8A33D),
  MagnetDriveState.notDownloaded => const Color(0xFF9E9E9E),
};

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

/// 在线源页签顺序（与统一搜索分段顺序一致）：123AV / PH
/// 走 Dart 直连，MissAV / 潮流走 py 桥，18AV 走 Dart 直连
/// 移植。2026-11-27 用户令：演员库模块删除 who's 在线源，
/// who's 不许回来；MJV 与潮流共用同一种子、浏览面重复，
/// 不单设页签（只进详情页竞速后补线）。

/// 单次加载超时：挂住的查询也要落到错误态，不许无限转圈。
const _loadTimeout = Duration(seconds: 20);

class ActressLibraryNativePage extends StatefulWidget {
  const ActressLibraryNativePage({
    super.key,
    required this.repository,
    required this.store,
    this.fallback,
    this.bind,
    this.onlineFetch,
    this.magnetStateResolver,
    this.initialActress,
    this.initialTag,
    this.initialActressQuery,
    this.initialSearchQuery,
  });

  /// 入口下钻（首页全局搜索「演员段」点卡 / 作品段「更多」
  /// 等外部入口用）：非空时进页直接停在该演员的作品下钻，
  /// 与页内点演员行同一条路（_openWorks 的落点状态）。
  final String? initialActress;

  /// 入口下钻：非空时进页直接停在该标签的作品下钻。
  final String? initialTag;

  /// 入口筛选（全局搜索「演员段更多」用）：非空时进页停在
  /// 演员页签并按名筛选（op actresses 的 q），筛选 chip 可清。
  final String? initialActressQuery;

  /// 入口搜索（全局搜索「作品段更多」用）：非空时进页把该
  /// 词放进统一搜索并直接出结果，与页内手打搜索同一条路。
  final String? initialSearchQuery;

  final AppRepository repository;
  final LocalStore store;

  /// 磁力三态解析器（测试/预览注入假件；生产缺省现建默认
  /// 解析器，接 115 任务/已提交表，见 actress_magnet_state）。
  final MagnetDriveStateResolver? magnetStateResolver;

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
/// 123AV / PH 都走 Dart 直连（cards + 页签 id）。
class _OnlineState {
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

  /// null = 本地女优库段（localItems 是库行 Map）；非空 =
  /// 在线源段（cards 是 Dart 直连卡）。
  final String? sourceId;
  var localItems = <Map<String, dynamic>>[];
  var cards = <OnlineVideoCard>[];
  var loading = true;
  String? error;

  int get count => sourceId == null ? localItems.length : cards.length;
}

class _ActressLibraryNativePageState extends State<ActressLibraryNativePage> {
  late ActressLibraryDbFallback _fallback =
      widget.fallback ?? ActressLibraryDbFallback();
  ActressMytvBind get _bind => widget.bind ?? ActressMytvBind.instance;

  late final ActressOnlineClient _onlineClient = ActressOnlineClient();
  ActressOnlineFetch get _onlineFetch =>
      widget.onlineFetch ?? _onlineClient.get;

  final _searchController = TextEditingController();

  /// 当前源：0 本地女优库（默认）、1 123AV、2 PH。
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

  // ---- 磁力分类（导入库登记，动态组） ----
  /// 磁力分类组：生效库为导入槽且登记非空时才有（登记只写
  /// 导入槽，查询层在别的库上查不到登记表、自然回空）。
  var _magnetCategories = <({String name, int count})>[];

  /// 当前选中的磁力分类：非空时内容区出该分类的并集作品
  /// 网格（主分类 ∪ 登记，谓词在查询层），顶部带回退 chip。
  String? _magnetCategory;

  /// 作品卡三态徽标快照（按 vodId）：列表加载后用解析器快照
  /// 合成，只对含磁力地址的作品有值；不逐卡查网盘。
  final _magnetStates = <String, MagnetDriveState>{};
  final _magnetBadgePending = <String>{};

  /// 演员页签的名字筛选（外部入口带入，见 widget.initialActressQuery）：
  /// 非空时演员页签只出名字含该词的演员，分类区出可清的筛选 chip。
  var _actressNameQuery = '';

  // ---- 在线源浏览态 ----
  /// py 桥（MissAV / 潮流页签与取流共用，经仓储既有 py
  /// 机件调种子蜘蛛）。
  late final ActressPyBridge _pyBridge = ActressPyBridge(widget.repository);

  /// 可浏览在线源（源条顺序）：123AV → PH → MissAV →
  /// 潮流 → 18AV → 片库桥接站平铺（2026-11-27 用户令，
  /// 见 actress_site_bridge.dart 注册表）。
  late final List<ActressOnlineSource> _browsableSources = [
    kActressOnlineSources[0],
    kActressOnlineSources[1],
    ...actressPyBrowsableSources(_pyBridge),
    kActressOnlineSources[2],
    ...actressBridgedLibrarySources(_pyBridge),
  ];

  List<(String, String)> get _onlineTabs => [
    for (final source in _browsableSources) (source.id, source.label),
  ];

  ActressOnlineSource? _sourceById(String id) {
    for (final source in _browsableSources) {
      if (source.id == id) return source;
    }
    return null;
  }

  late final _online = <String, _OnlineState>{
    for (final source in _browsableSources) source.id: _OnlineState(),
  };

  // ---- 搜索态 ----
  var _searching = false;
  var _searchSections = <_SearchSection>[];
  var _searchGeneration = 0;

  var _generation = 0;

  String get _onlineSourceId => _browsableSources[_sourceIndex - 1].id;

  @override
  void initState() {
    super.initState();
    // 外部入口下钻/筛选（首页全局搜索）：在首帧加载前把落点
    // 状态摆好，_loadLocal 直接按落点取数，不先闪一遍默认列表。
    final initialActress = widget.initialActress?.trim() ?? '';
    final initialTag = widget.initialTag?.trim() ?? '';
    if (initialActress.isNotEmpty) {
      _worksActress = initialActress;
    } else if (initialTag.isNotEmpty) {
      _worksTag = initialTag;
    }
    final actressQuery = widget.initialActressQuery?.trim() ?? '';
    if (actressQuery.isNotEmpty) {
      _localTab = 2;
      _actressNameQuery = actressQuery;
    }
    unawaited(_loadLocal(reset: true));
    unawaited(_loadMagnetCategories());
    final searchQuery = widget.initialSearchQuery?.trim() ?? '';
    if (searchQuery.isNotEmpty) {
      _searchController.text = searchQuery;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_submitSearch());
      });
    }
  }

  bool get _inMagnet => _magnetCategory != null;

  /// 磁力分类组加载：查询层回登记分类（名 + 并集计数）；没
  /// 登记/读不到回空组，分类栏就不出这一组。
  Future<void> _loadMagnetCategories() async {
    try {
      final result = await _fallback
          .handle({'op': 'magnetCategories'})
          .timeout(_loadTimeout);
      if (!mounted || result['ok'] != true) return;
      final categories = <({String name, int count})>[
        for (final row in (result['categories'] as List? ?? const []))
          if (row is Map && (row['name'] ?? '').toString().isNotEmpty)
            (
              name: (row['name'] ?? '').toString(),
              count: (row['count'] as num?)?.toInt() ?? 0,
            ),
      ];
      setState(() {
        _magnetCategories = categories;
        // 选中分类被删库带走了：退出磁力下钻回最新。
        if (_magnetCategory != null &&
            !categories.any((c) => c.name == _magnetCategory)) {
          _magnetCategory = null;
          unawaited(_loadLocal(reset: true));
        }
      });
    } catch (_) {
      // 磁力组读不到不拖垮本地分类栏：保持空组不出。
    }
  }

  /// 卡片三态徽标合成：本页新作品先批量取磁力地址（查询层
  /// 一次查），再用解析器快照一次合成（任务列表 + 已提交表
  /// 各取一次），不逐卡查网盘。没有磁力地址的作品不算、不
  /// 显示徽标；解析失败保持无徽标，不拖垮列表。
  Future<void> _resolveMagnetBadges(
    List<Map<String, dynamic>> rows,
  ) async {
    final targets = <String>[];
    final codeByVodId = <String, String>{};
    for (final row in rows) {
      final vodId = (row['vodId'] ?? '').toString();
      if (vodId.isEmpty) continue;
      if (_magnetStates.containsKey(vodId)) continue;
      if (!_magnetBadgePending.add(vodId)) continue;
      targets.add(vodId);
      final code = (row['code'] ?? '').toString();
      codeByVodId[vodId] = code.isNotEmpty ? code : vodId;
    }
    if (targets.isEmpty) return;
    try {
      final result = await _fallback
          .handle({'op': 'magnetUrls', 'vodIds': targets})
          .timeout(_loadTimeout);
      if (result['ok'] != true) return;
      final raw = result['urls'];
      if (raw is! Map || raw.isEmpty) return;
      final refs = <MagnetWorkRef>[
        for (final entry in raw.entries)
          if (entry.value is List && (entry.value as List).isNotEmpty)
            MagnetWorkRef(
              vodId: entry.key.toString(),
              code:
                  codeByVodId[entry.key.toString()] ??
                  entry.key.toString(),
              magnetUrls: [
                for (final url in entry.value as List) url.toString(),
              ],
            ),
      ];
      if (refs.isEmpty) return;
      final resolver =
          widget.magnetStateResolver ?? MagnetDriveStateResolver();
      final states = await resolver.snapshotForWorks(refs);
      if (!mounted || states.isEmpty) return;
      setState(() => _magnetStates.addAll(states));
    } catch (_) {
      // 徽标合成失败不挡列表：这一页就没徽标，下次加载再试。
    } finally {
      _magnetBadgePending.removeAll(targets);
    }
  }

  void _pickMagnetCategory(String name) {
    if (_magnetCategory == name) return;
    setState(() {
      _magnetCategory = name;
      _worksActress = null;
      _worksTag = null;
    });
    unawaited(_loadLocal(reset: true));
  }

  void _closeMagnet() {
    setState(() => _magnetCategory = null);
    unawaited(_loadLocal(reset: true));
  }

  @override
  void dispose() {
    _preheatHandle.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// 头像预热句柄/取数（与详情页同一份缓存、同一套 key）：
  /// 页面退出 cancel 即停，不阻塞切换。
  final _preheatHandle = ActressAvatarPreheatHandle();
  var _preheatQueued = false;
  late final ActressAvatarBytesFetcher _avatarFetcher =
      javdbAvatarBytesFetcher(JavdbApiClient());

  /// 演员列表加载后后台预热：合并行里没头像地址的演员按作
  /// 品数从高到低排队去 JavDB 补、落本地缓存（策略见
  /// actress_avatar.dart 的 actressAvatarPreheat：每轮 20
  /// 人、间隔 800 毫秒、只进缓存不回写库）。网格里的占位
  /// 会经缓存更新通知自动换图。
  void _startAvatarPreheat() {
    final candidates = <({String name, int count})>[];
    for (final row in _mergedActresses(_localActresses)) {
      final avatar = (row['avatar'] ?? '').toString();
      // 有效口径：占位地址（站根/通用未知图/相对路径）算
      // 没头像、照样排队（actressAvatarUrlUsable）。
      if (actressAvatarUrlUsable(avatar)) continue;
      final name = (row['name'] ?? '').toString();
      if (name.isEmpty) continue;
      final count = row['count'];
      candidates.add((name: name, count: count is num ? count.toInt() : 0));
    }
    if (candidates.isEmpty) return;
    unawaited(
      actressAvatarPreheat(
        candidates: candidates,
        fetcher: _avatarFetcher,
        handle: _preheatHandle,
      ),
    );
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
      } else if (_inMagnet) {
        result = await _fallback
            .handle({
              'op': 'magnetWorks',
              'category': _magnetCategory,
              'page': page,
            })
            .timeout(_loadTimeout);
      } else if (_localTab == 1) {
        result = await _fallback
            .handle({'op': 'list', 'kind': 'rank'})
            .timeout(_loadTimeout);
      } else if (_localTab == 2) {
        result = await _fallback
            .handle({
              'op': 'actresses',
              'page': page,
              if (_actressNameQuery.isNotEmpty) 'q': _actressNameQuery,
            })
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
          _localError = actressDbErrorText(
            result['error'],
            fallback: '本地女优库不可用',
          );
        });
        return;
      }
      List<Map<String, dynamic>>? badgeRows;
      setState(() {
        _localLoading = false;
        _localLoaded = true;
        _localError = null;
        if (_localTab == 3 && !_inWorks && !_inMagnet) {
          _localTags = [
            for (final row in (result['tags'] as List? ?? const []))
              Map<String, dynamic>.from(row as Map),
          ];
          _localHasMore = false;
        } else if (_localTab == 2 && !_inWorks && !_inMagnet) {
          final rows = [
            for (final row in (result['actresses'] as List? ?? const []))
              Map<String, dynamic>.from(row as Map),
          ];
          _localActresses = more ? [..._localActresses, ...rows] : rows;
          _localPage = page;
          _localHasMore = rows.length >= 24;
          _preheatQueued = true;
        } else {
          final rows = [
            for (final row in (result['items'] as List? ?? const []))
              Map<String, dynamic>.from(row as Map),
          ];
          _localItems = more ? [..._localItems, ...rows] : rows;
          _localPage = page;
          // 排行榜固定 50 条单页，不分页。
          _localHasMore = _localTab == 1 && !_inMagnet
              ? false
              : rows.length >= 24;
          badgeRows = rows;
        }
      });
      if (badgeRows != null) {
        unawaited(_resolveMagnetBadges(badgeRows!));
      }
      if (_preheatQueued) {
        _preheatQueued = false;
        _startAvatarPreheat();
      }
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _localLoading = false;
        _localLoaded = true;
        _localError = actressErrorText(
          error,
          fallback: '本地女优库加载失败，点按重试',
        );
      });
    }
  }

  void _pickLocalTab(int tab) {
    if (_localTab == tab && !_inWorks && !_inMagnet) return;
    setState(() {
      _localTab = tab;
      _worksActress = null;
      _worksTag = null;
      _magnetCategory = null;
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
      _magnetCategory = null;
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

  /// 演员显示层同名合并（2026-11-27 用户令，只改显示不动库）：
  /// 归一化键 = 库层既有 actressNameKey（去全部空白含全角空格、
  /// 小写）再叠一层全角 ASCII 转半角。同键多行合并成一张卡：
  /// 显示名与头像取第一行非空值，作品数取最大值不相加（库里
  /// 同名多行本是同一人的重复计数，相加会虚增）。
  List<Map<String, dynamic>> _mergedActresses(
    List<Map<String, dynamic>> rows,
  ) {
    final order = <String>[];
    final byKey = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final name = (row['name'] ?? '').toString();
      final key = actressNameKey(_halfWidth(name));
      if (key.isEmpty) continue;
      final count = (row['count'] as num?)?.toInt() ?? 0;
      final existing = byKey[key];
      if (existing == null) {
        order.add(key);
        byKey[key] = {...row, 'count': count};
        continue;
      }
      if (count > ((existing['count'] as num?)?.toInt() ?? 0)) {
        existing['count'] = count;
      }
      if ((existing['avatar'] ?? '').toString().isEmpty &&
          (row['avatar'] ?? '').toString().isNotEmpty) {
        existing['avatar'] = row['avatar'];
      }
    }
    return [for (final key in order) byKey[key]!];
  }

  /// 全角 ASCII（！-～ 与全角空格）转半角，供名字归一化用。
  String _halfWidth(String text) {
    final buffer = StringBuffer();
    for (final unit in text.codeUnits) {
      if (unit == 0x3000) {
        buffer.writeCharCode(0x20);
      } else if (unit >= 0xFF01 && unit <= 0xFF5E) {
        buffer.writeCharCode(unit - 0xFEE0);
      } else {
        buffer.writeCharCode(unit);
      }
    }
    return buffer.toString();
  }

  // ================= 在线源 =================

  Future<void> _loadOnline(String sourceId, {bool more = false}) async {
    final state = _online[sourceId]!;
    if (state.loading) return;
    if (more && !state.hasMore) return;
    final page = more ? state.page + 1 : 1;
    setState(() => state.loading = true);
    try {
      await _loadDartOnline(sourceId, state, page: page, more: more);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        state.loading = false;
        state.loaded = true;
        state.error = actressErrorText(
          error,
          fallback: '这个源暂时取不到内容，点按重试',
        );
      });
    }
  }

  /// 123AV / PH 的 Dart 直连加载（2026-11-27 照魔蚁修正版
  /// 移植的新链，替代 jar 旧链）：页签取卡、空页即止。
  /// 桥接站（actress_site_bridge）同走此路，首拉前先装
  /// 源站真实分类进页签。
  Future<void> _loadDartOnline(
    String sourceId,
    _OnlineState state, {
    required int page,
    required bool more,
  }) async {
    final source = _sourceById(sourceId)!;
    if (state.primaryId.isEmpty) {
      state.primaryId = source.defaultPrimaryId;
      state.secondaryId = source.defaultSecondaryId;
    }
    if (!more && source is ActressBridgedSiteSource) {
      await source.ensureTabs(widget.repository);
      if (!mounted) return;
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
        for (final (id, label) in _onlineTabs)
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
            unawaited(_resolveMagnetBadges(section.localItems));
          } else {
            section.error = actressDbErrorText(
              result['error'],
              fallback: '本地女优库不可用',
            );
          }
        });
      } catch (error) {
        if (!mounted || generation != _searchGeneration) return;
        setState(() {
          section.loading = false;
          section.error = actressErrorText(
            error,
            fallback: '本地搜索失败，点按重试',
          );
        });
      }
    }());
    // 在线段：逐段填充、互不拖累（Dart 直连与 py 桥同走
    // fetchCards 接口，py 源忽略 fetch 参数走仓储机件）。
    for (final (id, _) in _onlineTabs) {
      unawaited(() async {
        final section = _searchSections
            .where((row) => row.sourceId == id)
            .firstOrNull;
        final source = _sourceById(id);
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
            section.error = actressErrorText(
              error,
              fallback: '搜索失败，点按重试',
            );
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
    unawaited(_loadMagnetCategories());
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
                  key: const ValueKey('native-manage-dual-page'),
                  leading: const Icon(
                    Icons.swap_horiz_rounded,
                    color: Neon.cyan,
                  ),
                  title: const Text(
                    '数据库管理页（导入/激活）',
                    style: TextStyle(color: Neon.text),
                  ),
                  subtitle: const Text(
                    '导入 .db / .sql 激活演员库（需带版本字段）',
                    style: TextStyle(color: Neon.textDim, fontSize: 12),
                  ),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => const ActressDbManagePage(),
                      ),
                    );
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
    );
  }

  /// 最顶导航栏（2026-11-27 11:17 用户令：站名与页首平
  /// 铺）：标题「演员库」+ 六个站名平铺成排 + 数据库管理
  /// 钮，同处页面最顶一行。站名区占中间弹性宽，放不下在
  /// 栏内横向滑动；标题与管理钮固定两端、不被挤走（管
  /// 理/导入入口必须够得着）。原标题下方独立源条行已撤，
  /// 内容区随之上移。
  Widget _topBar() {
    return Container(
      key: const ValueKey('native-source-bar'),
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
          const SizedBox(width: 10),
          Expanded(child: _sourceStrip()),
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
                  selected: _localTab == index && !_inWorks && !_inMagnet,
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
          else if (_inMagnet)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: ActressNeonPill(
                key: const ValueKey('native-magnet-back'),
                label: '磁力：$_magnetCategory ✕',
                selected: true,
                onTap: _closeMagnet,
            ),
          )
          else if (_localTab == 2 && _actressNameQuery.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: ActressNeonPill(
                key: const ValueKey('native-actress-query-clear'),
                label: '演员名：$_actressNameQuery ✕',
                selected: true,
                onTap: () {
                  setState(() => _actressNameQuery = '');
                  unawaited(_loadLocal(reset: true));
                },
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
          // 磁力分类组（动态）：导入磁力分类库后才出现，点分类
          // 按并集谓词出片；下钻/作品下钻时不出（已有回退 chip）。
          if (!_inWorks && !_inMagnet && _magnetCategories.isNotEmpty)
            SizedBox(
              key: const ValueKey('native-magnet-group'),
              height: 42,
              child: Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(left: 12, right: 2),
                    child: Text(
                      '磁力',
                      style: TextStyle(
                        color: Neon.textDim,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(6, 4, 12, 4),
                      itemCount: _magnetCategories.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final category = _magnetCategories[index];
                        return Center(
                          child: ActressNeonPill(
                            key: ValueKey(
                              'native-magnet-cat-${category.name}',
                            ),
                            label: '${category.name} · ${category.count}',
                            selected: false,
                            compact: true,
                            onTap: () => _pickMagnetCategory(category.name),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    }
    final id = _onlineSourceId;
    // Dart 直连源的页签行：123AV 一行栏目；PH 两行（排序 +
    // 分类）。选中态以 state 里的页签 id 为准（未加载时用
    // 源缺省页签）。
    final source = _sourceById(id)!;
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

  Widget _browseBody() {
    if (_sourceIndex == 0) return _localBody();
    final id = _onlineSourceId;
    final state = _online[id]!;
    final count = state.cards.length;
    if (state.loading && count == 0) {
      return const Center(child: CircularProgressIndicator(color: Neon.pink));
    }
    if (state.error != null && count == 0) {
      return _stateArea(
        message: state.error!,
        retryLabel: '重试',
        onRetry: () => unawaited(_loadOnline(id)),
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
        itemBuilder: (context, index) => _onlineCard(
          _sourceById(id)!,
          state.cards[index],
          badge: null,
        ),
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
    if (_inWorks || _inMagnet || _localTab == 0 || _localTab == 1) {
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
      // 演员页签：三列网格卡（2026-11-27 用户令），显示层先做
      // 同名合并（见 _mergedActresses），只改显示不动库数据。
      final merged = _mergedActresses(_localActresses);
      if (_localLoaded && merged.isEmpty) {
        return _stateArea(
          message: _actressNameQuery.isNotEmpty
              ? '没有名字含「$_actressNameQuery」的演员'
              : '本地库里暂时没有演员数据',
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
          key: const ValueKey('native-actress-grid'),
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
          itemCount: merged.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 12,
            crossAxisSpacing: 10,
            childAspectRatio: 0.78,
          ),
          itemBuilder: (context, index) {
            final row = merged[index];
            final name = (row['name'] ?? '').toString();
            final avatar = (row['avatar'] ?? '').toString();
            final count = row['count'];
            return InkWell(
              key: ValueKey('native-actress-$name'),
              onTap: () => _openWorks(actress: name),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                decoration: actressNeonCardDecoration(radius: 10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 52,
                      height: 52,
                      child: ClipOval(
                        child: ActressAvatar(
                          name: name,
                          avatarUrl: avatar,
                          avatarFetcher: _avatarFetcher,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Neon.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '作品 $count 部',
                      style: const TextStyle(
                        color: Neon.textDim,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
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
    // 分段一次性建出（不懒建）：段数固定三段、每段只出第一页结果，
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
                  : _onlineCard(
                      _sourceById(section.sourceId!)!,
                      section.cards[index],
                      badge: section.label,
                    ),
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
    final magnetState = _magnetStates[vodId];
    return _posterCard(
      key: ValueKey('native-work-$vodId'),
      title: (item['title'] ?? '').toString(),
      pic: (item['pic'] ?? '').toString(),
      subtitle: subtitle,
      badge: badge,
      magnetText: magnetState == null ? null : '115 · ${magnetState.label}',
      magnetColor: magnetState == null
          ? null
          : _magnetStateColor(magnetState),
      placeholder: code.isEmpty ? 'NV' : code,
      onTap: () => _openLocalDetail(item),
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
    String? magnetText,
    Color? magnetColor,
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
          if (magnetText != null && magnetColor != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_outlined, size: 12, color: magnetColor),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      magnetText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: magnetColor, fontSize: 10.5),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 站名平铺条（嵌在最顶导航栏里、与页首同行，2026-11-27
  /// 11:17 用户令）：女优库（本地，默认）/ 123AV / PH /
  /// MissAV / 潮流 / 18AV。栏内宽度有限：每段按内容定宽、
  /// 不挤变形，放不下的部分在栏内横向滑动可见。在线段一
  /// 律带「未验」小标（照 123AV/PH 现行样子：本机出口未
  /// 验通的部分如实标，手机终验为准）。
  Widget _sourceStrip() {
    final segments = <(String, String, bool)>[
      ('native-source-local', '女优库', false),
      for (final (id, label) in _onlineTabs)
        ('native-source-$id', label, true),
    ];
    return SizedBox(
      height: 40,
      child: ListView.separated(
        key: const ValueKey('native-source-bar-scroll'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        itemCount: segments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 2),
        itemBuilder: (context, i) => InkWell(
          key: ValueKey(segments[i].$1),
          onTap: () => _selectSource(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  segments[i].$2,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: _sourceIndex == i
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: _sourceIndex == i ? Neon.cyan : Neon.textDim,
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
    );
  }
}
