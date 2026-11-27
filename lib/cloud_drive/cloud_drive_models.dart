// 适配层：网盘核心在魔蚁侧依赖的模型（原 lib/models.dart 的子集）。
//
// 修仙版没有魔蚁的 lib/models.dart，本文件按魔蚁原样移植
// cloud_drive_engine / cloud_cover_scrape 实际用到的类与成员：
// Drama（含 toJson/fromJson，引擎落盘缓存要用）、Episode、
// DramaDetail、CatalogPage，以及它们连带依赖的 CatalogCategory /
// CatalogTag / CatalogFilterOption / CatalogFilterGroup / DetailTag /
// MagnetLink / PlaybackDrm / PlaybackPlan / intValue，字段与方法
// 照原样、不改名。另含 AppFailure：魔蚁侧它定义在 core_bridge.dart，
// engine 经该文件导入拿到它；修仙版不搬 core_bridge，这里按原定义
// （与 lib/actress/actress_adapter_models.dart 里的同名类一致）收进来。
library;

import 'dart:convert';

class AppFailure implements Exception {
  AppFailure(this.message, {this.code = ''});
  final String message;
  final String code;
  @override
  String toString() => message;
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
  factory CatalogCategory.fromJson(Map<String, dynamic> json) =>
      CatalogCategory(
        json['id'] as String? ?? '',
        json['name'] as String? ?? '全部',
        kind: json['kind'] as String? ?? '',
        folderId: json['folderId'] as String? ?? '',
      );
}

class CatalogTag {
  const CatalogTag(this.id, this.name);
  final String id;
  final String name;
  String get folderId => id.startsWith('tag:') ? id : 'tag:$id';
  factory CatalogTag.fromJson(Object? value) {
    if (value is Map) {
      final map = Map<String, dynamic>.from(value);
      return CatalogTag(
        map['id']?.toString() ?? '',
        map['name']?.toString() ?? '',
      );
    }
    final text = value?.toString() ?? '';
    return CatalogTag(text, text);
  }
}

class CatalogFilterOption {
  const CatalogFilterOption(this.id, this.name);
  final String id;
  final String name;
  factory CatalogFilterOption.fromJson(Map<String, dynamic> json) =>
      CatalogFilterOption(
        json['id']?.toString() ?? '',
        json['name']?.toString() ?? '',
      );
}

class CatalogFilterGroup {
  const CatalogFilterGroup(this.key, this.name, this.options);
  final String key;
  final String name;
  final List<CatalogFilterOption> options;
  factory CatalogFilterGroup.fromJson(Map<String, dynamic> json) =>
      CatalogFilterGroup(
        json['key']?.toString() ?? '',
        json['name']?.toString() ?? '',
        [
          for (final row in json['options'] as List? ?? const [])
            if (row is Map)
              CatalogFilterOption.fromJson(Map<String, dynamic>.from(row)),
        ].where((option) => option.id.isNotEmpty).toList(),
      );
}

int intValue(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

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
    // peers 是跨源聚合搜索里其它站源的同一部剧，用于一键切换播放源。
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
  /// [folderId] 作为 category 参数再次请求目录实现下钻（层级不限）；
  /// action=动作卡，点击不走详情/播放，直接按 [sourceId] 里的动作
  /// JSON 打开对应界面（见 action_protocol.dart）。
  final String kind;
  final String folderId;
  bool get isFolder => kind == 'folder';
  bool get isAction => kind == 'action';
  bool get isTagFolder => isFolder && folderId.startsWith('tag:');
  final List<Drama> peers;
  String get releaseLabel => switch (releaseStatus) {
    'finished' || 'completed' => '已完结',
    'ongoing' => '连载中',
    _ => '状态未知',
  };

  factory Drama.fromJson(Map<String, dynamic> json) => Drama(
    id: json['id'] as String? ?? '',
    source: json['source'] as String? ?? 'hongguo',
    sourceId: json['sourceId'] as String? ?? '',
    title: json['title'] as String? ?? '短剧',
    description: json['description'] as String? ?? '',
    cover: json['cover'] as String? ?? json['pic'] as String? ?? '',
    episodes: intValue(json['episodes']),
    category: json['category'] as String? ?? '',
    vip: json['vip'] == true
        ? true
        : json['vip'] == false &&
              (json['source'] != 'huangdou' ||
                  intValue(json['metadataSchema']) >= 1)
        ? false
        : null,
    heat: json['heat']?.toString() ?? '',
    views: json['views']?.toString() ?? '',
    onlineDate: json['onlineDate'] as String? ?? '',
    tags: [
      for (final tag in json['tags'] as List? ?? const [])
        if (tag is String)
          tag
        else if (tag is Map)
          (tag['name']?.toString() ?? '')
        else
          '',
    ].where((tag) => tag.isNotEmpty).toList(),
    releaseStatus: json['releaseStatus'] as String? ?? '',
    kind: json['kind'] as String? ?? 'video',
    folderId: json['folderId'] as String? ?? '',
    peers: [
      for (final row in json['peers'] as List? ?? const [])
        Drama.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
  );
  Map<String, dynamic> toJson() => {
    'metadataSchema': 1,
    'id': id,
    'source': source,
    'sourceId': sourceId,
    'title': title,
    'description': description,
    'cover': cover,
    'episodes': episodes,
    'category': category,
    'vip': vipStatus,
    'heat': heat,
    'views': views,
    'onlineDate': onlineDate,
    'tags': tags,
    'releaseStatus': releaseStatus,
    if (kind != 'video') 'kind': kind,
    if (folderId.isNotEmpty) 'folderId': folderId,
    if (peers.isNotEmpty) 'peers': [for (final peer in peers) peer.toJson()],
  };

  // withPeers 复制一份并替换跨源副本列表，用于切换播放源时把副本关系传递下去。
  Drama withPeers(List<Drama> value) => Drama(
    id: id,
    source: source,
    sourceId: sourceId,
    title: title,
    description: description,
    cover: cover,
    episodes: episodes,
    category: category,
    vip: vipStatus,
    heat: heat,
    views: views,
    onlineDate: onlineDate,
    tags: tags,
    releaseStatus: releaseStatus,
    kind: kind,
    folderId: folderId,
    peers: value,
  );

  Drama merge(Drama fresh) {
    if (id != fresh.id) return fresh;
    const genericCategories = {
      '短剧',
      '真人剧',
      '漫剧',
      'AI剧',
      'AI 剧',
      'AI短剧',
      'AI 短剧',
      'AI漫剧',
      'AI 漫剧',
    };
    return Drama(
      id: id,
      source: fresh.source.isEmpty ? source : fresh.source,
      sourceId: fresh.sourceId.isEmpty ? sourceId : fresh.sourceId,
      title: fresh.title.isEmpty || fresh.title == '短剧' ? title : fresh.title,
      description: fresh.description.isEmpty ? description : fresh.description,
      cover: fresh.cover.isEmpty ? cover : fresh.cover,
      episodes: fresh.episodes > 0 ? fresh.episodes : episodes,
      category:
          fresh.category.isEmpty ||
              genericCategories.contains(fresh.category) &&
                  category.isNotEmpty &&
                  !genericCategories.contains(category)
          ? category
          : fresh.category,
      vip: fresh.vipStatus ?? vipStatus,
      heat: fresh.heat.isEmpty ? heat : fresh.heat,
      views: fresh.views.isEmpty ? views : fresh.views,
      onlineDate: fresh.onlineDate.isEmpty ? onlineDate : fresh.onlineDate,
      tags: fresh.tags.isEmpty ? tags : fresh.tags,
      releaseStatus:
          fresh.releaseStatus.isEmpty || fresh.releaseStatus == 'unknown'
          ? releaseStatus
          : fresh.releaseStatus,
      // 文件夹性粘住（2026-11-27 问题 6）：kind 只许往“是文件
      // 夹”并，不许被不懂类型的合并方（详情/封面更新重建出的
      // kind='' 条目）冲掉——folderId 本来就是空才回退，kind
      // 此前无条件取新值，文件夹卡被合并一次就变回普通条目、
      // 点按改走详情，观感就是“文件夹点了没反应”。
      kind: isFolder || fresh.isFolder
          ? 'folder'
          : (fresh.kind.isEmpty ? kind : fresh.kind),
      folderId: fresh.folderId.isEmpty ? folderId : fresh.folderId,
      peers: fresh.peers.isEmpty ? peers : fresh.peers,
    );
  }
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

/// 显示用集标题：链接型标题回“第N集”，干净标题原样回。
String displayEpisodeTitle(String title, int number) =>
    episodeTitleLooksLikeUrl(title) ? '第$number集' : title;

/// 显示用集数行：干净标题拼“第N集 | 标题”，链接型、空、与标签相同的
/// 标题只显示集数标签，绝不把链接拼进显示文本。
String displayEpisodeLine(String? title, int number) {
  final label = '第$number集';
  final text = (title ?? '').trim();
  if (text.isEmpty || text == label || episodeTitleLooksLikeUrl(text)) {
    return label;
  }
  return '$label | $text';
}

/// heat 值是否像文件大小：jar 侧 heat 取 vod_remarks，TG 站把文件
/// 大小（如 1.4MB）塞进该字段，标“热度”会拿文件大小冒充热度。
bool heatLooksLikeFileSize(String heat) {
  final value = heat.trim();
  return RegExp(
    r'^\d+(\.\d+)?\s*(B|KB|MB|GB|TB)$',
    caseSensitive: false,
  ).hasMatch(value);
}

/// 显示用 heat 文案：文件大小形状的值标“大小”，其余标“热度”。
String heatDisplayText(String heat) =>
    heatLooksLikeFileSize(heat) ? '大小 $heat' : '热度 $heat';

class DetailTag {
  const DetailTag({required this.id, required this.name});
  final String id;
  final String name;
  factory DetailTag.fromJson(Object? value) {
    if (value is Map) {
      final map = Map<String, dynamic>.from(value);
      final name = map['name'] as String? ?? '';
      return DetailTag(id: map['id'] as String? ?? name, name: name);
    }
    final name = value?.toString() ?? '';
    return DetailTag(id: name, name: name);
  }
}

class MagnetLink {
  const MagnetLink({
    required this.name,
    required this.url,
    this.sizeLabel = '',
    this.quality = '',
    this.date = '',
    this.tags = const [],
  });
  final String name;
  final String url;
  final String sizeLabel;
  final String quality;
  final String date;
  final List<String> tags;

  factory MagnetLink.fromJson(Map<String, dynamic> json) => MagnetLink(
    name: json['name'] as String? ?? '',
    url: json['url'] as String? ?? '',
    sizeLabel: json['sizeLabel'] as String? ?? '',
    quality: json['quality'] as String? ?? '',
    date: json['date'] as String? ?? '',
    tags: [
      for (final row in json['tags'] as List? ?? const [])
        if (row != null && row.toString().isNotEmpty) row.toString(),
    ],
  );

  String get metaLabel => [
    if (sizeLabel.isNotEmpty) sizeLabel,
    if (quality.isNotEmpty) quality,
    for (final tag in tags) tag,
    if (date.length == 8)
      '${date.substring(0, 4)}-${date.substring(4, 6)}-${date.substring(6, 8)}',
  ].join(' · ');
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
    this.extraInfo = const [],
  });
  final Drama drama;
  final List<Episode> episodes;
  final String warning;
  final String backdrop;
  final List<String> stills;
  final List<Drama> related;
  final List<DetailTag> tags;
  final List<MagnetLink> magnets;

  /// 附加信息行（标签 → 值）：详情页信息卡的数据来源之一
  /// （在线源详情页自带的发行日期/长度/制作商等，源里有才带，
  /// 没有就是空——详情页不编造）。与 Drama 自带字段（onlineDate
  /// 等）重复时详情页优先用这里的。
  final List<(String, String)> extraInfo;

  DramaDetail withDrama(Drama value) => DramaDetail(
    value,
    episodes,
    warning: warning,
    backdrop: backdrop,
    stills: stills,
    related: related,
    tags: tags,
    magnets: magnets,
    extraInfo: extraInfo,
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
    extraInfo: extraInfo,
  );

  DramaDetail withStills(List<String> value) => DramaDetail(
    drama,
    episodes,
    warning: warning,
    backdrop: backdrop,
    stills: value,
    related: related,
    tags: tags,
    magnets: magnets,
    extraInfo: extraInfo,
  );

  DramaDetail withExtraInfo(List<(String, String)> value) => DramaDetail(
    drama,
    episodes,
    warning: warning,
    backdrop: backdrop,
    stills: stills,
    related: related,
    tags: tags,
    magnets: magnets,
    extraInfo: value,
  );

  DramaDetail withTags(List<DetailTag> value) => DramaDetail(
    drama,
    episodes,
    warning: warning,
    backdrop: backdrop,
    stills: stills,
    related: related,
    tags: value,
    magnets: magnets,
    extraInfo: extraInfo,
  );

  DramaDetail withRelated(List<Drama> value) => DramaDetail(
    drama,
    episodes,
    warning: warning,
    backdrop: backdrop,
    stills: stills,
    related: value,
    tags: tags,
    magnets: magnets,
    extraInfo: extraInfo,
  );

  factory DramaDetail.fromJson(Map<String, dynamic> json) {
    final rows = json['chapters'] as List? ?? const [];
    final dramaJson = Map<String, dynamic>.from(json['drama'] as Map);
    Object? pick(String key) => json[key] ?? dramaJson[key];
    final stillsRaw = pick('stills');
    final relatedRaw = pick('related');
    final tagsRaw = pick('tags');
    final magnetsRaw = pick('magnets');
    return DramaDetail(
      Drama.fromJson(dramaJson),
      [
        for (var i = 0; i < rows.length; i++)
          Episode(Map<String, dynamic>.from(rows[i] as Map), i + 1),
      ],
      warning: json['warning'] as String? ?? '',
      backdrop: pick('backdrop') as String? ?? '',
      stills: [
        for (final row in stillsRaw as List? ?? const [])
          if (row != null && row.toString().isNotEmpty) row.toString(),
      ],
      related: [
        for (final row in relatedRaw as List? ?? const [])
          if (row is Map) Drama.fromJson(Map<String, dynamic>.from(row)),
      ],
      tags: [
        for (final row in tagsRaw as List? ?? const [])
          if (row != null) DetailTag.fromJson(row),
      ].where((tag) => tag.name.isNotEmpty).toList(),
      magnets: [
        for (final row in magnetsRaw as List? ?? const [])
          if (row is Map) MagnetLink.fromJson(Map<String, dynamic>.from(row)),
      ].where((magnet) => magnet.url.isNotEmpty).toList(),
    );
  }
}

class CatalogPage {
  CatalogPage(
    this.items, {
    this.hasMore = false,
    this.warning = '',
    this.page = 1,
    this.fresh = false,
    this.tags = const [],
    this.filters = const [],
  });
  final List<Drama> items;
  final bool hasMore;
  final String warning;
  final int page;
  final bool fresh;

  /// 分类响应携带的标签集（标签一等浏览维度），渲染为可点 chip，
  /// 点击以 tag 的 folderId（tag: 前缀）下钻。
  final List<CatalogTag> tags;

  /// 分类响应携带的筛选组（站源侧筛选面板，如主题/设定/背景），
  /// 渲染为筛选行，选项透传回站源作二次筛选。
  final List<CatalogFilterGroup> filters;
  factory CatalogPage.fromJson(Map<String, dynamic> json) => CatalogPage(
    [
      for (final row in json['items'] as List? ?? const [])
        Drama.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
    hasMore: json['hasMore'] == true,
    warning: json['warning'] as String? ?? '',
    page: intValue(json['page']) > 0 ? intValue(json['page']) : 1,
    fresh: json['fresh'] == true,
    tags: [
      for (final row in json['tags'] as List? ?? const [])
        CatalogTag.fromJson(row),
    ].where((tag) => tag.id.isNotEmpty).toList(),
    filters: [
      for (final row in json['filters'] as List? ?? const [])
        if (row is Map)
          CatalogFilterGroup.fromJson(Map<String, dynamic>.from(row)),
    ].where((group) => group.key.isNotEmpty).toList(),
  );
}


/// 播放 DRM 信息（源侧随播放结果带回，字段口径与 FongMi 系
/// `drm:{key,type,header,forceKey}` 对齐）：
/// - [type]：许可证体系，如 com.widevine.alpha / org.w3.clearkey /
///   com.microsoft.playready（也认 widevine / clearkey 短名）。
/// - [key]：type 为服务器型时是许可证服务器地址（可带 `|头=值&...`
///   后缀形式的请求头，由归一化层拆开）；ClearKey 本地键时是
///   十六进制 `kid:key` 对或现成的 JWK JSON，归一化在
///   tvbox_player_bridge / live_drm 里完成，这里只存原样。
/// - [headers]：许可证请求头。
/// 只有 EXO 核（Media3）能消费这组信息；带 drm 的计划在播放器
/// 路由时强制走 EXO（见 player_screen 的 useNativeForPlan）。
class PlaybackDrm {
  const PlaybackDrm({
    required this.type,
    required this.key,
    this.headers = const {},
    this.forceKey = false,
  });

  final String type;
  final String key;
  final Map<String, String> headers;
  final bool forceKey;

  bool get isValid => type.isNotEmpty && key.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'type': type,
    'key': key,
    'headers': headers,
    'forceKey': forceKey,
  };

  /// 容忍两种形态：本站 toJson 的 {type,key,headers,forceKey} 与
  /// FongMi 系的 {key,type,header,forceKey}（header 可为 Map 或
  /// JSON 字符串）。字段不全返回 null，不硬造。
  static PlaybackDrm? fromJson(Object? value) {
    if (value is! Map) return null;
    final map = value.map((k, v) => MapEntry(k.toString(), v));
    final type = (map['type'] ?? '').toString().trim();
    final key = (map['key'] ?? '').toString().trim();
    if (type.isEmpty || key.isEmpty) return null;
    final headers = <String, String>{};
    void absorb(Object? raw) {
      if (raw is Map) {
        raw.forEach((k, v) {
          if (v != null) headers[k.toString()] = v.toString();
        });
      } else if (raw is String && raw.trim().startsWith('{')) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) absorb(decoded);
        } catch (_) {}
      }
    }

    absorb(map['headers']);
    absorb(map['header']);
    return PlaybackDrm(
      type: type,
      key: key,
      headers: headers,
      forceKey: map['forceKey'] == true,
    );
  }
}

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
    this.drm,
    this.subs = const [],
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

  /// 强制走 mpv（media_kit）播放：光盘类（ISO/VIDEO_TS/BDMV）只有
  /// mpv 能播，原生/ijk 播不了；引擎在取流时置真，播放器路由时
  /// 认它（与 decryptionKey 的强制 mpv 语义一致）。复制方法必须透传。
  final bool forceMpv;

  /// DRM 信息；null 表示明流。带值时只有 EXO 核能播，
  /// 路由层据此强制走 EXO（decryptionKey 的强制 mpv 与此互斥，
  /// 两者同时出现时 decryptionKey 优先，保持既有口径）。
  final PlaybackDrm? drm;
  bool get hasDrm => drm?.isValid ?? false;
  /// 源在播放结果里给的外挂字幕列表（subs 字段透传，第 8 点）。
  final List<SubtitleSource> subs;
  bool get hasAlternative => session.isNotEmpty && routeIndex + 1 < routeCount;

  PlaybackPlan withDanmaku(String sessionValue, String danmakuIdValue) =>
      PlaybackPlan(
        url: url,
        originalUrl: originalUrl,
        headers: headers,
        decryptionKey: decryptionKey,
        quality: quality,
        qualities: qualities,
        session: sessionValue,
        danmakuId: danmakuIdValue,
        prefetchedBytes: prefetchedBytes,
        expiresAt: expiresAt,
        routeIndex: routeIndex,
        routeCount: routeCount,
        local: local,
        needsParse: needsParse,
        forceMpv: forceMpv,
        drm: drm,
        subs: subs,
      );

  PlaybackPlan withUrl(String value) => PlaybackPlan(
    url: value,
    originalUrl: originalUrl,
    headers: headers,
    decryptionKey: decryptionKey,
    quality: quality,
    qualities: qualities,
    session: session,
    danmakuId: danmakuId,
    prefetchedBytes: prefetchedBytes,
    expiresAt: expiresAt,
    routeIndex: routeIndex,
    routeCount: routeCount,
    local: local,
    needsParse: needsParse,
    forceMpv: forceMpv,
        drm: drm,
    subs: subs,
  );

  PlaybackPlan withHeaders(Map<String, String> value) => PlaybackPlan(
    url: url,
    originalUrl: originalUrl,
    headers: value,
    decryptionKey: decryptionKey,
    quality: quality,
    qualities: qualities,
    session: session,
    danmakuId: danmakuId,
    prefetchedBytes: prefetchedBytes,
    expiresAt: expiresAt,
    routeIndex: routeIndex,
    routeCount: routeCount,
    local: local,
    needsParse: needsParse,
    forceMpv: forceMpv,
        drm: drm,
    subs: subs,
  );

  PlaybackPlan withNeedsParse(bool value) => PlaybackPlan(
    url: url,
    originalUrl: originalUrl,
    headers: headers,
    decryptionKey: decryptionKey,
    quality: quality,
    qualities: qualities,
    session: session,
    danmakuId: danmakuId,
    prefetchedBytes: prefetchedBytes,
    expiresAt: expiresAt,
    routeIndex: routeIndex,
    routeCount: routeCount,
    local: local,
    needsParse: value,
    forceMpv: forceMpv,
        drm: drm,
    subs: subs,
  );
  factory PlaybackPlan.fromJson(Map<String, dynamic> json) => PlaybackPlan(
    url: json['url'] as String? ?? '',
    originalUrl: json['originalUrl'] as String? ?? '',
    local: json['local'] == true,
    headers: (json['headers'] as Map? ?? {}).map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    ),
    decryptionKey: json['decryptionKey'] as String? ?? '',
    quality: intValue(json['quality']),
    qualities: (json['qualities'] as List? ?? []).map(intValue).toSet().toList()
      ..sort((a, b) => b.compareTo(a)),
    session: json['session'] as String? ?? '',
    danmakuId: json['danmakuId'] as String? ?? '',
    prefetchedBytes: intValue(json['prefetchedBytes']),
    expiresAt: intValue(json['expiresAt']),
    routeIndex: intValue(json['routeIndex']),
    routeCount: intValue(json['routeCount']) > 0
        ? intValue(json['routeCount'])
        : 1,
    needsParse: json['parse'] == true || json['needsParse'] == true,
    drm: PlaybackDrm.fromJson(json['drm']),
    subs: parseSubtitleSources(json['subs']),
  );
}

// --- 以下 SubtitleSource / parseSubtitleSources 原样移植自魔蚁
// lib/track_selection.dart（PlaybackPlan.subs 与 fromJson 依赖）。

/// 音轨/字幕轨切换 + 外挂字幕的纯逻辑层（第 8 点）。
///
/// 只做三件事，全是纯函数/不可变模型，方便单测：
/// 1. [SubtitleSource] 与 [parseSubtitleSources]：把播放结果里的
///    `subs` 字段（源给的字幕列表）归一成强类型列表；
/// 2. [chooseDefaultSubtitle]：外挂字幕的默认选择规则；
/// 3. [TrackChoice]/[TrackMenuEntry] 与两个 build 函数：把播放器
///    当前轨道列表映射成菜单条目模型，UI 只负责渲染与回调用。

/// 一条外挂字幕（来自播放结果的 `subs` 字段）。
class SubtitleSource {
  const SubtitleSource({
    required this.url,
    this.name = '',
    this.lang = '',
    this.format = '',
  });

  final String url;
  final String name;
  final String lang;

  /// 字幕格式：srt / vtt / ass / ssa / ttml 等小写扩展名；源没给时
  /// 由地址扩展名推断，推不出为空串。
  final String format;

  String get label {
    if (name.isNotEmpty) return name;
    if (lang.isNotEmpty) return lang;
    return '外挂字幕';
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    if (name.isNotEmpty) 'name': name,
    if (lang.isNotEmpty) 'lang': lang,
    if (format.isNotEmpty) 'format': format,
  };

  @override
  bool operator ==(Object other) =>
      other is SubtitleSource &&
      other.url == url &&
      other.name == name &&
      other.lang == lang &&
      other.format == format;

  @override
  int get hashCode => Object.hash(url, name, lang, format);
}

String _text(Object? value) => value?.toString().trim() ?? '';

/// 由字幕地址推断格式（只看路径尾部扩展名，忽略查询串）。
String inferSubtitleFormat(String url) {
  var path = url.trim();
  final query = path.indexOf('?');
  if (query >= 0) path = path.substring(0, query);
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return '';
  final ext = path.substring(dot + 1).toLowerCase();
  return const {'srt', 'vtt', 'ass', 'ssa', 'ttml', 'xml', 'lrc'}.contains(ext)
      ? ext
      : '';
}

/// 归一一条 subs 元素；形态不合法（无地址）时返回 null。
SubtitleSource? _subtitleFrom(Object? row) {
  if (row is String) {
    final url = row.trim();
    if (url.isEmpty) return null;
    return SubtitleSource(url: url, format: inferSubtitleFormat(url));
  }
  if (row is! Map) return null;
  final map = Map<String, dynamic>.from(row);
  final url = _text(map['url'] ?? map['v'] ?? map['src'] ?? map['address']);
  if (url.isEmpty) return null;
  var format = _text(map['format'] ?? map['type']).toLowerCase();
  if (format.startsWith('.')) format = format.substring(1);
  if (format.isEmpty) format = inferSubtitleFormat(url);
  return SubtitleSource(
    url: url,
    name: _text(map['name'] ?? map['n'] ?? map['title']),
    lang: _text(map['lang'] ?? map['language']),
    format: format,
  );
}

/// 解析播放结果的 `subs` 字段：数组元素认对象
/// `{url, name, lang, format}`（含 n/v 等别名）与裸地址字符串；
/// 非数组/空一律回空列表，同地址去重保序。
List<SubtitleSource> parseSubtitleSources(Object? raw) {
  if (raw is! List) return const [];
  final seen = <String>{};
  final out = <SubtitleSource>[];
  for (final row in raw) {
    final sub = _subtitleFrom(row);
    if (sub == null) continue;
    if (!seen.add(sub.url)) continue;
    out.add(sub);
  }
  return out;
}
