import '../models/media_item.dart';
import 'drama_site_content.dart';
import 'drama_sites.dart';

/// 合并分类里一个站的条目：该站有这个分类时，取数用这个分类 id。
class NovelCategoryEntry {
  const NovelCategoryEntry(this.siteId, this.categoryId);

  final String siteId;
  final String categoryId;
}

/// 合并后的一个分类：名字是各站分类展示名的合体，entries 是有该分类
/// 的站（站 id + 该站分类 id），点它进混排目录页。
class MergedNovelCategory {
  const MergedNovelCategory(this.name, this.entries);

  final String name;
  final List<NovelCategoryEntry> entries;
}

/// 小说区一般分类用的核心站：核心小说站里去掉成人站（成人站只进
/// 成人小说页，不混进一般小说页）。目前剩 aabook 与 ylxs 两站，
/// 顺序跟核心站表一致。
List<String> coreGeneralNovelSiteIds() => [
  for (final id in coreReadingSiteIds)
    if (coreReadingKinds[id] == 'novel' &&
        !coreAdultReadingSiteIds.contains(id))
      id,
];

/// 把各站分类按展示名合并（纯函数，页测不落网络）：
/// 首位是合成的「全部」（每站首分类，点它混排各站首页），其后是
/// 按名合并的分类（站数多的在前，同站数按首次出现顺序）。
/// 各站自带名叫「全部」的分类不另起一条（已由合成「全部」覆盖），
/// 空名与无分类的站不进表。
List<MergedNovelCategory> mergeNovelCategories(
  Map<String, List<DramaSiteCategory>> bySite,
  List<String> siteOrder,
) {
  final allEntries = <NovelCategoryEntry>[];
  for (final siteId in siteOrder) {
    final categories = bySite[siteId];
    if (categories == null || categories.isEmpty) continue;
    allEntries.add(NovelCategoryEntry(siteId, categories.first.id));
  }
  final merged = <String, List<NovelCategoryEntry>>{};
  final firstSeen = <String, int>{};
  for (final siteId in siteOrder) {
    final categories = bySite[siteId];
    if (categories == null) continue;
    final seenInSite = <String>{};
    for (final category in categories) {
      final name = category.displayName.trim();
      if (name.isEmpty || name == '全部') continue;
      if (!seenInSite.add(name)) continue;
      firstSeen.putIfAbsent(name, () => firstSeen.length);
      (merged[name] ??= []).add(
        NovelCategoryEntry(siteId, category.id),
      );
    }
  }
  final named = merged.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.length.compareTo(a.value.length);
      if (byCount != 0) return byCount;
      return firstSeen[a.key]!.compareTo(firstSeen[b.key]!);
    });
  return [
    if (allEntries.isNotEmpty) MergedNovelCategory('全部', allEntries),
    for (final entry in named)
      MergedNovelCategory(entry.key, entry.value),
  ];
}

/// 各站目录轮流取一条混排（纯函数）：站 1 第 1 条、站 2 第 1 条、…
/// 站 1 第 2 条、站 2 第 2 条…，空站跳过，总量默认 60 条。
List<MediaItem> interleaveCatalogItems(
  List<List<MediaItem>> perSite, {
  int cap = 60,
}) {
  final out = <MediaItem>[];
  var index = 0;
  while (out.length < cap) {
    var advanced = false;
    for (final list in perSite) {
      if (index < list.length) {
        out.add(list[index]);
        advanced = true;
        if (out.length >= cap) break;
      }
    }
    if (!advanced) break;
    index++;
  }
  return out;
}

/// 拉一般小说核心站的分类并合并：每站 15 秒超时，取不到的站静默跳过
/// （不因一站失败拖垮整条分类条）。
Future<List<MergedNovelCategory>> loadCoreNovelCategories() async {
  final siteIds = coreGeneralNovelSiteIds();
  final bySite = <String, List<DramaSiteCategory>>{};
  await Future.wait(
    siteIds.map((siteId) async {
      try {
        final client = readingSiteContentClient(siteId);
        if (client == null) return;
        final categories = await client
            .categories()
            .timeout(const Duration(seconds: 15));
        bySite[siteId] = categories;
      } catch (_) {
        // 取不到的站跳过，不进合并表。
      }
    }),
  );
  return mergeNovelCategories(bySite, siteIds);
}
