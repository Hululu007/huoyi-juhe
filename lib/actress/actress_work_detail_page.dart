import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../services/local_media_proxy.dart' show LocalMediaProxy;
import '../services/native_player.dart' show NativePlayer;
import 'actress_adapter_http.dart'
    show FeedProbeFetch, feedProbePlayable, probeStreamHead;
import 'actress_adapter_models.dart' show AppFailure, Drama;
import 'actress_adapter_repository.dart' show AppRepository;
import 'actress_inline_player.dart';
import 'actress_javdb_api.dart';
import 'actress_javdb_image.dart';
import 'actress_library_db.dart' show ActressLibraryDbFallback;
import 'actress_neon.dart';
import 'actress_online_parse.dart'
    show OnlineDetailInfo, OnlineVideoCard, av123CodeOf;
import 'actress_online_sources.dart';
import 'code_meta_section.dart' show loadCodeMetaForDrama;
import 'whos_fallback.dart' show whosSourceId;

/// 一条已取到的可播目标：直链 + 播放请求头。
class ActressPlayTarget {
  const ActressPlayTarget(this.url, [this.headers = const {}]);

  final String url;
  final Map<String, String> headers;
}

/// 起播前地址加工（生产走本地代理带头，测试可注入直通）。
typedef ActressPlayUrlPrep =
    Future<String> Function(String url, Map<String, String> headers);

enum _LineStatus { searching, ready, resolving, failed, empty }

/// 详情页里的一条播放线路：本地库线路开页即 ready；在线线路
/// （who's / 123AV / PH）打开详情后按番号后台搜，搜到才
/// ready。取流结果按线缓存，海报竞速与点行起播共用同一份
/// resolver 期约，不重复取。
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
/// （毛玻璃底 + 海报，右下圆形播放键；点海报在**页内起播**，
/// 海报区原地变播放器钉顶，下方照常滚动，不跳播放器页）→
/// 信息卡（番号可点复制 / 发行日期 / 长度 / 制作商 / 系列 /
/// 导演 / 评分——评分只认 JavDB 接口真数据，没数据不显示、
/// 不编；右上评分缎带同理）→ 简介（有才显示）→ 相关分类
/// chips → 演员区（全部演员含男演员，头像本地库优先）→
/// 剧照区（横滑 + 全部 N；来源：在线详情页自带剧照、JavDB
/// 预览图；没有就不显示）→ 播放线路（本地库开页即在，
/// who's / 123AV / PH 按番号后台追加；海报键竞速：全部线
/// 路同尺验活、谁先验活谁先播，总闸 40 秒；点行起播该行，
/// 失败原因上屏、绝不无限转圈）→ 她们还演出过（本地库按
/// 演员查）→ 你可能也喜欢（本地库相关作品）。
class ActressWorkDetailPage extends StatefulWidget {
  const ActressWorkDetailPage.local({
    super.key,
    required String vodId,
    required this.fallback,
    required this.repository,
    this.onlineFetch,
    this.javdbClient,
    this.probeFetch,
    this.playerFactory,
    this.playUrlPrep,
    this.onActress,
    this.onTag,
    this.onSearchCode,
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
    this.probeFetch,
    this.playerFactory,
    this.playUrlPrep,
    this.onActress,
    this.onTag,
    this.onSearchCode,
  }) : localVodId = null,
       onlineSource = source,
       onlineCard = card,
       entryCode = null,
       entryTitle = '',
       entryPoster = '';

  /// 按番号入口（who's 卡等只有番号与标题/封面的场合）：没
  /// 有自有源线路，全部线路（who's / 123AV / PH / 本地库）
  /// 打开后按番号后台搜。
  const ActressWorkDetailPage.byCode({
    super.key,
    required String code,
    String title = '',
    String poster = '',
    required this.fallback,
    required this.repository,
    this.onlineFetch,
    this.javdbClient,
    this.probeFetch,
    this.playerFactory,
    this.playUrlPrep,
    this.onActress,
    this.onTag,
    this.onSearchCode,
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
  final FeedProbeFetch? probeFetch;
  final NativePlayer Function()? playerFactory;
  final ActressPlayUrlPrep? playUrlPrep;
  final void Function(String name)? onActress;
  final void Function(String tag)? onTag;
  final void Function(String code)? onSearchCode;

  @override
  State<ActressWorkDetailPage> createState() => _ActressWorkDetailPageState();
}

class _ActressWorkDetailPageState extends State<ActressWorkDetailPage> {
  late final ActressOnlineClient _onlineClient = ActressOnlineClient();
  late final JavdbApiClient _javdb = widget.javdbClient ?? JavdbApiClient();

  ActressOnlineFetch get _fetch => widget.onlineFetch ?? _onlineClient.get;

  var _loading = true;
  String? _loadError;

  var _code = '';
  var _title = '';
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
          _loadError = (result['error'] ?? '本地库无此番号').toString();
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
        _loadError = '详情加载失败：${_shortError(error)}';
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

  /// 在线三线追加（本地作品与在线作品共用）：who's 走仓储
  /// py 链、123AV/PH 走 Dart 直连、（在线作品时）本地库按
  /// 番号反查一条。加完即启动后台搜索，互不阻塞。
  void _appendOnlineLines({bool includeSelf = true}) {
    if (_code.isEmpty) return;
    _lines.add(
      _Line(id: 'whos', label: "who's", resolver: _resolveWhosLine),
    );
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
        line.note = _shortError(error);
      });
    }
  }

  Future<ActressPlayTarget?> _resolveWhosLine() async {
    // who's py 链：番号当 id 直接要详情（蜘蛛 detailContent
    // 吃番号），再经仓储 resolve 取直链（与魔蚁女优页竞速的
    // B 路同形）。py 取页多通道慢，超时给到 70 秒（桥上限）。
    final drama = Drama(
      id: _code,
      source: whosSourceId,
      sourceId: _code,
      title: _title,
      cover: _poster,
    );
    final detail = await widget.repository
        .detail(drama)
        .timeout(const Duration(seconds: 70));
    if (detail.episodes.isEmpty) return null;
    final plan = await widget.repository
        .resolve(drama, detail.episodes.first)
        .timeout(const Duration(seconds: 20));
    if (plan.needsParse || plan.url.isEmpty) return null;
    return ActressPlayTarget(plan.url, plan.headers);
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
    unawaited(_loadJavdbSupplement());
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
      if (_poster.isEmpty && movie.poster.isNotEmpty) _poster = movie.poster;
      if (_date.isEmpty && movie.releaseDate.isNotEmpty) {
        _date = movie.releaseDate;
      }
      if (_duration.isEmpty && movie.durationSeconds > 0) {
        _duration = '${(movie.durationSeconds / 60).round()} 分钟';
      }
      for (final (label, value) in extra.extraInfo) {
        if (label == '系列' && _series.isEmpty) _series = value;
        if (label == '制作商' && _maker.isEmpty) _maker = value;
        if (label == '导演' && _director.isEmpty) _director = value;
      }
      for (final still in extra.stills) {
        if (!_stills.contains(still) && _stills.length < 24) {
          _stills.add(still);
        }
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

  String _shortError(Object error) {
    if (error is AppFailure) return error.message;
    final text = error.toString().split('\n').first.trim();
    return text.length > 60 ? '${text.substring(0, 60)}…' : text;
  }

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
  /// 路边搜边验，谁先验活谁先播；总闸 40 秒，全灭把原因
  /// 写在海报区，不许无限转圈。
  Future<void> _playBest() async {
    if (_playBusy || _playingUrl != null) return;
    if (_lines.isEmpty) {
      setState(() => _playError = '暂无可播线路：这部作品还没有任何线路');
      return;
    }
    setState(() {
      _playBusy = true;
      _playError = null;
    });
    final completer = Completer<(_Line, ActressPlayTarget)?>();
    var remaining = _lines.length;
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
      const Duration(seconds: 40),
      onTimeout: () => null,
    );
    if (!mounted) return;
    setState(() => _playBusy = false);
    if (winner == null) {
      setState(
        () => _playError = '暂无可播线路：本地库与在线源都没搜到可播地址',
      );
      return;
    }
    await _startPlayback(winner.$1, winner.$2);
  }

  /// 点行起播：该行还没搜到先等它（带总超时），验活后播；
  /// 失败把原因落到行上 + 海报区，点按可重试。
  Future<void> _playLine(_Line line) async {
    if (line.nowPlaying) return;
    setState(() {
      line.status = _LineStatus.resolving;
      _playError = null;
    });
    try {
      final target = await line.resolve().timeout(
        const Duration(seconds: 75),
      );
      if (!mounted) return;
      if (target == null) {
        setState(() {
          line.status = _LineStatus.empty;
          line.note = '未找到';
          _playError = '${line.label} 没有找到这部作品';
        });
        return;
      }
      setState(() => line.status = _LineStatus.ready);
      if (!line.verified && !await _verify(target)) {
        setState(() {
          line.status = _LineStatus.failed;
          line.note = '地址验活未通过';
          _playError = '${line.label} 的地址验活未通过，可能已失效';
        });
        return;
      }
      line.verified = true;
      await _startPlayback(line, target);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        line.status = _LineStatus.failed;
        line.note = _shortError(error);
        _playError = '${line.label} 取地址失败：${_shortError(error)}';
      });
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

  /// 海报/播放器区（钉顶）：未起播是毛玻璃底 + 海报 + 右下
  /// 圆形播放键；起播后原地换成内嵌播放器。
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
                Positioned(
                  right: 14,
                  bottom: 12,
                  child: Container(
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
                if (_playBusy)
                  const Positioned(
                    left: 14,
                    bottom: 16,
                    child: Text(
                      '正在搜索可播线路…',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                if (_playError != null && !_playBusy)
                  Positioned(
                    left: 14,
                    right: 84,
                    bottom: 14,
                    child: Text(
                      _playError!,
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
        Text(
          _title.isEmpty ? _code : _title,
          style: const TextStyle(
            color: Neon.text,
            fontSize: 17,
            fontWeight: FontWeight.w800,
            height: 1.4,
          ),
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
        const SizedBox(height: 18),
        _sectionTitle('播放线路'),
        const SizedBox(height: 4),
        const Text(
          '打开详情后按番号自动搜索 · 点行起播 · 失败点按重试',
          style: TextStyle(color: Neon.textDim, fontSize: 11),
        ),
        const SizedBox(height: 8),
        _linesList(),
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
                    child: person.avatar.isEmpty
                        ? Center(
                            child: Text(
                              person.name.isEmpty
                                  ? '?'
                                  : person.name.characters.first,
                              style: const TextStyle(
                                color: Neon.text,
                                fontSize: 22,
                              ),
                            ),
                          )
                        : ActressNetImage(url: person.avatar),
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
                child: ActressNetImage(url: _stills[index]),
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

  Widget _linesList() {
    if (_lines.isEmpty) {
      return const Text(
        '暂无线路：本地库没有这部的地址，在线源还在搜索',
        style: TextStyle(color: Neon.textDim, fontSize: 12.5),
      );
    }
    return Column(
      children: [
        for (final line in _lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              key: ValueKey('work-detail-line-${line.id}'),
              onTap: () => unawaited(_playLine(line)),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: actressNeonCardDecoration(radius: 10),
                child: Row(
                  children: [
                    Icon(
                      line.nowPlaying
                          ? Icons.play_circle_fill_rounded
                          : Icons.play_circle_outline_rounded,
                      color: line.nowPlaying ? Neon.cyan : Neon.textDim,
                      size: 22,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        line.label,
                        style: TextStyle(
                          color: line.nowPlaying ? Neon.cyan : Neon.text,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      _lineStatusText(line),
                      style: const TextStyle(
                        color: Neon.textDim,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _lineStatusText(_Line line) {
    if (line.nowPlaying) return '播放中';
    return switch (line.status) {
      _LineStatus.searching => '搜索中…',
      _LineStatus.resolving => '取地址中…',
      _LineStatus.ready => line.verified ? '已验活 · 点播' : '已找到 · 点播',
      _LineStatus.empty => '未找到',
      _LineStatus.failed =>
        line.note.isEmpty ? '失败 · 点按重试' : '${line.note} · 点按重试',
    };
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
            child: ActressNetImage(url: stills[index]),
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
          child: Center(child: ActressNetImage(url: widget.stills[index], fit: BoxFit.contain)),
        ),
      ),
    );
  }
}
