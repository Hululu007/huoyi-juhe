import 'dart:async';

import 'api_client.dart';
import 'drama_site_content.dart';
import 'local_db_site_content.dart';
import 'm3u_export_db.dart';
import 'midnight_gate.dart';
import 'source_registry.dart';

class DramaSiteSearchResult {
  const DramaSiteSearchResult({
    required this.siteId,
    required this.siteName,
    required this.items,
  });

  final String siteId;
  final String siteName;
  final List<DramaSiteItem> items;
}

/// 本地库进全局搜索：按库里各站分别成组，站名后挂“·本地库”作
/// 来源标识，与线上站同列展示，不替换任何线上站的结果。
Future<List<DramaSiteSearchResult>> searchLocalDbSites(
  String query, {
  required M3uExportDbSink dbSink,
  required bool gateOpen,
}) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return const [];
  final categories = await dbSink.listCategories(gateOpen: gateOpen);
  final siteNames = <String, String>{};
  for (final category in categories) {
    siteNames.putIfAbsent(category.siteId, () => category.siteName);
  }
  final groups = <DramaSiteSearchResult>[];
  for (final entry in siteNames.entries) {
    final client = LocalDbContentClient(
      dbSiteId: entry.key,
      dbSink: dbSink,
    );
    final items = await client.search(trimmed);
    if (items.isNotEmpty) {
      groups.add(
        DramaSiteSearchResult(
          siteId: 'localdb:${entry.key}',
          siteName: '${entry.value}·本地库',
          items: items,
        ),
      );
    }
  }
  return groups;
}

/// 标签名转站源搜索词：资产里部分站的标签名自带站方计数后缀
/// （如 okxxx 的 `1080p (896)`、`18 (3122)`，见
/// `unified_category_work/tags_notes.md`），原样当关键词搜不到；
/// 只去尾部 ` (数字)`，名字其余部分一字不动。
String tagSearchQuery(String tagName) =>
    tagName.trim().replaceFirst(RegExp(r' \(\d+\)$'), '');

/// 按站分组搜全部可见站源（[SearchPage] 的「站源」页签）。
///
/// [siteIds] 有值时只搜这些站：标签页点标签只搜该标签名下的站
/// （`UnifiedVideoCategories.tagSitesFor` 给出的站），不向 200 多站
/// 全量扇出——全量扇出时请求在 [RequestGate]（16 并发）后排队，
/// 排在后面的站（wohs/jable/okxxx 都在站表尾部）45 秒预算耗在排队
/// 上、一个都没跑到就超时回空，页上只剩「站源里没有搜到相关内容」。
/// 只搜标签的站时并行数 <= 门限，并发一次跑完。
/// 限定站时不同时并本地库：本地库没有标签映射，按站搜不到它。
Future<List<DramaSiteSearchResult>> searchAllDramaSites(
  String query, {
  M3uExportDbSink? dbSink,
  Set<String>? siteIds,
}) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return const [];
  await SourceRegistry.instance.load();
  await MidnightGate.ensureLoaded();
  final gateOpen = MidnightGate.activated.value;
  final futures = <Future<DramaSiteSearchResult>>[];
  for (final site in SourceRegistry.instance.visibleDramaSites()) {
    if (site.id == 'original') continue;
    if (siteIds != null && !siteIds.contains(site.id)) continue;
    if (!gateOpen && MidnightGate.isAdultName(site.name)) continue;
    final client = await SourceRegistry.instance.clientFor(site.id);
    if (client == null) continue;
    futures.add(
      // 单站搜索超时按 ApiClient 的搜索预算 + 5 秒余量：ApiClient
      // 是主预算，调用层只当兜底，不盖帽；超时的站回空组，
      // 不卡住整轮搜索。
      client
          .search(trimmed)
          .timeout(
            ApiClient.dramaSearchTimeout + const Duration(seconds: 5),
          )
          .then(
            (items) => DramaSiteSearchResult(
              siteId: site.id,
              siteName: site.name,
              items: items,
            ),
          )
          .catchError(
            (_) => DramaSiteSearchResult(
              siteId: site.id,
              siteName: site.name,
              items: const [],
            ),
          ),
    );
  }
  final results = await Future.wait(futures);
  final merged = results.where((result) => result.items.isNotEmpty).toList();
  if (siteIds != null) return merged;
  try {
    merged.addAll(
      await searchLocalDbSites(
        trimmed,
        dbSink: dbSink ?? HiveM3uExportDb.instance,
        gateOpen: gateOpen,
      ),
    );
  } catch (_) {}
  return merged;
}
