import 'drama_site_content.dart';
import 'drama_sites.dart';
import 'm3u_export_db.dart';
import 'midnight_gate.dart';
import 'site_identity.dart';
import 'source_registry.dart';


/// 浏览自动爬取：把浏览页刚取到的分类视频列表存进本地库。
/// 存的是目录元数据（标题、封面、分类），没有播放地址；
/// 播放地址在播放时现取并回写（见 LocalDbContentClient 的 liveResolver）。
/// 只插新条：已在库里的条目不动，不刷 updatedAt、不打乱本地库顺序。
/// 失败静默：浏览绝不因写库失败而报错或卡住。
/// 成人站与普通站同样存库，不再设门。
/// 本地库自己的列表（localdb:）不回写。
Future<void> saveBrowsedCatalogToDb({
  required String siteId,
  required String siteName,
  required DramaSiteCategory category,
  required List<DramaSiteItem> items,
  required M3uExportDbSink dbSink,
}) async {
  try {
    if (siteId.startsWith('localdb:')) return;
    if (items.isEmpty) return;
    await MidnightGate.ensureLoaded();
    if (!MidnightGate.activated.value &&
        MidnightGate.isAdultName(siteName)) {
      return;
    }
    await SourceRegistry.instance.load();
    final custom = SourceRegistry.instance.customById(siteId);
    final dbSiteId = canonicalSiteKey(
      siteId: siteId,
      address: custom?.address ?? '',
      addressIsSiteAddress: custom != null &&
          addressIsSiteAddressForKind(custom.kind.name),
    );
    final gateOpen = MidnightGate.activated.value;
    final existing = await dbSink.listVideos(
      gateOpen: gateOpen,
      siteId: dbSiteId,
      categoryId: category.id,
    );
    final known = {for (final row in existing) row.videoId};
    final seen = <String>{};
    final fresh = [
      for (final item in items)
        if (!known.contains(item.id) && seen.add(item.id)) item,
    ];
    if (fresh.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final categoryPath =
        category.path.isNotEmpty ? category.path : category.name;
    await dbSink.saveExport(
      siteId: dbSiteId,
      siteName: siteName,
      categories: [
        M3uExportCategoryInfo(
          siteId: dbSiteId,
          siteName: siteName,
          categoryId: category.id,
          categoryName: category.name,
          categoryPath: categoryPath,
          parentId: category.parentId,
          extra: category.extra,
          updatedAt: now,
        ),
      ],
      videos: [
        for (final item in fresh)
          M3uExportVideoRecord(
            siteId: dbSiteId,
            siteName: siteName,
            categoryId: category.id,
            categoryName: category.name,
            categoryPath: categoryPath,
            videoId: item.id,
            title: item.title,
            url: '',
            cover: item.cover,
            synopsis: '',
            updatedAt: now,
          ),
      ],
    );
  } catch (_) {
    // 浏览自动存库失败静默，不打断浏览。
  }
}
