// 适配层：女优库模块在魔蚁侧依赖的 AppRepository（原 lib/core_bridge.dart
// 的抽象仓储，背后是魔蚁 Go 核 + py/jar 引擎）。
//
// 修仙版没有 Go 核，等价物是 SourceRegistry + DramaSiteContentClient
//（py / jar / 核心三路客户端，见 services/drama_site_content.dart）。
// 本文件只实现女优库实际调的 7 个方法，其余魔蚁仓储方法（红果账号、
// 榜单、下载、解析接口等）女优库没用到，未搬。
//
// 关键语义（与魔蚁 v42 一致）：
// - catalog / categories / detail / searchAcross：委托给注册表现取的
//   站客户端；站未注册、被用户关掉、取数失败时按站失败（searchAcross
//   跳过该站，catalog/detail/resolve 抛 AppFailure），不伪造空结果；
// - resolve：库里直链（episode raw['direct']==true，或 id / playId
//   本身就是 http(s) 地址）直接回 plan，不碰站客户端——2026-11-22
//   用户令“女优库全部播放只走数据库里的数据”，详情页点播就是这条；
//   站内集先调 client.playSource，dict 头非空时经 LocalMediaProxy
//   注册成本地代理地址（头随会话存，播放器拿裸地址播，与
//   drama_site_play._proxyIfNeeded 同一分支；外来壳代理地址先解包
//   再注册，解不出且站未实现 localProxy 时报诚实错误）；
// - cover：只回 drama.cover（懒取封面是魔蚁播放器内部用的，女优库
//   卡片直接用 drama.cover，不再二次取）；
// - searchAcrossProgressive：沿用魔蚁基类的默认实现（先整批搜完再
//   按站拆回调），修仙版 searchAllSites 另有 XP 门禁分流，这里不用。
//
// 注意：魔蚁的跨站探活计划里有 jar: / Go 槽 id（如
// jar:missav30:ZakaMissav、v_mjv011），修仙版注册表里没有这些 id，
// clientFor 回空、探活按站失败；站源合并（站点工人范围）完成后，
// 注册表里有了对应站，这些计划自动生效，不用改本文件。

import 'dart:async';
import 'dart:convert';

import '../services/drama_playback.dart' show DramaPlaySource;
import '../services/drama_site_content.dart'
    show
        DramaSiteContentClient,
        DramaSiteDetail,
        DramaSiteEpisode,
        DramaSiteItem;
import '../services/local_media_proxy.dart' show LocalMediaProxy;
import '../services/source_registry.dart' show SourceRegistry;
import 'actress_adapter_models.dart'
    show
        AppFailure,
        CatalogCategory,
        CatalogPage,
        Drama,
        DramaDetail,
        Episode,
        PlaybackPlan;

/// 魔蚁 AppRepository 在女优库里的实际用量（抽象口径）。
abstract class AppRepository {
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  });

  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  });

  /// 跨源聚合搜索：并发打所有给定站源，返回归一去重后的结果。
  Future<CatalogPage> searchAcross(List<String> sources, String query);

  /// 流式跨源搜索：每站回结果立即调 [onSite]，不等全部站回完。
  /// 默认实现走批回 [searchAcross] 再按站拆开回调。
  Future<void> searchAcrossProgressive(
    List<String> sources,
    String query, {
    required void Function(String source, List<Drama> items) onSite,
    bool Function()? shouldStop,
  }) async {
    if (shouldStop != null && shouldStop()) return;
    final page = await searchAcross(sources, query);
    final bySource = <String, List<Drama>>{};
    for (final item in page.items) {
      (bySource[item.source] ??= []).add(item);
    }
    for (final entry in bySource.entries) {
      if (shouldStop != null && shouldStop()) return;
      onSite(entry.key, entry.value);
    }
  }

  Future<String> cover(Drama drama, {bool force = false});

  Future<DramaDetail> detail(Drama drama);

  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  });
}

/// 修仙版实现：站客户端委托 + 库直链直通。
class XiuxianAppRepository extends AppRepository {
  XiuxianAppRepository();

  /// 测试/入口注入用：直接拿现成实例当仓储。
  static final XiuxianAppRepository shared = XiuxianAppRepository();

  Future<DramaSiteContentClient?> _clientFor(String siteId) =>
      SourceRegistry.instance.clientFor(siteId);

  Drama _itemToDrama(String source, DramaSiteItem item) => Drama(
    id: item.id,
    source: source,
    title: item.title,
    cover: item.cover,
    description: item.remark,
  );

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    final client = await _clientFor(source);
    if (client == null) throw AppFailure('该站源当前不可用');
    final rows = await client.categories();
    return [
      for (final row in rows) CatalogCategory(row.id, row.name),
    ];
  }

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    final client = await _clientFor(source);
    if (client == null) throw AppFailure('该站源当前不可用');
    if (query.trim().isNotEmpty) {
      final hits = await client.search(query.trim());
      return CatalogPage(
        [for (final hit in hits) _itemToDrama(source, hit)],
        page: 1,
      );
    }
    final result = await client.catalog(category, page);
    return CatalogPage(
      [for (final item in result.items) _itemToDrama(source, item)],
      hasMore: result.hasMore,
      page: page,
    );
  }

  @override
  Future<CatalogPage> searchAcross(
    List<String> sources,
    String query,
  ) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return CatalogPage(const []);
    final out = <Drama>[];
    final seen = <String>{};
    Future<void> worker(String source) async {
      DramaSiteContentClient? client;
      try {
        client = await _clientFor(source);
      } catch (_) {
        return;
      }
      if (client == null) return;
      List<DramaSiteItem> hits;
      try {
        hits = await client.search(trimmed);
      } catch (_) {
        return;
      }
      for (final hit in hits) {
        final drama = _itemToDrama(source, hit);
        if (seen.add('${drama.source}|${drama.id}')) out.add(drama);
      }
    }

    // 逐站串行：站数多、单站慢/挂是常态，并行 burst 会把出口打满。
    for (final source in sources) {
      await worker(source);
    }
    return CatalogPage(out);
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async =>
      drama.cover;

  @override
  Future<DramaDetail> detail(Drama drama) async {
    final client = await _clientFor(drama.source);
    if (client == null) throw AppFailure('该站源当前不可用');
    final loaded = await client.detail(drama.id);
    return _siteDetailToDramaDetail(drama, loaded);
  }

  DramaDetail _siteDetailToDramaDetail(
    Drama drama,
    DramaSiteDetail loaded,
  ) {
    final detailDrama = Drama(
      id: loaded.id,
      source: drama.source,
      sourceId: drama.sourceId,
      title: loaded.title,
      description: loaded.synopsis,
      cover: loaded.cover.isNotEmpty ? loaded.cover : drama.cover,
      episodes: loaded.episodes.length,
      category: loaded.extra['type_name'] ?? drama.category,
    );
    return DramaDetail(detailDrama, [
      for (var i = 0; i < loaded.episodes.length; i++)
        Episode({
          'id': loaded.episodes[i].videoId,
          'title': loaded.episodes[i].title,
          'flag': '正片',
          'currentEpisode': i + 1,
        }, i + 1),
    ]);
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async {
    // 库里直链：id / playId 本身就是地址，或 raw 标了 direct——
    // 直接回 plan，不碰站客户端（只走数据库令）。
    final direct = _directUrlOf(episode);
    if (direct != null) {
      return PlaybackPlan(
        url: direct,
        headers: _headersOf(episode.raw),
        needsParse: false,
      );
    }
    final client = await _clientFor(drama.source);
    if (client == null) throw AppFailure('该站源当前不可用');
    final episodeRef = DramaSiteEpisode(
      videoId: episode.id,
      title: episode.title,
      seriesId: drama.id,
    );
    final source = await client.playSource(episodeRef);
    final url = await _proxyIfNeeded(source);
    return PlaybackPlan(url: url, headers: const {}, needsParse: false);
  }

  /// 集里自带的直链地址：direct 标记优先，其次 id / playId / url。
  String? _directUrlOf(Episode episode) {
    final raw = episode.raw;
    for (final key in const ['id', 'playId', 'url']) {
      final value = raw[key];
      if (value is! String) continue;
      final text = value.trim();
      if (text.startsWith('http://') || text.startsWith('https://')) {
        if (key != 'id' || raw['direct'] == true || _looksLikeStream(text)) {
          return text;
        }
      }
    }
    return null;
  }

  /// id 是 http(s) 地址时，只在 direct 标记或流媒体形态下认作直链：
  /// 站内集的 id 常是视频 vid（如 '12345'），不是地址；但 whos 本地
  /// 详情的集 id 就是 hersav 直链（以 .m3u8 结尾），必须认。
  bool _looksLikeStream(String text) {
    final lower = text.toLowerCase();
    return lower.endsWith('.m3u8') ||
        lower.endsWith('.mp4') ||
        lower.contains('.m3u8?') ||
        lower.contains('.mp4?');
  }

  Map<String, String> _headersOf(Map<String, dynamic> raw) {
    final headers = raw['headers'];
    if (headers is! Map) return const {};
    return {
      for (final entry in headers.entries)
        if (entry.value is String) entry.key.toString(): entry.value as String,
    };
  }

  /// 取流结果 → 播放器可播地址（drama_site_play._proxyIfNeeded 同款
  /// 分支，减去蜘蛛 localProxy 会话那条——女优库直链不需要它）：
  /// 外来壳代理地址先解包，解得出上游就走本地代理转发（带播放头）；
  /// dict 头非空的直链经本地代理带上；其余直链原样。
  Future<String> _proxyIfNeeded(DramaPlaySource source) async {
    final url = source.url;
    if (_isForeignProxyUrl(url)) {
      final unwrapped = _unwrapForeignProxyUrl(url);
      if (unwrapped != null) {
        final headers = {...unwrapped.headers, ...source.headers};
        return LocalMediaProxy.instance.register(
          targetUrl: unwrapped.target,
          headers: headers,
        );
      }
      // 解不出（不透明令牌）：只能由蜘蛛自己的 localProxy 解析，
      // 适配层没有该会话，原样返回、播放器按原地址播，播不了时
      // 播放器自身报错，不在这里伪造地址。
      return url;
    }
    if (source.headers.isNotEmpty && url.startsWith('http')) {
      return LocalMediaProxy.instance.register(
        targetUrl: url,
        headers: source.headers,
      );
    }
    return url;
  }

  /// 外来壳代理地址判定：回环 host + 路径含 proxy，且不是本代理
  /// 自己的会话地址。
  bool _isForeignProxyUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.host != '127.0.0.1' && uri.host != 'localhost') return false;
    if (!uri.path.contains('proxy')) return false;
    return !LocalMediaProxy.instance.owns(url);
  }

  /// 外来壳代理地址解包：从 127.0.0.1:9978/proxy 这类地址里取出真正
  /// 的上游地址与查询里的头；取不出回空。
  ({String target, Map<String, String> headers})? _unwrapForeignProxyUrl(
    String url,
  ) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.query.isEmpty) return null;
    String? candidate;
    for (final key in const [
      'url',
      'u',
      'target',
      'src',
      'link',
      'playUrl',
      'playurl',
    ]) {
      final value = uri.queryParameters[key];
      if (value != null && value.isNotEmpty) {
        candidate = value;
        break;
      }
    }
    candidate ??= uri.query;
    var decoded = candidate;
    for (var i = 0; i < 2; i++) {
      if (decoded.contains('%3A') ||
          decoded.contains('%2F') ||
          decoded.contains('%3a') ||
          decoded.contains('%2f')) {
        try {
          decoded = Uri.decodeFull(decoded);
        } catch (_) {
          break;
        }
      } else {
        break;
      }
    }
    if (!decoded.startsWith('http://') && !decoded.startsWith('https://')) {
      return null;
    }
    final headers = <String, String>{};
    for (final key in const ['header', 'headers']) {
      final raw = uri.queryParameters[key];
      if (raw == null || raw.isEmpty) continue;
      try {
        final parsed = jsonDecode(raw);
        if (parsed is Map) {
          for (final entry in parsed.entries) {
            if (entry.value is String) {
              headers[entry.key.toString()] = entry.value as String;
            }
          }
        }
      } catch (_) {}
    }
    return (target: decoded, headers: headers);
  }
}
