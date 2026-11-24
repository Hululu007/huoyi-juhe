import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../actress/actress_widgets.dart';
import '../actress/code_meta_section.dart';
import '../actress/jav_code_meta.dart';
import '../models/media_item.dart';
import '../models/playlet_comment.dart';
import '../models/series_detail.dart'
    show CastMember, SeriesDetail, SeriesRelateBook;
import '../models/related_series.dart';
import '../widgets/player/related_series_sheet.dart';
import '../services/api_client.dart';
import '../services/backend_transport.dart';
import '../services/cultivation.dart';
import '../services/drama_site_content.dart' show DramaSiteItem;
import '../services/library_store.dart';
import '../services/player_history.dart';
import '../services/shelf_store.dart';
import '../services/watched_episodes.dart' show WatchedEpisodes, watchedIndexes;
import '../widgets/home/home_design.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_shelf.dart' show homeCardExtent;
import '../widgets/player/playlet_comment_panel.dart';
import '../widgets/player/story_player_panel.dart' show SeriesStatus;
import '../widgets/series_detail/series_detail_book.dart';
import '../widgets/series_detail/series_detail_common.dart';
import '../widgets/series_detail/series_detail_episodes.dart';
import '../widgets/series_detail/series_detail_hero.dart';
import '../widgets/series_detail/series_detail_info.dart';
import '../widgets/series_detail/series_detail_reviews.dart';
import '../widgets/series_detail/series_detail_theme.dart';
import '../widgets/series_detail/series_detail_top_bar.dart';
import '../widgets/series_detail/film_inline_player.dart';
import '../widgets/series_detail/moyi_detail_theme.dart';
import 'detail_page.dart' show openBookDetail;
import 'player_page.dart' show PlayerPage;

/// 影视区（外站）详情数据：从 `DramaSiteDetail` 直译过来，不经过短剧的
/// `SeriesDetail`（短剧详情接口没有站原字段）。
///
/// 字段来源：`synopsis` = 站详情简介；`extra` = 站原字段（演员 / 年份 /
/// 地区 / 分类 / 播放线路名等，键就是源字段名）；`stills` = 详情页自带
/// 剧照（核心详情 `extra['stills']`、TVBox 详情 `stills` 字段），
/// 没有的站为空，详情页不画剧照区。
class FilmSiteDetail {
  const FilmSiteDetail({
    this.synopsis = '',
    this.extra = const {},
    this.stills = const [],
  });

  final String synopsis;
  final Map<String, String> extra;
  final List<String> stills;
}

/// 短剧详情：版式照 PR #200（`feat/series-detail-redesign`，提交 `2c3a3e3`）
/// 定稿的设计稿右机——设计稿本身不在仓库里，版式规则以下面这段为准。
///
/// 自上而下：顶栏（只有返回）→ 头部 → 播放 / 收藏 → 选集 → 简介 →
/// 剧评 → 原著小说。页面跟随应用主题（浅色 / 深色 / 墨水屏 / OLED）；
/// 剧集主色只留作顶栏后面的一条淡色带。详情接口返回空不算失败，
/// 目录失败只在选集区块内联重试。
/// Note: 入口数据复用与占位裁撤见
/// .agents/notes/implemented/bug-fix/2026-09-30-series-detail-usability.md
class SeriesDetailPage extends StatefulWidget {
  const SeriesDetailPage({
    super.key,
    required this.seriesId,
    this.kind = 'video',
    this.title = '',
    this.cover = '',
    this.episodes = const [],
    this.startIndex,
    this.initialDetail,
    this.hasPlaybackProgress = false,
    this.historyStore,
    this.onPlaySelection,
    this.watchedIds = const <String>{},
    this.seriesLoader,
    this.commentLoader,
    this.directoryLoader,
    this.onPlayEpisode,
    this.siteDetailLoader,
    this.contentLoader,
    this.relatedLoader,
    this.homeRelatedLoader,
    this.onOpenRelatedFilm,
    this.onOpenRelatedSeries,
    this.onFilmCategoryTap,
    this.engineSiteId = '',
    this.shelfKind = 'video',
  });

  final String seriesId;
  final String kind;

  /// 引擎站（导入站）详情页：收藏写引擎书架条目，否则沿用原短剧收藏。
  final String engineSiteId;

  /// 引擎站收藏进书架分区用的 kind（video 进影视架，其余进书架）。
  final String shelfKind;
  final ValueChanged<RelatedSeries>? onOpenRelatedSeries;

  /// 详情接口回来前的兜底标题/封面（宿主播放页已拉过一次 seriesDetail）。
  final String title;
  final String cover;

  /// 剧集目录：宿主已有，避免二次拉目录。
  final List<Chapter> episodes;

  /// 宿主当前集优先；null 时从本地历史恢复。
  final int? startIndex;
  final SeriesDetail? initialDetail;
  final bool hasPlaybackProgress;
  final ReaderStore? historyStore;

  /// 携带已加载目录，feed 开播放器时无需再次请求。
  final void Function(int index, List<Chapter> episodes, SeriesDetail detail)?
  onPlaySelection;

  /// 已看集 id（映射成下标给选集格子灰字）。
  final Set<String> watchedIds;

  /// 测试注入缝；默认走 `ApiClient.seriesDetail`。
  final Future<SeriesDetail> Function(String seriesId)? seriesLoader;

  /// 测试注入缝；默认走 `ApiClient.playletComments`。
  final Future<PlayletCommentPage> Function(String seriesId)? commentLoader;

  /// 目录加载器（测试缝）。宿主（播放页）已拉过目录时直接传 [episodes]；
  /// 从 feed 等没有目录的入口进来时，页面自己拉（官方详情页也持有目录），
  /// 缺省走 `ApiClient.directoryChapters(id, tab: '短剧')`。
  final Future<List<List<Chapter>>> Function(String seriesId)? directoryLoader;

  /// 点选集格或播放钮的目标行为。默认推整页播放器；宿主播放页打开
  /// 详情时传入「关闭详情 + 切集」，不叠第二个播放器。
  final ValueChanged<int>? onPlayEpisode;

  /// 影视区专属：外站详情加载器（`openDramaSiteItem` 传，内部调站
  /// `detail`，与 `directoryLoader` 共用同一份缓存详情，不多请求一次）。
  /// 为空 = 短剧入口，简介 / 线路 / 剧照三区一律不画，短剧流程零改动。
  final Future<FilmSiteDetail> Function(String seriesId)? siteDetailLoader;

  /// 影视区专属：内联播放器的取流（`openDramaSiteItem` 传站客户端的
  /// 取流，(itemId, tab) -> 取流响应）。为空时内联播放器走番茄接口，
  /// 影视区不要不传。
  final Future<Map<String, dynamic>> Function(String itemId, String tab)?
  contentLoader;

  /// 影视区专属：同站相关推荐加载器（`openDramaSiteItem` 传，按详情
  /// 分类匹配同分类目录，取不到退本站首页）。为空时不画推荐视频区。
  /// 推荐视频取本站同分类（魔蚁 `_recommendedSection` / `_loadRecommended`
  /// 同一套算法：同分类优先、凑不满 6 个用本站其他补、排除当前这部）。
  final Future<List<DramaSiteItem>> Function(String seriesId)? relatedLoader;

  /// 影视区专属：本站首页相关推荐加载器（`openDramaSiteItem` 传本站
  /// 首页目录）。魔蚁的相关推荐取详情接口自带的 `related` 列表，
  /// 修仙版站详情解析里没有 `related` 字段，改取本站首页、并排除
  /// 推荐视频区已展示的条目与当前这部。为空时不画相关推荐区。
  final Future<List<DramaSiteItem>> Function(String seriesId)?
  homeRelatedLoader;

  /// 影视区专属：点推荐卡片的打开方式（`openDramaSiteItem` 传，调
  /// `openDramaSiteItem` 进新详情页）。为空时点卡片不做事。
  final void Function(DramaSiteItem item)? onOpenRelatedFilm;

  /// 影视区专属：点魔蚁详情区分类标签的打开方式（`openDramaSiteItem`
  /// 传，调 `openFilmCategoryTag`：先按标签名匹配本站分类进浏览页，
  /// 匹配不到退站源搜索）。为空时标签只展示、不可点；短剧分支不传，
  /// 短剧头项标签保持原样不动。
  final ValueChanged<String>? onFilmCategoryTap;

  @override
  State<SeriesDetailPage> createState() => _SeriesDetailPageState();
}

class _SeriesDetailPageState extends State<SeriesDetailPage> {
  /// 选集一段 50 集（1–50 / 51–80 …）。
  static const _pageSize = 50;

  SeriesDetail _detail = SeriesDetail.empty;
  bool _detailDone = false;
  bool _detailFailed = false;
  bool _episodesFailed = false;
  bool _commentsLoading = true;
  bool _commentsFailed = false;
  bool _historyDone = false;
  bool _hasProgress = false;
  bool _shelfBusy = false;
  int _currentIndex = 0;
  Map<String, dynamic>? _savedHistory;
  Set<String> _watchedIds = {};
  Set<int> _watched = {};
  final BackendRequest _requests = BackendRequest();

  /// feed 等入口没带目录时自拉的剧集（宿主传了 [SeriesDetailPage.episodes]
  /// 就以宿主为准，不重复请求）。
  List<Chapter> _loadedEpisodes = const [];
  bool _episodesDone = false;
  PlayletCommentPage? _comments;

  /// 影视区站详情（简介 / 原字段 / 剧照）：短剧入口不加载。
  FilmSiteDetail? _filmDetail;
  bool _filmDetailDone = false;
  bool _filmDetailFailed = false;

  /// 影视区头区演员行匹配结果（番号 → 演员与导演）：站详情回来后按
  /// 番号查三站元数据 + who's 索引（与 CodeMetaSection 同一份匹配，
  /// 见 actress/code_meta_section.dart）。null = 未匹配到或尚未查完，
  /// 头区不画演员行。只在影视区入口查，短剧没有番号不查。
  CodeMeta? _codeMeta;
  int _codeMetaGeneration = 0;

  /// 影视区推荐视频：同站同分类（relatedLoader 那套算法），取 6 个；
  /// 没回来或取不到时整块不占位，不留空白块。
  List<DramaSiteItem> _recommendedItems = const [];
  bool _recommendedDone = false;
  bool _recommendedStarted = false;

  /// 影视区相关推荐：本站首页（homeRelatedLoader），排除推荐视频区
  /// 已展示的条目与当前这部，取 6 个；没回来或取不到时整块不占位。
  List<DramaSiteItem> _relatedItems = const [];
  bool _relatedDone = false;
  bool _relatedStarted = false;

  /// 推荐区卡片列宽档：与魔蚁详情页同一档（列宽 150→85；390 宽手机
  /// 4 列、单卡约 82 宽，原横排卡 120 宽）。两块推荐区共用。
  static const _recommendColumnWidth = 85.0;

  /// 有站详情加载器 = 影视区入口；短剧入口 loader 为空。
  bool get _isFilmSite => widget.siteDetailLoader != null;

  final ScrollController _scroll = ScrollController();

  /// 影视区内联播放器的键：选集切集与全屏都经它调播放器。
  final _inlinePlayerKey = GlobalKey<FilmInlinePlayerState>();

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.startIndex ?? 0;
    _hasProgress = widget.hasPlaybackProgress || _currentIndex > 0;
    _watchedIds = {...widget.watchedIds};
    _syncEpisodes();
    final initial = widget.initialDetail;
    if (initial != null && !initial.isEmpty) {
      _detail = initial;
      _detailDone = true;
    }
    unawaited(_loadHistory());
    if (!_detailDone) unawaited(_loadDetail());
    unawaited(_loadEpisodes());
    unawaited(_loadComments());
    if (_isFilmSite) unawaited(_loadFilmDetail());
  }

  @override
  void dispose() {
    _requests.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<T> _request<T>(Future<T> Function() body) =>
      ApiClient.instance.withCancellation(_requests, body);

  Future<void> _loadHistory() async {
    try {
      final store = widget.historyStore ?? LibraryStore.instance;
      final values = await Future.wait<Object?>([
        PlayerHistory(store).load(widget.seriesId),
        WatchedEpisodes(store).ids(widget.seriesId),
      ]);
      if (!mounted) return;
      _savedHistory = values[0] as Map<String, dynamic>?;
      _watchedIds.addAll(values[1] as Set<String>);
    } catch (_) {
      // 本地历史不可用不阻断目录和播放。
    }
    if (!mounted) return;
    setState(() {
      _historyDone = true;
      _syncEpisodes();
    });
  }

  void _syncEpisodes() {
    if (_episodes.isNotEmpty) {
      if (widget.startIndex == null) {
        final savedIndex = resumeEpisodeIndex(_savedHistory, _episodes);
        _currentIndex = savedIndex ?? 0;
        _hasProgress = savedIndex != null;
      }
      _currentIndex = _currentIndex.clamp(0, _episodes.length - 1);
    }
    _watched = watchedIndexes(_watchedIds, _episodes);
  }

  Future<void> _loadDetail() async {
    setState(() {
      _detailDone = false;
      _detailFailed = false;
    });
    try {
      final detail = await _request(
        () =>
            widget.seriesLoader?.call(widget.seriesId) ??
            ApiClient.instance.seriesDetail(widget.seriesId, strict: true),
      );
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _detailDone = true;
        // 空回包不是失败：目录能给的照常渲染，简介 / 演员自然为空。
        _detailFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _detailDone = true;
        _detailFailed = true;
      });
    }
  }

  Future<void> _loadFilmDetail() async {
    final loader = widget.siteDetailLoader;
    if (loader == null) return;
    setState(() {
      _filmDetailDone = false;
      _filmDetailFailed = false;
    });
    try {
      final detail = await _request(() => loader(widget.seriesId));
      if (!mounted) return;
      setState(() {
        _filmDetail = detail;
        _filmDetailDone = true;
        _filmDetailFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _filmDetailDone = true;
        _filmDetailFailed = true;
      });
    }
    _loadCodeMeta();
    _loadRecommended();
  }

  /// 影视区头区演员行：站详情回来后按番号查三站元数据 + who's 索引
  ///（与 CodeMetaSection 同一份匹配）。代次守卫：重试后旧结果不再
  /// 写回。查不到时 _codeMeta 为 null，头区不画演员行、简介区演员照常。
  Future<void> _loadCodeMeta() async {
    if (!_isFilmSite) return;
    final generation = ++_codeMetaGeneration;
    final meta = await loadCodeMetaForDrama(
      dramaId: widget.seriesId,
      title: _titleText,
      sourceId: widget.engineSiteId,
    );
    if (!mounted || generation != _codeMetaGeneration) return;
    setState(() => _codeMeta = meta);
  }

  /// 名字归一（与魔蚁详情页同一口径）：去首尾空白；“々”展开成前一字
  ///（佐々木 → 佐佐木）。简介区演员去重用。
  String _normalizeName(String name) {
    final out = StringBuffer();
    for (var i = 0; i < name.length; i++) {
      final ch = name[i];
      if (ch == '々' && out.isNotEmpty) {
        out.write(name[i - 1]);
      } else {
        out.write(ch);
      }
    }
    return out.toString().trim();
  }

  /// 头像地址是否“像能加载”：与演员库汇总同一口径——非空、且 URI 的
  /// path 不是空也不是只有 `/`（裸域名如 https://v.hersav.me/ 跳过，
  /// 当成没有头像、回落首字圆圈）。
  static String _validAvatarUrl(String url) {
    if (url.isEmpty) return '';
    final path = Uri.tryParse(url)?.path ?? '';
    if (path.isEmpty || path == '/') return '';
    return url;
  }

  /// 影视区推荐视频：同站同分类（relatedLoader 那套算法），取 6 个；
  /// 取不到整块不画。只拉一次；拉完再拉相关推荐（去重要排除这里的 id）。
  Future<void> _loadRecommended() async {
    final loader = widget.relatedLoader;
    if (loader == null) {
      // 没有推荐加载器 = 推荐视频区不存在，仍要放行相关推荐去重。
      if (mounted) setState(() => _recommendedDone = true);
      _loadRelated();
      return;
    }
    if (_recommendedStarted) return;
    _recommendedStarted = true;
    try {
      final items = await _request(() => loader(widget.seriesId));
      if (!mounted) return;
      setState(() {
        _recommendedItems = items.take(6).toList(growable: false);
        _recommendedDone = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _recommendedDone = true);
    }
    _loadRelated();
  }

  /// 影视区相关推荐：本站首页（homeRelatedLoader），排除推荐视频区
  /// 已展示的条目与当前这部，取 6 个；取不到整块不画，不留空白块。
  /// 只拉一次；推荐视频还没回来时先等它（去重要排除那边的 id）。
  Future<void> _loadRelated() async {
    final loader = widget.homeRelatedLoader;
    if (loader == null || _relatedStarted) return;
    if (!_recommendedDone) return;
    _relatedStarted = true;
    try {
      final items = await _request(() => loader(widget.seriesId));
      if (!mounted) return;
      final shown = _recommendedItems.map((item) => item.id).toSet();
      final picked = <DramaSiteItem>[];
      for (final item in items) {
        if (item.id == widget.seriesId) continue;
        if (item.title.isEmpty) continue;
        if (shown.contains(item.id)) continue;
        if (picked.any((other) => other.id == item.id)) continue;
        picked.add(item);
        if (picked.length >= 6) break;
      }
      setState(() {
        _relatedItems = picked;
        _relatedDone = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _relatedDone = true);
    }
  }

  /// 影视区站原字段（短剧入口 `_filmDetail` 为 null 时返回空串）。
  String _filmExtra(String key) => _filmDetail?.extra[key] ?? '';

  List<String> _splitFilmField(String value) => value
      .split(RegExp(r'[,，、/｜|]+'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);

  /// 影视区播放线路名：站原字段 `vod_play_from` / `play_from` / `from` /
  /// `source`（多线路用 `$$$` 隔开，见 TVBox `vod_play_from`）。
  /// 没有线路信息的站默认一行「在线播放」；注意这只是展示行——多线路的
  /// 选集本就按线路名前缀拼在集名里（`线路-集名`），不另做线路筛选，
  /// 选集仍走现有选集区。
  List<String> _filmLines() {
    for (final key in const ['vod_play_from', 'play_from', 'from', 'source']) {
      final raw = _filmExtra(key);
      if (raw.isEmpty) continue;
      final lines = raw
          .split('\$\$\$')
          .expand((part) => part.split(','))
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList(growable: false);
      if (lines.isNotEmpty) return lines.toSet().toList(growable: false);
    }
    return const ['在线播放'];
  }

  /// 影视区头项状态行：集数标签 + 年份 / 地区 / 备注（站原字段）。
  String _filmStatusLine() {
    final parts = <String>[];
    if (_detail.episodeLabel.isNotEmpty) parts.add(_detail.episodeLabel);
    for (final key in const ['year', 'area', 'remarks']) {
      final value = _filmExtra(key);
      if (value.isNotEmpty) parts.add(value);
    }
    return parts.join(' · ');
  }

  /// 影视区头项分类标签：站原字段 `category` + `tags`。
  List<String> _filmCategories() {
    final seen = <String>{};
    final result = <String>[];
    for (final value in [_filmExtra('category'), _filmExtra('tags')]) {
      for (final part in _splitFilmField(value)) {
        if (seen.add(part)) result.add(part);
      }
    }
    return result;
  }

  /// 影视区演员：站原字段 `actor` / `actress`，逗号 / 顿号分隔。
  /// 头区演员行已显示的人这里不再重复（魔蚁 `_visibleTags` 同一口径：
  /// 名字归一后比对，头区有的名字从简介区演员行里去掉）。
  List<CastMember> _filmCast() {
    final seen = <String>{};
    final result = <CastMember>[];
    final codeCast = _codeMeta?.cast.map(_normalizeName).toSet() ?? const {};
    for (final key in const ['actor', 'actress']) {
      for (final name in _splitFilmField(_filmExtra(key))) {
        if (codeCast.contains(_normalizeName(name))) continue;
        if (seen.add(name)) result.add(CastMember(actor: name));
      }
    }
    return result;
  }

  Future<void> _loadComments() async {
    setState(() {
      _commentsLoading = true;
      _commentsFailed = false;
    });
    try {
      final page = await _request(
        () =>
            widget.commentLoader?.call(widget.seriesId) ??
            ApiClient.instance.playletComments(widget.seriesId, count: 10),
      );
      if (!mounted) return;
      setState(() {
        _comments = page;
        _commentsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _commentsLoading = false;
        _commentsFailed = true;
      });
    }
  }

  Future<void> _loadEpisodes() async {
    if (widget.episodes.isNotEmpty || widget.seriesId.isEmpty) {
      _episodesDone = true;
      return;
    }
    setState(() {
      _episodesDone = false;
      _episodesFailed = false;
    });
    try {
      final volumes = await _request(
        () =>
            widget.directoryLoader?.call(widget.seriesId) ??
            ApiClient.instance.directoryChapters(
              widget.seriesId,
              tab: widget.kind == 'manju' ? '漫剧' : '短剧',
            ),
      );
      if (!mounted) return;
      setState(() {
        _loadedEpisodes = volumes
            .expand((volume) => volume)
            .toList(growable: false);
        _episodesDone = true;
        _syncEpisodes();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _episodesDone = true;
        _episodesFailed = true;
      });
    }
  }

  /// 生效剧集：宿主带的优先，否则用自拉的。
  List<Chapter> get _episodes =>
      widget.episodes.isNotEmpty ? widget.episodes : _loadedEpisodes;

  String get _titleText =>
      _detail.title.isNotEmpty ? _detail.title : widget.title;

  String get _coverText =>
      _detail.cover.isNotEmpty ? _detail.cover : widget.cover;

  /// 选集区头部右侧的状态文案（官方实机：`已完结 共105集 ›`）。
  String? get _episodeStatusText {
    final count = _detail.episodeCount > 0
        ? _detail.episodeCount
        : _episodes.length;
    return switch (_detail.status) {
      SeriesStatus.finished => count > 0 ? '已完结 共$count集' : '已完结',
      SeriesStatus.updating => count > 0 ? '更新至$count集' : '更新中',
      SeriesStatus.updateToday => '今日更新',
      SeriesStatus.updateStop => '断更',
      _ => null,
    };
  }

  /// 播放钮文案。目录失败不再是「重试加载」——重试在选集区块里；
  /// 这里只是不可播。
  String get _playLabel {
    if (!_episodesDone || !_historyDone) return '加载中…';
    if (_episodes.isEmpty) return _episodesFailed ? '暂不可播放' : '暂无剧集';
    if (_episodes[_currentIndex].disabled) return '暂不可播放';
    return _hasProgress ? '继续播放 · 第${_currentIndex + 1}集' : '立即播放';
  }

  bool get _playable =>
      _episodesDone &&
      _historyDone &&
      _episodes.isNotEmpty &&
      !_episodes[_currentIndex].disabled;

  /// 剧集主色混合到画布后的实色带顶，null 表示不出色带（灰色系 / 墨水屏）。
  Color? _bandTop(HomePalette palette) {
    final tint = seriesBandTint(_detail.seriesColorHex, palette);
    return tint == null
        ? null
        : Color.alphaBlend(tint, moyiPageGradient.colors[1]);
  }

  /// 实机状态行 = `episodeLabel · 播放量`，没有追更段（官方 `bp` 布局
  /// 只有集数与播放量）。
  String _statusLine() {
    final parts = <String>[];
    if (_detail.episodeLabel.isNotEmpty) parts.add(_detail.episodeLabel);
    if (_detail.playCount > 0) parts.add('${_detail.playLabel}次播放');
    return parts.join(' · ');
  }

  /// 影视区选集点按：不在这里推整页播放器，改由顶部内联播放器起播
  /// 该集（照火蚁TV详情页点选集直接播）。短剧仍走 [_play]。
  void _playInline(int index) {
    if (_episodes.isEmpty) return;
    final target = index.clamp(0, _episodes.length - 1);
    if (_episodes[target].disabled) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该剧集暂不可播放')));
      return;
    }
    setState(() => _currentIndex = target);
    _scrollToPlayer();
    unawaited(_inlinePlayerKey.currentState?.playEpisode(target));
  }

  /// 切集后把详情内容滚回顶部（播放器已固定在顶部常驻，滚回 0 是
  /// 让选集区回到播放器正下方）。
  void _scrollToPlayer() {
    if (!_scroll.hasClients) return;
    unawaited(
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      ),
    );
  }

  /// 内联播放器的全屏钮：内联会话已先存档 + 销毁播放器，这里只推整页
  /// 播放器（整页从历史续看；回来后点海报播放钮按最新历史续播）。
  void _openInlineFullscreen() {
    final selection = widget.onPlaySelection;
    if (selection != null) {
      selection(_currentIndex, _episodes, _detail);
      return;
    }
    if (widget.onPlayEpisode != null) {
      widget.onPlayEpisode!(_currentIndex);
      return;
    }
    _play(_currentIndex);
  }

  void _play(int index) {
    if (_episodes.isEmpty) return;
    final target = index.clamp(0, _episodes.length - 1);
    if (_episodes[target].disabled) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该剧集暂不可播放')));
      return;
    }
    if (widget.onPlaySelection != null) {
      widget.onPlaySelection!(target, _episodes, _detail);
      return;
    }
    if (widget.onPlayEpisode != null) {
      widget.onPlayEpisode!(target);
      return;
    }
    unawaited(
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            bookId: widget.seriesId,
            kind: widget.kind,
            title: _titleText.isEmpty ? '第${target + 1}集' : _titleText,
            cover: _coverText,
            eps: _episodes,
            startIndex: target,
            shortSeries: true,
            // 全集播放页是短剧，记 drama（看完一集 +300、时长记短剧）。
            cultivationCategory: CultivationCategory.drama,
            initialSeriesDetail: _detail,
            historyStore: widget.historyStore,
          ),
        ),
      ),
    );
  }

  void _openOriginalBook(SeriesRelateBook book) {
    unawaited(
      openBookDetail(
        context,
        MediaItem(
          id: book.id,
          title: book.title,
          cover: book.cover,
          author: '',
          badge: '原著小说',
          ep: '',
          kind: 'book',
        ),
      ),
    );
  }

  void _openAllComments() {
    unawaited(
      PlayletCommentPanel.show(
        context,
        seriesId: widget.seriesId,
        total: _comments?.totalCount ?? _detail.commentCount,
      ),
    );
  }

  Future<void> _openRelatedSeries() async {
    final entry = await RelatedSeriesSheet.show(context, widget.seriesId);
    if (!mounted || entry == null) return;
    final open = widget.onOpenRelatedSeries;
    if (open != null) {
      open(entry);
      return;
    }
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => SeriesDetailPage(
            seriesId: entry.id,
            kind: entry.kind,
            title: entry.title,
            cover: entry.cover,
            historyStore: widget.historyStore,
            seriesLoader: widget.seriesLoader,
            directoryLoader: widget.directoryLoader,
            commentLoader: widget.commentLoader,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    // 全页深紫蓝渐变底：内层组件靠深色主题取浅色字（影视区魔蚁详情同款
    // 做法），墨水屏不强制、保持黑白；剧照背景那套不动。
    final darkPage = !palette.eink;
    return Theme(
      data: Theme.of(
        context,
      ).copyWith(brightness: darkPage ? Brightness.dark : Brightness.light),
      child: Scaffold(
        key: const ValueKey('series-detail-page'),
        backgroundColor: Colors.transparent,
        // 影视区改内联播放器后不再要底部大播放钮（播放器就在顶部）；
        // 短剧保留。
        bottomNavigationBar: _isFilmSite ? null : _bottomPlayBar(palette),
        body: Stack(
          children: [
            Positioned.fill(child: _backdrop(palette)),
            SafeArea(
              child: Column(
                children: [
                  // 影视区：返回箭头在播放器顶栏里，这里不再另画顶栏；
                  // 短剧保留原顶栏。
                  if (!_isFilmSite)
                    SeriesDetailTopBar(
                      onBack: () => Navigator.of(context).maybePop(),
                    ),
                  // 影视区：内联播放器固定在顶部，不进滚动区（2026-11-24
                  // 用户令：详情页上下滑时播放器跟着走，要固定住）。只有
                  // 下面的详情内容（魔蚁详情 / 剧照 / 推荐）可以上下滑。
                  if (_isFilmSite) _pinnedFilmPlayer(),
                  Expanded(
                    child: CustomScrollView(
                      key: const ValueKey('series-detail-content'),
                      controller: _scroll,
                      slivers: [
                        if (_isFilmSite) ...[
                          // 影视区新顺序（照火蚁TV播放详情页）：魔蚁详情（海报 /
                          // 标题 / 集数 / 站源 / 加入追剧 / 选集 / 简介）→
                          // 本片剧照 → 相关推荐；内联播放器已固定在滚动区外，
                          // 不在这里。播放线路折进「站源」行，不再单独成区；
                          // 剧评 / 原著是短剧专属，影视区没有。
                          SliverToBoxAdapter(child: _filmMoyiDetail()),
                          SliverToBoxAdapter(child: _filmStillsSection()),
                          SliverToBoxAdapter(
                            child: _filmRecommendedSection(),
                          ),
                          SliverToBoxAdapter(child: _filmRelatedSection()),
                        ] else ...[
                          SliverToBoxAdapter(child: _hero()),
                          SliverToBoxAdapter(child: _episodeSection()),
                          SliverToBoxAdapter(child: _introSection()),
                          SliverToBoxAdapter(child: _reviewsSection()),
                          if (_detail.originalBook != null)
                            SliverToBoxAdapter(
                              child: SeriesDetailBookSection(
                                book: _detail.originalBook!,
                                onOpen: () =>
                                    _openOriginalBook(_detail.originalBook!),
                              ),
                            ),
                        ],
                        const SliverToBoxAdapter(child: SizedBox(height: 24)),
                      ],
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

  /// 详情页底部大播放钮（照对方详情页的底部「继续观看」按钮）：与头部
  /// 播放钮同文案、同动作（播当前/续看集），头部钮保留；海报本身不点播。
  Widget _bottomPlayBar(HomePalette palette) => SafeArea(
    top: false,
    child: ColoredBox(
      color: moyiSheetFill,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: FilledButton(
          key: const ValueKey('series-detail-bottom-play-button'),
          onPressed: _playable ? () => _play(_currentIndex) : null,
          style: FilledButton.styleFrom(
            backgroundColor: seriesAccent(palette),
            foregroundColor: seriesOnAccent(palette),
            disabledBackgroundColor: moyiDarkCardFill,
            disabledForegroundColor: moyiMutedOnDark,
            elevation: 0,
            minimumSize: const Size.fromHeight(52),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: const StadiumBorder(),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          child: Text(_playLabel),
        ),
      ),
    ),
  );

  /// 顶部淡色带：只铺在状态栏 + 顶栏后面（高度 = 安全区顶 + 顶栏），在
  /// 顶栏下缘淡出到画布。墨水屏 / 灰色系时整页就是画布色。
  Widget _backdrop(HomePalette palette) {
    final top = _bandTop(palette);
    final height = MediaQuery.paddingOf(context).top + seriesDetailTopBarHeight;
    return Stack(
      children: [
        Positioned.fill(
          child: const DecoratedBox(
            decoration: BoxDecoration(gradient: moyiPageGradient),
          ),
        ),
        if (top != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: height,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [top, Colors.transparent],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _hero() => ValueListenableBuilder<int>(
    valueListenable: ShelfStore.instance.listenable,
    builder: (context, _, _) => SeriesDetailHero(
      title: _titleText,
      coverUrl: ApiClient.instance.absoluteUrl(_coverText),
      // 影视区：状态行 / 分类标签走站原字段（年份 / 地区 / 备注 / 分类），
      // 短剧走详情接口的原字段。
      statusLine: _isFilmSite ? _filmStatusLine() : _statusLine(),
      categories: _isFilmSite ? _filmCategories() : _detail.categories,
      playLabel: _playLabel,
      playEnabled: _playable,
      onPlay: () => _play(_currentIndex),
      saved: ShelfStore.instance.contains(
        widget.shelfKind,
        widget.engineSiteId.isEmpty
            ? widget.seriesId
            : 'engine:${widget.engineSiteId}:${widget.seriesId}',
      ),
      shelfEnabled: widget.seriesId.isNotEmpty,
      shelfBusy: _shelfBusy,
      onToggleShelf: _toggleShelf,
    ),
  );

  Widget _episodeSection() => SeriesDetailEpisodes(
    episodes: _episodes,
    currentIndex: _currentIndex,
    watched: _watched,
    initialRange: _currentIndex ~/ _pageSize,
    pageSize: _pageSize,
    statusText: _episodes.isEmpty ? null : _episodeStatusText,
    hasRelatedSeries: _detail.hasRelatedSeries,
    onOpenRelatedSeries: _openRelatedSeries,
    loading: !_episodesDone,
    failed: _episodesFailed,
    onRetry: () => unawaited(_loadEpisodes()),
    // 影视区点选集格进内联播放器起播该集；短剧仍走整页播放器。
    onSelect: _isFilmSite ? _playInline : _play,
  );

  Widget _introSection() => SeriesDetailIntroSection(
    loading: !_detailDone,
    failed: _detailFailed,
    intro: _detail.intro,
    cast: _detail.cast,
    onRetry: () => unawaited(_loadDetail()),
  );

  /// 影视区简介：简介与演员都走站详情（`synopsis` / `actor` 原字段），
  /// 复用短剧简介区同一套展开 / 演员横排版式。站详情没回来时整块不画，
  /// 只有真的请求失败才给区块内重试。
  Widget _filmIntroSection() => SeriesDetailIntroSection(
    loading: !_filmDetailDone,
    failed: _filmDetailFailed,
    intro: _filmDetail?.synopsis ?? '',
    cast: _filmCast(),
    onRetry: () => unawaited(_loadFilmDetail()),
  );

  /// 影视区顶部内联播放器：固定在详情页顶部，不跟详情内容一起滑走
  /// （2026-11-24 用户令）。竖屏按 16:9 全宽；横屏时 16:9 全宽会
  /// 超出可用高，限高到屏高的 62% 并居中，保证下面的滚动区仍有
  /// 空间、Column 不溢出。
  Widget _pinnedFilmPlayer() {
    final size = MediaQuery.sizeOf(context);
    final player = _filmPlayer();
    if (size.width <= size.height) return player;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: size.height * 0.62),
        child: player,
      ),
    );
  }

  /// 影视区顶部内联播放器（照火蚁TV播放详情页）：16:9 黑色播放器，
  /// 点海报直接播；全屏走整页播放器，选集钮把选集区滚到可见处。
  Widget _filmPlayer() => FilmInlinePlayer(
    key: _inlinePlayerKey,
    seriesId: widget.seriesId,
    title: _titleText,
    coverUrl: ApiClient.instance.absoluteUrl(_coverText),
    episodes: _episodes,
    episodeIndex: _currentIndex,
    contentLoader: widget.contentLoader,
    onBack: () => Navigator.of(context).maybePop(),
    onFullscreen: _openInlineFullscreen,
    onOpenEpisodes: () {
      // 选集区在魔蚁详情里；滚到播放器下方一点让它露出来。
      if (!_scroll.hasClients) return;
      unawaited(
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        ),
      );
    },
  );

  /// 影视区魔蚁详情区（照魔蚁 box 详情页）：背景是本片剧照原图整幅显示，
  /// **不模糊**（旧毛玻璃的 `ImageFilter.blur` 已拆掉），只盖一层深紫蓝
  /// 渐变罩保证文字可读；没有剧照时回落到海报原图，仍不模糊。
  ///
  /// 自上而下是海报 + 标题 / 集数（金字）/ 站源卡片 / 加入追剧 / 选集 /
  /// 简介。整块强制深色（播放器界面本来就是深色），与应用浅色主题无关；
  /// 选集与简介两区复用现有组件，靠深色主题取浅色字。
  /// 播放线路不单独成区：线路名折进「站源」卡片（见 [_filmSourceLines]）。
  Widget _filmMoyiDetail() {
    final cover = ApiClient.instance.absoluteUrl(_coverText);
    final lines = _filmLines();
    final count = _episodes.isNotEmpty
        ? _episodes.length
        : (_detail.episodeCount > 0 ? _detail.episodeCount : 0);
    // 剧照背景取详情页自带剧照（与「本片剧照」同一来源），没有剧照时
    // 回落到海报原图。
    final stills = _filmDetail?.stills ?? const <String>[];
    final backgroundUrl = stills.isNotEmpty
        ? ApiClient.instance.absoluteUrl(stills.first)
        : cover;
    return Theme(
      data: Theme.of(context).copyWith(brightness: Brightness.dark),
      child: MoyiDetailBackground(
        imageUrl: backgroundUrl,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _filmPoster(cover),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _titleText,
                              key: const ValueKey('film-detail-title'),
                              style: moyiTitleStyle,
                            ),
                            const SizedBox(height: 8),
                            // 分类标签（站原字段 category + tags，见 _filmCategories）：
                            // 标题正下方的横排小标签，照原始版 fqapp 可点，点后按
                            // 标签筛出本站电影；没数据时整行不占位。
                            ..._filmCategoryTags(),
                            if (count > 0)
                              Text(
                                '共 $count 集 · 当前第 ${_currentIndex + 1} 集',
                                key: const ValueKey(
                                  'film-detail-episode-count',
                                ),
                                style: moyiGoldLineStyle,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // 头区演员行（番号匹配）：演员小头像 + 只留名字，放在
                  // 分类标签行下面、站源卡片上面；查不到不画本行。
                  ..._filmActorRow(),
                  const SizedBox(height: 12),
                  // 站源卡片：圆角卡片 + 紫色描边，线路名在卡片里各占一行。
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: moyiCardDecoration(radius: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _filmSourceLines(lines),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _followButton(),
                ],
              ),
            ),
            // 选集与简介复用现有区（自带左右 16 间距，与上面对齐）。
            _episodeSection(),
            _filmIntroSection(),
          ],
        ),
      ),
    );
  }

  /// 魔蚁详情头项的海报：96×136 圆角 12 + 紫色描边（对照图里卡片的
  /// 紫色描边）。封面为空时给深紫占位，不拿剧照冒充海报。
  Widget _filmPoster(String cover) {
    return Container(
      key: const ValueKey('film-detail-poster'),
      width: 96,
      height: 136,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: moyiPurple.withValues(alpha: 0.55), width: 1),
      ),
      child: cover.isEmpty
          ? const ColoredBox(
              color: Color(0xFF262543),
              child: Icon(
                Icons.movie_outlined,
                color: Colors.white54,
                size: 32,
              ),
            )
          : CachedNetworkImage(
              imageUrl: cover,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => const ColoredBox(
                color: Color(0xFF262543),
                child: Icon(
                  Icons.movie_outlined,
                  color: Colors.white54,
                  size: 32,
                ),
              ),
              placeholder: (_, _) => const ColoredBox(color: Color(0xFF262543)),
            ),
    );
  }

  /// 魔蚁详情区顶部的分类标签行：站原字段 `category` + `tags`
  /// 拆开去重后的横排小标签（`_filmCategories`）。站详情没回来
  /// （标签为空）时整行不占位；回调为空时只展示、不可点。
  List<Widget> _filmCategoryTags() {
    final categories = _filmCategories();
    if (categories.isEmpty) return const [];
    return [
      Wrap(
        key: const ValueKey('film-detail-categories'),
        spacing: 6,
        runSpacing: 6,
        children: [for (final name in categories) _filmCategoryTag(name)],
      ),
      const SizedBox(height: 8),
    ];
  }

  /// 一颗分类标签：紫底 + 紫描边胶囊 + 白字（魔蚁主题深色区里可读）。
  /// 回调在时包一层 InkWell 可点，点后把标签名交给
  /// [onFilmCategoryTap]；回调为空时就是普通展示块。
  Widget _filmCategoryTag(String name) {
    final onTap = widget.onFilmCategoryTap;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: moyiPurple.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: moyiPurple.withValues(alpha: 0.6), width: 1),
      ),
      child: Text(
        name,
        style: const TextStyle(fontSize: 12, height: 1.5, color: Colors.white),
      ),
    );
    if (onTap == null) return chip;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('film-detail-category-$name'),
        borderRadius: BorderRadius.circular(99),
        onTap: () => onTap(name),
        child: chip,
      ),
    );
  }

  /// 头区演员行（番号匹配，魔蚁 `_castChipsRow` 同一套）：演员小头像 +
  /// 只留名字（不带角色），点名字走站内标签搜索（与分类标签同一入口）；
  /// 导演跟一只“导演：X” chip。查不到元数据、或既无导演又无演员时
  /// 不占位。放在分类标签行下面、站源卡片上面。
  List<Widget> _filmActorRow() {
    final meta = _codeMeta;
    if (meta == null) return const [];
    final cast = meta.castWithAvatars;
    if (cast.isEmpty && meta.director.isEmpty) return const [];
    final onTap = widget.onFilmCategoryTap;
    return [
      const SizedBox(height: 10),
      Wrap(
        key: const ValueKey('film-detail-cast-row'),
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final actor in cast)
            _filmActorChip(actor.name, actor.avatarUrl, onTap),
          if (meta.director.isNotEmpty)
            Chip(
              key: const ValueKey('film-detail-director'),
              label: Text('导演：${meta.director}'),
              backgroundColor: moyiPurple.withValues(alpha: 0.35),
              side: BorderSide(color: moyiPurple.withValues(alpha: 0.6)),
              labelStyle: const TextStyle(fontSize: 12, color: Colors.white),
            ),
        ],
      ),
    ];
  }

  /// 一颗演员 chip：小头像（真照片，没有时回落名字首字圆圈）+ 只留名字。
  /// 回调在时可点（站内搜这个演员），回调为空时只展示。
  Widget _filmActorChip(
    String name,
    String avatarUrl,
    ValueChanged<String>? onTap,
  ) {
    final avatar = ActressAvatar(
      avatarUrl: _validAvatarUrl(avatarUrl),
      name: name,
      radius: 12,
    );
    const labelStyle = TextStyle(fontSize: 12, color: Colors.white);
    if (onTap == null) {
      return Chip(
        key: ValueKey('film-detail-cast-$name'),
        avatar: avatar,
        label: Text(name),
        backgroundColor: moyiPurple.withValues(alpha: 0.35),
        side: BorderSide(color: moyiPurple.withValues(alpha: 0.6)),
        labelStyle: labelStyle,
      );
    }
    return ActionChip(
      key: ValueKey('film-detail-cast-$name'),
      avatar: avatar,
      label: Text(name),
      onPressed: () => onTap(name),
      backgroundColor: moyiPurple.withValues(alpha: 0.35),
      side: BorderSide(color: moyiPurple.withValues(alpha: 0.6)),
      labelStyle: labelStyle,
    );
  }

  /// 「站源」行：首行带「站源：」前缀，多线路各占一行（照目标图
  /// MissAV / MissAV镜像两行的样子）。线路名取站原字段，无线路
  /// 信息默认「在线播放」。
  List<Widget> _filmSourceLines(List<String> lines) {
    final widgets = <Widget>[];
    for (var i = 0; i < lines.length; i++) {
      widgets.add(
        Text(
          i == 0 ? '站源： ${lines[i]}' : lines[i],
          key: ValueKey('film-detail-source-$i'),
          style: const TextStyle(
            fontSize: 13,
            height: 1.5,
            color: Colors.white70,
          ),
        ),
      );
    }
    return widgets;
  }

  /// 「加入追剧」：就是详情页原来的收藏（写本机书架），换成魔蚁主题的
  /// 粉紫渐变按钮 + 白字 + 下拉箭头。点按切换收藏态，箭头只作版式。
  Widget _followButton() {
    return ValueListenableBuilder<int>(
      valueListenable: ShelfStore.instance.listenable,
      builder: (context, _, _) {
        final saved = ShelfStore.instance.contains(
          widget.shelfKind,
          widget.engineSiteId.isEmpty
              ? widget.seriesId
              : 'engine:${widget.engineSiteId}:${widget.seriesId}',
        );
        return MoyiGradientButton(
          key: const ValueKey('film-detail-follow'),
          label: saved ? '已追剧' : '加入追剧',
          icon: saved ? Icons.bookmark_rounded : Icons.bookmark_add_outlined,
          trailing: const Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 18,
            color: Colors.white,
          ),
          enabled: !_shelfBusy && widget.seriesId.isNotEmpty,
          onPressed: _toggleShelf,
        );
      },
    );
  }

  /// 影视区本片剧照：取详情页自带剧照（`FilmSiteDetail.stills`），横排
  /// 滑动，点一张全屏看。站没给剧照就不画本区，不拿封面冒充。
  Widget _filmStillsSection() {
    final stills = _filmDetail?.stills ?? const <String>[];
    if (stills.isEmpty) {
      return const SizedBox.shrink(
        key: ValueKey('series-detail-stills-section'),
      );
    }
    return SeriesSection(
      key: const ValueKey('series-detail-stills-section'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SeriesSectionHeader(title: '本片剧照'),
          SizedBox(
            height: 96,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: stills.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final url = ApiClient.instance.absoluteUrl(stills[i]);
                return GestureDetector(
                  onTap: () => _openStill(url),
                  child: Container(
                    width: 160,
                    height: 96,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: moyiPurple.withValues(alpha: 0.55),
                        width: 1,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: CachedNetworkImage(
                      imageUrl: url,
                      width: 160,
                      height: 96,
                      fit: BoxFit.cover,
                      placeholder: (_, _) =>
                          const SizedBox(width: 160, height: 96),
                      errorWidget: (_, _, _) => const SizedBox(
                        width: 160,
                        height: 96,
                        child: Icon(Icons.broken_image),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 影视区推荐视频：本站同分类（relatedLoader 那套算法），取 6 个，
  /// 小卡片网格（与魔蚁 `_recommendedSection` 同一套列宽档）。
  /// 没回来或取不到时整块不占位，不留空白块；点卡片进详情页。
  Widget _filmRecommendedSection() {
    if (!_recommendedDone || _recommendedItems.isEmpty) {
      return const SizedBox.shrink(
        key: ValueKey('series-detail-recommended-section'),
      );
    }
    return _recommendGrid(
      sectionKey: 'series-detail-recommended-section',
      cardPrefix: 'film-recommended-card',
      title: '推荐视频',
      items: _recommendedItems,
    );
  }

  /// 影视区相关推荐：本站首页（homeRelatedLoader），排除推荐视频区
  /// 已展示的条目与当前这部，取 6 个，小卡片网格。
  /// 没回来或取不到时整块不占位，不留空白块；点卡片进详情页。
  Widget _filmRelatedSection() {
    if (!_relatedDone || _relatedItems.isEmpty) {
      return const SizedBox.shrink(
        key: ValueKey('series-detail-related-section'),
      );
    }
    return _recommendGrid(
      sectionKey: 'series-detail-related-section',
      cardPrefix: 'film-related-card',
      title: '相关推荐',
      items: _relatedItems,
    );
  }

  /// 推荐区小卡片网格（两块推荐区共用，魔蚁 `_recommendedSection` /
  /// `_relatedSection` 同一套列宽档）：列宽档 150→85，390 宽手机 4 列、
  /// 单卡约 82 宽（原横排卡 120 宽）；卡片是影视网格的 HomeMediaCard
  ///（封面 5:7 + 标题两行 + 一行副标题，卡高按 homeCardExtent 算）。
  Widget _recommendGrid({
    required String sectionKey,
    required String cardPrefix,
    required String title,
    required List<DramaSiteItem> items,
  }) {
    final scaler = MediaQuery.textScalerOf(context);
    return SeriesSection(
      key: ValueKey(sectionKey),
      bottom: 8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SeriesSectionHeader(title: title),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns =
                  (constraints.maxWidth / _recommendColumnWidth).floor().clamp(
                    2,
                    6,
                  );
              final tileWidth =
                  (constraints.maxWidth - (columns - 1) * 10) / columns;
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  mainAxisExtent: homeCardExtent(context, tileWidth, scaler),
                ),
                itemCount: items.length,
                itemBuilder: (_, index) {
                  final item = items[index];
                  return HomeMediaCard(
                    key: ValueKey('$cardPrefix-${item.id}'),
                    item: MediaItem(
                      id: item.id,
                      title: item.title,
                      cover: item.cover,
                      author: '',
                      badge: '',
                      ep: item.remark,
                      kind: 'film',
                    ),
                    coverWidth: tileWidth,
                    onTap: () => _openRelatedFilm(item),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }

  /// 点推荐卡进详情页：正在播时先停当前这部（内联播放器停播），
  /// 再走 onOpenRelatedFilm 进新详情页（魔蚁 `_openRelated` 同一套：
  /// 播着片点推荐先停当前，否则旧片音频继续）；没在播时照旧只进详情页。
  Future<void> _openRelatedFilm(DramaSiteItem item) async {
    try {
      await _inlinePlayerKey.currentState?.session.pause();
    } catch (_) {
      // 播放器还没起播或已销毁时 pause 不挡进详情页。
    }
    widget.onOpenRelatedFilm?.call(item);
  }

  void _openStill(String url) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          children: [
            InteractiveViewer(
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.contain,
                errorWidget: (_, _, _) => const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('剧照加载失败', style: TextStyle(color: Colors.white)),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(dialogContext),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reviewsSection() => SeriesDetailReviews(
    comments: _comments?.comments ?? const <PlayletComment>[],
    total: _comments?.totalCount ?? _detail.commentCount,
    loading: _commentsLoading,
    failed: _commentsFailed,
    onRetry: () => unawaited(_loadComments()),
    onShowAll: _openAllComments,
  );

  // ---- 收藏 ----

  Future<void> _toggleShelf() async {
    if (_shelfBusy) return;
    final shelf = ShelfStore.instance;
    if (!shelf.isReady) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('本地收藏暂不可用，请稍后重试')));
      return;
    }
    setState(() => _shelfBusy = true);
    try {
      final isEngine = widget.engineSiteId.isNotEmpty;
      final added = await shelf.toggle(
        MediaItem(
          id: isEngine
              ? 'engine:${widget.engineSiteId}:${widget.seriesId}'
              : widget.seriesId,
          seriesId: widget.seriesId,
          title: _titleText,
          cover: _coverText,
          author: '',
          badge: isEngine
              ? (widget.engineSiteId.startsWith('localdb:') ? '本地库' : '')
              : '短剧',
          ep: _detail.episodeLabel,
          kind: widget.shelfKind,
          source: isEngine ? 'engine:${widget.engineSiteId}' : '',
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(added ? '已收藏到本机书架' : '已取消收藏')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('收藏失败，请重试')));
    } finally {
      if (mounted) setState(() => _shelfBusy = false);
    }
  }
}
