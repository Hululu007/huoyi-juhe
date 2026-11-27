/// 网盘站内容客户端（修仙版）：把网盘引擎（魔蚁的目录/详情/播放
/// 模型）适配成修仙版的 [DramaSiteContentClient]，站号 `cloud:<网盘id>`。
///
/// 文件夹约定（与修仙版现有客户端对齐后的定法）：修仙版的
/// [DramaSiteItem] 没有 folder 字段位，引擎 Drama 的 folder 语义
/// 按下面三条编码进条目本身——
/// - 文件夹条目：`id` 带 `folder:` 前缀（`folder:<folderId>`，
///   聚合虚拟夹是 `folder:__all__`），`remark` 固定为「文件夹」；
///   文件夹感知的界面（网盘页）认前缀点按走 [catalog] 下钻，
///   下钻时把条目 id（或去掉前缀的 folderId）当 category 传回。
/// - 文件/剧集条目：`id` 用引擎的卡片 id（`<网盘>:<文件id>`，
///   分组/光盘是 `<网盘>:group:…` / `<网盘>:disc:…`），点按走
///   [detail]；`remark` 是引擎给的说明（集数/文件大小时长等）。
/// - 分类只有一个根分类（id `all`、名「网盘」）；[catalog] 的
///   categoryId：`''`/`all` 是根，`folder:<id>` 与裸 `<id>`
///   都按文件夹 id 下钻，与引擎 category 语义（folderId、'' 为根）
///   一一对应。
///
/// detail 按 id 重建：引擎 detail 要整个 Drama，修仙版只给
/// seriesId 字符串。本客户端在 [catalog]/[search] 时把引擎给的
/// Drama 原样缓存进 [_seen]，detail 先查这份缓存；查不到（进程
/// 重启后直接打开旧详情）就按引擎的 dramaId 约定拼一个最小
/// Drama（id + source + 文件名占位标题）交给引擎——引擎自己的
/// 条目缓存若还在（同一引擎实例刚拉过目录）就能取回真详情，
/// 不在时引擎如实回「文件信息已过期」提示，本客户端把提示放进
/// synopsis、选集为空，不编数据。
///
/// 播放：engine.resolve 的 PlaybackPlan 映射成 [DramaPlaySource]
/// （url + headers）。PlaybackPlan.forceMpv（光盘/ISO 强制 mpv）
/// 在 DramaPlaySource 里没有对应字段，如实丢弃——这类文件在
/// 修仙版播放器路由里走缺省核，能不能播以真机为准（见交付笔记）。
/// 图片文件引擎已按约定回 `pics://` 地址，原样透传给现有
/// pics 浏览链路（drama_site_play 对 pics:// 有现成处理）。
library;

import '../services/drama_playback.dart';
import '../services/drama_site_content.dart';
import '../services/drama_sites.dart';
import 'cloud_drive_engine.dart';
import 'cloud_drive_factory.dart';
import 'cloud_drive_models.dart';

/// 引擎接缝：客户端只依赖这三个方法，单测注入假实现，
/// 不把网络打进测试。
abstract class CloudCatalogGateway {
  Future<CatalogPage> catalog({
    required String source,
    required int page,
    required String query,
    required String category,
  });

  Future<DramaDetail> detail(Drama drama);

  Future<PlaybackPlan> resolve(Drama drama, Episode episode);
}

/// 真引擎的接缝适配（引擎单例经 [CloudDriveFactory] 懒建）。
class EngineCloudCatalogGateway implements CloudCatalogGateway {
  EngineCloudCatalogGateway(this._engineFuture);

  final Future<CloudDriveEngine> _engineFuture;

  @override
  Future<CatalogPage> catalog({
    required String source,
    required int page,
    required String query,
    required String category,
  }) async {
    final engine = await _engineFuture;
    return engine.catalog(
      source: source,
      page: page,
      query: query,
      category: category,
    );
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    final engine = await _engineFuture;
    return engine.detail(drama);
  }

  @override
  Future<PlaybackPlan> resolve(Drama drama, Episode episode) async {
    final engine = await _engineFuture;
    return engine.resolve(drama, episode);
  }
}

class CloudDriveContentClient implements DramaSiteContentClient {
  CloudDriveContentClient({
    required this.providerId,
    CloudCatalogGateway? gateway,
    this.rootFolderId,
    this.rootFolderName,
  }) : _gateway =
           gateway ??
           EngineCloudCatalogGateway(CloudDriveFactory.engine());

  /// 文件夹条目 id 前缀（见文件头约定）。
  static const folderItemPrefix = 'folder:';

  /// 根分类 id（与修仙版其余站的 `all` 兜底口径一致）。
  static const rootCategoryId = 'all';

  final String providerId;
  final CloudCatalogGateway _gateway;

  /// rooted 变体（片库网格点文件夹卡下钻用）：非空时本客户端
  /// 钉死在这个文件夹上——[categories] 只回这一个文件夹分类，
  /// [catalog] 的根分类（`''`/`all`）也归一到这个文件夹，
  /// 让 SiteBrowsePage 打开即是该文件夹的内容，而不是网盘根。
  /// 为空（缺省）是非 rooted 形态，行为与从前一字不变。
  final String? rootFolderId;
  final String? rootFolderName;

  bool get isRooted => (rootFolderId ?? '').isNotEmpty;

  /// rooted 时的唯一分类 id（`folder:<rootFolderId>`）。
  String get rootedCategoryId => '$folderItemPrefix$rootFolderId';

  String get _source => 'cloud:$providerId';

  /// catalog/search 见过的引擎 Drama 原样缓存（detail 重建用），
  /// 简单 FIFO，上限与引擎条目缓存同量级。
  final Map<String, Drama> _seen = {};
  static const _seenCap = 500;

  void _remember(Drama drama) {
    if (_seen.length >= _seenCap) _seen.remove(_seen.keys.first);
    _seen[drama.id] = drama;
  }

  /// 条目 id 是否文件夹条目。
  static bool isFolderItemId(String itemId) =>
      itemId.startsWith(folderItemPrefix);

  /// 文件夹条目 id → 引擎 category（folderId）。
  static String folderCategoryOf(String itemId) =>
      itemId.substring(folderItemPrefix.length);

  /// catalog 的 categoryId 归一成引擎 category：
  /// `''`/`all` → 根（引擎 ''），`folder:<id>` → `<id>`，其余原样。
  static String engineCategoryOf(String categoryId) {
    if (categoryId.isEmpty || categoryId == rootCategoryId) return '';
    if (categoryId.startsWith(folderItemPrefix)) {
      return categoryId.substring(folderItemPrefix.length);
    }
    return categoryId;
  }

  DramaSiteItem _asItem(Drama drama) {
    _remember(drama);
    if (drama.isFolder) {
      return DramaSiteItem(
        id: '$folderItemPrefix${drama.folderId}',
        title: drama.title,
        cover: drama.cover,
        remark: '文件夹',
      );
    }
    return DramaSiteItem(
      id: drama.id,
      title: drama.title,
      cover: drama.cover,
      remark: drama.description,
    );
  }

  /// catalog 的 categoryId 先过 rooted 归一再转引擎 category：
  /// rooted 时 `''`/`all`（浏览页默认选中值）归一到根文件夹，
  /// 其余 categoryId（下钻的 `folder:<id>`/裸 id）原样往下走。
  String _effectiveCategoryOf(String categoryId) {
    if (isRooted &&
        (categoryId.isEmpty || categoryId == rootCategoryId)) {
      return rootedCategoryId;
    }
    return categoryId;
  }

  @override
  Future<List<DramaSiteCategory>> categories() async {
    if (isRooted) {
      final name = (rootFolderName ?? '').isNotEmpty
          ? rootFolderName!
          : '网盘';
      return [DramaSiteCategory(rootedCategoryId, name)];
    }
    return const [DramaSiteCategory(rootCategoryId, '网盘')];
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    final result = await _gateway.catalog(
      source: _source,
      page: page < 1 ? 1 : page,
      query: '',
      category: engineCategoryOf(_effectiveCategoryOf(categoryId)),
    );
    return DramaSiteCatalogPage(
      items: [for (final drama in result.items) _asItem(drama)],
      hasMore: result.hasMore,
    );
  }

  /// 按 id 重建 Drama：先查 [_seen] 缓存；没有就拼最小 Drama
  /// （见文件头说明）。
  Drama _dramaFor(String seriesId) {
    final cached = _seen[seriesId];
    if (cached != null) return cached;
    return Drama(
      id: seriesId,
      source: _source,
      title: CloudDriveEngine.fileIdOf(seriesId),
    );
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    if (isFolderItemId(seriesId)) {
      throw StateError('这是文件夹，请在网盘页里打开它下钻浏览');
    }
    final drama = _dramaFor(seriesId);
    final result = await _gateway.detail(drama);
    final detailDrama = result.drama;
    final synopsisParts = <String>[
      if (detailDrama.description.isNotEmpty) detailDrama.description,
      if (result.warning.isNotEmpty) result.warning,
    ];
    return DramaSiteDetail(
      id: detailDrama.id,
      title: detailDrama.title,
      cover: detailDrama.cover,
      synopsis: synopsisParts.join('\n'),
      extra: {
        if (result.tags.isNotEmpty)
          '标签': result.tags.map((tag) => tag.name).join(' · '),
      },
      episodes: [
        for (final episode in result.episodes)
          DramaSiteEpisode(
            videoId: episode.id,
            title: episode.title,
            seriesId: detailDrama.id,
          ),
      ],
    );
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    final drama = episode.seriesId.isNotEmpty
        ? _dramaFor(episode.seriesId)
        : Drama(
            id: CloudDriveEngine.dramaId(providerId, episode.videoId),
            source: _source,
            title: episode.title,
          );
    final engineEpisode = Episode(
      {'id': episode.videoId, 'title': episode.title},
      1,
    );
    final plan = await _gateway.resolve(drama, engineEpisode);
    // forceMpv 无对应字段，如实丢弃（见文件头）。
    return DramaPlaySource(url: plan.url, headers: plan.headers);
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final needle = query.trim();
    if (needle.isEmpty) return const [];
    final result = await _gateway.catalog(
      source: _source,
      page: 1,
      query: needle,
      category: '',
    );
    return [for (final drama in result.items) _asItem(drama)];
  }
}
