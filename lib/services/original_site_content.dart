import '../models/media_item.dart';
import 'api_client.dart';
import 'drama_playback.dart';
import 'drama_site_content.dart';
import 'drama_sites.dart';
import 'episode_source_cache.dart';

/// 番茄短剧（original）的蜘蛛客户端适配：把原生番茄接口包成
/// DramaSiteContentClient，让导出、浏览、网格走同一套口径。
///
/// 原生侧没有分类导航：分类只给“全部”（与浏览页“没分类只留全部”
/// 的回退一致）。目录按首页短剧流（tab_type=8）的游标顺序翻页；
/// 详情走短剧目录，取流走短剧 content（stream）。
/// 导出模型每条只记一个地址：详情多集时记第一集可播地址。
class OriginalContentClient extends DramaSiteContentClient {
  OriginalContentClient({
    Future<HomepagePage> Function({int offset, String? sessionId})?
    homepageLoader,
    Future<List<List<Chapter>>> Function(String seriesId)? directoryLoader,
    Future<Map<String, dynamic>> Function(String seriesId)? detailLoader,
    Future<Map<String, dynamic>> Function(String itemId)? contentLoader,
  }) : _homepageLoader =
           homepageLoader ??
           (({int offset = 0, String? sessionId}) =>
               ApiClient.instance.homepagePage(
                 tabType: 8,
                 offset: offset,
                 sessionId: sessionId,
               )),
       _directoryLoader =
           directoryLoader ??
           ((seriesId) =>
               ApiClient.instance.directoryChapters(seriesId, tab: '短剧')),
       _detailLoader =
           detailLoader ??
           ((seriesId) => ApiClient.instance.detail(seriesId)),
       _contentLoader =
           contentLoader ??
           ((itemId) =>
               ApiClient.instance.content(itemId, tab: '短剧', mode: 'stream'));

  final Future<HomepagePage> Function({int offset, String? sessionId})
  _homepageLoader;
  final Future<List<List<Chapter>>> Function(String seriesId) _directoryLoader;
  final Future<Map<String, dynamic>> Function(String seriesId) _detailLoader;
  final Future<Map<String, dynamic>> Function(String itemId) _contentLoader;

  /// 顺序翻页游标：导出与网格都是按页顺序调 catalog，页码→游标
  /// 用这组状态串起来；页码倒退或重进时从头开始。
  int _lastPage = 0;
  int? _nextOffset;
  String? _sessionId;
  bool _exhausted = false;

  @override
  Future<List<DramaSiteCategory>> categories() async {
    return const [DramaSiteCategory('all', '全部')];
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    if (page <= 1) {
      _lastPage = 0;
      _nextOffset = null;
      _sessionId = null;
      _exhausted = false;
    } else if (_exhausted || page != _lastPage + 1) {
      // 已到流尾，或调用方跳页（短剧流是游标不是页码，跳页拿不到
      // 对应页）：直接回空页，让调用方按“无更多”收尾，不回错页数据。
      if (_exhausted) {
        return const DramaSiteCatalogPage(items: [], hasMore: false);
      }
      throw StateError('番茄短剧流只支持顺序翻页');
    }
    final feed = await _homepageLoader(
      offset: _nextOffset ?? 0,
      sessionId: _sessionId,
    );
    _lastPage = page;
    _nextOffset = feed.nextOffset;
    _sessionId = feed.sessionId;
    _exhausted = feed.nextOffset == null;
    return DramaSiteCatalogPage(
      items: [
        for (final item in feed.items)
          DramaSiteItem(
            id: item.id,
            title: item.title,
            cover: item.cover,
            remark: item.ep,
          ),
      ],
      hasMore: !_exhausted,
    );
  }

  String _firstString(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value != null && value is! String && '$value'.trim().isNotEmpty) {
        return '$value'.trim();
      }
    }
    return '';
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final volumes = await _directoryLoader(seriesId);
    var title = '';
    var cover = '';
    var synopsis = '';
    try {
      final envelope = await _detailLoader(seriesId);
      final data = envelope['data'] is Map
          ? Map<String, dynamic>.from(envelope['data'] as Map)
          : <String, dynamic>{};
      title = _firstString(data, ['book_name', 'title', 'name']);
      cover = _firstString(data, ['cover', 'thumb_pic', 'thumb', 'pic']);
      synopsis = _firstString(data, [
        'abstract',
        'synopsis',
        'description',
        'intro',
      ]);
    } catch (_) {
      // 书详情拿不到不影响目录与取流：标题与简介留空，导出时
      // 用列表封面兜底，浏览详情页仍能看到选集。
    }
    final episodes = <DramaSiteEpisode>[];
    for (final volume in volumes) {
      for (final chapter in volume) {
        episodes.add(
          DramaSiteEpisode(
            videoId: '\u0001${chapter.itemId}',
            title: chapter.title,
            seriesId: seriesId,
          ),
        );
      }
    }
    return DramaSiteDetail(
      id: seriesId,
      title: title,
      cover: cover,
      synopsis: synopsis,
      episodes: episodes,
    );
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    final parts = episode.videoId.split('\u0001');
    if (parts.length < 2 || parts.sublist(1).join('\u0001').isEmpty) {
      throw StateError('选集缺少播放信息');
    }
    final playId = parts.sublist(1).join('\u0001');
    final response = await _contentLoader(playId);
    final source = EpisodeSource.fromResponse(response);
    return DramaPlaySource(
      url: source.url,
      keyHex: source.keyHex,
      variants: [
        for (final variant in source.variants)
          DramaPlayVariant(
            name: variant.name,
            url: variant.url,
            keyHex: variant.keyHex,
            height: variant.height,
          ),
      ],
    );
  }
}
