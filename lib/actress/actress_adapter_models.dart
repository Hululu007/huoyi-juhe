// 适配层：女优库模块在魔蚁侧依赖的模型（原 lib/models.dart 的子集）。
//
// 修仙版（fqapp）没有 SourceSite / Drama / DramaDetail / Episode /
// PlaybackPlan / CatalogPage 这些类，本文件按魔蚁 v42 的同名类原样
// 移植构造与字段，只取女优库模块实际用到的成员（fromJson / merge /
// withPeers 等魔蚁播放器内部用的复制方法未搬，需要时再补）。
// 命名与魔蚁一致是为了让 lib/actress/ 下 23 个文件只改 import 行、
// 不改业务代码。

int intValue(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

/// 与魔蚁 AppRepository 同款的通用失败（见 actress_adapter_repository.dart）。
class AppFailure implements Exception {
  AppFailure(this.message, {this.code = ''});
  final String message;
  final String code;
  @override
  String toString() => message;
}

/// 站源一条记录：只含女优库用到的字段（id / 名 / 分区 / 槽位 / 来源）。
class SourceSite {
  const SourceSite(
    this.id,
    this.name,
    this.description, {
    this.section = sectionDrama,
    this.slotId = '',
    this.origin = originBuiltin,
    this.configId = '',
    this.configName = '',
    this.importType = '',
    this.importExt = '',
  });

  static const sectionDrama = 'drama';
  static const sectionVideo = 'video';
  static const originBuiltin = 'builtin';
  static const originConfig = 'config';
  static const originImport = 'import';

  /// 测试注入的导入站（与魔蚁 models.dart 的 importedSites 同口径）：
  /// 单元测试把合成站写进这里，LocalStore.visibleSources 会一并
  /// 包含它们；生产代码不写这里。
  static final Map<String, SourceSite> importedSites = {};

  final String id;
  final String name;
  final String description;
  final String section;
  final String slotId;
  final String origin;
  final String configId;
  final String configName;
  final String importType;
  final String importExt;
  bool get isVideoSection => section == sectionVideo;
  bool get isDramaSection => section != sectionVideo;

  /// HTML 导入站：点选进宿主页面，不走目录/搜索/聚合链路。
  bool get isHtmlSite => importType == 'html';
  String get coreSlotId => slotId.isEmpty ? id : slotId;
}

class Drama {
  const Drama({
    required this.id,
    required this.source,
    required this.title,
    this.sourceId = '',
    this.description = '',
    this.cover = '',
    this.episodes = 0,
    this.category = '',
    bool? vip,
    this.heat = '',
    this.views = '',
    this.onlineDate = '',
    this.tags = const [],
    this.releaseStatus = '',
    this.kind = 'video',
    this.folderId = '',
    this.peers = const [],
  }) : vipStatus = vip;
  final String id;
  final String source;
  final String sourceId;
  final String title;
  final String description;
  final String cover;
  final int episodes;
  final String category;
  final bool? vipStatus;
  bool get vip => vipStatus == true;
  final String heat;
  final String views;
  final String onlineDate;
  final List<String> tags;
  final String releaseStatus;

  /// 目录条目类型：video=视频卡（缺省）；folder=文件夹卡，点击以
  /// [folderId] 作为 category 参数再次请求目录实现下钻（层级不限）。
  final String kind;
  final String folderId;
  bool get isFolder => kind == 'folder';
  bool get isAction => kind == 'action';
  bool get isTagFolder => isFolder && folderId.startsWith('tag:');
  final List<Drama> peers;
}

class Episode {
  Episode(this.raw, int fallback)
    : id = raw['id'] as String? ?? '',
      title = raw['title'] as String? ?? '第$fallback集',
      number = intValue(raw['currentEpisode']) > 0
          ? intValue(raw['currentEpisode'])
          : fallback,
      vip = raw['vip'] == true,
      vertical = raw['vertical'] as bool?;
  final Map<String, dynamic> raw;
  final String id;
  final String title;
  final int number;
  final bool vip;
  final bool? vertical;
}

/// 集标题是否像链接：源数据有时把播放地址塞进标题字段，直接显示会把
/// 直链暴露在界面上。标题里含链接 scheme 或以流媒体后缀结尾时只用集数标签。
bool episodeTitleLooksLikeUrl(String title) {
  final text = title.trim().toLowerCase();
  return text.contains('://') ||
      text.endsWith('.m3u8') ||
      text.endsWith('.mp4');
}

class DramaDetail {
  DramaDetail(
    this.drama,
    this.episodes, {
    this.warning = '',
    this.backdrop = '',
    this.stills = const [],
    this.related = const [],
    this.tags = const [],
    this.magnets = const [],
  });
  final Drama drama;
  final List<Episode> episodes;
  final String warning;
  final String backdrop;
  final List<String> stills;
  final List<Drama> related;
  final List<DetailTag> tags;
  final List<MagnetLink> magnets;

  DramaDetail withDrama(Drama value) => DramaDetail(
    value,
    episodes,
    warning: warning,
    backdrop: backdrop,
    stills: stills,
    related: related,
    tags: tags,
    magnets: magnets,
  );

  DramaDetail withEpisodes(List<Episode> value) => DramaDetail(
    drama,
    value,
    warning: warning,
    backdrop: backdrop,
    stills: stills,
    related: related,
    tags: tags,
    magnets: magnets,
  );
}

/// 详情标签（女优库只透传，不解析）。
class DetailTag {
  const DetailTag(this.name, {this.id = ''});
  final String name;
  final String id;
}

/// 磁力链接（女优库只透传，不解析、不播放）。
class MagnetLink {
  const MagnetLink(this.url, {this.title = ''});
  final String url;
  final String title;
}

/// 取流结果：直链 + 播放头。needsParse=true 表示解析型计划（壳解析/
/// 嗅探），验不了活；女优库只走数据库直链时恒为 false。
class PlaybackPlan {
  const PlaybackPlan({
    required this.url,
    this.originalUrl = '',
    this.headers = const {},
    this.decryptionKey = '',
    this.quality = 0,
    this.qualities = const [],
    this.session = '',
    this.danmakuId = '',
    this.prefetchedBytes = 0,
    this.expiresAt = 0,
    this.routeIndex = 0,
    this.routeCount = 1,
    this.local = false,
    this.needsParse = false,
    this.forceMpv = false,
  });
  final String url;
  final String originalUrl;
  final Map<String, String> headers;
  final String decryptionKey;
  final int quality;
  final List<int> qualities;
  final String session;
  final String danmakuId;
  final int prefetchedBytes;
  final int expiresAt;
  final int routeIndex;
  final int routeCount;
  final bool local;
  final bool needsParse;

  /// 强制走 mpv（media_kit）播放：光盘类只有 mpv 能播。
  final bool forceMpv;
  bool get hasAlternative => session.isNotEmpty && routeIndex + 1 < routeCount;
}

class CatalogCategory {
  const CatalogCategory(
    this.id,
    this.name, {
    this.local = false,
    this.kind = '',
    this.folderId = '',
  });
  static const all = CatalogCategory('', '全部');
  final String id;
  final String name;
  final bool local;

  /// 分类条目本身也可为文件夹（多级分类）：kind=folder 时点入下钻。
  final String kind;
  final String folderId;
  bool get isFolder => kind == 'folder' || folderId.isNotEmpty;
  String get drillId => folderId.isNotEmpty ? folderId : id;
}

/// 一页目录：女优库只用 items / hasMore / warning / page。
class CatalogPage {
  CatalogPage(
    this.items, {
    this.hasMore = false,
    this.warning = '',
    this.page = 1,
    this.fresh = false,
  });
  final List<Drama> items;
  final bool hasMore;
  final String warning;
  final int page;
  final bool fresh;
}
