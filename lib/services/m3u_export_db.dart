/// 单库原则：媒体库（导出、爬存数据）只用一个库、一个 db 文件。
///
/// 全部数据进同一个箱：原始线上数据、本地爬存数据、各站点数据、
/// 线上地址与本地路径，都在这个箱里——线上地址与本地路径是
/// 同一条记录的两个字段（双轨），不是两个库。
/// 不按站点、按来源、按类型分库：内置站、采集站、书源站、
/// py/jar/JS/规则站的数据全进这一个箱；以后加小说、漫画、
/// 听书等类型也进这一个箱，不另开箱。
/// 库内区分靠层级：站点（归一键，见 site_identity）→ 分类 →
/// 多级分类（categoryPath + parentId），各站布局与详情字段
/// 按站原样保留，不强行统一成一套；相同站点只存一份。
/// 不在这个箱里的东西（不是分库，是本来就不是库数据）：
/// m3u 文本是导出给外部播放器的产物文件，视频字节是文件
/// （记录里 localPath 指向它），播放器离线缓存是另一套
/// 带清理生命周期的缓存子系统。
library;

import 'dart:io';

import 'package:hive_ce/hive.dart';

import 'encrypted_hive.dart';
import 'midnight_gate.dart';
import 'public_folder.dart';
import 'secure_key_provider.dart';
import 'site_identity.dart';

/// 库内一律归一键：写侧把记录换成归一键再落盘，读侧把传入
/// 的 id 归一后再比对；调用方传原始 id 也能读到同一批记录。
/// 旧箱迁移同样先换键再拷（见 _migrateFromLegacy），
/// 不留原始键的记录在新箱里。
M3uExportCategoryInfo _rekeyCategory(
  M3uExportCategoryInfo category,
  String siteId,
) {
  return M3uExportCategoryInfo(
    siteId: siteId,
    siteName: category.siteName,
    categoryId: category.categoryId,
    categoryName: category.categoryName,
    categoryPath: category.categoryPath,
    parentId: category.parentId,
    extra: category.extra,
    updatedAt: category.updatedAt,
  );
}

M3uExportVideoRecord _rekeyVideo(
  M3uExportVideoRecord video,
  String siteId,
) {
  return M3uExportVideoRecord(
    siteId: siteId,
    siteName: video.siteName,
    categoryId: video.categoryId,
    categoryName: video.categoryName,
    categoryPath: video.categoryPath,
    videoId: video.videoId,
    title: video.title,
    url: video.url,
    localPath: video.localPath,
    cover: video.cover,
    synopsis: video.synopsis,
    extra: video.extra,
    episodeCount: video.episodeCount,
    updatedAt: video.updatedAt,
  );
}

class M3uExportCategoryInfo {
  const M3uExportCategoryInfo({
    required this.siteId,
    required this.siteName,
    required this.categoryId,
    required this.categoryName,
    this.categoryPath = '',
    this.parentId = '',
    this.extra = const {},
    required this.updatedAt,
  });

  final String siteId;
  final String siteName;
  final String categoryId;
  final String categoryName;

  /// 分类路径：从站根到本分类的完整路径，层级间用 / 连接；
  /// 单级分类时路径即分类名。详情挂在最末级分类（视频记录
  /// 的 categoryId）下，不压平成一级。
  final String categoryPath;

  /// 父分类 id：顶级分类为空；多级分类时指向上级分类的
  /// categoryId，层级链按 parentId 走，不跨站混。
  final String parentId;

  /// 分类级扩展字段：该站分类自带的属性，按站原样保留。
  final Map<String, String> extra;
  final int updatedAt;

  String get key => 'cat:$siteId|$categoryId';

  Map<String, dynamic> toMap() => {
    'siteId': siteId,
    'siteName': siteName,
    'categoryId': categoryId,
    'categoryName': categoryName,
    'categoryPath': categoryPath,
    'parentId': parentId,
    'extra': extra,
    'updatedAt': updatedAt,
  };

  static M3uExportCategoryInfo? fromMap(Map<dynamic, dynamic> raw) {
    final siteId = raw['siteId'];
    final categoryId = raw['categoryId'];
    if (siteId is! String ||
        siteId.isEmpty ||
        categoryId is! String ||
        categoryId.isEmpty) {
      return null;
    }
    String text(dynamic value) => value is String ? value : '';
    final categoryName = text(raw['categoryName']);
    final categoryPath = text(raw['categoryPath']);
    final extra = <String, String>{};
    final rawExtra = raw['extra'];
    if (rawExtra is Map) {
      for (final entry in rawExtra.entries) {
        extra[entry.key.toString()] = entry.value.toString();
      }
    }
    return M3uExportCategoryInfo(
      siteId: siteId,
      siteName: text(raw['siteName']),
      categoryId: categoryId,
      categoryName: categoryName,
      categoryPath: categoryPath.isEmpty ? categoryName : categoryPath,
      parentId: text(raw['parentId']),
      extra: extra,
      updatedAt: raw['updatedAt'] is int ? raw['updatedAt'] as int : 0,
    );
  }
}

class M3uExportVideoRecord {
  const M3uExportVideoRecord({
    required this.siteId,
    required this.siteName,
    required this.categoryId,
    required this.categoryName,
    this.categoryPath = '',
    required this.videoId,
    required this.title,
    required this.url,
    this.localPath = '',
    required this.cover,
    required this.synopsis,
    this.extra = const {},
    this.episodeCount = 0,
    required this.updatedAt,
  });

  final String siteId;
  final String siteName;
  final String categoryId;
  final String categoryName;
  final String categoryPath;
  final String videoId;
  final String title;

  /// 线上地址：始终保留，下载成功也不被本地路径覆盖。
  final String url;

  /// 本地路径：没下载时为空；下载成功后记本地文件路径。
  final String localPath;
  final String cover;
  final String synopsis;

  /// 详情原字段扩展：通用列之外的站原字段，按站原样保留。
  final Map<String, String> extra;

  /// 集数：取详情时为详情选集数，详情拿不到时为 0（表示未知）。
  final int episodeCount;
  final int updatedAt;

  String get key => 'video:$siteId|$videoId';

  /// 写库合并：双轨两字段并存，互不覆盖。
  ///
  /// 原始链接只读：新记录的 url 为空时沿用旧 url，绝不让一次
  /// 写库把线上地址刷空；本地路径另起字段：新记录没下载时
  /// 沿用旧本地路径（且旧文件还在），重复导出不刷空已下载
  /// 的指针；旧文件已删时不留死指针，回落线上。
  M3uExportVideoRecord mergedForSave(M3uExportVideoRecord? existing) {
    if (existing == null) return this;
    var localPath = this.localPath;
    if (localPath.isEmpty &&
        existing.localPath.isNotEmpty &&
        File(existing.localPath).existsSync()) {
      localPath = existing.localPath;
    }
    var url = this.url;
    if (url.isEmpty && existing.url.isNotEmpty) url = existing.url;
    if (localPath == this.localPath && url == this.url) return this;
    return M3uExportVideoRecord(
      siteId: siteId,
      siteName: siteName,
      categoryId: categoryId,
      categoryName: categoryName,
      categoryPath: categoryPath,
      videoId: videoId,
      title: title,
      url: url,
      localPath: localPath,
      cover: cover,
      synopsis: synopsis,
      extra: extra,
      episodeCount: episodeCount,
      updatedAt: updatedAt,
    );
  }

  Map<String, dynamic> toMap() => {
    'siteId': siteId,
    'siteName': siteName,
    'categoryId': categoryId,
    'categoryName': categoryName,
    'categoryPath': categoryPath,
    'videoId': videoId,
    'title': title,
    'url': url,
    'localPath': localPath,
    'cover': cover,
    'synopsis': synopsis,
    'extra': extra,
    'episodeCount': episodeCount,
    'updatedAt': updatedAt,
  };

  static M3uExportVideoRecord? fromMap(Map<dynamic, dynamic> raw) {
    final siteId = raw['siteId'];
    final videoId = raw['videoId'];
    final url = raw['url'];
    if (siteId is! String ||
        siteId.isEmpty ||
        videoId is! String ||
        videoId.isEmpty ||
        url is! String ||
        url.isEmpty) {
      return null;
    }
    String text(dynamic value) => value is String ? value : '';
    final localPath = text(raw['localPath']);
    final categoryName = text(raw['categoryName']);
    final categoryPath = text(raw['categoryPath']);
    final extra = <String, String>{};
    final rawExtra = raw['extra'];
    if (rawExtra is Map) {
      for (final entry in rawExtra.entries) {
        extra[entry.key.toString()] = entry.value.toString();
      }
    }
    M3uExportVideoRecord build({
      required String onlineUrl,
      required String local,
    }) {
      return M3uExportVideoRecord(
        siteId: siteId,
        siteName: text(raw['siteName']),
        categoryId: text(raw['categoryId']),
        categoryName: categoryName,
        categoryPath: categoryPath.isEmpty ? categoryName : categoryPath,
        videoId: videoId,
        title: text(raw['title']),
        url: onlineUrl,
        localPath: local,
        cover: text(raw['cover']),
        synopsis: text(raw['synopsis']),
        extra: extra,
        episodeCount:
            raw['episodeCount'] is int ? raw['episodeCount'] as int : 0,
        updatedAt: raw['updatedAt'] is int ? raw['updatedAt'] as int : 0,
      );
    }

    if (localPath.isEmpty && !_looksOnline(url)) {
      return build(onlineUrl: '', local: url);
    }
    return build(onlineUrl: url, local: localPath);
  }

  static bool _looksOnline(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https');
  }
}

/// 双轨播放解析：有本地文件走本地，没本地走线上，两处都没有回 null，
/// 调用方须把 null 如实报成“没有可播地址”，不要静默失败。
String? resolveExportedPlayUrl(M3uExportVideoRecord record) {
  if (record.localPath.isNotEmpty &&
      File(record.localPath).existsSync()) {
    return record.localPath;
  }
  if (record.url.isNotEmpty) return record.url;
  return null;
}

abstract interface class M3uExportDbSink {
  Future<void> saveExport({
    required String siteId,
    required String siteName,
    required List<M3uExportCategoryInfo> categories,
    required List<M3uExportVideoRecord> videos,
  });

  Future<List<M3uExportVideoRecord>> listVideos({
    required bool gateOpen,
    String? siteId,
    String? categoryId,
  });

  Future<List<M3uExportCategoryInfo>> listCategories({
    required bool gateOpen,
    String? siteId,
  });

  Future<M3uExportVideoRecord?> getVideo({
    required bool gateOpen,
    required String siteId,
    required String videoId,
  });
}

class HiveM3uExportDb implements M3uExportDbSink {
  HiveM3uExportDb({
    HiveInterface? hive,
    this._keys,
    this.directoryResolver,
  }) : _hive = hive ?? Hive;

  static final HiveM3uExportDb instance = HiveM3uExportDb();

  /// 旧箱名：公开目录启用前的数据落点，迁移后只作备份，不再读取。
  static const _boxName = 'm3u_export_v1';

  /// 公开目录里的箱名：与旧箱名不同，避免同一会话里新旧箱
  /// 按名撞上（Hive 按名登记已开箱）。
  static const _publicBoxName = 'm3u_export_v1_pub';

  /// 手机根目录下的公开文件夹名。
  static const publicFolderName = '火蚁聚合';

  final HiveInterface _hive;
  final SecureKeyProvider? _keys;

  /// 公开目录解析：默认取主外置存储根下的火蚁聚合文件夹；
  /// 测试注入临时目录。文件夹不存在时自动创建。
  final Future<Directory> Function()? directoryResolver;
  Future<Box<dynamic>>? _opening;

  bool get isReady => EncryptedHive.isBoxOpen(_hive, _publicBoxName);

  Future<Directory> _publicDir() async {
    final resolve = directoryResolver ?? _defaultPublicDir;
    final dir = await resolve();
    try {
      await dir.create(recursive: true);
    } on FileSystemException catch (e) {
      throw StateError(
        '无法创建火蚁聚合文件夹（${dir.path}）：${e.message}',
      );
    }
    return dir;
  }

  static Future<Directory> _defaultPublicDir() async {
    final root = await PublicFolder.publicRoot();
    return Directory('$root/$publicFolderName');
  }

  Future<Box<dynamic>> _box() async {
    if (EncryptedHive.isBoxOpen(_hive, _publicBoxName)) {
      return EncryptedHive.box<dynamic>(_hive, _publicBoxName);
    }
    final opening = _opening ??= _openPublic();
    try {
      return await opening;
    } finally {
      if (identical(_opening, opening)) _opening = null;
    }
  }

  Future<Box<dynamic>> _openPublic() async {
    final dir = await _publicDir();
    final box = await EncryptedHive.openBox<dynamic>(
      _hive,
      _publicBoxName,
      keys: _keys,
      path: dir.path,
    );
    await _migrateFromLegacy(box);
    return box;
  }

  /// 旧箱到公开箱的一次性迁移：公开箱为空且旧箱有数据时
  /// 全量拷过去；旧箱文件保留作备份，不删除、不再读取。
  /// 迁移失败（旧箱打不开等）不拦新箱使用，下次打开再试。
  /// 拷过去之前先把记录换成归一键，不留原始键与新键并存的两份。
  Future<void> _migrateFromLegacy(Box<dynamic> publicBox) async {
    if (publicBox.isNotEmpty) return;
    Box<dynamic>? legacy;
    try {
      if (EncryptedHive.isBoxOpen(_hive, _boxName)) {
        legacy = EncryptedHive.box<dynamic>(_hive, _boxName);
      } else {
        legacy = await EncryptedHive.openBox<dynamic>(
          _hive,
          _boxName,
          keys: _keys,
        );
      }
    } catch (_) {
      return;
    }
    if (legacy.isEmpty) return;
    final entries = <dynamic, dynamic>{};
    for (final key in legacy.keys) {
      final raw = legacy.get(key);
      // 按键前缀分流，不用 fromMap 试解析：视频记录也有
      // siteId/categoryId，分类 fromMap 会误把它认成分类。
      if (raw is Map && key is String && key.startsWith('cat:')) {
        final category = M3uExportCategoryInfo.fromMap(raw);
        if (category != null) {
          final keyed = _rekeyCategory(
            category,
            canonicalSiteKey(siteId: category.siteId),
          );
          entries[keyed.key] = keyed.toMap();
          continue;
        }
      }
      if (raw is Map && key is String && key.startsWith('video:')) {
        final video = M3uExportVideoRecord.fromMap(raw);
        if (video != null) {
          final keyed = _rekeyVideo(
            video,
            canonicalSiteKey(siteId: video.siteId),
          );
          entries[keyed.key] = keyed.toMap();
          continue;
        }
      }
      entries[key] = raw;
    }
    if (entries.isNotEmpty) await publicBox.putAll(entries);
  }

  @override
  Future<void> saveExport({
    required String siteId,
    required String siteName,
    required List<M3uExportCategoryInfo> categories,
    required List<M3uExportVideoRecord> videos,
  }) async {
    final box = await _box();
    final dbSiteId = canonicalSiteKey(siteId: siteId);
    final keyedCategories = [
      for (final category in categories) _rekeyCategory(category, dbSiteId),
    ];
    final keyedVideos = [
      for (final video in videos) _rekeyVideo(video, dbSiteId),
    ];
    await box.putAll({
      for (final category in keyedCategories)
        category.key: category.toMap(),
    });
    await box.putAll({
      for (final video in keyedVideos)
        video.key: video
            .mergedForSave(
              box.get(video.key) is Map
                  ? M3uExportVideoRecord.fromMap(
                      box.get(video.key) as Map,
                    )
                  : null,
            )
            .toMap(),
    });
  }

  @override
  Future<List<M3uExportVideoRecord>> listVideos({
    required bool gateOpen,
    String? siteId,
    String? categoryId,
  }) async {
    final box = await _box();
    final want = siteId == null ? null : canonicalSiteKey(siteId: siteId);
    final records = <M3uExportVideoRecord>[];
    for (final raw in box.values) {
      if (raw is! Map) continue;
      final record = M3uExportVideoRecord.fromMap(raw);
      if (record == null) continue;
      if (!gateOpen && MidnightGate.isAdultName(record.siteName)) continue;
      if (want != null && record.siteId != want) continue;
      if (categoryId != null && record.categoryId != categoryId) continue;
      records.add(record);
    }
    records.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return records;
  }

  @override
  Future<List<M3uExportCategoryInfo>> listCategories({
    required bool gateOpen,
    String? siteId,
  }) async {
    final box = await _box();
    final want = siteId == null ? null : canonicalSiteKey(siteId: siteId);
    final categories = <M3uExportCategoryInfo>[];
    for (final key in box.keys) {
      if (key is! String || !key.startsWith('cat:')) continue;
      final raw = box.get(key);
      if (raw is! Map) continue;
      final category = M3uExportCategoryInfo.fromMap(raw);
      if (category == null) continue;
      if (!gateOpen && MidnightGate.isAdultName(category.siteName)) continue;
      if (want != null && category.siteId != want) continue;
      categories.add(category);
    }
    categories.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return categories;
  }

  @override
  Future<M3uExportVideoRecord?> getVideo({
    required bool gateOpen,
    required String siteId,
    required String videoId,
  }) async {
    final box = await _box();
    final raw =
        box.get('video:${canonicalSiteKey(siteId: siteId)}|$videoId');
    if (raw is! Map) return null;
    final record = M3uExportVideoRecord.fromMap(raw);
    if (record == null) return null;
    if (!gateOpen && MidnightGate.isAdultName(record.siteName)) return null;
    return record;
  }
}

class MemoryM3uExportDb implements M3uExportDbSink {
  final categories = <String, M3uExportCategoryInfo>{};
  final videos = <String, M3uExportVideoRecord>{};

  @override
  Future<void> saveExport({
    required String siteId,
    required String siteName,
    required List<M3uExportCategoryInfo> categories,
    required List<M3uExportVideoRecord> videos,
  }) async {
    final dbSiteId = canonicalSiteKey(siteId: siteId);
    for (final category in categories) {
      final keyed = _rekeyCategory(category, dbSiteId);
      this.categories[keyed.key] = keyed;
    }
    for (final video in videos) {
      final keyed = _rekeyVideo(video, dbSiteId);
      this.videos[keyed.key] =
          keyed.mergedForSave(this.videos[keyed.key]);
    }
  }

  @override
  Future<List<M3uExportVideoRecord>> listVideos({
    required bool gateOpen,
    String? siteId,
    String? categoryId,
  }) async {
    final want = siteId == null ? null : canonicalSiteKey(siteId: siteId);
    final records = [
      for (final video in videos.values)
        if ((gateOpen || !MidnightGate.isAdultName(video.siteName)) &&
            (want == null || video.siteId == want) &&
            (categoryId == null || video.categoryId == categoryId))
          video,
    ];
    records.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return records;
  }

  @override
  Future<List<M3uExportCategoryInfo>> listCategories({
    required bool gateOpen,
    String? siteId,
  }) async {
    final want = siteId == null ? null : canonicalSiteKey(siteId: siteId);
    final result = [
      for (final category in categories.values)
        if ((gateOpen || !MidnightGate.isAdultName(category.siteName)) &&
            (want == null || category.siteId == want))
          category,
    ];
    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  @override
  Future<M3uExportVideoRecord?> getVideo({
    required bool gateOpen,
    required String siteId,
    required String videoId,
  }) async {
    final record =
        videos['video:${canonicalSiteKey(siteId: siteId)}|$videoId'];
    if (record == null) return null;
    if (!gateOpen && MidnightGate.isAdultName(record.siteName)) return null;
    return record;
  }
}
