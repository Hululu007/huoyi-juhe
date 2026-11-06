import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/cultivation.dart';
import '../services/drama_sites.dart';
import '../services/drama_site_content.dart';
import '../services/live_sources.dart';
import '../services/source_registry.dart';
import '../widgets/home/drama_site_grid.dart';
import '../widgets/site_grid_dialog.dart';
import 'category_page.dart';
import 'live_source_page.dart';
import 'local_library_page.dart';
import 'source_management_page.dart';

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

/// 影视区内置站：核心影视区首批修复好能播的站（芽果走核心，其余
/// 走原 Dart 客户端；昨天 6 站进核心后再追加）。顺序跟短剧区登记表
/// 一致，只列这 5 个，不动主列表“只列用户导入站”的规则。
List<DramaSite> videoZoneSites() {
  const ids = {
    'huangdou',
    'huangju',
    'yeguo',
    'yaguo',
    'niuguo',
    'tgdrama',
    ...coreVideoSiteIds,
  };
  return [for (final site in dramaSites) if (ids.contains(site.id)) site];
}

/// 内置导入视频站：随包发布的 py / 阅读 JSON 站（builtin=true，
/// 非 jar），与午夜 jar 站同属午夜区；用户自己导入的站不在此列
/// （用户站走下方单独的网格）。
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

/// 影视区统一站表：午夜区就是影视区，不再分两块。内置影视区 5 站
/// 在前、午夜 jar 视频站次之、内置导入视频站在后，按 id 去重，
/// 供统一切换器与网格共用。
List<({String id, String name})> unifiedVideoZoneSites(
  List<SourceEntry> customEntries,
) {
  final seen = <String>{};
  final out = <({String id, String name})>[];
  for (final site in videoZoneSites()) {
    if (seen.add(site.id)) out.add((id: site.id, name: site.name));
  }
  for (final entry in midnightJarVideoSites(customEntries)) {
    if (seen.add(entry.id)) out.add((id: entry.id, name: entry.name));
  }
  for (final entry in builtinImportedVideoSites(customEntries)) {
    if (seen.add(entry.id)) out.add((id: entry.id, name: entry.name));
  }
  return out;
}

/// 影视区可见站表：只留已解锁的站。146 个成人站按在核心登记表里的
/// 顺序均分 4 档（元婴 3000 开第 1 档、化神 8000 第 2 档、炼虚 15000
/// 第 3 档、合体 30000 全开）；未解锁的站完全隐藏，不在列表里出现，
/// 不灰掉、不占位、不露站名，修为到了自动出现。非成人站原样保留。
List<({String id, String name})> visibleVideoZoneSites(
  List<SourceEntry> customEntries,
  int xp,
) {
  final all = unifiedVideoZoneSites(customEntries);
  final adultOrder = coreVideoSiteIds.toList();
  final visibleIds = visibleSiteIds(
    [for (final site in all) site.id],
    adultOrder,
    xp,
  ).toSet();
  return [for (final site in all) if (visibleIds.contains(site.id)) site];
}

/// 推荐页全局「影视」区的可见站表（纯函数，可单测）：视频站与
/// 阅读站按登记表顺序拼在一起，视频在前、阅读在后；阅读内部按
/// 小说、漫画、听书的登记顺序。
///
/// 视频站用 [visibleVideoZoneSites]（5 个果站 + 核心视频站，按修为
/// 分 4 档）；阅读成人站按在阅读登记表里的下标分同样的 4 档
/// （[adultTierForIndex] / [adultTierUnlocked]），非成人阅读站
/// 始终显示。未解锁的站完全不出现，不灰掉、不占位、不露站名。
/// 站表读核心登记表现取，加站减站自动跟着变。
List<({String id, String name, String kind})> visibleFilmZoneSites(int xp) {
  final out = <({String id, String name, String kind})>[
    for (final site in visibleVideoZoneSites(const [], xp))
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

class VideoPage extends StatefulWidget {
  const VideoPage({super.key});

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  static const _videoZoneSiteKey = 'video_zone_site_id';

  bool _loading = true;
  String? _selectedId;
  String? _videoZoneId;

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
    if (mounted) setState(() {});
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
    final videoZone = visibleVideoZoneSites(
      SourceRegistry.instance.custom,
      xp,
    );
    setState(() {
      _loading = false;
      _selectedId = sites.isEmpty ? null : sites.first.id;
      _videoZoneId = videoZone.any((site) => site.id == savedVideoZoneId)
          ? savedVideoZoneId
          : (videoZone.isEmpty ? null : videoZone.first.id);
    });
  }

  List<SourceEntry> _playableSites() {
    return videoPagePlayableSites(SourceRegistry.instance.custom);
  }

  /// 午夜区站切换（午夜区就是影视区，统一表含内置 5 站 + 午夜
  /// jar 视频站）：点药丸弹居中弹窗，站点四列网格，点一项即切换
  /// 并持久化。分类走右上角分类按钮进分类页（卡片上方不再放分类
  /// 这一排，分类弹窗已废弃）。
  Future<void> _openVideoZoneSiteSwitcher() async {
    final xp = CultivationService.instance.snapshot.totalXp;
    final sites = visibleVideoZoneSites(SourceRegistry.instance.custom, xp);
    if (sites.isEmpty || !mounted) return;
    final picked = await showSiteGridDialog(
      context: context,
      sites: sites,
      selectedId: _videoZoneId,
    );
    if (picked == null || !mounted) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_videoZoneSiteKey, picked);
    } catch (_) {}
    if (mounted) {
      setState(() => _videoZoneId = picked);
    }
  }

  /// 右上角分类：打开分类页并直接落在影视 tab，内容随当前视频站
  /// 变化（切站后打开即显示新站的标签），点标签进视频搜索。
  Future<void> _openVideoCategoryPage() async {
    final siteId = _videoZoneId;
    if (siteId == null || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => CategoryPage(
          videoSiteId: siteId,
          openVideoTab: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final sites = _playableSites();
    final remoteJson = [
      for (final entry in SourceRegistry.instance.custom)
        if (entry.kind == SourceKind.remoteJson && entry.enabled) entry,
    ];
    final midnightSources = LiveSources.midnightSources;
    // 影视区只列已解锁的站（未解锁的完全隐藏）；成人直播源到元婴期
    // 才出现，修为不到时连这一节都不显示。
    final xp = CultivationService.instance.snapshot.totalXp;
    final unlockedVideo =
        CultivationService.instance.snapshot.unlockedVideo;
    final unifiedSites = visibleVideoZoneSites(
      SourceRegistry.instance.custom,
      xp,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('影视'),
        actions: [
          TextButton(
            onPressed: _videoZoneId == null
                ? null
                : _openVideoCategoryPage,
            style: TextButton.styleFrom(
              foregroundColor: IconTheme.of(context).color,
            ),
            child: const Text('分类'),
          ),
          IconButton(
            icon: const Icon(Icons.video_library),
            tooltip: '本地库',
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const LocalLibraryPage(),
                ),
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
      body: LayoutBuilder(
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
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Theme.of(context).dividerColor,
                          ),
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
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.arrow_drop_down, size: 20),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                DramaSiteGrid(
                  key: ValueKey('video-zone-$_videoZoneId'),
                  siteId: _videoZoneId!,
                  categoryId: 'all',
                  gridWidth: width,
                  showFilterBar: false,
                  columns: 4,
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
                      '暂无可播放的影视站源。去站源管理添加 MacCMS 站点，'
                      '或导入 Python / Jar / JS 蜘蛛（引擎仅支持 Android）。',
                    ),
                  ),
                )
              else if (_selectedId != null)
                DramaSiteGrid(
                  key: ValueKey('video-site-$_selectedId'),
                  siteId: _selectedId!,
                  categoryId: 'all',
                  gridWidth: width,
                  columns: 4,
                ),
              if (unlockedVideo && midnightSources.isNotEmpty) ...[
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      '成人直播源',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                SliverList.builder(
                  itemCount: midnightSources.length,
                  itemBuilder: (context, index) {
                    final source = midnightSources[index];
                    return ListTile(
                      title: Text(source.name),
                      subtitle: Text(
                        '${source.description}。点开看分类与频道。',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              LiveSourceBrowsePage(source: source),
                        ),
                      ),
                    );
                  },
                ),
              ],
              if (remoteJson.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                    child: Text(
                      '远程配置（已展开为上方选站）：'
                      '${remoteJson.map((e) => e.name).join('、')}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
