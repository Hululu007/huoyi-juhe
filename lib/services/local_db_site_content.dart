import 'drama_playback.dart';
import 'drama_site_content.dart';
import 'drama_sites.dart';
import 'm3u_export_db.dart';
import 'midnight_gate.dart';

/// 本地库当成一个站：把导出存进 db 的视频按同一套站接口
/// （分类、列表、详情、取流、搜索）挂回现有页面，不另起浏览口。
/// 站号用 `localdb:<归一键>`，经 SourceRegistry.clientFor 解析；
/// 同一站点的多入口（内置、采集、书源）读同一批记录。
class LocalDbContentClient implements DramaSiteContentClient {
  LocalDbContentClient({
    required this.dbSiteId,
    required this.dbSink,
    this.liveResolver,
  });

  static const pageSize = 20;

  final String dbSiteId;
  final M3uExportDbSink dbSink;

  /// 播放自动爬取：本地库记录没有可播地址时，现取原站地址的解析器。
  /// 由 SourceRegistry 在创建本地库客户端时注入（它认得归一键到
  /// 原站的映射）；为空时保持旧行为（直接报没有可播地址）。
  /// 返回 null 表示原站也解析不出，不写库。
  final Future<DramaPlaySource?> Function(String videoId)? liveResolver;

  Future<bool> _gateOpen() async {
    await MidnightGate.ensureLoaded();
    return MidnightGate.activated.value;
  }

  DramaSiteItem _asItem(M3uExportVideoRecord record) {
    return DramaSiteItem(
      id: record.videoId,
      title: record.title,
      cover: record.cover,
      remark: record.episodeCount > 0 ? '共${record.episodeCount}集' : '',
    );
  }

  String _plainVideoId(String videoId) {
    if (!videoId.contains('\u0001')) return videoId;
    return videoId.split('\u0001').last;
  }

  @override
  Future<List<DramaSiteCategory>> categories() async {
    final gateOpen = await _gateOpen();
    final categories = await dbSink.listCategories(
      gateOpen: gateOpen,
      siteId: dbSiteId,
    );
    return [
      for (final category in categories)
        DramaSiteCategory(
          category.categoryId,
          category.categoryName,
          parentId: category.parentId,
          path: category.categoryPath,
          extra: category.extra,
        ),
    ];
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    final gateOpen = await _gateOpen();
    final videos = await dbSink.listVideos(
      gateOpen: gateOpen,
      siteId: dbSiteId,
      categoryId: categoryId,
    );
    final safePage = page < 1 ? 1 : page;
    final start = (safePage - 1) * pageSize;
    if (start >= videos.length) {
      return const DramaSiteCatalogPage(items: [], hasMore: false);
    }
    final end = (start + pageSize).clamp(0, videos.length);
    return DramaSiteCatalogPage(
      items: [for (final video in videos.sublist(start, end)) _asItem(video)],
      hasMore: end < videos.length,
    );
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final gateOpen = await _gateOpen();
    final record = await dbSink.getVideo(
      gateOpen: gateOpen,
      siteId: dbSiteId,
      videoId: _plainVideoId(seriesId),
    );
    if (record == null) throw StateError('本地库没有该视频');
    return DramaSiteDetail(
      id: record.videoId,
      title: record.title,
      cover: record.cover,
      synopsis: record.synopsis,
      extra: record.extra,
      episodes: [
        DramaSiteEpisode(
          videoId: record.videoId,
          title: record.title,
          seriesId: record.videoId,
        ),
      ],
    );
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    final gateOpen = await _gateOpen();
    final record = await dbSink.getVideo(
      gateOpen: gateOpen,
      siteId: dbSiteId,
      videoId: _plainVideoId(episode.videoId),
    );
    if (record == null) throw StateError('本地库没有该视频');
    final url = resolveExportedPlayUrl(record);
    if (url != null) return DramaPlaySource(url: url);
    // 播放自动爬取：浏览存库的记录只有元数据、没有地址，
    // 播放时现取原站地址并回写进库，下次直接走库里地址。
    final resolver = liveResolver;
    if (resolver != null) {
      try {
        final live = await resolver(_plainVideoId(episode.videoId));
        if (live != null) {
          try {
            await dbSink.saveExport(
              siteId: dbSiteId,
              siteName: record.siteName,
              categories: const [],
              videos: [
                M3uExportVideoRecord(
                  siteId: record.siteId,
                  siteName: record.siteName,
                  categoryId: record.categoryId,
                  categoryName: record.categoryName,
                  categoryPath: record.categoryPath,
                  videoId: record.videoId,
                  title: record.title,
                  url: live.url,
                  localPath: record.localPath,
                  cover: record.cover,
                  synopsis: record.synopsis,
                  extra: record.extra,
                  episodeCount: record.episodeCount,
                  updatedAt: DateTime.now().millisecondsSinceEpoch,
                ),
              ],
            );
          } catch (_) {
            // 回写失败不影响本次播放。
          }
          return live;
        }
      } catch (_) {
        // 现取失败时落回旧报错。
      }
    }
    throw StateError('没有可播地址：本地文件已删、线上地址已失效');
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    final gateOpen = await _gateOpen();
    final videos = await dbSink.listVideos(
      gateOpen: gateOpen,
      siteId: dbSiteId,
    );
    return [
      for (final video in videos)
        if (video.title.toLowerCase().contains(needle)) _asItem(video),
    ];
  }
}
