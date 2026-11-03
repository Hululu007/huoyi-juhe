import 'dart:async';

import 'drama_site_content.dart';
import 'drama_sites.dart';

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

Future<List<DramaSiteSearchResult>> searchAllDramaSites(
  String query,
) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return const [];
  final futures = <Future<DramaSiteSearchResult>>[];
  for (final site in dramaSites) {
    if (site.id == 'original') continue;
    final client = dramaSiteContentClient(site.id);
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
  return results.where((result) => result.items.isNotEmpty).toList();
}
