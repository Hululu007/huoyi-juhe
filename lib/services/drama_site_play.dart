import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../models/playlet_comment.dart';
import '../models/series_detail.dart';
import '../pages/player_page.dart';
import '../pages/series_detail_page.dart';
import 'drama_playback.dart';
import 'drama_site_content.dart';
import 'source_registry.dart';

/// 外站剧集的详情与播放入口：只用原始站点的详情页与播放页。
/// 详情页拿目录与标题封面，播放页拿选集与取流；评论与底部信息
/// 外站没有，不去原站接口取，返回空页，避免把外站 id 送去原站查。
/// 外站取流预加载：当前集解析完后，后台预取后面两集的播放地址，
///
/// 切到下一集时先命中缓存，不再等一次接口；预取失败直接丢弃，
///
/// 不影响当前播放。缓存只留当前这部剧，退出详情页即失效。
class _PlaySourcePreload {
  final Map<String, DramaPlaySource> _cache = {};
  final Set<String> _inFlight = {};

  String _key(DramaSiteEpisode episode) =>
      '${episode.seriesId}|${episode.videoId}';

  DramaPlaySource? take(DramaSiteEpisode episode) => _cache[_key(episode)];

  Future<void> _fetchAndCache(
    DramaSiteContentClient client,
    DramaSiteEpisode episode,
    String key,
  ) async {
    try {
      _cache[key] = await client.playSource(episode);
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

Future<void> openDramaSiteItem(
  BuildContext context,
  String siteId,
  DramaSiteItem item,
) async {
  final client = await SourceRegistry.instance.clientFor(siteId);
  if (!context.mounted) return;
  if (client == null) return;
  final preload = _PlaySourcePreload();
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
        onPlaySelection: (index, episodes, detail) {
          Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => PlayerPage(
                bookId: item.id,
                kind: 'video',
                title: item.title,
                cover: item.cover,
                eps: episodes,
                startIndex: index,
                shortSeries: true,
                initialSeriesDetail: detail,
                seriesLoader: (_) async => detail,
                contentLoader: (chapter) async {
                  final episode = DramaSiteEpisode(
                    videoId: chapter.itemId,
                    title: chapter.title,
                    seriesId: item.id,
                  );
                  final cached = preload.take(episode);
                  final source =
                      cached ?? await client.playSource(episode);
                  final loaded = await loadSiteDetail();
                  final index = loaded.episodes.indexWhere(
                    (e) => e.videoId == episode.videoId,
                  );
                  if (index >= 0) {
                    preload.prefetch(client, loaded.episodes, index);
                  }
                  return source.toResponse();
                },
              ),
            ),
          );
        },
      ),
    ),
  );
}
