import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../models/playlet_comment.dart';
import '../models/series_detail.dart';
import '../pages/player_page.dart';
import '../pages/series_detail_page.dart';
import 'drama_site_content.dart';

/// 外站剧集的详情与播放入口：只用原始站点的详情页与播放页。
/// 详情页拿目录与标题封面，播放页拿选集与取流；评论与底部信息
/// 外站没有，不去原站接口取，返回空页，避免把外站 id 送去原站查。
Future<void> openDramaSiteItem(
  BuildContext context,
  String siteId,
  DramaSiteItem item,
) async {
  final client = dramaSiteContentClient(siteId);
  if (client == null) return;
  DramaSiteDetail? cachedDetail;
  Future<DramaSiteDetail> detail() async {
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
          final loaded = await detail();
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
                  final source = await client.playSource(
                    DramaSiteEpisode(
                      videoId: chapter.itemId,
                      title: chapter.title,
                      seriesId: item.id,
                    ),
                  );
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
