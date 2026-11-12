import 'dart:async';

import 'api_client.dart';
import 'cultivation.dart';
import 'drama_site_content.dart';
import 'drama_sites.dart';
import 'local_db_site_content.dart';
import 'm3u_export_db.dart';
import 'midnight_gate.dart';
import 'source_registry.dart';

/// 一个站的一组搜索结果（站源搜索与全局搜索共用）。
class DramaSiteSearchResult {
  const DramaSiteSearchResult({
    required this.siteId,
    required this.siteName,
    required this.items,
    this.contentType = ContentType.mixed,
    this.readingCore = false,
  });

  final String siteId;
  final String siteName;
  final List<DramaSiteItem> items;

  /// 该站的内容类型：全局搜索按它分组标「视频/小说/漫画/听书」；
  /// 站源搜索不区分类型，默认综合。
  final ContentType contentType;

  /// 是否核心阅读站：这类站打开时必须走阅读客户端（见
  /// [GlobalSearchTarget.readingCore] 的撞名说明）。
  final bool readingCore;
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

/// 全局搜索里一条结果的类型标签：视频 / 小说 / 漫画 / 听书 / 综合。
/// 与 [ContentTypeLabel.label] 不同：视频站在这里标「视频」不标「影视」，
/// 与四种内容的叫法一致。
String globalSearchTypeLabel(ContentType type) => switch (type) {
  ContentType.video => '视频',
  ContentType.novel => '小说',
  ContentType.comic => '漫画',
  ContentType.audio => '听书',
  ContentType.mixed => '综合',
};

/// 全局搜索的目标站：一个可搜的站。
///
/// 三块来源拼在一起：短剧区站表行（[dramaSites]）、登记条目（py 种子 /
/// jar 内置 / 用户导入）、核心阅读站（[coreReadingSiteIds]）。午夜 jar
/// 内置站也收（与 [SourceRegistry.visibleDramaSites] 不同，那张表不收
/// 它们，站源搜索因此搜不到它们）；已排除的死站根本不在登记表里，自然
/// 不会进来。TG 频道 103 个是 jar 站里的一个条目（ZakaTg），搜它就是
/// 调该条目的客户端，不按频道扇出。
class GlobalSearchTarget {
  const GlobalSearchTarget({
    required this.id,
    required this.name,
    required this.contentType,
    this.readingCore = false,
  });

  /// 站 id：站表裸 id、登记条目 id（`seed_<id>` / `jar:<jarId>:<key>` /
  /// 导入 id），阅读站是核心站 id。
  final String id;
  final String name;
  final ContentType contentType;

  /// 是否核心阅读站：这类站的客户端走 [readingSiteContentClient]，
  /// 不走登记表解析——`hongguo` 这个 id 视频站与听书站撞名，登记表
  /// 解析会抢先拿到视频客户端，打开时必须按这个标记走阅读客户端。
  final bool readingCore;
}

/// 某站在此修为下是否可见（纯函数，可单测）：沿用影视区现有的境界门禁
/// 口径——视频站按 [adultVideoSiteOrder] 分 4 档，阅读站按核心阅读登记
/// 顺序分同样的 4 档；不在分档表里 = 非成人站，原样保留。未解锁的成人
/// 站连搜索都不进，结果不会漏给没解锁的用户。
bool globalSearchSiteVisible(
  String siteId,
  int xp, {
  required bool readingCore,
}) {
  if (readingCore) {
    if (!coreAdultReadingSiteIds.contains(siteId)) return true;
    final order = coreReadingSiteIds.toList();
    final tier = adultTierForIndex(order.indexOf(siteId), order.length);
    return adultTierUnlocked(tier, xp);
  }
  final tier = adultTierForSiteId(siteId, adultVideoSiteOrder);
  if (tier == null) return true;
  return adultTierUnlocked(tier, xp);
}

/// 全局搜索的站表（纯函数，可单测）：以登记表为准，全量收录，一个不落。
///
/// - 站表行：[dramaSites] 全部（被用户关掉的除外），一律按视频站算；
/// - 登记条目：`custom` 里已启用、可搜的六种（MacCMS / py / jar / JS /
///   XBPQ / 阅读），已有裸站行代表的（种子 id、jar key 归一化后与裸行
///   相同）不重复列，与 [SourceRegistry.visibleDramaSites] 同款去重，
///   但午夜 jar 内置站也收；
/// - 核心阅读站：[coreReadingSiteIds] 全收，类型走 [coreReadingKinds]，
///   不与裸行去重（视频红果与红果听书是两个源）。
///
/// 过滤：[types] 有值时只留这些类型；[siteIds] 有值时只留这些站；
/// [xp] 有值时按境界门禁过滤（见 [globalSearchSiteVisible]），为 null
/// 时不过滤；[shortDramaOnly] 只留短剧站（站表 id 或站名判据，与短剧区
/// 共用 [isShortDramaSite]）。`original`（番茄原始短剧站）不进：后端
/// 搜索已覆盖它，站源搜索不重复查（与 [searchAllDramaSites] 同款）。
List<GlobalSearchTarget> globalSearchTargets({
  required List<DramaSite> dramaSiteRows,
  required List<SourceEntry> customEntries,
  required bool Function(String siteId) isBuiltinEnabled,
  Set<ContentType>? types,
  Set<String>? siteIds,
  int? xp,
  bool shortDramaOnly = false,
  bool includeReadingCore = true,
}) {
  bool passesType(ContentType type) => types == null || types.contains(type);
  bool passesScope(String id) => siteIds == null || siteIds.contains(id);
  bool passesGate(String id, {required bool readingCore}) =>
      xp == null || globalSearchSiteVisible(id, xp, readingCore: readingCore);
  bool passesShortDrama(String id, String name) =>
      !shortDramaOnly || isShortDramaSite(adultSiteIdForUnifiedId(id), name);

  // 裸站行集合：与 visibleDramaSites 同款，取全部已启用裸行（过滤前），
  // 登记条目归一化后撞上它就不再重复列；裸行被关掉时条目不跟着藏。
  final bareKeys = <String>{
    for (final site in dramaSiteRows)
      if (isBuiltinEnabled(site.id)) adultSiteIdForUnifiedId(site.id),
  };
  final targets = <GlobalSearchTarget>[];
  for (final site in dramaSiteRows) {
    if (site.id == 'original') continue;
    if (!isBuiltinEnabled(site.id)) continue;
    if (!passesType(ContentType.video) ||
        !passesScope(site.id) ||
        !passesGate(site.id, readingCore: false) ||
        !passesShortDrama(site.id, site.name)) {
      continue;
    }
    targets.add(
      GlobalSearchTarget(
        id: site.id,
        name: site.name,
        contentType: ContentType.video,
      ),
    );
  }
  for (final entry in customEntries) {
    if (!entry.enabled) continue;
    if (entry.kind != SourceKind.customMaccms &&
        entry.kind != SourceKind.pyImport &&
        entry.kind != SourceKind.jarImport &&
        entry.kind != SourceKind.jsImport &&
        entry.kind != SourceKind.xbpqImport &&
        entry.kind != SourceKind.legadoImport) {
      continue;
    }
    if (bareKeys.contains(adultSiteIdForUnifiedId(entry.id))) continue;
    final type = entry.contentType;
    if (!passesType(type) ||
        !passesScope(entry.id) ||
        !passesGate(entry.id, readingCore: false) ||
        !passesShortDrama(entry.id, entry.name)) {
      continue;
    }
    targets.add(
      GlobalSearchTarget(id: entry.id, name: entry.name, contentType: type),
    );
  }
  if (includeReadingCore) {
    for (final id in coreReadingSiteIds) {
      final kind = coreReadingKinds[id] ?? 'novel';
      final type = ContentTypeLabel.fromKey(kind);
      final name = coreReadingSiteNames[id] ?? id;
      if (!passesType(type) ||
          !passesScope(id) ||
          !passesGate(id, readingCore: true) ||
          !passesShortDrama(id, name)) {
        continue;
      }
      targets.add(
        GlobalSearchTarget(
          id: id,
          name: name,
          contentType: type,
          readingCore: true,
        ),
      );
    }
  }
  return targets;
}

/// 全局搜索的客户端解析：默认走登记表 / 阅读工厂；测试注入假客户端用。
typedef GlobalSearchClientResolver = Future<DramaSiteContentClient?> Function(
  GlobalSearchTarget target,
);

Future<DramaSiteContentClient?> _defaultGlobalSearchClient(
  GlobalSearchTarget target,
) {
  if (target.readingCore) {
    return Future.value(readingSiteContentClient(target.id));
  }
  return SourceRegistry.instance.clientFor(target.id);
}

/// 对一批目标站并行搜索（执行层，可单测）：单站超时 / 报错 / 无客户端
/// 只回空组，不拖垮整次搜索；只有出结果的站才进返回列表。
Future<List<DramaSiteSearchResult>> searchGlobalTargets(
  String query,
  List<GlobalSearchTarget> targets, {
  GlobalSearchClientResolver? clientResolver,
  Duration? perSiteTimeout,
}) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty || targets.isEmpty) return const [];
  final resolve = clientResolver ?? _defaultGlobalSearchClient;
  final timeout =
      perSiteTimeout ??
      ApiClient.dramaSearchTimeout + const Duration(seconds: 5);
  final results = await Future.wait(
    targets.map((target) async {
      try {
        final client = await resolve(target);
        if (client == null) return null;
        final items = await client.search(trimmed).timeout(timeout);
        if (items.isEmpty) return null;
        return DramaSiteSearchResult(
          siteId: target.id,
          siteName: target.name,
          items: items,
          contentType: target.contentType,
          readingCore: target.readingCore,
        );
      } catch (_) {
        return null;
      }
    }),
  );
  return [
    for (final result in results)
      if (result != null) result,
  ];
}

/// 全局搜索：查全部内置站 + 用户导入站 + 核心阅读站（登记表为准）。
///
/// [types] / [shortDramaOnly] 按页签过滤（综合不过滤；小说 / 漫画 /
/// 听书按类型；短剧 / 漫剧按视频 + 短剧）；[siteIds] 有值时只搜这些站
/// （标签页限定范围）；[xp] 有值时按该修为过境界门禁，为 null 时读当前
/// 修为快照。单站失败不拖垮整次搜索（见 [searchGlobalTargets]）。
/// 本地库与 [searchAllDramaSites] 同款并入（限定站时不并）。
Future<List<DramaSiteSearchResult>> searchAllSites(
  String query, {
  Set<ContentType>? types,
  bool shortDramaOnly = false,
  Set<String>? siteIds,
  int? xp,
  M3uExportDbSink? dbSink,
  GlobalSearchClientResolver? clientResolver,
  Duration? perSiteTimeout,
}) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return const [];
  await SourceRegistry.instance.load();
  final effectiveXp = xp ?? CultivationService.instance.snapshot.totalXp;
  final targets = globalSearchTargets(
    dramaSiteRows: dramaSites,
    customEntries: SourceRegistry.instance.custom,
    isBuiltinEnabled: SourceRegistry.instance.isBuiltinEnabled,
    types: types,
    siteIds: siteIds,
    xp: effectiveXp,
    shortDramaOnly: shortDramaOnly,
  );
  final merged = await searchGlobalTargets(
    trimmed,
    targets,
    clientResolver: clientResolver,
    perSiteTimeout: perSiteTimeout,
  );
  if (siteIds != null) return merged;
  try {
    // 本地库是用户自己的收藏，与站源搜索同款：不卡门禁，全量并入。
    merged.addAll(
      await searchLocalDbSites(
        trimmed,
        dbSink: dbSink ?? HiveM3uExportDb.instance,
        gateOpen: true,
      ),
    );
  } catch (_) {}
  return merged;
}
