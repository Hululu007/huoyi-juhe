import 'dart:convert';

import 'package:flutter/services.dart';

/// 统一分类浏览页数据：201 核心视频站的静态分类按名归并。
///
/// 数据来自 `assets/unified_video_categories.json`（由
/// `unified_category_work/generate_unified_asset.py` 从 Rust 模块的
/// 静态 CATS 抽取生成，Dart 侧不写死分类名；分类变了重新生成一遍即可）。
/// 现状：127 站有静态 CATS（2838 条，1600 去重名）；标签已接进
/// （2026-11-06，`~/workspace/tpd_harvest/all_stations_tags.json`，
/// 50 站、38205 名、40648 条，只收 `browsable` 为真的；2026-11-08 摘
/// AOXX69 后为 49 站、38065 名、40486 条）；53 站既无
/// 静态 CATS 也无可用标签（见 `sitesWithoutCategories` 与工作笔记
/// `unified_category_work/tags_notes.md`），另 21 站只有标签、没有
/// 静态 CATS。
///
/// 统一页分分类 + 标签两部分（用户 2026-11-06 定）：分类一组、标签
/// 一组并列。标签格式如下，不用改结构：
///
/// ```json
/// "tags": {
///   "标签名": [{"siteId": "站 id", "url": "站内标签链接", "browsable": true}]
/// }
/// ```
///
/// 只收 `browsable` 为真的标签（链接点开真能出内容才算可用；字段缺失
/// 或为假的一律不进页）。点标签后走同一条汇总链路
/// （`UnifiedBrowseContentPage`，按站 `catalog(url, 1)` 取内容）。

/// 热门分类门槛：>=5 个站有该分类（现 86 个名）。
const int unifiedHotSiteThreshold = 5;

/// 统一分类资产路径。
const String unifiedVideoCategoriesAsset =
    'assets/unified_video_categories.json';

/// 一个分类名下的一站：站 id + 该站的分类路径（调
/// `dramaSiteContentClient(siteId).catalog(path, 1)` 取内容）。
class UnifiedCategorySite {
  const UnifiedCategorySite({required this.siteId, required this.path});

  final String siteId;
  final String path;
}

/// 一个标签名下的一站：站 id + 该站的标签链接 + 是否可浏览。
class UnifiedTagSite {
  const UnifiedTagSite({
    required this.siteId,
    required this.url,
    required this.browsable,
  });

  final String siteId;
  final String url;
  final bool browsable;
}

/// 统一分类浏览页的全部数据（分类 + 标签两部分）。
class UnifiedVideoCategories {
  const UnifiedVideoCategories({
    required this.categories,
    required this.tags,
    required this.sitesWithoutCategories,
    required this.siteCount,
    required this.totalSiteCount,
  });

  /// 分类名 -> 有它的站（按站 id、路径排过序）。
  final Map<String, List<UnifiedCategorySite>> categories;

  /// 标签名 -> 有它的站（只含 `browsable` 为真的站）。
  final Map<String, List<UnifiedTagSite>> tags;

  /// 既无静态分类、也无可用标签的站 id（动态分类或无标签体系；
  /// 如实记下，不丢；只有标签、没有静态分类的站不在里面）。
  final List<String> sitesWithoutCategories;

  /// 有静态分类的站数。
  final int siteCount;

  /// 核心视频站总数。
  final int totalSiteCount;

  /// 热门分类名：>= [unifiedHotSiteThreshold] 个站（现 86 个），
  /// 按站数降序、同站数按名升序。
  List<String> get hotNames => _sortedNames(
    categories.keys.where(
      (name) => categories[name]!.length >= unifiedHotSiteThreshold,
    ),
  );

  /// 全部的分量名：按站数降序、同站数按名升序。
  List<String> get allNames => _sortedNames(categories.keys);

  /// 全部的标签名：按站数降序、同站数按名升序。
  List<String> get tagNames => _sortedNames(
    tags.keys,
    counts: {for (final e in tags.entries) e.key: e.value.length},
  );

  List<String> _sortedNames(
    Iterable<String> names, {
    Map<String, int>? counts,
  }) {
    final list = names.toList();
    list.sort((a, b) {
      final ca = counts?[a] ?? categories[a]?.length ?? 0;
      final cb = counts?[b] ?? categories[b]?.length ?? 0;
      if (ca != cb) return cb.compareTo(ca);
      return a.compareTo(b);
    });
    return list;
  }

  /// 某分类名的站列表（无此名返回空）。
  List<UnifiedCategorySite> sitesFor(String name) =>
      categories[name] ?? const [];

  /// 某标签名的站列表（无此名返回空）。
  List<UnifiedTagSite> tagSitesFor(String name) => tags[name] ?? const [];

  /// 某分类名的站数。
  int siteCountFor(String name) => categories[name]?.length ?? 0;

  /// 空数据（资产缺失/损坏时的兜底，不炸页）。
  static const UnifiedVideoCategories empty = UnifiedVideoCategories(
    categories: {},
    tags: {},
    sitesWithoutCategories: [],
    siteCount: 0,
    totalSiteCount: 0,
  );
}

/// 解析统一分类资产（纯函数，可单测；字段缺失/类型不对/JSON 损坏时
/// 容错返回空数据，不抛错——资产是生成物，出问题宁可少显示，不炸页）。
UnifiedVideoCategories parseUnifiedVideoCategories(String jsonText) {
  Object? decoded;
  try {
    decoded = jsonDecode(jsonText);
  } catch (_) {
    return UnifiedVideoCategories.empty;
  }
  if (decoded is! Map) return UnifiedVideoCategories.empty;
  final categories = <String, List<UnifiedCategorySite>>{};
  final rawCats = decoded['categories'];
  if (rawCats is Map) {
    for (final entry in rawCats.entries) {
      final name = entry.key.toString().trim();
      if (name.isEmpty || entry.value is! List) continue;
      final sites = <UnifiedCategorySite>[];
      for (final raw in entry.value as List) {
        if (raw is! Map) continue;
        final siteId = (raw['siteId'] ?? '').toString().trim();
        final path = (raw['path'] ?? '').toString().trim();
        if (siteId.isEmpty || path.isEmpty) continue;
        sites.add(UnifiedCategorySite(siteId: siteId, path: path));
      }
      if (sites.isNotEmpty) categories[name] = sites;
    }
  }
  final tags = <String, List<UnifiedTagSite>>{};
  final rawTags = decoded['tags'];
  if (rawTags is Map) {
    for (final entry in rawTags.entries) {
      final name = entry.key.toString().trim();
      if (name.isEmpty || entry.value is! List) continue;
      final sites = <UnifiedTagSite>[];
      for (final raw in entry.value as List) {
        if (raw is! Map) continue;
        final siteId = (raw['siteId'] ?? '').toString().trim();
        final url = (raw['url'] ?? '').toString().trim();
        // 只收 browsable 明确为真的标签；字段缺失或为假的不进页。
        if (siteId.isEmpty || url.isEmpty || raw['browsable'] != true) {
          continue;
        }
        sites.add(
          UnifiedTagSite(siteId: siteId, url: url, browsable: true),
        );
      }
      if (sites.isNotEmpty) tags[name] = sites;
    }
  } else if (rawTags is List) {
    // 兼容列表形：[{name, siteId, url, browsable}, ...]。
    for (final raw in rawTags) {
      if (raw is! Map) continue;
      final name = (raw['name'] ?? '').toString().trim();
      final siteId = (raw['siteId'] ?? '').toString().trim();
      final url = (raw['url'] ?? '').toString().trim();
      if (name.isEmpty ||
          siteId.isEmpty ||
          url.isEmpty ||
          raw['browsable'] != true) {
        continue;
      }
      (tags[name] ??= []).add(
        UnifiedTagSite(siteId: siteId, url: url, browsable: true),
      );
    }
  }
  final without = <String>[];
  final rawWithout = decoded['sites_without_categories'];
  if (rawWithout is List) {
    for (final item in rawWithout) {
      final id = item.toString().trim();
      if (id.isNotEmpty) without.add(id);
    }
  }
  int asInt(Object? value) => value is int
      ? value
      : int.tryParse(value?.toString() ?? '') ?? 0;
  return UnifiedVideoCategories(
    categories: categories,
    tags: tags,
    sitesWithoutCategories: without,
    siteCount: asInt(decoded['site_count']),
    totalSiteCount: asInt(decoded['total_site_count']),
  );
}

/// 读统一分类资产（生产默认 rootBundle；测试可注入假 bundle）。
/// 读不到/解析失败返回空数据，不抛错。
Future<UnifiedVideoCategories> loadUnifiedVideoCategories({
  AssetBundle? bundle,
}) async {
  try {
    final text = await (bundle ?? rootBundle).loadString(
      unifiedVideoCategoriesAsset,
    );
    return parseUnifiedVideoCategories(text);
  } catch (_) {
    return UnifiedVideoCategories.empty;
  }
}
