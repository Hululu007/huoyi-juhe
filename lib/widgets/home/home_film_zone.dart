import 'package:flutter/material.dart';

import '../../pages/video_page.dart';
import '../../services/cultivation.dart';
import '../../services/drama_site_content.dart';
import 'drama_site_grid.dart';
import 'home_design.dart';
import 'home_shelf.dart';

/// 影视区站条目的类型后缀（药丸上的小字）：视频不带后缀，
/// 小说 / 漫画 / 听书带。
String filmZoneKindLabel(String kind) => switch (kind) {
  'novel' => '小说',
  'comic' => '漫画',
  'audio' => '听书',
  _ => '视频',
};

/// 推荐页顶部的全局「影视」区：核心里所有站点的视频、小说、漫画、
/// 听书都在这里，不用逐区切换。站表读核心登记表动态取（见
/// [visibleFilmZoneSites]），加站减站自动跟着变。
///
/// 版式跟影视页午夜区同款：标题「影视」+ 站点药丸横滑条 + 当前站
/// 的内容网格（4 列，分类走各站自己的首分类）。点药丸切站，
/// 切站即换网格；修为到了新档位，解锁的站自动出现在药丸条里，
/// 未解锁的站完全不显示。
///
/// 网格只在点过药丸后才挂（不点不取数）：推荐页打开时不额外发
/// 请求，取数只在用户点站时触发；没点之前药丸条下面只留一行提示。
///
/// 阅读站与视频站同 id 时（如红果听书 hongguo 与视频红果同 id），
/// 网格按站类型显式取阅读客户端，不跟视频客户端撞 id。
class HomeFilmZone extends StatefulWidget {
  const HomeFilmZone({
    super.key,
    required this.gridWidth,
    this.sites,
    this.clientForSite,
  });

  final double gridWidth;

  /// 注入可见站表（页测用）：为空时按当前修为从核心登记表现取。
  final List<({String id, String name, String kind})>? sites;

  /// 注入取数客户端（页测用）：为空时网格按站 id 自行取客户端，
  /// 阅读站走阅读客户端。
  final DramaSiteContentClient? Function(String siteId)? clientForSite;

  @override
  State<HomeFilmZone> createState() => _HomeFilmZoneState();
}

class _HomeFilmZoneState extends State<HomeFilmZone> {
  String? _selectedId;

  List<({String id, String name, String kind})> get _sites =>
      widget.sites ??
      visibleFilmZoneSites(
        CultivationService.instance.snapshot.totalXp,
      );

  @override
  void initState() {
    super.initState();
    // 注入站表时由调用方控制列表，不跟修为走；现取时修为变化要重建，
    // 解锁的新站自动出现。
    if (widget.sites == null) {
      CultivationService.instance.snapshotNotifier.addListener(
        _onCultivationChanged,
      );
    }
  }

  void _onCultivationChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (widget.sites == null) {
      CultivationService.instance.snapshotNotifier.removeListener(
        _onCultivationChanged,
      );
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(HomeFilmZone oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sites != oldWidget.sites && widget.sites != null) {
      // 注入站表换了：已选站不在新表里时回落到首站。
      if (_selectedId != null &&
          !widget.sites!.any((site) => site.id == _selectedId)) {
        _selectedId = null;
      }
    }
  }

  String? get _selectedSiteId {
    final sites = _sites;
    if (sites.isEmpty) return null;
    final selected = _selectedId;
    if (selected != null && sites.any((site) => site.id == selected)) {
      return selected;
    }
    // 没点过药丸时不默认选站、不挂网格（不取数）；点过之后才显示
    // 该站的网格。
    return null;
  }

  DramaSiteContentClient? _clientFor(String siteId, String kind) {
    final injected = widget.clientForSite;
    if (injected != null) return injected(siteId);
    if (kind != 'video') return readingSiteContentClient(siteId);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final sites = _sites;
    final palette = HomePalette.of(context);
    final selectedId = _selectedSiteId;
    final selectedKind = selectedId == null
        ? 'video'
        : sites.firstWhere((site) => site.id == selectedId).kind;
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: HomeSectionHeader(
            key: const Key('film-zone-header'),
            title: '影视',
          ),
        ),
        if (sites.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('暂无可显示的站点'),
            ),
          )
        else ...[
          SliverToBoxAdapter(
            child: SizedBox(
              height: 40,
              child: ListView(
                key: const Key('film-zone-site-strip'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final site in sites)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        key: Key('film-zone-site-${site.id}'),
                        onTap: () =>
                            setState(() => _selectedId = site.id),
                        child: Container(
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                          ),
                          decoration: BoxDecoration(
                            color: site.id == selectedId
                                ? palette.ink
                                : palette.searchBar,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            site.kind == 'video'
                                ? site.name
                                : '${site.name}·${filmZoneKindLabel(site.kind)}',
                            style: TextStyle(
                              fontSize: 13,
                              color: site.id == selectedId
                                  ? palette.canvas
                                  : palette.ink,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (selectedId != null)
            DramaSiteGrid(
              key: ValueKey('film-zone-grid-$selectedId'),
              siteId: selectedId,
              categoryId: 'all',
              gridWidth: widget.gridWidth,
              showFilterBar: false,
              columns: 4,
              client: _clientFor(selectedId, selectedKind),
            )
          else
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  '点一个站点看内容',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ),
        ],
      ],
    );
  }
}
