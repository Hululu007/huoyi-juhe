import 'dart:io';

import 'package:hive_ce/hive.dart';

import 'encrypted_hive.dart';
import 'midnight_gate.dart';
import 'secure_key_provider.dart';

class M3uExportCategoryInfo {
  const M3uExportCategoryInfo({
    required this.siteId,
    required this.siteName,
    required this.categoryId,
    required this.categoryName,
    this.categoryPath = '',
    required this.updatedAt,
  });

  final String siteId;
  final String siteName;
  final String categoryId;
  final String categoryName;

  /// 分类路径：该站自己的层级路径（蜘蛛分类目前是平的，路径即
  /// 分类名；字段留给以后多级分类，跨站不混）。
  final String categoryPath;
  final int updatedAt;

  String get key => 'cat:$siteId|$categoryId';

  Map<String, dynamic> toMap() => {
    'siteId': siteId,
    'siteName': siteName,
    'categoryId': categoryId,
    'categoryName': categoryName,
    'categoryPath': categoryPath,
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
    return M3uExportCategoryInfo(
      siteId: siteId,
      siteName: text(raw['siteName']),
      categoryId: categoryId,
      categoryName: categoryName,
      categoryPath: categoryPath.isEmpty ? categoryName : categoryPath,
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
}

class HiveM3uExportDb implements M3uExportDbSink {
  HiveM3uExportDb({HiveInterface? hive, this._keys}) : _hive = hive ?? Hive;

  static final HiveM3uExportDb instance = HiveM3uExportDb();
  static const _boxName = 'm3u_export_v1';

  final HiveInterface _hive;
  final SecureKeyProvider? _keys;
  Future<Box<dynamic>>? _opening;

  bool get isReady => EncryptedHive.isBoxOpen(_hive, _boxName);

  Future<Box<dynamic>> _box() async {
    if (EncryptedHive.isBoxOpen(_hive, _boxName)) {
      return EncryptedHive.box<dynamic>(_hive, _boxName);
    }
    final opening = _opening ??= EncryptedHive.openBox<dynamic>(
      _hive,
      _boxName,
      keys: _keys,
    );
    try {
      return await opening;
    } finally {
      if (identical(_opening, opening)) _opening = null;
    }
  }

  @override
  Future<void> saveExport({
    required String siteId,
    required String siteName,
    required List<M3uExportCategoryInfo> categories,
    required List<M3uExportVideoRecord> videos,
  }) async {
    final box = await _box();
    await box.putAll({
      for (final category in categories) category.key: category.toMap(),
    });
    await box.putAll({
      for (final video in videos) video.key: video.toMap(),
    });
  }

  @override
  Future<List<M3uExportVideoRecord>> listVideos({
    required bool gateOpen,
    String? siteId,
    String? categoryId,
  }) async {
    final box = await _box();
    final records = <M3uExportVideoRecord>[];
    for (final raw in box.values) {
      if (raw is! Map) continue;
      final record = M3uExportVideoRecord.fromMap(raw);
      if (record == null) continue;
      if (!gateOpen && MidnightGate.isAdultName(record.siteName)) continue;
      if (siteId != null && record.siteId != siteId) continue;
      if (categoryId != null && record.categoryId != categoryId) continue;
      records.add(record);
    }
    records.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return records;
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
    for (final category in categories) {
      this.categories[category.key] = category;
    }
    for (final video in videos) {
      this.videos[video.key] = video;
    }
  }

  @override
  Future<List<M3uExportVideoRecord>> listVideos({
    required bool gateOpen,
    String? siteId,
    String? categoryId,
  }) async {
    final records = [
      for (final video in videos.values)
        if ((gateOpen || !MidnightGate.isAdultName(video.siteName)) &&
            (siteId == null || video.siteId == siteId) &&
            (categoryId == null || video.categoryId == categoryId))
          video,
    ];
    records.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return records;
  }
}
