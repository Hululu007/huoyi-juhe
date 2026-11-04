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
  LocalDbContentClient({required this.dbSiteId, required this.dbSink});

  static const pageSize = 20;

  final String dbSiteId;
  final M3uExportDbSink dbSink;

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
    if (url == null) {
      throw StateError('没有可播地址：本地文件已删、线上地址已失效');
    }
    return DramaPlaySource(url: url);
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
