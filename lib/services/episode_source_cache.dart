import 'dart:async';
import 'dart:convert';

import '../models/media_item.dart';
import 'api_client.dart';
import 'drama_playback.dart';

class EpisodeVariant {
  final String name;
  final String url;
  final String keyHex;
  final int height;

  const EpisodeVariant({
    required this.name,
    required this.url,
    required this.keyHex,
    required this.height,
  });
}

class EpisodeSource {
  final String url;
  final String keyHex;

  /// All playable renditions of this episode, best-quality first
  /// (official panel lists resolutions high→low). Empty when the upstream
  /// only offered one stream — the quality row is hidden then.
  final List<EpisodeVariant> variants;

  /// 服务端分集方向（官方 `VideoInfo.vertical`），随取流响应下发。
  /// `null` = 该响应没有这个字段（旧后端、离线缓存）；播放页把 null 与
  /// false 一样当作「不竖屏」，保留「全屏观看」。
  final bool? vertical;

  const EpisodeSource(
    this.url, [
    this.keyHex = '',
    this.variants = const [],
    this.vertical,
  ]);

  EpisodeSource withVariant(EpisodeVariant variant) =>
      EpisodeSource(variant.url, variant.keyHex, variants, vertical);

  factory EpisodeSource.fromResponse(Map<String, dynamic> response) {
    final data = response['data'] is Map
        ? Map<String, dynamic>.from(response['data'] as Map)
        : response;
    var rawUrl = (data['video_url'] ?? data['main_url'] ?? '')
        .toString()
        .trim();
    if (rawUrl.isEmpty) rawUrl = _extractVideoUrl(response);
    if (rawUrl.isEmpty) throw ApiException('获取播放地址失败');
    final url = ApiClient.instance.absoluteUrl(rawUrl);
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw ApiException('获取播放地址失败');
    }
    final variants = <EpisodeVariant>[];
    final rawVariants = data['variants'];
    if (rawVariants is List) {
      for (final row in rawVariants) {
        if (row is! Map) continue;
        final name = '${row['name']}'.trim();
        final raw = '${row['url'] ?? ''}'.trim();
        final key = '${row['key_hex'] ?? ''}'.trim();
        if (name.isEmpty || raw.isEmpty) continue;
        final vUrl = ApiClient.instance.absoluteUrl(raw);
        final vUri = Uri.tryParse(vUrl);
        if (vUri == null ||
            (vUri.scheme != 'http' && vUri.scheme != 'https') ||
            vUri.host.isEmpty) {
          continue;
        }
        variants.add(
          EpisodeVariant(
            name: name,
            url: vUrl,
            keyHex: key,
            height: int.tryParse('${row['height'] ?? ''}') ?? 0,
          ),
        );
      }
    }
    return EpisodeSource(
      url,
      (data['key_hex'] ?? '').toString().trim(),
      variants,
      _verticalOf(data['vertical'] ?? response['vertical']),
    );
  }
}

/// The rendition to try after [failed] could not start: the next lower one
/// with a different stream, else the next higher one. Null when [failed] is
/// not listed or no other stream exists.
EpisodeVariant? fallbackVariant(List<EpisodeVariant> variants, String failed) {
  final index = variants.indexWhere((variant) => variant.name == failed);
  if (index < 0) return null;
  final url = variants[index].url;
  for (final variant in variants.skip(index + 1)) {
    if (variant.url != url) return variant;
  }
  for (final variant in variants.take(index).toList().reversed) {
    if (variant.url != url) return variant;
  }
  return null;
}

/// Lenient `vertical` decoding for the backend response.
bool? _verticalOf(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final text = value.trim().toLowerCase();
    if (text == 'true' || text == '1') return true;
    if (text == 'false' || text == '0') return false;
  }
  return null;
}

enum EpisodeSourceOrigin {
  network,
  cacheHit,
  pending,
  prefetchHit,
  prefetchPending,
}

class EpisodeSourceRequest {
  final Future<EpisodeSource> future;
  final EpisodeSourceOrigin origin;

  const EpisodeSourceRequest(this.future, this.origin);
}

/// 往后 [ahead] 集的预加载窗口：当前集之后、尚未播到的集（11-01 预加载
/// 规格：往后 5 集）。窗口随播滑动（换集时调用方重算），集数不够时只返回
/// 剩余的集，到最后一集时返回空表；只算地址、不建播放器、不下载视频字节。
List<Chapter> upcomingChapters(
  List<Chapter> episodes,
  int index, {
  int ahead = 5,
}) {
  if (episodes.isEmpty || index < 0 || index >= episodes.length) return const [];
  final end = (index + 1 + ahead).clamp(0, episodes.length);
  return episodes.sublist(index + 1, end);
}

/// Page-local address metadata only. Never creates a player or downloads video.
/// Completed entries are bounded; outstanding demand requests remain joinable
/// until they finish, even if a quick swipe temporarily leaves their episode.
class EpisodeSourceCache {
  /// 覆盖往后 5 集短剧：5 集 × 每集约 2 分钟。
  static const timeToLive = Duration(minutes: 10);

  /// 当前集 + 往后 5 集（11-01 预加载规格：总数始终维持 5 集预加载）。
  static const capacity = 6;

  final Future<EpisodeSource> Function(Chapter) _loader;
  final Duration Function() _now;
  final _ready = <String, _SourceEntry>{};
  final _pending = <String, _SourceEntry>{};
  Set<String>? _retained;
  Future<void>? _prefetching;
  bool _disposed = false;

  EpisodeSourceCache({required this._loader, Duration Function()? now})
    : _now = now ?? _monotonicClock();

  void retainOnly(Set<String> ids) {
    _retained = Set.of(ids);
    _ready.removeWhere((id, _) => !ids.contains(id));
  }

  EpisodeSourceRequest request(Chapter chapter, {bool refresh = false}) =>
      _request(chapter, refresh: refresh, prefetch: false);

  EpisodeSourceRequest _request(
    Chapter chapter, {
    bool refresh = false,
    required bool prefetch,
  }) {
    if (_disposed) throw StateError('Episode source cache is disposed');
    final id = chapter.itemId;
    if (refresh) invalidate(id);
    _ready.removeWhere((_, entry) => !_fresh(entry));
    final ready = _ready.remove(id);
    if (ready != null) {
      _ready[id] = ready;
      return EpisodeSourceRequest(
        ready.future,
        ready.prefetched
            ? EpisodeSourceOrigin.prefetchHit
            : EpisodeSourceOrigin.cacheHit,
      );
    }
    final pending = _pending[id];
    if (pending != null && _fresh(pending)) {
      return EpisodeSourceRequest(
        pending.future,
        pending.prefetched
            ? EpisodeSourceOrigin.prefetchPending
            : EpisodeSourceOrigin.pending,
      );
    }
    final entry = _SourceEntry(_now(), prefetch);
    _pending[id] = entry;
    entry.future = Future.sync(() => _loader(chapter)).then(
      (source) {
        if (!_disposed && identical(_pending[id], entry)) {
          _pending.remove(id);
          if (_fresh(entry) && (_retained?.contains(id) ?? true)) {
            _ready[id] = entry;
            while (_ready.length > capacity) {
              _ready.remove(_ready.keys.first);
            }
          }
        }
        return source;
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_pending[id], entry)) _pending.remove(id);
        Error.throwWithStackTrace(error, stack);
      },
    );
    return EpisodeSourceRequest(entry.future, EpisodeSourceOrigin.network);
  }

  /// Only one speculative request may be in flight. A queued request checks
  /// the page's lifecycle/selection again before it is allowed to start.
  /// Speculative failures are silent and evicted so demand can retry normally.
  Future<void> prefetch(
    Chapter chapter, {
    required bool Function() stillWanted,
  }) async {
    while (_prefetching != null) {
      await _prefetching;
      if (_disposed) return;
    }
    if (_disposed || !stillWanted()) return;
    final request = _request(chapter, prefetch: true);
    final pending = request.future.then<void>((_) {}, onError: (Object _) {});
    _prefetching = pending;
    await pending;
    if (identical(_prefetching, pending)) _prefetching = null;
  }

  bool _fresh(_SourceEntry entry) => _now() - entry.started < timeToLive;

  void invalidate(String id) {
    _ready.remove(id);
    // A late result from this request cannot replace a refreshed entry.
    _pending.remove(id);
  }

  void dispose() {
    _disposed = true;
    _ready.clear();
    _pending.clear();
    _retained = null;
  }
}

class _SourceEntry {
  final Duration started;
  final bool prefetched;
  late final Future<EpisodeSource> future;

  _SourceEntry(this.started, this.prefetched);
}

/// 跨页共享的取流预取存储：信息流里提前取到的下一部第一集地址，供播放页直接用。
///
/// 键是 `bookId|itemId`（Chapter 本身不带 bookId，调用方拼；两边都走
/// [keyFor]，保证拼法一致）。只给 ApiClient 默认路径用：写的一方是信息流
/// 的 prefetchNextDrama，读的一方是播放页 _episodeSource，且仅当播放页
/// 的 contentLoader 为空时才读（站点专用 loader 的播放页不读，避免跨站串扰）。
/// 只存地址、不建播放器、不下载视频字节；TTL 与页内缓存一致（10 分钟）。
class SharedEpisodePrefetch {
  static const timeToLive = Duration(minutes: 10);

  /// 往后 3 部 × 每部 1 集，另留余量给滑动时新进窗口的部。
  static const capacity = 12;

  static final SharedEpisodePrefetch instance = SharedEpisodePrefetch._();

  /// 仅测试用：一个隔离的实例（自己的表 + 自己的时钟）。
  factory SharedEpisodePrefetch.forTest({required Duration Function() now}) =>
      SharedEpisodePrefetch._(now: now);

  SharedEpisodePrefetch._({Duration Function()? now})
    : _now = now ?? _monotonicClock();

  final Duration Function() _now;
  final _entries = <String, _SharedEntry>{};

  static String keyFor(String bookId, String itemId) => '$bookId|$itemId';

  void put({
    required String bookId,
    required String itemId,
    required EpisodeSource source,
  }) {
    _entries.removeWhere((_, entry) => !_fresh(entry));
    final key = keyFor(bookId, itemId);
    _entries.remove(key);
    _entries[key] = _SharedEntry(_now(), source);
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  EpisodeSource? get({required String bookId, required String itemId}) {
    final key = keyFor(bookId, itemId);
    final entry = _entries[key];
    if (entry == null) return null;
    if (!_fresh(entry)) {
      _entries.remove(key);
      return null;
    }
    return entry.source;
  }

  bool _fresh(_SharedEntry entry) => _now() - entry.started < timeToLive;

  /// 仅测试用：清空本实例的表。
  void clear() => _entries.clear();
}

class _SharedEntry {
  final Duration started;
  final EpisodeSource source;

  _SharedEntry(this.started, this.source);
}

/// 外站解析结果的跨页内存缓存：切到别的站、再切回来时不再重新跑
/// playerContent 取流，直接用缓存的地址播。
///
/// 与页内缓存的区别：
/// - [EpisodeSourceCache] 是每页一个实例，键只有集 id，页面销毁即失效，
///   切站回来必然重新解析；[SharedEpisodePrefetch] 只给原始站预取用，
///   键是 bookId|itemId，且只读不写解析结果。
/// - 本缓存是进程内全局单例，键含站 + 视频 + 集，同一视频不同集、同一集
///   不同站都区分开；退出进程即清空，不落盘——地址常带签名，落盘既要
///   管过期又涉隐私，内存已满足“切站回来”这个场景。
///
/// 只存解析成功的原始地址（client.playSource 的返回值、进代理之前）：
/// - 命中时仍走正常播放链路：代理映射（_proxyIfNeeded）与 dict 头每次
///   都重做，只是跳过 playerContent 取流，代理与头信息不会丢；
/// - 失败不缓存：取流抛错只清在途记录，下次调用重新解析（可重试）；
/// - 两个并发请求同键只解析一次，后到的加入在途的同一个 Future。
///
/// 过期 10 分钟，依据：
/// - 草榴签名地址有效期约请求时 +6800 秒（rust/src/endpoints/drama/
///   caoliu.rs），v01 的 geo 令牌 ttl 兜底 3600 秒（v01.rs）；
/// - 树内同类签名地址缓存（EpisodeSourceCache、SharedEpisodePrefetch）
///   早已用 10 分钟，且 10 分钟远小于上述两个已知有效期下限（3600 秒
///   的约 1/6），过期地址硬播的风险低；过期后再次调用重新解析。
class DramaPlaySourceCache {
  static const timeToLive = Duration(minutes: 10);

  /// 32 条：切站回来只涉及最近看过的几部剧几集，32 条足够覆盖；
  /// 只存原始地址不占代理会话，不会顶掉本地代理 200 会话的上限。
  static const capacity = 32;

  static final DramaPlaySourceCache instance = DramaPlaySourceCache._();

  /// 仅测试用：一个隔离的实例（自己的表 + 自己的时钟）。
  factory DramaPlaySourceCache.forTest({required Duration Function() now}) =>
      DramaPlaySourceCache._(now: now);

  DramaPlaySourceCache._({Duration Function()? now})
    : _now = now ?? _monotonicClock();

  final Duration Function() _now;
  final _ready = <String, _ResolvedEntry>{};
  final _pending = <String, Future<DramaPlaySource>>{};

  static String keyFor({
    required String siteId,
    required String seriesId,
    required String videoId,
  }) => '$siteId|$seriesId|$videoId';

  /// 取流（命中缓存直接回，不命中跑 [loader] 解析一次）：
  /// 成功才缓存，失败不缓存、错误原样抛给调用方重试。
  Future<DramaPlaySource> resolve({
    required String siteId,
    required String seriesId,
    required String videoId,
    required Future<DramaPlaySource> Function() loader,
  }) {
    final key = keyFor(
      siteId: siteId,
      seriesId: seriesId,
      videoId: videoId,
    );
    _ready.removeWhere((_, entry) => !_fresh(entry));
    final ready = _ready.remove(key);
    if (ready != null) {
      _ready[key] = ready;
      return Future.value(ready.source);
    }
    final pending = _pending[key];
    if (pending != null) return pending;
    final started = _now();
    late final Future<DramaPlaySource> future;
    future = Future.sync(loader).then(
      (source) {
        if (identical(_pending[key], future)) {
          _pending.remove(key);
          if (_freshEntry(started)) {
            _ready[key] = _ResolvedEntry(started, source);
            while (_ready.length > capacity) {
              _ready.remove(_ready.keys.first);
            }
          }
        }
        return source;
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_pending[key], future)) _pending.remove(key);
        Error.throwWithStackTrace(error, stack);
      },
    );
    _pending[key] = future;
    return future;
  }

  /// 后台暖缓存：只解析、不建播放器；失败静默丢弃，不影响当前播放，
  /// 下次点播时重新解析。
  void prefetch({
    required String siteId,
    required String seriesId,
    required String videoId,
    required Future<DramaPlaySource> Function() loader,
  }) {
    unawaited(
      resolve(
        siteId: siteId,
        seriesId: seriesId,
        videoId: videoId,
        loader: loader,
      ).then<void>((_) {}, onError: (Object _) {}),
    );
  }

  bool _fresh(_ResolvedEntry entry) => _freshEntry(entry.started);

  bool _freshEntry(Duration started) => _now() - started < timeToLive;

  void invalidate({
    required String siteId,
    required String seriesId,
    required String videoId,
  }) {
    final key = keyFor(
      siteId: siteId,
      seriesId: seriesId,
      videoId: videoId,
    );
    _ready.remove(key);
    _pending.remove(key);
  }

  /// 仅测试用：清空本实例的表。
  void clear() {
    _ready.clear();
    _pending.clear();
  }
}

class _ResolvedEntry {
  final Duration started;
  final DramaPlaySource source;

  _ResolvedEntry(this.started, this.source);
}

Duration Function() _monotonicClock() {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
}

// Compatibility with older backends without normalized stream metadata.
String _extractVideoUrl(Map<String, dynamic> payload) {
  String visit(dynamic value, [int depth = 0]) {
    if (depth > 7 || value == null) return '';
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.startsWith('http://') ||
          trimmed.startsWith('https://') ||
          trimmed.startsWith('/src/')) {
        return trimmed;
      }
      if (trimmed.startsWith('{')) {
        try {
          return visit(jsonDecode(trimmed), depth + 1);
        } catch (_) {
          return '';
        }
      }
      return '';
    }
    if (value is List) {
      for (final item in value.reversed) {
        final found = visit(item, depth + 1);
        if (found.isNotEmpty) return found;
      }
      return '';
    }
    if (value is Map) {
      for (final key in ['video_url', 'play_url', 'main_url', 'url']) {
        final found = visit(value[key], depth + 1);
        if (found.isNotEmpty) return found;
      }
      for (final key in [
        'data',
        'video_info',
        'video_list',
        'play_info_list',
        'video_model',
      ]) {
        final found = visit(value[key], depth + 1);
        if (found.isNotEmpty) return found;
      }
      for (final nested in value.values) {
        final found = visit(nested, depth + 1);
        if (found.isNotEmpty) return found;
      }
    }
    return '';
  }

  return visit(payload);
}
