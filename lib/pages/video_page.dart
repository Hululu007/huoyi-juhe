import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../actress/actress_adapter_repository.dart';
import '../actress/actress_adapter_store.dart';
import '../actress/actress_list_page.dart';
import '../services/api_client.dart';
import '../services/cultivation.dart';
import '../services/drama_sites.dart';
import '../services/drama_site_content.dart';
import '../services/local_file_import.dart';
import '../services/site_thumb_cache.dart';
import '../services/source_registry.dart';
import '../services/video_zone_display_names.dart';
import '../widgets/home/drama_site_grid.dart';
import '../widgets/home/home_design.dart';
import '../widgets/series_detail/moyi_detail_theme.dart';
import '../widgets/site_grid_dialog.dart';
import 'category_page.dart';
import 'local_library_page.dart';
import 'mine_page.dart';
import 'source_management_page.dart';
import 'web_scrape_page.dart';

/// 影视页选站规则：只列用户自己导入的站，预置的内置站不列。
/// 新用户打开影视区是空白的，按空态提示去站源管理添加或导入。
List<SourceEntry> videoPagePlayableSites(List<SourceEntry> entries) {
  return [
    for (final entry in entries)
      if ((entry.kind == SourceKind.customMaccms ||
              entry.kind == SourceKind.pyImport ||
              entry.kind == SourceKind.jarImport ||
              entry.kind == SourceKind.jsImport ||
              entry.kind == SourceKind.xbpqImport ||
              entry.kind == SourceKind.idjPlugin ||
              (entry.kind == SourceKind.legadoImport &&
                  entry.extra['hasExplore'] == true)) &&
          entry.extra['builtin'] != true &&
          entry.enabled &&
          (entry.contentType == ContentType.video ||
              entry.contentType == ContentType.mixed))
        entry,
  ];
}

/// 午夜页视频站列表：jar 内置批的视频站（已启用），
/// 音频听书站不在此列。
List<SourceEntry> midnightJarVideoSites(List<SourceEntry> entries) {
  return [
    for (final entry in entries)
      if (isMidnightJarBuiltin(entry) && entry.enabled) entry,
  ];
}

/// 该站是不是影视站（电影/剧集）：短剧站返回 false。
/// 判据走短剧区共用的 [isShortDramaSite]，行 id 先归一化成裸 id
/// 再判：种子行 `seed_yaguo`→`yaguo`、jar 行
/// `jar:zakatv:ZakaHddj`→`hddj`，否则 id 判据永远对不上、只剩
/// 名字兜底（芽果/AI淫航/幻影AI/AI不用钱这种名字不带「短剧」的短剧站
/// 就漏进影视区）；红果/HGTV/猫果等果站名字里也没有「短剧」，
/// 同样靠裸 id 判据拦；黄果漫剧靠名字里的「漫剧」拦。
bool isFilmVideoSite(String id, String name) =>
    !isShortDramaSite(adultSiteIdForUnifiedId(id), name);

/// 影视区内置站：核心影视站（只留影视，短剧已摘掉；判据走
/// [isFilmVideoSite]，与短剧区共用同一份短剧判据）。顺序跟登记表
/// 一致，只列影视站，不动主列表“只列用户导入站”的规则。
/// 默认选中仍是保存过的选择，没有保存过才取第一个。
List<DramaSite> videoZoneSites() {
  const ids = {...coreVideoSiteIds};
  return [
    for (final site in dramaSites)
      if (ids.contains(site.id) && isFilmVideoSite(site.id, site.name)) site,
  ];
}

/// 内置导入视频站：随包发布的 py / 阅读 JSON 站（builtin=true，
/// 非 jar），与午夜 jar 站同属午夜区；用户自己导入的站不在此列
/// （用户站走 [videoPagePlayableSites]，见 [unifiedVideoZoneSites]
/// 第四路）。
List<SourceEntry> builtinImportedVideoSites(List<SourceEntry> entries) {
  return [
    for (final entry in entries)
      if (entry.extra['builtin'] == true &&
          (entry.kind == SourceKind.pyImport ||
              entry.kind == SourceKind.legadoImport) &&
          entry.enabled &&
          (entry.contentType == ContentType.video ||
              entry.contentType == ContentType.mixed))
        entry,
  ];
}

/// 影视区统一站表：午夜区就是影视区，不再分两块。内置影视站
/// 在前、午夜 jar 视频站次之、内置导入视频站在后、用户导入的
/// 影视站最后（第四路，[videoPagePlayableSites] 再过
/// [isFilmVideoSite] 摘短剧），按 id 去重，供统一切换器与网格
/// 共用。四路都只留影视站，短剧站一律摘掉（判据走
/// [isFilmVideoSite]，与短剧区共用同一份短剧判据）。用户站 id
/// 若与内置站撞 id，内置那条在前、去重后只留内置那条。
/// 分档过滤不在这里做，[visibleVideoZoneSites] 会对整张统一表
/// 再做一次。显示名走修仙版两段式短名（[videoZoneDisplayName]，如
/// 「🔞黄枫谷·黄瓜」「🔞虚天殿·Verse」），只改显示、不动 id 与分档。
List<({String id, String name})> unifiedVideoZoneSites(
  List<SourceEntry> customEntries,
) {
  final seen = <String>{};
  final out = <({String id, String name})>[];
  for (final site in videoZoneSites()) {
    if (seen.add(site.id)) {
      out.add((id: site.id, name: videoZoneDisplayName(site.id, site.name)));
    }
  }
  for (final entry in midnightJarVideoSites(customEntries)) {
    if (!isFilmVideoSite(entry.id, entry.name)) continue;
    if (seen.add(entry.id)) {
      out.add((id: entry.id, name: videoZoneDisplayName(entry.id, entry.name)));
    }
  }
  for (final entry in builtinImportedVideoSites(customEntries)) {
    if (!isFilmVideoSite(entry.id, entry.name)) continue;
    if (seen.add(entry.id)) {
      out.add((id: entry.id, name: videoZoneDisplayName(entry.id, entry.name)));
    }
  }
  for (final entry in videoPagePlayableSites(customEntries)) {
    if (!isFilmVideoSite(entry.id, entry.name)) continue;
    if (seen.add(entry.id)) {
      out.add((id: entry.id, name: videoZoneDisplayName(entry.id, entry.name)));
    }
  }
  return out;
}

/// 影视区可见站表：只留已解锁的站。201 个成人站按内嵌分档登记顺序
/// （adultVideoSiteOrder，删核心前的核心登记顺序）均分 4 档（元婴 3000
/// 开第 1 档、化神 8000 第 2 档、炼虚 15000 第 3 档、合体 30000 全开）；
/// 未解锁的站完全隐藏，不在列表里出现，不灰掉、不占位、不露站名，
/// 修为到了自动出现。非成人站原样保留。种子行 `seed_<id>` 与 jar 行
/// `jar:<jarId>:<key>` 查档位时先归一化成核心站 id（见
/// adultSiteIdForUnifiedId），从未进过核心的站不分档、原样保留。
List<({String id, String name})> visibleVideoZoneSites(
  List<SourceEntry> customEntries,
  int xp,
) {
  final all = unifiedVideoZoneSites(customEntries);
  final adultOrder = adultVideoSiteOrder;
  final visibleIds = visibleSiteIds(
    [for (final site in all) site.id],
    adultOrder,
    xp,
  ).toSet();
  return [
    for (final site in all)
      if (visibleIds.contains(site.id)) site,
  ];
}

/// 影视/午夜区切换弹窗用的带区·分组条目（纯函数，可单测）：
/// 区：统一表前三路（核心影视站、午夜 jar 站、内置导入站）的 id
/// 进内置区，第四路用户导入站进导入区（按来源集判，不查登记行
/// 的 `builtin` 标记，撞 id 时内置优先）；插件站（kind=idjPlugin）
/// 进插件区（用户 2026-11-26 令新增第三区）。
/// 组：午夜 jar 站与内置导入视频站进「午夜」组，核心影视站与
/// 用户导入的影视站进「视频」组（用户站不在 midnightIds 里，
/// 自动落视频组；区则由 customById 查到且 `builtin != true`
/// 判定为导入区）。
/// 已在站源管理里关掉的内置站（`isBuiltinEnabled==false`）不列出；
/// 隐藏只认归一化后的核心站 id（`adultSiteIdForUnifiedId`）：种子行
/// `seed_x` / jar 行 `jar:...:Key` 与裸站行 `x` 是同一站，站源管理里
/// 的开关管的也是裸 id，归一化后两边才对得上。
/// [isBuiltinEnabled] 默认读 `SourceRegistry.instance.isBuiltinEnabled`，
/// 单测可注入。
List<SiteGridEntry> videoZoneSiteEntries(
  List<SourceEntry> customEntries,
  int xp, {
  bool Function(String siteId)? isBuiltinEnabled,
}) {
  final isEnabled =
      isBuiltinEnabled ?? SourceRegistry.instance.isBuiltinEnabled;
  final midnightIds = <String>{
    for (final entry in midnightJarVideoSites(customEntries)) entry.id,
    for (final entry in builtinImportedVideoSites(customEntries)) entry.id,
  };
  // 内置区 id 集 = 统一表前三路（核心影视站 + 午夜 jar 站 + 内置
  // 导入站）的 id；其余进统一表的站（第四路用户导入站）进导入区。
  // 按来源集判区、不用 customById 查 `builtin`：用户站 id 若与
  // 内置站撞 id，统一表去重已只留内置那条，区判定也要跟着保留
  // 内置（customById 里后写入的用户行会盖掉内置行，不能靠它判）。
  final builtinIds = <String>{
    for (final site in videoZoneSites()) site.id,
    ...midnightIds,
  };
  final pluginIds = <String>{
    for (final entry in customEntries)
      if (entry.kind == SourceKind.idjPlugin) entry.id,
  };
  final entries = <SiteGridEntry>[];
  for (final site in visibleVideoZoneSites(customEntries, xp)) {
    final zone = pluginIds.contains(site.id)
        ? SiteGridZone.plugin
        : builtinIds.contains(site.id)
        ? SiteGridZone.builtin
        : SiteGridZone.import;
    if (zone == SiteGridZone.builtin &&
        !isEnabled(adultSiteIdForUnifiedId(site.id))) {
      continue;
    }
    entries.add((
      id: site.id,
      name: site.name,
      zone: zone,
      group: midnightIds.contains(site.id)
          ? SiteGridGroup.midnight
          : SiteGridGroup.video,
    ));
  }
  return entries;
}

/// 推荐页全局「影视」区的可见站表（纯函数，可单测）：视频站与
/// 阅读站按登记表顺序拼在一起，视频在前、阅读在后；阅读内部按
/// 小说、漫画、听书的登记顺序。
///
/// 视频站用 [visibleVideoZoneSites]（内嵌影视站，已摘短剧，按修为
/// 分 4 档）；阅读成人站按在阅读登记表里的下标分同样的 4 档
/// （[adultTierForIndex] / [adultTierUnlocked]），非成人阅读站
/// 始终显示。未解锁的站完全不出现，不灰掉、不占位、不露站名。
/// 视频站表默认读 SourceRegistry.instance.custom（种子 + jar 内嵌站
/// 现取），单测可传 customEntries 注入；加站减站自动跟着变。
List<({String id, String name, String kind})> visibleFilmZoneSites(
  int xp, [
  List<SourceEntry>? customEntries,
]) {
  final entries = customEntries ?? SourceRegistry.instance.custom;
  final out = <({String id, String name, String kind})>[
    for (final site in visibleVideoZoneSites(entries, xp))
      (id: site.id, name: site.name, kind: 'video'),
  ];
  final readingOrder = coreReadingSiteIds.toList();
  for (final id in readingOrder) {
    final kind = coreReadingKinds[id] ?? 'novel';
    if (coreAdultReadingSiteIds.contains(id)) {
      final tier = adultTierForIndex(
        readingOrder.indexOf(id),
        readingOrder.length,
      );
      if (!adultTierUnlocked(tier, xp)) continue;
    }
    out.add((id: id, name: coreReadingSiteNames[id] ?? id, kind: kind));
  }
  return out;
}

/// 影视区用户自导站列表：只留已解锁的影视站。
///
/// 在 [videoPagePlayableSites]（只列用户自己导入的站）之上再过两遍：
/// ①短剧过滤（[isFilmVideoSite]，与短剧区共用同一份短剧判据）——
/// 用户自导的短剧蜘蛛（名字带短剧/漫剧、或 id 在短剧集里）归短剧区
/// 药丸（visibleShortDramaSites 已收用户导入站，不会丢站），不进
/// 影视区这张用户网格；②现有的可见性逻辑（[visibleSiteIds]）：
/// 行 id 能归一化到分档表里的成人站按档位解锁（元婴 3000 开第 1 档、
/// 化神 8000 第 2 档、炼虚 15000 第 3 档、合体 30000 全开），未解锁
/// 的不进列表；不在表里的站（用户自己的采集/py 站）原样保留。
/// 修为到了自动出现，列表随修为变化（VideoPage 监听修为快照）。
List<SourceEntry> visibleVideoPagePlayableSites(
  List<SourceEntry> entries,
  int xp,
) {
  final playable = videoPagePlayableSites(entries);
  final visibleIds = visibleSiteIds(
    [for (final entry in playable) entry.id],
    adultVideoSiteOrder,
    xp,
  ).toSet();
  return [
    for (final entry in playable)
      if (visibleIds.contains(entry.id) &&
          isFilmVideoSite(entry.id, entry.name))
        entry,
  ];
}

class VideoPage extends StatefulWidget {
  /// 点它翻转切回游戏（右上角金色「游戏」大钮）。
  /// 不传时顶栏不显示切换钮（老调用点与测试用）。
  const VideoPage({super.key, this.onOpenGame});

  final VoidCallback? onOpenGame;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  static const _videoZoneSiteKey = 'video_zone_site_id';

  bool _loading = true;
  String? _selectedId;
  String? _videoZoneId;

  /// 午夜区当前站的真实首分类（核心站登记里只有「全部」兜底，
  /// `catalog('all')` 对多数核心站是空的——mjv011 的 all 地址
  /// 只回 1822 字节的跳转页、avyan 回「系统提示」页，取不到卡片；
  /// 先调 `categories()` 取真实首分类再取列表。取不到时回落 'all'。
  String? _videoZoneCategoryId;
  int _videoZoneCategoryGeneration = 0;

  @override
  void initState() {
    super.initState();
    // 修为变化时重建：解锁新档位后站自动出现（未解锁的站完全不显示）。
    CultivationService.instance.snapshotNotifier.addListener(
      _onCultivationChanged,
    );
    _load();
  }

  void _onCultivationChanged() {
    if (!mounted) return;
    // 修为变化（解锁新档位）时可见表变了：当前选中的站若已不在可见
    // 表里（或未选站但已有可见站），回到第一个可见站；修为只涨不跌，
    // 已解锁的站不会再锁住，选中站一般不受影响。
    final sites = _playableSites();
    if (_selectedId == null || !sites.any((site) => site.id == _selectedId)) {
      _selectedId = sites.isEmpty ? null : sites.first.id;
    }
    setState(() {});
  }

  @override
  void dispose() {
    CultivationService.instance.snapshotNotifier.removeListener(
      _onCultivationChanged,
    );
    super.dispose();
  }

  Future<void> _load() async {
    await SourceRegistry.instance.load();
    String? savedVideoZoneId;
    try {
      final preferences = await SharedPreferences.getInstance();
      savedVideoZoneId = preferences.getString(_videoZoneSiteKey);
      // 老午夜选择迁移：午夜区就是影视区，未存过影视区选择时，
      // 沿用此前的午夜视频站选择（在统一表里才有效）。
      savedVideoZoneId ??= preferences.getString('midnight_video_site_id');
    } catch (_) {}
    if (!mounted) return;
    final sites = _playableSites();
    // 只从已解锁的站里选：修为不到的站完全不显示，保存过的选择若在
    // 未解锁档里也回落到第一个已解锁站。
    final xp = CultivationService.instance.snapshot.totalXp;
    final videoZone = visibleVideoZoneSites(SourceRegistry.instance.custom, xp);
    setState(() {
      _loading = false;
      _selectedId = sites.isEmpty ? null : sites.first.id;
      _videoZoneId = videoZone.any((site) => site.id == savedVideoZoneId)
          ? savedVideoZoneId
          : (videoZone.isEmpty ? null : videoZone.first.id);
    });
    final zoneId = _videoZoneId;
    if (zoneId != null) _resolveVideoZoneCategory(zoneId);
  }

  /// 给午夜区当前站取真实首分类：核心站登记里只有「全部」兜底，
  /// 直接 `catalog('all')` 多数站是空的。取不到就回落 'all'，
  /// 网格行为与原来一致。超时按 ApiClient 的分类预算 + 5 秒余量
  /// （不多不少盖帽 ApiClient 的 30 秒），切站后旧站的结果不落地
  /// （代次号守）。
  Future<void> _resolveVideoZoneCategory(String siteId) async {
    final generation = ++_videoZoneCategoryGeneration;
    String? resolved;
    try {
      final client =
          dramaSiteContentClient(siteId) ??
          await SourceRegistry.instance.clientFor(siteId);
      if (client != null) {
        final categories = await client.categories().timeout(
          ApiClient.dramaCategoriesTimeout + const Duration(seconds: 5),
        );
        final usable = categories
            .where((c) => c.id.isNotEmpty && c.id != 'all')
            .toList();
        resolved = usable.isNotEmpty
            ? usable.first.id
            : (categories.isNotEmpty ? categories.first.id : null);
      }
    } catch (_) {
      resolved = null;
    }
    if (!mounted || generation != _videoZoneCategoryGeneration) return;
    setState(() => _videoZoneCategoryId = resolved);
  }

  List<SourceEntry> _playableSites() {
    // 用户自导站也过一遍现有可见性逻辑：能归一化到分档表里的成人站
    // 按档位解锁，未解锁的不进列表；不在表里的站原样保留。
    return visibleVideoPagePlayableSites(
      SourceRegistry.instance.custom,
      CultivationService.instance.snapshot.totalXp,
    );
  }

  /// 切换弹窗默认打开的区：平时是当前站所在的区（没有当前站时内置区）；
  /// 刚批量导进视频站时一次性打开导入区，让用户直接看到新站
  /// （站源管理批量导入成功后写一次标记，见
  /// [consumeSiteGridOpenImportZoneOnce]，读一次即清掉，不影响
  /// 以后的默认区）。
  Future<SiteGridZone> _resolveInitialZone(
    List<SiteGridEntry> entries,
  ) async {
    final openImportOnce = await consumeSiteGridOpenImportZoneOnce();
    if (openImportOnce &&
        entries.any((entry) => entry.zone == SiteGridZone.import)) {
      return SiteGridZone.import;
    }
    return entries
            .where((entry) => entry.id == _videoZoneId)
            .firstOrNull
            ?.zone ??
        SiteGridZone.builtin;
  }

  /// 午夜区站切换（午夜区就是影视区，统一表含核心影视站 + 午夜
  /// jar 视频站 + 内置导入视频站 + 用户导入的影视站）：点药丸弹居中弹窗，站点四列网格，点一项即切换
  /// 并持久化。分类走右上角分类按钮进分类页（卡片上方不再放分类
  /// 这一排，分类弹窗已废弃）。
  Future<void> _openVideoZoneSiteSwitcher() async {
    final xp = CultivationService.instance.snapshot.totalXp;
    final entries = videoZoneSiteEntries(SourceRegistry.instance.custom, xp);
    if (entries.isEmpty || !mounted) return;
    final initialZone = await _resolveInitialZone(entries);
    if (!mounted) return;
    final picked = await showSiteGridDialog(
      context: context,
      sites: entries,
      selectedId: _videoZoneId,
      initialZone: initialZone,
      enablePluginZone: true,
      onDeleteSite: deleteSiteGridEntry,
      // 站点透视（C1）：片库 / 影视 / 短剧选站弹窗启用站内封面。
      thumbCache: SiteThumbCache.instance,
      thumbFetcher: fetchSiteHomeCover,
    );
    if (!mounted) return;
    if (picked == null) {
      // 弹窗里删/藏了当前站：当前站不在可见表里就回落到首站，别留野 id。
      await _fallBackVideoZoneSiteIfHidden();
      return;
    }
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_videoZoneSiteKey, picked);
    } catch (_) {}
    if (mounted) {
      setState(() {
        _videoZoneId = picked;
        _videoZoneCategoryId = null;
      });
      _resolveVideoZoneCategory(picked);
    }
  }

  /// 弹窗里删/藏了当前午夜站：当前站不在可见表里就回落到首站（或空）。
  Future<void> _fallBackVideoZoneSiteIfHidden() async {
    final xp = CultivationService.instance.snapshot.totalXp;
    final entries = videoZoneSiteEntries(SourceRegistry.instance.custom, xp);
    final resolved = resolveCurrentSiteId(
      _videoZoneId,
      [for (final entry in entries) entry.id],
    );
    if (resolved == _videoZoneId) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      if (resolved == null) {
        await preferences.remove(_videoZoneSiteKey);
      } else {
        await preferences.setString(_videoZoneSiteKey, resolved);
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _videoZoneId = resolved;
      _videoZoneCategoryId = null;
    });
    if (resolved != null) _resolveVideoZoneCategory(resolved);
  }

  /// 右上角分类：打开分类页并直接落在影视 tab，内容随当前视频站
  /// 变化（切站后打开即显示新站的标签），点标签进视频搜索。
  Future<void> _openVideoCategoryPage() async {
    final siteId = _videoZoneId;
    if (siteId == null || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => CategoryPage(videoSiteId: siteId, openVideoTab: true),
      ),
    );
  }

  /// 女优库入口（魔蚁合入，2026-11-22）：进原生女优库列表页。
  /// 仓储走修仙版站注册表委托（XiuxianAppRepository），站表状态
  /// 走 LocalStore.instance。2026-11-26 曾同步合并演员库页作
  /// 入口，同日 15:05 用户改令翻回原生页：合并页
  /// （ActressLibraryWebEntryPage）留树休眠、不删，入口不再
  /// 指向它。
  Future<void> _openActressLibrary() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ActressListPage(
          repository: XiuxianAppRepository.shared,
          store: LocalStore.instance,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// 未到元婴期时的上锁页：不露源名与站名，只写还差多少修为。
  /// 与直播区锁页同款写法（见 LivePage._lockedBody）：大锁图标 +
  /// 「影视源需要元婴期」+ 还差多少修为（约几集短剧）+ 去我的页看进度。
  /// 门槛与换算直接读修为快照：[CultivationSnapshot.unlockedVideo]
  ///（元婴 3000 修为）、[CultivationSnapshot.xpToVideoZone]、
  /// [CultivationSnapshot.episodesToVideoZone]，不硬写数字。
  Widget _lockedBody(BuildContext context) {
    final snapshot = CultivationService.instance.snapshot;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 48, color: moyiMutedOnDark),
            const SizedBox(height: 16),
            const Text(
              '影视源需要元婴期',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '还差 ${snapshot.xpToVideoZone} 修为（约 ${snapshot.episodesToVideoZone} 集短剧）解锁，修为到了自动显示影视源。',
              textAlign: TextAlign.center,
              style: const TextStyle(color: moyiBodyOnDark),
            ),
            const SizedBox(height: 16),
            MoyiGradientButton(
              label: '去我的页看进度',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const MinePage()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 右上角金色「游戏」切换钮：点一下 3D 翻转切回游戏界面。
  /// 游戏在后台继续挂机；onOpenGame 没传时不显示。
  Widget _gameSwitchButton() {
    final onOpenGame = widget.onOpenGame;
    if (onOpenGame == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: FilledButton.icon(
        onPressed: onOpenGame,
        icon: const Icon(Icons.sports_esports, size: 18),
        label: const Text('游戏'),
        style: FilledButton.styleFrom(
          backgroundColor: moyiGold,
          foregroundColor: Colors.black,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 全页深紫蓝渐变底：网格卡片等内层组件靠深色主题取浅色字（与首页同款
    // 做法），墨水屏不强制、保持黑白。
    final darkPage = !HomePalette.of(context).eink;
    final pageTheme = Theme.of(
      context,
    ).copyWith(brightness: darkPage ? Brightness.dark : Brightness.light);
    if (_loading) {
      return Theme(
        data: pageTheme,
        child: const Scaffold(
          backgroundColor: Colors.transparent,
          body: MoyiPageBackground(
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      );
    }
    // 未到元婴期（3000 修为）时整页上锁：与直播区锁页同款，不露任何
    // 站名与内容；修为到了自动显示影视源（页面监听修为快照）。
    final snapshot = CultivationService.instance.snapshot;
    if (!snapshot.unlockedVideo) {
      return Theme(
        data: pageTheme,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('影视'),
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            scrolledUnderElevation: 0,
            foregroundColor: Colors.white,
            actions: [_gameSwitchButton()],
          ),
          body: MoyiPageBackground(child: _lockedBody(context)),
        ),
      );
    }
    final sites = _playableSites();
    final remoteJson = [
      for (final entry in SourceRegistry.instance.custom)
        if (entry.kind == SourceKind.remoteJson && entry.enabled) entry,
    ];
    // 影视区只列已解锁的站（未解锁的完全隐藏）；直播源不在影视区
    // 出现（秀果/欲火聚合/百年直播只在直播 tab，影视区不混直播）。
    final xp = CultivationService.instance.snapshot.totalXp;
    final unifiedSites = visibleVideoZoneSites(
      SourceRegistry.instance.custom,
      xp,
    );

    return Theme(
      data: pageTheme,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('影视'),
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          foregroundColor: Colors.white,
          actions: [
            _gameSwitchButton(),
            TextButton(
              onPressed: _videoZoneId == null ? null : _openVideoCategoryPage,
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: const Text('分类'),
            ),
            IconButton(
              icon: const Icon(Icons.travel_explore_rounded),
              tooltip: '网页爬取',
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const WebScrapePage()),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.video_library),
              tooltip: '本地库',
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LocalLibraryPage()),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.list),
              tooltip: '站源管理',
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const SourceManagementPage(),
                  ),
                );
                await _load();
              },
            ),
          ],
        ),
        body: MoyiPageBackground(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return CustomScrollView(
                slivers: [
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        '午夜区',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  // 女优库入口（魔蚁合入，2026-11-22）：一张通往演员库的卡片，
                  // 点进 ActressListPage（4 页签：首页/分类/女优/收藏）。
                  // 门禁：本分支已在元婴期（unlockedVideo）之后，修为不到
                  // 时整页是上锁页、这张卡根本不出现，不另立门禁；成人站
                  // 分档口径仍以 cultivation.dart 为准。
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: InkWell(
                        onTap: _openActressLibrary,
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: moyiDarkCardFill,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: moyiDarkCardBorder),
                          ),
                          child: const Row(
                            children: [
                              Icon(
                                Icons.people_outline,
                                size: 22,
                                color: Colors.white,
                              ),
                              SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '女优库',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                    SizedBox(height: 2),
                                    Text(
                                      '演员库 · 本地数据库 + 站源',
                                      style: TextStyle(
                                        color: moyiMutedOnDark,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                Icons.chevron_right,
                                size: 20,
                                color: moyiMutedOnDark,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_videoZoneId != null) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: InkWell(
                          onTap: _openVideoZoneSiteSwitcher,
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: moyiDarkCardFill,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: moyiDarkCardBorder),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  unifiedSites
                                          .where(
                                            (site) => site.id == _videoZoneId,
                                          )
                                          .firstOrNull
                                          ?.name ??
                                      '',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(
                                  Icons.arrow_drop_down,
                                  size: 20,
                                  color: moyiMutedOnDark,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    DramaSiteGrid(
                      key: ValueKey(
                        'video-zone-$_videoZoneId-${_videoZoneCategoryId ?? 'all'}',
                      ),
                      siteId: _videoZoneId!,
                      categoryId: _videoZoneCategoryId ?? 'all',
                      gridWidth: width,
                      showFilterBar: false,
                      columns: 3,
                    ),
                  ],
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          for (final site in sites)
                            ChoiceChip(
                              label: Text(site.name),
                              selected: site.id == _selectedId,
                              onSelected: (_) =>
                                  setState(() => _selectedId = site.id),
                              backgroundColor: moyiDarkCardFill,
                              selectedColor: moyiPurple,
                              labelStyle: const TextStyle(color: Colors.white),
                              side: const BorderSide(color: moyiDarkCardBorder),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (sites.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          '暂无你导入的影视站源。核心影视站见上方午夜区；'
                          '要加站去站源管理添加 MacCMS 站点，'
                          '或导入 Python / Jar / JS 蜘蛛（引擎仅支持 Android）。',
                          style: TextStyle(color: moyiMutedOnDark),
                        ),
                      ),
                    )
                  else if (_selectedId != null)
                    DramaSiteGrid(
                      key: ValueKey('video-site-$_selectedId'),
                      siteId: _selectedId!,
                      categoryId: 'all',
                      gridWidth: width,
                      columns: 3,
                    ),
                  if (remoteJson.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                        child: Text(
                          '远程配置（已展开为上方选站）：'
                          '${remoteJson.map((e) => e.name).join('、')}',
                          style: TextStyle(
                            fontSize: 13,
                            color: moyiMutedOnDark,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
