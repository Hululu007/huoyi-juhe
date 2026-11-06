import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../models/playlet_comment.dart';
import '../models/series_detail.dart';
import '../pages/listen_mode_page.dart';
import '../pages/pics_viewer_page.dart';
import '../pages/player_page.dart';
import '../pages/reader_page.dart';
import '../pages/search_page.dart';
import '../pages/series_detail_page.dart';
import '../pages/tgdrama_channel_page.dart';
import 'drama_playback.dart';
import 'drama_site_content.dart';
import 'engine_reading_store.dart';
import 'library_store.dart';
import 'midnight_gate.dart';
import 'reader_history.dart';
import 'episode_source_cache.dart';
import 'local_media_proxy.dart';
import 'nonvideo_play.dart';
import 'shelf_store.dart';
import 'source_registry.dart';
import 'tgdrama_content.dart';

/// 外站剧集的详情与播放入口：只用原始站点的详情页与播放页。
/// 详情页拿目录与标题封面，播放页拿选集与取流；评论与底部信息
/// 外站没有，不去原站接口取，返回空页，避免把外站 id 送去原站查。
/// 外站取流预加载：当前集解析完后，后台预取后面两集的播放地址，
///
/// 切到下一集时先命中缓存，不再等一次接口；预取失败直接丢弃，
///
/// 不影响当前播放。缓存只留当前这部剧，退出详情页即失效。
/// 外来壳代理地址判定（可单测）：回环 host + 路径含 proxy，且不是
/// 本代理自己的会话地址（本代理地址也回环，但 owns 判定在前）。
bool isForeignProxyUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  if (uri.host != '127.0.0.1' && uri.host != 'localhost') return false;
  if (!uri.path.contains('proxy')) return false;
  return !LocalMediaProxy.instance.owns(url);
}

/// 外来壳代理地址解包（可单测）：从 127.0.0.1:9978/proxy 这类外壳代理
/// 地址里取出真正的上游地址；取不出（查询是不透明令牌、只能由蜘蛛
/// 自己的 localProxy 解析）时回空，调用方改走蜘蛛 localProxy 会话。
/// 常见形态：?url=、?u=、?target=、?src=、?link=、?playUrl=（值已解码
/// 一次，双重编码的再解一次），以及整个查询串本身就是一条 urlencoded
/// 上游地址；查询里带的 header/headers（JSON 对象）一并取出。
/// 注意：本函数只看查询形态，不判定是不是外来代理地址；生产调用方
/// 先过 isForeignProxyUrl 再调它，避免把正常带 url 参数的接口误解包。
({String target, Map<String, String> headers})? unwrapForeignProxyUrl(
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

/// 取流结果 → 播放器可播地址：逐条地址独立决策——外来壳代理地址先解包，
/// 解得出上游就走 /r/ 转发（带播放头与查询里的头，不再要求蜘蛛实现
/// localProxy）；解不出（不透明令牌）才走蜘蛛 localProxy 会话，蜘蛛没
/// 实现就报诚实错误；dict 头非空的直链经 /r/ 带上；其余直链原样。
/// 主地址与每个 variant 一起换，keyHex 与高度原样保留。
Future<DramaPlaySource> _proxyIfNeeded(
  DramaSiteContentClient client,
  DramaPlaySource source,
) async {
  final proxy = LocalMediaProxy.instance;
  // /h/ 会话懒注册：只有遇到解不出上游的外来代理地址时才建。
  String? sessionUrl;
  Future<String> handlerSessionUrl() async {
    if (sessionUrl != null) return sessionUrl!;
    if (client is! LocalProxyCapable) {
      throw StateError('该站未实现本地代理，无法转接壳代理地址');
    }
    final capable = client as LocalProxyCapable;
    sessionUrl = await proxy.registerHandler(
      handler: (requestUri) async {
        final result = await capable.localProxy(requestUri);
        if (result == null) {
          throw StateError('该站未实现本地代理');
        }
        return result;
      },
    );
    return sessionUrl!;
  }

  Future<String> mapOne(String url) async {
    if (isForeignProxyUrl(url)) {
      final unwrapped = unwrapForeignProxyUrl(url);
      if (unwrapped != null) {
        final headers = {...unwrapped.headers, ...source.headers};
        return proxy.register(targetUrl: unwrapped.target, headers: headers);
      }
      final session = await handlerSessionUrl();
      final query = Uri.parse(url).query;
      return query.isEmpty ? session : '$session?$query';
    }
    if (source.headers.isNotEmpty && url.startsWith('http')) {
      return proxy.register(targetUrl: url, headers: source.headers);
    }
    return url;
  }

  final mappedUrl = await mapOne(source.url);
  final variants = <DramaPlayVariant>[];
  for (final variant in source.variants) {
    variants.add(
      DramaPlayVariant(
        name: variant.name,
        url: await mapOne(variant.url),
        keyHex: variant.keyHex,
        height: variant.height,
      ),
    );
  }
  return DramaPlaySource(
    url: mappedUrl,
    keyHex: source.keyHex,
    variants: variants,
  );
}

class _PlaySourcePreload {
  final Map<String, DramaPlaySource> _cache = {};
  final Set<String> _inFlight = {};

  String _key(DramaSiteEpisode episode) =>
      '${episode.seriesId}|${episode.videoId}';

  DramaPlaySource? take(DramaSiteEpisode episode) => _cache[_key(episode)];

  void put(DramaSiteEpisode episode, DramaPlaySource source) {
    _cache[_key(episode)] = source;
  }

  Future<void> _fetchAndCache(
    DramaSiteContentClient client,
    DramaSiteEpisode episode,
    String key,
  ) async {
    try {
      final raw = await client.playSource(episode);
      _cache[key] = await _proxyIfNeeded(client, raw);
    } catch (_) {
    } finally {
      _inFlight.remove(key);
    }
  }

  void prefetch(
    DramaSiteContentClient client,
    List<DramaSiteEpisode> episodes,
    int currentIndex,
  ) {
    for (var i = 1; i <= 2; i++) {
      final next = currentIndex + i;
      if (next >= episodes.length) break;
      final episode = episodes[next];
      final key = _key(episode);
      if (_cache.containsKey(key) || !_inFlight.add(key)) continue;
      unawaited(_fetchAndCache(client, episode, key));
    }
  }
}

List<SourceEntry> engineSwitchCandidates(
  List<SourceEntry> entries, {
  Set<ContentType>? types,
}) {
  return [
    for (final entry in entries)
      if (entry.enabled &&
          (types == null || types.contains(entry.contentType)) &&
          (entry.kind == SourceKind.pyImport ||
              entry.kind == SourceKind.jarImport ||
              entry.kind == SourceKind.jsImport ||
              entry.kind == SourceKind.xbpqImport ||
              entry.kind == SourceKind.legadoImport ||
              entry.extra['remoteConfigId'] != null))
        entry,
  ];
}

class _SwitchHit {
  const _SwitchHit({
    required this.siteId,
    required this.siteName,
    required this.item,
  });

  final String siteId;
  final String siteName;
  final DramaSiteItem item;
}

Future<void> showEngineSourceSwitch(
  BuildContext context, {
  required String title,
  required int currentIndex,
  required String currentSiteId,
  Set<ContentType> types = const {ContentType.mixed},
}) async {
  await MidnightGate.ensureLoaded();
  if (!context.mounted) return;
  final gateOpen = MidnightGate.activated.value;
  final candidates = engineSwitchCandidates(
    SourceRegistry.instance.custom,
    types: types,
  )
      .where((entry) => entry.id != currentSiteId)
      .where(
        (entry) => gateOpen || !MidnightGate.isAdultName(entry.name),
      )
      .toList();
  final hits = await showDialog<List<_SwitchHit>>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('换源'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.search),
              title: Text('原始版搜索：$title'),
              subtitle: const Text('去原始版（番茄）搜同名书'),
              onTap: () {
                Navigator.pop(dialogContext);
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => SearchPage(initialQuery: title),
                  ),
                );
              },
            ),
            const Divider(height: 1),
            Flexible(
              child: candidates.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: Text('没有其他可换源的导入站'),
                    )
                  : FutureBuilder<List<_SwitchHit>>(
          future: Future.wait(
            candidates.map((entry) async {
              try {
                final client = await SourceRegistry.instance.clientFor(
                  entry.id,
                );
                if (client == null) return null;
                final results = await client
                    .search(title)
                    .timeout(const Duration(seconds: 15));
                if (results.isEmpty) return null;
                return _SwitchHit(
                  siteId: entry.id,
                  siteName: entry.name,
                  item: results.first,
                );
              } catch (_) {
                return null;
              }
            }),
          ).then(
            (rows) => rows.whereType<_SwitchHit>().toList(),
          ),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final rows = snapshot.data!;
            if (rows.isEmpty) {
              return const Text('其他站没有搜到同名内容');
            }
            return ListView.builder(
              shrinkWrap: true,
              itemCount: rows.length,
              itemBuilder: (_, i) {
                final hit = rows[i];
                return ListTile(
                  title: Text(hit.item.title),
                  subtitle: Text(hit.siteName),
                  onTap: () => Navigator.pop(dialogContext, [hit]),
                );
              },
            );
          },
            ),
          ),
          ],
        ),
      ),
    ),
  );
  if (hits == null || hits.isEmpty) return;
  final picked = hits.first;
  if (!context.mounted) return;
  await openDramaSitePlayback(
    context,
    siteId: picked.siteId,
    seriesId: picked.item.id,
    title: picked.item.title,
    cover: picked.item.cover,
    startIndex: currentIndex,
  );
}

Future<void> openDramaSitePlayback(
  BuildContext context, {
  required String siteId,
  required String seriesId,
  required String title,
  required String cover,
  List<Chapter>? episodes,
  int startIndex = 0,
  SeriesDetail? initialDetail,
}) async {
  final client = await SourceRegistry.instance.clientFor(siteId);
  if (!context.mounted) return;
  if (client == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('该站源当前不可用')));
    return;
  }
  final preload = _PlaySourcePreload();
  final entry = SourceRegistry.instance.customById(siteId);
  // 播放页收藏与详情页收藏同规则：按站点登记的内容类型定架子，
  // 未登记的站按当前内容定（视频 video、音频 audio）。
  String shelfKind(String fallback) =>
      entry == null ? fallback : engineShelfKindFor(entry.contentType);
  DramaSiteDetail? cachedDetail;
  Future<DramaSiteDetail> loadSiteDetail() async {
    cachedDetail ??= await client.detail(seriesId);
    return cachedDetail!;
  }

  var resolvedEpisodes = episodes;
  if (resolvedEpisodes == null) {
    try {
      final loaded = await loadSiteDetail();
      resolvedEpisodes = [
        for (final episode in loaded.episodes)
          Chapter(
            itemId: episode.videoId,
            title: episode.title,
            volumeName: '',
          ),
      ];
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('目录加载失败：$error')),
        );
      }
      return;
    }
  }
  if (resolvedEpisodes.isEmpty) return;
  final safeIndex = startIndex.clamp(0, resolvedEpisodes.length - 1);
  final chapters = resolvedEpisodes;

  Future<DramaPlaySource> resolveSource(Chapter chapter) async {
    final episode = DramaSiteEpisode(
      videoId: chapter.itemId,
      title: chapter.title,
      seriesId: seriesId,
    );
    final cached = preload.take(episode);
    if (cached != null) return cached;
    final raw = await client.playSource(episode);
    final source = await _proxyIfNeeded(client, raw);
    preload.put(episode, source);
    final loaded = await loadSiteDetail();
    final found = loaded.episodes.indexWhere(
      (e) => e.videoId == episode.videoId,
    );
    if (found >= 0) {
      preload.prefetch(client, loaded.episodes, found);
    }
    return source;
  }

  void saveIndex(int index) {
    unawaited(EngineReadingStore.instance.saveIndex(siteId, seriesId, index));
  }

  void addToShelf({String kind = 'book'}) {
    final item = MediaItem(
      id: 'engine:$siteId:$seriesId',
      title: title,
      cover: cover,
      author: '',
      badge: siteId.startsWith('localdb:') ? '本地库' : '',
      ep: '',
      kind: kind,
      source: 'engine:$siteId',
      seriesId: seriesId,
    );
    unawaited(
      ShelfStore.instance.add(item).then((_) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已加入书架')));
        }
      }),
    );
  }

  DramaPlaySource first;
  try {
    first = await resolveSource(chapters[safeIndex]);
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('取流失败：$error')),
      );
    }
    return;
  }
  if (!context.mounted) return;
  switch (classifyPlayUrl(first.url)) {
    case PlayUrlKind.novel:
      final engineBookId = 'engine:$siteId:$seriesId';
      var readerStart = safeIndex;
      try {
        final saved =
            await ReaderHistory(LibraryStore.instance).load(engineBookId);
        final chapterId = saved?['chapterId']?.toString();
        final episode = num.tryParse(saved?['episode']?.toString() ?? '');
        var historyIndex = chapterId == null
            ? -1
            : chapters.indexWhere((c) => c.itemId == chapterId);
        if (historyIndex < 0 && episode != null && episode.isFinite) {
          historyIndex =
              episode.toInt().clamp(0, chapters.length - 1).toInt();
        }
        if (historyIndex > readerStart) readerStart = historyIndex;
      } catch (_) {}
      if (!context.mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ReaderPage(
            bookId: engineBookId,
            title: title,
            cover: cover,
            chapters: chapters,
            startIndex: readerStart,
            localOnly: true,
            chapterLoader: (chapter) async =>
                parseNovelPayload((await resolveSource(chapter)).url).content,
            shelfItem: MediaItem(
              id: engineBookId,
              title: title,
              cover: cover,
              author: '',
              badge: '',
              ep: '',
              kind: 'book',
              source: 'engine:$siteId',
              seriesId: seriesId,
            ),
            onSwitchSource: (index) => showEngineSourceSwitch(
              context,
              title: title,
              currentIndex: index,
              currentSiteId: siteId,
              types: {ContentType.novel, ContentType.mixed},
            ),
          ),
        ),
      );
      try {
        final saved =
            await ReaderHistory(LibraryStore.instance).load(engineBookId);
        final chapterId = saved?['chapterId']?.toString();
        final episode = num.tryParse(saved?['episode']?.toString() ?? '');
        var historyIndex = chapterId == null
            ? -1
            : chapters.indexWhere((c) => c.itemId == chapterId);
        if (historyIndex < 0 && episode != null && episode.isFinite) {
          historyIndex =
              episode.toInt().clamp(0, chapters.length - 1).toInt();
        }
        if (historyIndex >= 0) saveIndex(historyIndex);
      } catch (_) {}
    case PlayUrlKind.pics:
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PicsViewerPage(
            seriesTitle: title,
            episodes: chapters,
            startIndex: safeIndex,
            resolve: (chapter) async =>
                parsePicsUrls((await resolveSource(chapter)).url),
            onIndexChanged: saveIndex,
            onAddToShelf: () => addToShelf(kind: 'manga'),
            onSwitchSource: (index) => showEngineSourceSwitch(
              context,
              title: title,
              currentIndex: index,
              currentSiteId: siteId,
              types: {ContentType.comic, ContentType.mixed},
            ),
          ),
        ),
      );
    case PlayUrlKind.audio:
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ListenModePage(
            seriesTitle: title,
            coverUrl: cover,
            episodes: chapters,
            initialIndex: safeIndex,
            onAddToShelf: () => addToShelf(kind: shelfKind('audio')),
            resolveSource: (chapter) async {
              final source = await resolveSource(chapter);
              return EpisodeSource(source.url, source.keyHex);
            },
          ),
        ),
      );
    case PlayUrlKind.video:
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            bookId: seriesId,
            kind: 'video',
            title: title,
            cover: cover,
            eps: chapters,
            startIndex: safeIndex,
            shortSeries: true,
            onAddToShelf: () => addToShelf(kind: shelfKind('video')),
            initialSeriesDetail: initialDetail,
            seriesLoader: initialDetail == null
                ? null
                : (_) async => initialDetail,
            contentLoader: (chapter) async {
              final source = await resolveSource(chapter);
              return source.toResponse();
            },
          ),
        ),
      );
  }
}

String engineShelfKindFor(ContentType type) {
  switch (type) {
    case ContentType.video:
      return 'video';
    case ContentType.comic:
      return 'manga';
    case ContentType.audio:
      return 'audio';
    default:
      return 'book';
  }
}

Future<void> openDramaSiteItem(
  BuildContext context,
  String siteId,
  DramaSiteItem item,
) async {
  final client = await SourceRegistry.instance.clientFor(siteId);
  if (!context.mounted) return;
  if (client == null) return;
  // TG影视库频道条目：频道不是剧，不进剧详情页，改推进频道剧列表页；
  // 列表页里点剧再走正常剧详情 → 选集播放。搜索/首页/分类页点频道
  // 都走这里，拦截一次全覆盖。
  if (client is TgdramaContentClient &&
      TgdramaContentClient.isChannelItemId(item.id)) {
    final channelId = item.id.substring(
      TgdramaContentClient.channelItemPrefix.length,
    );
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => TgdramaChannelPage(
          siteId: siteId,
          channelId: channelId,
          title: item.title,
          client: client,
        ),
      ),
    );
    return;
  }
  final entry = SourceRegistry.instance.customById(siteId);
  final isEngineSite = siteId.startsWith('localdb:') ||
      coreReadingSiteIds.contains(siteId) ||
      (entry != null &&
          entry.kind != SourceKind.customMaccms &&
          entry.kind != SourceKind.builtinDrama);
  DramaSiteDetail? cachedDetail;
  Future<DramaSiteDetail> loadSiteDetail() async {
    cachedDetail ??= await client.detail(item.id);
    return cachedDetail!;
  }

  final initialDetail = SeriesDetail(
    seriesId: item.id,
    title: item.title,
    cover: item.cover,
    episodeLabel: item.remark,
  );
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => SeriesDetailPage(
        seriesId: item.id,
        kind: 'video',
        title: item.title,
        cover: item.cover,
        engineSiteId: isEngineSite ? siteId : '',
        shelfKind: entry == null
            ? switch (coreReadingKinds[siteId]) {
                'comic' => 'manga',
                'audio' => 'audio',
                'novel' => 'book',
                _ => 'video',
              }
            : engineShelfKindFor(entry.contentType),
        initialDetail: initialDetail,
        directoryLoader: (id) async {
          final loaded = await loadSiteDetail();
          return [
            [
              for (final episode in loaded.episodes)
                Chapter(
                  itemId: episode.videoId,
                  title: episode.title,
                  volumeName: '',
                ),
            ],
          ];
        },
        commentLoader: (_) async => const PlayletCommentPage(),
        onPlaySelection: (index, episodes, detail) =>
            openDramaSitePlayback(
              context,
              siteId: siteId,
              seriesId: item.id,
              title: item.title,
              cover: item.cover,
              episodes: episodes,
              startIndex: index,
              initialDetail: detail,
            ),
      ),
    ),
  );
}
