import 'dart:async';
import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../services/local_media_proxy.dart' show LocalMediaProxy;
import '../services/native_player.dart' show NativePlayer;
import 'actress_avatar.dart';
import 'actress_adapter_http.dart'
    show FeedProbeFetch, feedProbePlayable, probeStreamHead;
import 'actress_adapter_repository.dart' show AppRepository;
import 'actress_error_text.dart';
import 'actress_inline_player.dart';
import 'actress_javdb_api.dart';
import 'actress_javdb_image.dart';
import 'actress_still_capture.dart';
import 'actress_library_db.dart' show ActressLibraryDbFallback;
import 'actress_neon.dart';
import 'actress_online_parse.dart'
    show OnlineDetailInfo, OnlineVideoCard, av123CodeOf;
import 'actress_online_sources.dart';
import 'actress_py_lines.dart';
import 'code_meta_section.dart' show loadCodeMetaForDrama;
import 'whos_fallback.dart' show whosSourceId;
// whosSourceId 只用于本地库番号元数据（code_meta_section 的
// 三站元数据按 whos 源 id 索引），是本地库数据管线，不是
// 在线 who's 线路（2026-11-27 已按令删除，见 _appendOnlineLines）。

/// 一条已取到的可播目标：直链 + 播放请求头。
class ActressPlayTarget {
  const ActressPlayTarget(this.url, [this.headers = const {}]);

  final String url;
  final Map<String, String> headers;
}

/// 起播前地址加工（生产走本地代理带头，测试可注入直通）。
typedef ActressPlayUrlPrep =
    Future<String> Function(String url, Map<String, String> headers);

enum _LineStatus { searching, ready, failed, empty }

/// 详情页里的一条播放线路：本地库线路开页即 ready；在线线路
/// （123AV / PH）打开详情后按番号后台搜，搜到才 ready。
/// 取流结果按线缓存，海报竞速共用同一份 resolver 期约，不
/// 重复取。线路列表自 2026-11-27 起不上屏（用户令隐藏），
/// 线路只作竞速与自动换线的内部结构，状态文案不上屏。
class _Line {
  _Line({
    required this.id,
    required this.label,
    this.target,
    this.resolver,
  }) : status = target != null ? _LineStatus.ready : _LineStatus.searching;

  final String id;
  final String label;
  ActressPlayTarget? target;
  final Future<ActressPlayTarget?> Function()? resolver;
  Future<ActressPlayTarget?>? resolveFuture;
  _LineStatus status;
  var verified = false;
  var nowPlaying = false;
  String note = '';

  Future<ActressPlayTarget?> resolve() {
    final current = target;
    if (current != null) return Future.value(current);
    return resolveFuture ??= () async {
      final found = await resolver?.call();
      if (found != null) target = found;
      return found;
    }();
  }
}

/// 作品详情页（2026-11-27 用户令，照 AvPlay 本尊版式 + 本
/// App 口径）：
///
/// 钉顶栏（小海报 + 番号 + 标题，右侧搜索/更多）→ 大海报区
/// （毛玻璃底 + 海报，海报正中央圆形播放键；点海报在**页内
/// 起播**，海报区原地变播放器钉顶，下方照常滚动，不跳播放
/// 器页）→ 大标题（旁带「翻译」切换：JavDB 给了原名/译名
/// 才出，没数据不出）→ 信息卡（番号可点复制 / 发行日期 /
/// 长度 / 制作商 / 系列 / 导演 / 评分——评分只认 JavDB 接口
/// 真数据，没数据不显示、不编；右上评分缎带同理）→ 简介
/// （有才显示）→ 相关分类 chips → 演员区（全部演员含男演
/// 员，头像本地库优先、JavDB 补）→ 剧照区（横滑 + 全部 N；
/// 来源：在线详情页自带剧照、JavDB 预览图；两者都没有时走
/// 截帧兜底——在线解析验活拿到流后无头截帧、缓存回填，见
/// actress_still_capture.dart；再没有就不显示）→ 下载链接
/// （只有 JavDB 真返回磁力才出，点按复制）→ 她们还演出过
/// （本地库按演员查，JavDB actor_movies 填空位）→ 你可能
/// 也喜欢（本地库相关作品，JavDB relative_movies 填空位）。
/// 播放线路不上屏（2026-11-27 用户令隐藏）：海报键背后自
/// 动竞速——本地女优库 → 123AV → PH 全部线路同尺验活、谁
/// 先验活谁先播，总闸 40 秒；全灭在播放区显示「暂无可播线
/// 路」，绝不无限转圈。裁决：AvPlay 的「在线平台」行与隐
/// 藏令相撞，以隐藏令为准，不摆平台行。
class ActressWorkDetailPage extends StatefulWidget {
  const ActressWorkDetailPage.local({
    super.key,
    required String vodId,
    required this.fallback,
    required this.repository,
    this.onlineFetch,
    this.javdbClient,
    this.stillCapturer,
    this.stillCache,
    this.probeFetch,
    this.playerFactory,
    this.playUrlPrep,
    this.onActress,
    this.onTag,
    this.onSearchCode,
    this.raceGate = const Duration(seconds: 40),
    this.lateLineWindow = const Duration(seconds: 35),
  }) : localVodId = vodId,
       onlineSource = null,
       onlineCard = null,
       entryCode = null,
       entryTitle = '',
       entryPoster = '';

  const ActressWorkDetailPage.online({
    super.key,
    required ActressOnlineSource source,
    required OnlineVideoCard card,
    required this.fallback,
    required this.repository,
    this.onlineFetch,
    this.javdbClient,
    this.stillCapturer,
    this.stillCache,
    this.probeFetch,
    this.playerFactory,
    this.playUrlPrep,
    this.onActress,
    this.onTag,
    this.onSearchCode,
    this.raceGate = const Duration(seconds: 40),
    this.lateLineWindow = const Duration(seconds: 35),
  }) : localVodId = null,
       onlineSource = source,
       onlineCard = card,
       entryCode = null,
       entryTitle = '',
       entryPoster = '';

  /// 按番号入口（只有番号与标题/封面的场合）：没有自有源
  /// 线路，全部线路（123AV / PH / 本地库）打开后按番号
  /// 后台搜。
  const ActressWorkDetailPage.byCode({
    super.key,
    required String code,
    String title = '',
    String poster = '',
    required this.fallback,
    required this.repository,
    this.onlineFetch,
    this.javdbClient,
    this.stillCapturer,
    this.stillCache,
    this.probeFetch,
    this.playerFactory,
    this.playUrlPrep,
    this.onActress,
    this.onTag,
    this.onSearchCode,
    this.raceGate = const Duration(seconds: 40),
    this.lateLineWindow = const Duration(seconds: 35),
  }) : localVodId = null,
       onlineSource = null,
       onlineCard = null,
       entryCode = code,
       entryTitle = title,
       entryPoster = poster;

  final String? localVodId;
  final ActressOnlineSource? onlineSource;
  final OnlineVideoCard? onlineCard;
  final String? entryCode;
  final String entryTitle;
  final String entryPoster;
  final ActressLibraryDbFallback fallback;
  final AppRepository repository;
  final ActressOnlineFetch? onlineFetch;
  final JavdbApiClient? javdbClient;

  /// 剧照截帧器（JavDB 无剧照时的兜底）：测试注入假实现，
  /// 生产缺省走 MediaKitStillCapturer。
  final ActressStillCapturer? stillCapturer;

  /// 截帧缓存：测试注入临时目录版，生产缺省走 App 缓存目录。
  final ActressStillCache? stillCache;
  final FeedProbeFetch? probeFetch;
  final NativePlayer Function()? playerFactory;
  final ActressPlayUrlPrep? playUrlPrep;
  final void Function(String name)? onActress;
  final void Function(String tag)? onTag;
  final void Function(String code)? onSearchCode;

  /// 主竞速总闸（本地 + Dart 直连 + py 同层线）：到点还没
  /// 有验活赢家就转入后补线等待，不许无限转圈。测试可调短。
  final Duration raceGate;

  /// 后补线（MJV 现拉，整链约 45 秒）在主竞速全灭后额外
  /// 等待的窗口：窗口内后补线验活即接上起播，窗口耗尽才
  /// 定「暂无可播线路」。测试可调短。
  final Duration lateLineWindow;

  @override
  State<ActressWorkDetailPage> createState() => _ActressWorkDetailPageState();
}

class _ActressWorkDetailPageState extends State<ActressWorkDetailPage> {
  late final ActressOnlineClient _onlineClient = ActressOnlineClient();
  late final JavdbApiClient _javdb = widget.javdbClient ?? JavdbApiClient();

  /// py 桥（MissAV / 潮流索引 / MJV 现拉三线共用）：经
  /// 仓储既有 py 机件调种子蜘蛛，验活探针与竞速同源。
  late final ActressPyBridge _pyBridge = ActressPyBridge(
    widget.repository,
    verifyFetch: widget.probeFetch,
  );

  /// 后补线（MJV 现拉）：不进主竞速总闸，开页即后台现拉，
  /// 主线先播后它验活完只入换线池；主线全灭时在
  /// [lateLineWindow] 窗口内等它接上（见 _playBest）。
  final _lateLines = <_Line>[];

  ActressOnlineFetch get _fetch => widget.onlineFetch ?? _onlineClient.get;

  var _loading = true;
  String? _loadError;

  var _code = '';
  var _title = '';

  /// 译名/原名（JavDB origin_title 或 JavDB 标题，与当前标
  /// 题不同才有）：大标题旁出「翻译」切换，没数据不显示。
  var _altTitle = '';
  var _showAltTitle = false;

  /// 下载链接（JavDB 磁力真数据）：没数据整区不出、不编造。
  var _magnets = <JavdbMagnet>[];

  var _poster = '';
  var _date = '';
  var _duration = '';
  var _maker = '';
  var _series = '';
  var _director = '';
  var _score = '';
  var _scoreCount = 0;
  var _synopsis = '';
  var _typeName = '';
  var _tags = <String>[];
  var _cast = <({String name, String avatar})>[];
  final _stills = <String>[];
  final _lines = <_Line>[];
  var _alsoStarred = <Map<String, dynamic>>[];
  var _mayLike = <Map<String, dynamic>>[];

  String? _playingLineId;
  String? _playingUrl;
  var _playBusy = false;
  String? _playError;
  final _autoTried = <String>{};
  var _generation = 0;

  bool get _isOnlineEntry => widget.onlineCard != null;

  @override
  void initState() {
    super.initState();
    if (_isOnlineEntry) {
      final card = widget.onlineCard!;
      final source = widget.onlineSource!;
      _code = source.id == '123av' ? av123CodeOf(card.pageUrl) : '';
      _title = card.title;
      _poster = card.cover;
      _loading = false;
      _setupLinesForOnlineEntry();
      _startSupplements();
    } else if (widget.entryCode != null) {
      _code = widget.entryCode!;
      _title = widget.entryTitle;
      _poster = widget.entryPoster;
      _loading = false;
      _appendOnlineLines();
      _startSupplements();
    } else {
      unawaited(_loadLocalDetail());
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  // ================= 数据装配 =================

  Future<void> _loadLocalDetail() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final result = await widget.fallback
          .handle({'op': 'detail', 'vodId': widget.localVodId!})
          .timeout(const Duration(seconds: 20));
      if (!mounted || generation != _generation) return;
      if (result['ok'] != true || result['item'] is! Map) {
        setState(() {
          _loading = false;
          _loadError = actressDbErrorText(
            result['error'],
            fallback: '详情没拉到，点按重试',
          );
        });
        return;
      }
      final item = Map<String, dynamic>.from(result['item'] as Map);
      setState(() {
        _loading = false;
        _code = (item['vodId'] ?? widget.localVodId!).toString();
        _title = (item['title'] ?? '').toString();
        _poster = (item['pic'] ?? '').toString();
        _date = (item['date'] ?? '').toString();
        _typeName = (item['typeName'] ?? '').toString();
        _synopsis = (item['content'] ?? '').toString().trim();
        _tags = [
          for (final row in (item['tags'] as List? ?? const []))
            row.toString(),
        ];
        _cast = [
          for (final row in (item['actressInfo'] as List? ?? const []))
            if (row is Map)
              (
                name: (row['name'] ?? '').toString(),
                avatar: (row['avatar'] ?? '').toString(),
              ),
        ];
        if (_cast.isEmpty) {
          _cast = [
            for (final row in (item['actresses'] as List? ?? const []))
              (name: row.toString(), avatar: ''),
          ];
        }
        final playUrls = [
          for (final row in (item['playUrls'] as List? ?? const []))
            row.toString(),
        ];
        _lines
          ..clear()
          ..addAll([
            for (var i = 0; i < playUrls.length; i++)
              _Line(
                id: 'local-$i',
                label: playUrls.length > 1 ? '女优库 · 线路${i + 1}' : '女优库',
                target: ActressPlayTarget(playUrls[i]),
              ),
          ]);
        _mayLike = [
          for (final row in (item['related'] as List? ?? const []))
            if (row is Map) Map<String, dynamic>.from(row),
        ];
      });
      _appendOnlineLines();
      _startSupplements();
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _loadError = actressErrorText(
          error,
          fallback: '详情没拉到，点按重试',
        );
      });
    }
  }

  void _setupLinesForOnlineEntry() {
    final source = widget.onlineSource!;
    final card = widget.onlineCard!;
    _lines.add(
      _Line(
        id: 'dart-${source.id}',
        label: source.label,
        resolver: () async {
          final play = await source
              .resolvePlay(card, fetch: _fetch)
              .timeout(const Duration(seconds: 35));
          _fillFromOnlineInfo(play.detail);
          return ActressPlayTarget(play.streamUrl, play.headers);
        },
      ),
    );
    _appendOnlineLines(includeSelf: false);
  }

  /// 在线线追加（本地作品与在线作品共用）：123AV/PH/18AV
  /// 走 Dart 直连、MissAV 与潮流索引走 py 桥（同层竞速）、
  /// （在线作品时）本地库按番号反查一条；MJV 现拉整链约
  /// 45 秒、超过主竞速总闸，单独作后补线（_lateLines），
  /// 不进主竞速。竞速顺序：本地女优库（开页即在的本地
  /// 线路 / 按番号反查）→ 123AV → PH → 18AV → MissAV →
  /// 潮流索引。2026-11-27 用户令：演员库删除 who's 在线
  /// 线路（片库 who's py 站本体不动）。加完即启动后台
  /// 搜索，互不阻塞。
  void _appendOnlineLines({bool includeSelf = true}) {
    if (_code.isEmpty) return;
    for (final source in kActressLineSources) {
      if (!includeSelf && source.id == widget.onlineSource?.id) continue;
      if (_lines.any((line) => line.id == 'dart-${source.id}')) continue;
      _lines.add(
        _Line(
          id: 'dart-${source.id}',
          label: source.label,
          resolver: () => _resolveDartLine(source),
        ),
      );
    }
    if (widget.onlineSource?.id != 'missav') {
      _lines.add(
        _Line(
          id: 'py-missav',
          label: 'MissAV',
          resolver: () => _pyBridge
              .playMissavByCode(_code)
              .timeout(const Duration(seconds: 35)),
        ),
      );
    }
    if (widget.onlineSource?.id != 'chaoliu') {
      _lines.add(
        _Line(
          id: 'py-chaoliu-index',
          label: '潮流',
          resolver: () => _pyBridge
              .playChaoliuIndex(_code)
              .timeout(const Duration(seconds: 35)),
        ),
      );
    }
    _lateLines.add(
      _Line(
        id: 'py-mjv-live',
        label: 'MJV',
        resolver: () => _pyBridge
            .playChaoliuLive(_code)
            .timeout(const Duration(seconds: 90)),
      ),
    );
    if (_isOnlineEntry || widget.entryCode != null) {
      _lines.add(
        _Line(
          id: 'local-by-code',
          label: '女优库',
          resolver: _resolveLocalByCode,
        ),
      );
    }
    for (final line in _lines) {
      if (line.resolver != null && line.status == _LineStatus.searching) {
        unawaited(_runLineSearch(line));
      }
    }
    // 后补线开页即后台现拉（resolve 期约已缓存，_playBest
    // 等它时不重复取）。
    for (final line in _lateLines) {
      if (line.resolver != null && line.status == _LineStatus.searching) {
        unawaited(_runLineSearch(line));
      }
    }
  }

  Future<void> _runLineSearch(_Line line) async {
    try {
      final target = await line.resolve();
      if (!mounted) return;
      setState(() {
        if (target != null) {
          line.status = _LineStatus.ready;
        } else {
          line.status = _LineStatus.empty;
          line.note = '未找到';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        line.status = _LineStatus.failed;
        line.note = _lineErrorText(error);
      });
    }
  }

  Future<ActressPlayTarget?> _resolveDartLine(
    ActressOnlineSource source,
  ) async {
    final cards = await source
        .fetchCards(
          primaryId: source.defaultPrimaryId,
          secondaryId: source.defaultSecondaryId,
          query: _code,
          page: 1,
          fetch: _fetch,
        )
        .timeout(const Duration(seconds: 30));
    OnlineVideoCard? hit;
    for (final card in cards) {
      if (actressOnlineCardMatches(source: source, card: card, code: _code)) {
        hit = card;
        break;
      }
    }
    if (hit == null) return null;
    final play = await source
        .resolvePlay(hit, fetch: _fetch)
        .timeout(const Duration(seconds: 35));
    _fillFromOnlineInfo(play.detail);
    return ActressPlayTarget(play.streamUrl, play.headers);
  }

  Future<ActressPlayTarget?> _resolveLocalByCode() async {
    final search = await widget.fallback
        .handle({'op': 'search', 'q': _code, 'page': 1})
        .timeout(const Duration(seconds: 20));
    if (search['ok'] != true) return null;
    String? vodId;
    for (final row in (search['items'] as List? ?? const [])) {
      if (row is Map &&
          (row['vodId'] ?? '').toString().toLowerCase() ==
              _code.toLowerCase()) {
        vodId = (row['vodId'] ?? '').toString();
        break;
      }
    }
    if (vodId == null) return null;
    final detail = await widget.fallback
        .handle({'op': 'detail', 'vodId': vodId})
        .timeout(const Duration(seconds: 20));
    if (detail['ok'] != true || detail['item'] is! Map) return null;
    final item = Map<String, dynamic>.from(detail['item'] as Map);
    final urls = [
      for (final row in (item['playUrls'] as List? ?? const []))
        row.toString(),
    ];
    if (urls.isEmpty) return null;
    if (_mayLike.isEmpty) {
      setState(() {
        _mayLike = [
          for (final row in (item['related'] as List? ?? const []))
            if (row is Map) Map<String, dynamic>.from(row),
        ];
      });
    }
    return ActressPlayTarget(urls.first);
  }

  /// 在线详情信息回填：只补空位，不覆盖已有（本地库优先）。
  void _fillFromOnlineInfo(OnlineDetailInfo info) {
    if (!mounted) return;
    setState(() {
      if (_title.isEmpty || _title == _code) {
        if (info.title.isNotEmpty) _title = info.title;
      }
      if (_poster.isEmpty && info.poster.isNotEmpty) _poster = info.poster;
      if (_date.isEmpty) _date = info.date;
      if (_duration.isEmpty) _duration = info.duration;
      if (_maker.isEmpty) _maker = info.maker;
      for (final tag in info.tags) {
        if (!_tags.contains(tag) && _tags.length < 20) _tags.add(tag);
      }
      for (final still in info.stills) {
        if (!_stills.contains(still) && _stills.length < 24) {
          _stills.add(still);
        }
      }
      if (_cast.isEmpty && info.actresses.isNotEmpty) {
        _cast = [for (final name in info.actresses) (name: name, avatar: '')];
      }
    });
  }

  // ================= 后台补充（不挡开页） =================

  void _startSupplements() {
    unawaited(_loadCodeMeta());
    // JavDB 补充跑完（成败都算）再看剧照：仍为空才走截帧兜底。
    unawaited(
      _loadJavdbSupplement().then((_) => _captureStillsFallback()),
    );
    unawaited(_loadAlsoStarred());
    // 在线入口：开页就后台拉本源详情（剧照/演员/信息回填），
    // 不等点播才在线路解析里顺带回填——剧照区要开页就有。
    final source = widget.onlineSource;
    final card = widget.onlineCard;
    if (source != null && card != null) {
      unawaited(() async {
        try {
          final info = await source
              .fetchInfo(card, fetch: _fetch)
              .timeout(const Duration(seconds: 30));
          if (info != null) _fillFromOnlineInfo(info);
        } catch (_) {
          // 本源详情拉不到不挡页：其余补充链照常。
        }
      }());
    }
  }

  Future<void> _loadCodeMeta() async {
    if (_code.isEmpty) return;
    try {
      final meta = await loadCodeMetaForDrama(
        dramaId: _code,
        title: _title,
        sourceId: whosSourceId,
      );
      if (!mounted || meta == null) return;
      setState(() {
        if (_director.isEmpty) _director = meta.director;
        if (_maker.isEmpty) _maker = meta.maker;
        if (_date.isEmpty && meta.year != null) _date = '${meta.year}';
        if (_cast.isEmpty) {
          _cast = [
            for (final row in meta.castWithAvatars)
              (name: row.name, avatar: row.avatarUrl),
          ];
        } else {
          final avatars = {
            for (final row in meta.castWithAvatars) row.name: row.avatarUrl,
          };
          _cast = [
            for (final person in _cast)
              (
                name: person.name,
                avatar: person.avatar.isNotEmpty
                    ? person.avatar
                    : (avatars[person.name] ?? ''),
              ),
          ];
        }
      });
      unawaited(_loadAlsoStarred());
    } catch (_) {
      // 元数据资源缺失/损坏不挡详情页。
    }
  }

  Future<void> _loadJavdbSupplement() async {
    if (_code.isEmpty) return;
    final result = await actressJavdbSupplement(code: _code, client: _javdb);
    if (!mounted || result == null) return;
    final movie = result.movie;
    final extra = result.extra;
    setState(() {
      // 评分只认接口真数据：有才显示（含缎带），没给保持空。
      if (_score.isEmpty) {
        _score = extra.score.isNotEmpty ? extra.score : movie.score;
        _scoreCount = extra.scoreCount;
      }
      if (_poster.isEmpty) {
        if (extra.poster.isNotEmpty) {
          _poster = extra.poster;
        } else if (movie.poster.isNotEmpty) {
          _poster = movie.poster;
        }
      }
      if (_date.isEmpty && movie.releaseDate.isNotEmpty) {
        _date = movie.releaseDate;
      }
      // duration 字段单位是分钟（jar 路线实证），照原值显示。
      if (_duration.isEmpty && movie.durationMinutes > 0) {
        _duration = '${movie.durationMinutes} 分钟';
      }
      // 译名/原名：与当前标题不同才留，标题旁出「翻译」切换。
      if (_altTitle.isEmpty) {
        for (final candidate in [extra.originTitle, movie.title]) {
          if (candidate.isNotEmpty && candidate != _title) {
            _altTitle = candidate;
            break;
          }
        }
      }
      for (final (label, value) in extra.extraInfo) {
        if (label == '系列' && _series.isEmpty) _series = value;
        if (label == '制作商' && _maker.isEmpty) _maker = value;
        if (label == '导演' && _director.isEmpty) _director = value;
      }
      for (final tag in extra.tags) {
        if (!_tags.contains(tag) && _tags.length < 20) _tags.add(tag);
      }
      // 搜索信封自带的预览图也是剧照真数据（详情没给时兜底）。
      for (final still in [...extra.stills, ...movie.previewImages]) {
        if (!_stills.contains(still) && _stills.length < 24) {
          _stills.add(still);
        }
      }
      if (_magnets.isEmpty && result.magnets.isNotEmpty) {
        _magnets = result.magnets;
      }
      // JavDB 的相关推荐 / 演员其他作品只填空位：本地库已给
      // 的两排横卡优先，不覆盖。
      if (_mayLike.isEmpty && extra.relativeMovies.isNotEmpty) {
        _mayLike = [
          for (final row in extra.relativeMovies) _javdbRow(row),
        ];
      }
      if (_alsoStarred.isEmpty && extra.actorMovies.isNotEmpty) {
        _alsoStarred = [
          for (final row in extra.actorMovies) _javdbRow(row),
        ];
      }
      if (extra.actors.isNotEmpty) {
        final byName = {for (final actor in extra.actors) actor.name: actor};
        final known = {for (final person in _cast) person.name};
        _cast = [
          for (final person in _cast)
            (
              name: person.name,
              avatar: person.avatar.isNotEmpty
                  ? person.avatar
                  : (byName[person.name]?.avatarUrl ?? ''),
            ),
          for (final actor in extra.actors)
            if (!known.contains(actor.name))
              (name: actor.name, avatar: actor.avatarUrl),
        ];
      }
    });
  }

  /// JavdbMovie → 横卡行（与本地库行同形：vodId 用番号，点
  /// 开走本地详情页按番号入口的既有行为）。
  Map<String, dynamic> _javdbRow(JavdbMovie movie) => {
    'vodId': movie.number,
    'title': movie.title,
    'pic': movie.poster,
  };

  /// 磁力条目点按：只复制磁力链接并提示（下载链接区是
  /// AvPlay 版式展示，点按与行尾复制按钮同义，不做任何
  /// 提交动作）。
  Future<void> _copyMagnet(int index) async {
    if (index < 0 || index >= _magnets.length) return;
    await Clipboard.setData(ClipboardData(text: _magnets[index].url));
    if (!mounted) return;
    _snack('已复制');
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// 剧照截帧兜底（JavDB 没给剧照时）：先读缓存，命中直接
  /// 回填；没命中才从现行在线解析（本地线路 / 123AV / PH
  /// 按番号解析 → 验活）拿一条能播的流，无头截多帧、落缓
  /// 存再回填。全程异步、不挡开页；任何一步失败就让剧照区
  /// 保持不出，不弹窗、不拿封面冒充。截到的帧以 file: 引用
  /// 进 _stills（渲染处按前缀分流，见 actressStillImage）。
  Future<void> _captureStillsFallback() async {
    if (!mounted || _code.isEmpty || _stills.isNotEmpty) return;
    final cache = widget.stillCache ?? ActressStillCache();
    ActressPlayTarget? target;
    var sourceId = '';
    // 缓存按来源分键：逐线先查缓存，任一命中即回填。
    for (final line in _lines) {
      final cached = await cache.read(_code, line.id);
      if (!mounted) return;
      if (cached.isNotEmpty) {
        setState(() {
          for (final path in cached.take(6)) {
            final ref = 'file:$path';
            if (!_stills.contains(ref)) _stills.add(ref);
          }
        });
        return;
      }
    }
    for (final line in _lines) {
      try {
        final found = await line.resolve().timeout(
          const Duration(seconds: 35),
        );
        if (found == null) continue;
        if (!await _verify(found)) continue;
        target = found;
        sourceId = line.id;
        break;
      } catch (_) {
        // 单线失败继续下一条。
      }
    }
    if (!mounted || target == null) return;
    final capturer = widget.stillCapturer ?? const MediaKitStillCapturer();
    final frames = await capturer
        .captureFrames(url: target.url, headers: target.headers, count: 5)
        .timeout(const Duration(seconds: 90), onTimeout: () => const []);
    if (!mounted || frames.isEmpty) return;
    final paths = await cache.write(_code, sourceId, frames);
    if (!mounted) return;
    setState(() {
      if (paths.isNotEmpty) {
        for (final path in paths.take(6)) {
          final ref = 'file:$path';
          if (!_stills.contains(ref)) _stills.add(ref);
        }
      } else {
        // 落盘失败：帧只在内存里没法引用，宁可不出也不假装。
      }
    });
  }

  Future<void> _loadAlsoStarred() async {
    if (_cast.isEmpty || _alsoStarred.isNotEmpty) return;
    try {
      final result = await widget.fallback
          .handle({'op': 'works', 'actress': _cast.first.name, 'page': 1})
          .timeout(const Duration(seconds: 20));
      if (!mounted || result['ok'] != true) return;
      setState(() {
        _alsoStarred = [
          for (final row in (result['items'] as List? ?? const []))
            if (row is Map &&
                (row['vodId'] ?? '').toString().toLowerCase() !=
                    _code.toLowerCase())
              Map<String, dynamic>.from(row),
        ].take(10).toList();
      });
    } catch (_) {
      // 查不到就整区不显示，不编数据。
    }
  }

  /// 线路内部失败原因：只留中文人话，异常原文一律吞掉映射
  /// （2026-11-27 错误文案中文化令）。线路不上屏后这只是内
  /// 部记录口径，仍不许把英文异常原文带出去。
  String _lineErrorText(Object error) =>
      actressErrorText(error, fallback: '取地址失败');

  // ================= 起播（页内） =================

  Future<bool> _verify(ActressPlayTarget target) async {
    try {
      final uri = Uri.tryParse(target.url);
      if (uri == null || uri.host.isEmpty) return false;
      final probe = widget.probeFetch ?? probeStreamHead;
      final response = await probe(
        target.url,
        target.headers,
        const Duration(seconds: 5),
      );
      return feedProbePlayable(uri, response);
    } catch (_) {
      return false;
    }
  }

  /// 海报播放键：全部线路竞速——本地线路直接验活，在线线
  /// 路边搜边验，谁先验活谁先播；主竞速总闸 [raceGate]
  /// （40 秒）。MJV 现拉后补线不进主竞速：主线先出结果
  /// 先播，后补线随后验活完只入换线池（播中报错时经
  /// _onInlinePlaybackError 自动换上）；主线全灭时不在
  /// 总闸处提前定死「暂无可播线路」，再给后补线
  /// [lateLineWindow] 的窗口等它接上，窗口耗尽才定。
  Future<void> _playBest() async {
    if (_playBusy || _playingUrl != null) return;
    if (_lines.isEmpty && _lateLines.isEmpty) {
      setState(() => _playError = '暂无可播线路');
      return;
    }
    setState(() {
      _playBusy = true;
      _playError = null;
    });
    final completer = Completer<(_Line, ActressPlayTarget)?>();
    var remaining = _lines.length;
    if (remaining == 0) completer.complete(null);
    for (final line in _lines) {
      unawaited(() async {
        try {
          final target = await line.resolve();
          if (target != null && await _verify(target)) {
            line.verified = true;
            if (!completer.isCompleted) completer.complete((line, target));
          }
        } catch (_) {
          // 单线失败不拖垮竞速，其余线继续。
        } finally {
          remaining--;
          if (remaining == 0 && !completer.isCompleted) {
            completer.complete(null);
          }
        }
      }());
    }
    final winner = await completer.future.timeout(
      widget.raceGate,
      onTimeout: () => null,
    );
    if (!mounted) return;
    if (winner != null) {
      setState(() => _playBusy = false);
      await _startPlayback(winner.$1, winner.$2);
      // 主线已播：后补线继续在后台拉，验活后入换线池。
      unawaited(_adoptLateLines());
      return;
    }
    // 主竞速全灭：后补线还在拉就等它，不提前定死。
    final lateWinner = await _waitLateWinner();
    if (!mounted) return;
    setState(() => _playBusy = false);
    if (lateWinner == null) {
      setState(() => _playError = '暂无可播线路');
      return;
    }
    await _startPlayback(lateWinner.$1, lateWinner.$2);
  }

  /// 等后补线（MJV 现拉）在 [lateLineWindow] 内出结果并
  /// 验活：首个验活的返回；全灭/超时返回 null。resolve
  /// 期约与开页后台搜索共用同一份，不重复取。
  Future<(_Line, ActressPlayTarget)?> _waitLateWinner() async {
    if (_lateLines.isEmpty) return null;
    final completer = Completer<(_Line, ActressPlayTarget)?>();
    var remaining = _lateLines.length;
    for (final line in _lateLines) {
      unawaited(() async {
        try {
          final target = await line.resolve();
          if (target != null && await _verify(target)) {
            line.verified = true;
            if (!completer.isCompleted) completer.complete((line, target));
          }
        } catch (_) {
          // 后补线单线失败不拖垮其余后补线。
        } finally {
          remaining--;
          if (remaining == 0 && !completer.isCompleted) {
            completer.complete(null);
          }
        }
      }());
    }
    return completer.future.timeout(
      widget.lateLineWindow,
      onTimeout: () => null,
    );
  }

  /// 后补线事后入池：主线已起播后，后补线拉到并验活就
  /// 追加进 _lines（target 已缓存），播中报错时既有自动
  /// 换线机件会把它换上；拉不到/验不活就静默丢弃。
  Future<void> _adoptLateLines() async {
    for (final line in _lateLines) {
      try {
        final target = await line.resolve();
        if (!mounted || target == null) continue;
        if (!await _verify(target)) continue;
        line.verified = true;
        if (!mounted) return;
        setState(() {
          if (!_lines.any((row) => row.id == line.id)) _lines.add(line);
        });
      } catch (_) {
        // 后补线入池失败静默：主线照常播。
      }
    }
  }

  Future<void> _startPlayback(_Line line, ActressPlayTarget target) async {
    final prep =
        widget.playUrlPrep ??
        (String url, Map<String, String> headers) async {
          if (headers.isEmpty) return url;
          return LocalMediaProxy.instance.register(
            targetUrl: url,
            headers: headers,
          );
        };
    final url = await prep(target.url, target.headers);
    if (!mounted) return;
    _autoTried
      ..clear()
      ..add(line.id);
    setState(() {
      _playingLineId = line.id;
      _playingUrl = url;
      _playError = null;
      for (final row in _lines) {
        row.nowPlaying = row.id == line.id;
      }
    });
  }

  /// 页内播放器报错：自动换下一条还没试过的线路（先验活
  /// 再换），全试完就把错误留在播放器区，不死循环。
  void _onInlinePlaybackError(String message) {
    if (!mounted) return;
    final current = _playingLineId;
    if (current != null) _autoTried.add(current);
    _Line? next;
    for (final line in _lines) {
      if (_autoTried.contains(line.id)) continue;
      if (line.target != null || line.resolver != null) {
        next = line;
        break;
      }
    }
    if (next == null) return;
    final candidate = next;
    unawaited(() async {
      try {
        final target = await candidate.resolve().timeout(
          const Duration(seconds: 40),
        );
        if (!mounted || target == null) return;
        if (!await _verify(target)) return;
        candidate.verified = true;
        await _startPlayback(candidate, target);
      } catch (_) {
        // 换线失败就停在当前错误态，等用户点行重试。
      }
    }());
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
            _posterArea(),
            Expanded(child: _scrollBody()),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
      decoration: BoxDecoration(
        color: Neon.bg,
        border: Border(
          bottom: BorderSide(color: Neon.violet.withValues(alpha: .55)),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('work-detail-back'),
            icon: const Icon(Icons.arrow_back_rounded, color: Neon.text),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Container(
            width: 30,
            height: 44,
            decoration: actressNeonCardDecoration(radius: 4),
            clipBehavior: Clip.antiAlias,
            child: _poster.isEmpty
                ? const SizedBox.shrink()
                : ActressNetImage(url: _poster),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _code.isNotEmpty ? _code : '作品详情',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Neon.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  _title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Neon.textDim, fontSize: 11.5),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('work-detail-search'),
            tooltip: '按番号搜索',
            icon: const Icon(Icons.search_rounded, color: Neon.textDim),
            onPressed: _code.isEmpty
                ? null
                : () => widget.onSearchCode?.call(_code),
          ),
          IconButton(
            key: const ValueKey('work-detail-more'),
            tooltip: '更多',
            icon: const Icon(Icons.more_vert_rounded, color: Neon.textDim),
            onPressed: () => unawaited(_showMoreSheet()),
          ),
        ],
      ),
    );
  }

  Future<void> _showMoreSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Neon.surface,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_code.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy_rounded, color: Neon.cyan),
                title: const Text(
                  '复制番号',
                  style: TextStyle(color: Neon.text),
                ),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: _code));
                  if (!sheetContext.mounted) return;
                  Navigator.of(sheetContext).pop();
                  if (!mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('番号已复制')));
                },
              ),
            ListTile(
              leading: const Icon(Icons.title_rounded, color: Neon.cyan),
              title: const Text('复制标题', style: TextStyle(color: Neon.text)),
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: _title));
                if (!sheetContext.mounted) return;
                Navigator.of(sheetContext).pop();
                if (!mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('标题已复制')));
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 海报/播放器区（钉顶）：未起播是毛玻璃底 + 海报 + 正中
  /// 央圆形播放键；起播后原地换成内嵌播放器。
  Widget _posterArea() {
    final playingUrl = _playingUrl;
    return AspectRatio(
      key: const ValueKey('work-detail-stage'),
      aspectRatio: 16 / 10,
      child: playingUrl != null
          ? ActressInlinePlayer(
              key: ValueKey('inline-$_playingLineId-$_playingUrl'),
              url: playingUrl,
              poster: _poster,
              playerFactory: widget.playerFactory,
              onPlaybackError: _onInlinePlaybackError,
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                if (_poster.isNotEmpty)
                  ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: ActressNetImage(url: _poster),
                  )
                else
                  const ColoredBox(color: Color(0xFF171021)),
                const ColoredBox(color: Color(0x59000000)),
                Center(
                  child: AspectRatio(
                    aspectRatio: 2 / 3,
                    child: Container(
                      decoration: actressNeonCardDecoration(radius: 8),
                      clipBehavior: Clip.antiAlias,
                      child: _poster.isEmpty
                          ? Center(
                              child: Text(
                                _code.isEmpty ? '暂无海报' : _code,
                                style: const TextStyle(color: Neon.textDim),
                              ),
                            )
                          : ActressNetImage(
                              url: _poster,
                              onRetry: () => setState(() {}),
                            ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: GestureDetector(
                    key: const ValueKey('work-detail-poster-play'),
                    behavior: HitTestBehavior.translucent,
                    onTap: () => unawaited(_playBest()),
                  ),
                ),
                // 播放键在海报正中央（2026-11-27 用户令，由右下改居中）。
                // IgnorePointer：键只是视觉提示，点击穿透到海报
                // 手势层（整张海报可点起播），别让键挡住点按。
                Center(
                  child: IgnorePointer(
                    child: Container(
                    key: const ValueKey('work-detail-play-button'),
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .45),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white24),
                    ),
                    child: _playBusy
                        ? const Padding(
                            padding: EdgeInsets.all(15),
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.5,
                            ),
                          )
                        : const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 32,
                          ),
                    ),
                  ),
                ),
                if (_playBusy)
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 16,
                    child: Text(
                      '正在搜索可播线路…',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                if (_playError != null && !_playBusy)
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 14,
                    child: Text(
                      _playError!,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFFF9E9E),
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _scrollBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Neon.pink));
    }
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _loadError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Neon.textDim, fontSize: 13),
              ),
              const SizedBox(height: 14),
              ActressNeonPill(
                label: '重试',
                selected: true,
                onTap: () => unawaited(_loadLocalDetail()),
              ),
            ],
          ),
        ),
      );
    }
    return ListView(
      key: const ValueKey('work-detail-scroll'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 36),
      children: [
        // 大标题 + 「翻译」切换（AvPlay 版式）：有译名/原名
        // 数据才出切换，没数据不显示、不编造。
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                _showAltTitle && _altTitle.isNotEmpty
                    ? _altTitle
                    : (_title.isEmpty ? _code : _title),
                key: const ValueKey('work-detail-title'),
                style: const TextStyle(
                  color: Neon.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  height: 1.4,
                ),
              ),
            ),
            if (_altTitle.isNotEmpty)
              InkWell(
                key: const ValueKey('work-detail-translate-toggle'),
                onTap: () =>
                    setState(() => _showAltTitle = !_showAltTitle),
                child: const Padding(
                  padding: EdgeInsets.fromLTRB(8, 4, 0, 4),
                  child: Text(
                    '[翻译]',
                    style: TextStyle(color: Neon.cyan, fontSize: 13),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _infoCard(),
        if (_synopsis.isNotEmpty) ...[
          const SizedBox(height: 16),
          _sectionTitle('简介'),
          const SizedBox(height: 6),
          Text(
            _synopsis,
            style: const TextStyle(
              color: Neon.textDim,
              fontSize: 13,
              height: 1.55,
            ),
          ),
        ],
        if (_tags.isNotEmpty) ...[
          const SizedBox(height: 18),
          _sectionTitle('相关分类'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tag in _tags)
                ActressNeonPill(
                  label: tag,
                  selected: false,
                  onTap: () => widget.onTag?.call(tag),
                ),
            ],
          ),
        ],
        if (_cast.isNotEmpty) ...[
          const SizedBox(height: 18),
          _sectionTitle('演员'),
          const SizedBox(height: 8),
          _castRow(),
        ],
        if (_stills.isNotEmpty) ...[
          const SizedBox(height: 18),
          Row(
            children: [
              _sectionTitle('剧照'),
              const Spacer(),
              if (_stills.length > 3)
                InkWell(
                  key: const ValueKey('work-detail-stills-all'),
                  onTap: () => _openStills(0, all: true),
                  child: Text(
                    '全部 ${_stills.length} >',
                    style: const TextStyle(color: Neon.textDim, fontSize: 12),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _stillsRow(),
        ],
        // 播放线路列表不上屏（2026-11-27 用户令隐藏）：海报
        // 播放键背后自动竞速（本地 → 123AV → PH），全灭在播
        // 放区显示「暂无可播线路」；线路状态文案不上屏。
        // 裁决：AvPlay 的「在线平台」行与隐藏令相撞，以隐藏
        // 令为准——不摆线路/平台列表、不单列平台行。
        if (_magnets.isNotEmpty) ...[
          const SizedBox(height: 18),
          _sectionTitle('下载链接'),
          const SizedBox(height: 8),
          _magnetsSection(),
        ],
        if (_alsoStarred.isNotEmpty) ...[
          const SizedBox(height: 18),
          _sectionTitle('她们还演出过'),
          const SizedBox(height: 8),
          _worksRail(_alsoStarred, 'also'),
        ],
        if (_mayLike.isNotEmpty) ...[
          const SizedBox(height: 18),
          _sectionTitle('你可能也喜欢'),
          const SizedBox(height: 8),
          _worksRail(_mayLike, 'like'),
        ],
      ],
    );
  }

  Widget _sectionTitle(String text) => Text(
    text,
    style: const TextStyle(
      color: Neon.text,
      fontSize: 15,
      fontWeight: FontWeight.w700,
    ),
  );

  Widget _infoCard() {
    final rows = <(String, String, bool)>[
      if (_code.isNotEmpty) ('番号', _code, true),
      if (_date.isNotEmpty) ('发行日期', _date, false),
      if (_duration.isNotEmpty) ('长度', _duration, false),
      if (_maker.isNotEmpty) ('制作商', _maker, false),
      if (_series.isNotEmpty) ('系列', _series, false),
      if (_director.isNotEmpty) ('导演', _director, false),
      if (_typeName.isNotEmpty) ('类型', _typeName, false),
      if (_score.isNotEmpty)
        (
          '评分',
          _scoreCount > 0 ? '$_score（共 $_scoreCount 人评分）' : _score,
          false,
        ),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Stack(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          decoration: actressNeonCardDecoration(radius: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (label, value, copyable) in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 76,
                        child: Text(
                          '$label：',
                          style: const TextStyle(
                            color: Neon.textDim,
                            fontSize: 13.5,
                          ),
                        ),
                      ),
                      Expanded(
                        child: copyable
                            ? InkWell(
                                key: const ValueKey('work-detail-copy-code'),
                                onTap: () async {
                                  await Clipboard.setData(
                                    ClipboardData(text: value),
                                  );
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('番号已复制')),
                                  );
                                },
                                child: Text(
                                  value,
                                  style: const TextStyle(
                                    color: Neon.text,
                                    fontSize: 13.5,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                              )
                            : Text(
                                value,
                                style: const TextStyle(
                                  color: Neon.text,
                                  fontSize: 13.5,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        // 评分缎带：只有 JavDB 接口给了真评分才挂，没数据不挂、
        // 不编数字（用户令）。
        if (_score.isNotEmpty)
          Positioned(
            right: 14,
            top: 0,
            child: Container(
              key: const ValueKey('work-detail-score-ribbon'),
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
              decoration: const BoxDecoration(
                color: Color(0xFFF2B33D),
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(4),
                ),
              ),
              child: Text(
                _score,
                style: const TextStyle(
                  color: Color(0xFF4A2F00),
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 下载链接区：只有 JavDB 真返回磁力条目才出现；条目带
  /// 高清标记/体积/日期等字段有啥摆啥。点按条目或行尾复制
  /// 按钮都只做一件事：复制磁力链接并提示「已复制」。
  Widget _magnetsSection() {
    return Container(
      key: const ValueKey('work-detail-magnets'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      decoration: actressNeonCardDecoration(radius: 12),
      child: Column(
        children: [
          for (var i = 0; i < _magnets.length; i++)
            InkWell(
              key: ValueKey('work-detail-magnet-$i'),
              onTap: () => unawaited(_copyMagnet(i)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _magnets[i].name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Neon.text,
                              fontSize: 13,
                            ),
                          ),
                        ),
                    if (_magnets[i].hd)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: const Color(0xFF55B16C)),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          '高清',
                          style: TextStyle(
                            color: Color(0xFF55B16C),
                            fontSize: 11,
                          ),
                        ),
                      ),
                    if (_magnets[i].cnsub)
                      Container(
                        margin: const EdgeInsets.only(left: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: Neon.cyan),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          '字幕',
                          style: TextStyle(color: Neon.cyan, fontSize: 11),
                        ),
                      ),
                        IconButton(
                          key: ValueKey('work-detail-magnet-copy-$i'),
                          icon: const Icon(
                            Icons.copy_outlined,
                            size: 16,
                            color: Neon.textDim,
                          ),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 30,
                            minHeight: 30,
                          ),
                          onPressed: () => unawaited(_copyMagnet(i)),
                        ),
                      ],
                    ),
                    if (_magnets[i].sizeLabel.isNotEmpty ||
                        _magnets[i].dateLabel.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Row(
                          children: [
                            if (_magnets[i].sizeLabel.isNotEmpty)
                              Text(
                                _magnets[i].sizeLabel,
                                style: const TextStyle(
                                  color: Neon.textDim,
                                  fontSize: 12,
                                ),
                              ),
                            if (_magnets[i].dateLabel.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(left: 10),
                                child: Text(
                                  _magnets[i].dateLabel,
                                  style: const TextStyle(
                                    color: Neon.textDim,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _castRow() {
    return SizedBox(
      height: 122,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _cast.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final person = _cast[index];
          return InkWell(
            key: ValueKey('work-detail-cast-${person.name}'),
            onTap: () => widget.onActress?.call(person.name),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 84,
              padding: const EdgeInsets.all(4),
              decoration: actressNeonCardDecoration(radius: 10),
              child: Column(
                children: [
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      color: Neon.surfaceHigh,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: ActressAvatar(
                      name: person.name,
                      avatarUrl: person.avatar,
                      javdbClient: _javdb,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    person.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Neon.text,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
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

  Widget _stillsRow() {
    return SizedBox(
      height: 104,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _stills.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          return InkWell(
            key: ValueKey('work-detail-still-$index'),
            onTap: () => _openStills(index),
            child: AspectRatio(
              aspectRatio: 16 / 10,
              child: Container(
                decoration: actressNeonCardDecoration(radius: 8),
                clipBehavior: Clip.antiAlias,
                child: actressStillImage(_stills[index]),
              ),
            ),
          );
        },
      ),
    );
  }

  void _openStills(int index, {bool all = false}) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => all
            ? _StillsAllPage(stills: _stills, code: _code)
            : _StillsViewerPage(stills: _stills, initialIndex: index),
      ),
    );
  }

  Widget _worksRail(List<Map<String, dynamic>> rows, String prefix) {
    return SizedBox(
      height: 180,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: rows.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final row = rows[index];
          final vodId = (row['vodId'] ?? '').toString();
          final pic = (row['pic'] ?? '').toString();
          return InkWell(
            key: ValueKey('work-detail-$prefix-$vodId'),
            onTap: vodId.isEmpty
                ? null
                : () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => ActressWorkDetailPage.local(
                        vodId: vodId,
                        fallback: widget.fallback,
                        repository: widget.repository,
                        onlineFetch: widget.onlineFetch,
                        javdbClient: widget.javdbClient,
                        stillCapturer: widget.stillCapturer,
                        stillCache: widget.stillCache,
                        probeFetch: widget.probeFetch,
                        playerFactory: widget.playerFactory,
                        playUrlPrep: widget.playUrlPrep,
                        onActress: widget.onActress,
                        onTag: widget.onTag,
                        onSearchCode: widget.onSearchCode,
                      ),
                    ),
                  ),
            child: SizedBox(
              width: 92,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 92,
                    height: 122,
                    decoration: actressNeonCardDecoration(radius: 8),
                    clipBehavior: Clip.antiAlias,
                    child: pic.isEmpty
                        ? const SizedBox.shrink()
                        : ActressNetImage(url: pic),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    (row['title'] ?? '').toString(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Neon.text, fontSize: 11.5),
                  ),
                  Text(
                    vodId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Neon.textDim, fontSize: 10),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 剧照图渲染分流：网络图走 ActressNetImage（JavDB 图床自
/// 动解密）；截帧落盘的本地帧以 file: 引用，走 Image.file。
Widget actressStillImage(String ref, {BoxFit fit = BoxFit.cover}) {
  if (ref.startsWith('file:')) {
    return Image.file(
      File(ref.substring(5)),
      fit: fit,
      errorBuilder: (context, error, stack) =>
          const ColoredBox(color: Color(0xFF1B1426)),
    );
  }
  return ActressNetImage(url: ref, fit: fit);
}

/// 剧照全览页：两列网格，点任意一张进全屏浏览。
class _StillsAllPage extends StatelessWidget {
  const _StillsAllPage({required this.stills, required this.code});

  final List<String> stills;
  final String code;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: actressNeonAppBar(
        title: Text(
          '剧照 · ${stills.length}',
          style: const TextStyle(fontSize: 16),
        ),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: stills.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 16 / 10,
        ),
        itemBuilder: (context, index) => InkWell(
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) =>
                  _StillsViewerPage(stills: stills, initialIndex: index),
            ),
          ),
          child: Container(
            decoration: actressNeonCardDecoration(radius: 8),
            clipBehavior: Clip.antiAlias,
            child: actressStillImage(stills[index]),
          ),
        ),
      ),
    );
  }
}

/// 剧照全屏浏览：左右滑翻页，带页码。
class _StillsViewerPage extends StatefulWidget {
  const _StillsViewerPage({required this.stills, required this.initialIndex});

  final List<String> stills;
  final int initialIndex;

  @override
  State<_StillsViewerPage> createState() => _StillsViewerPageState();
}

class _StillsViewerPageState extends State<_StillsViewerPage> {
  late final PageController _controller = PageController(
    initialPage: widget.initialIndex,
  );
  late var _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '${_index + 1} / ${widget.stills.length}',
          style: const TextStyle(fontSize: 15),
        ),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.stills.length,
        onPageChanged: (index) => setState(() => _index = index),
        itemBuilder: (context, index) => InteractiveViewer(
          child: Center(
            child: actressStillImage(
              widget.stills[index],
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    );
  }
}
