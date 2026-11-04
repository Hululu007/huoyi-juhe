import 'dart:async';

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

Future<List<DramaSiteSearchResult>> searchAllDramaSites(
  String query, {
  M3uExportDbSink? dbSink,
}) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return const [];
  await SourceRegistry.instance.load();
  await MidnightGate.ensureLoaded();
  final gateOpen = MidnightGate.activated.value;
  final futures = <Future<DramaSiteSearchResult>>[];
  for (final site in SourceRegistry.instance.visibleDramaSites()) {
    if (site.id == 'original') continue;
    if (!gateOpen && MidnightGate.isAdultName(site.name)) continue;
    final client = await SourceRegistry.instance.clientFor(site.id);
    if (client == null) continue;
    futures.add(
      client
          .search(trimmed)
          .timeout(const Duration(seconds: 15))
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
