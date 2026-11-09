import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import '../../pages/video_page.dart';
import '../../services/api_client.dart';
import '../../services/cultivation.dart';
import '../../services/drama_site_content.dart';
import '../../services/drama_site_play.dart';
import '../../services/source_registry.dart';
import 'home_design.dart';
import 'home_feed_states.dart';
import 'home_media_card.dart';
import 'home_shelf.dart';

/// 推荐页顶部的「影视」区：短剧区后面平铺推荐影视。
///
/// 不再是一排站点圆片、站点也不当一级分类：直接从已解锁的影视站
/// 里取内容，拼成一张视频卡片网格（三列）平铺展示，卡片点开走
/// 原站详情页（与影视页网格同路）。
///
/// 取数方式：每次取窗口内 3 个站的「全部」分类第 1 页（并行，单站
/// 30 秒超时），每站最多留 6 张，拼成一屏推荐；某站取不到就跳过
/// 该站（页脚记一笔，不卡住整区）。点「换一批」换下 3 个站；
/// 修为到了新档位，解锁的站自动进池子，未解锁的站完全不显示。
///
/// 只放影视（电影/剧集）：短剧站已从影视区站表摘掉（见
/// [visibleVideoZoneSites]），阅读站也不在这里（小说/漫画/听书
/// 走各自的分站区）；短剧区本身原样不动。
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

  /// 注入取数客户端（页测用）：为空时按站 id 自行取客户端。
  final DramaSiteContentClient? Function(String siteId)? clientForSite;

  @override
  State<HomeFilmZone> createState() => _HomeFilmZoneState();
}

/// 一窗取的站数：3 站拼一屏推荐，又不至于一次拉爆。
const int _filmWindowSize = 3;

/// widget 层 `.timeout()` 相对 ApiClient 预算的余量：ApiClient 的超时
/// 是主预算（分类 30 秒、目录 45 秒），widget 的超时只当兜底——防
/// 非核心客户端没有自己的超时一直挂起；比 ApiClient 多 5 秒，
/// 不盖帽 ApiClient 的预算，超时的错以 ApiClient 的为准。
const Duration _clientTimeoutMargin = Duration(seconds: 5);

/// 每站最多留的卡片数：3 站 × 6 张 = 一屏 18 张。
const int _filmItemsPerSite = 6;

/// 一站取到的推荐卡片。
class _FilmSiteItems {
  const _FilmSiteItems({required this.siteId, required this.items});

  final String siteId;
  final List<DramaSiteItem> items;
}

class _HomeFilmZoneState extends State<HomeFilmZone> {
  int _windowStart = 0;
  List<_FilmSiteItems> _sections = [];
  int _failed = 0;
  bool _loading = false;
  bool _loaded = false;

  /// 取数代次：修为变化/换站表时新一轮取数自增，旧一轮回来时
  /// 代次对不上就丢弃，不拿旧窗口覆盖新池子。
  int _loadGeneration = 0;

  /// 影视池：只留视频站（kind == 'video'），短剧与阅读站不在此列。
  List<({String id, String name, String kind})> get _pool {
    final sites =
        widget.sites ??
        visibleFilmZoneSites(
          CultivationService.instance.snapshot.totalXp,
        );
    return [for (final site in sites) if (site.kind == 'video') site];
  }

  List<({String id, String name, String kind})> get _window {
    final pool = _pool;
    if (pool.isEmpty) return const [];
    if (pool.length <= _filmWindowSize) return pool;
    final start = _windowStart % pool.length;
    return [
      for (var i = 0; i < _filmWindowSize; i++)
        pool[(start + i) % pool.length],
    ];
  }

  @override
  void initState() {
    super.initState();
    if (widget.sites == null) {
      CultivationService.instance.snapshotNotifier.addListener(
        _onCultivationChanged,
      );
    }
    // 打开推荐页即取第一窗推荐，不等用户点站。
    unawaited(_loadWindow());
  }

  void _onCultivationChanged() {
    if (!mounted) return;
    // 修为变化（解锁新档位）时池子变了：窗口回首窗，重新取数，
    // 解锁的新站自动出现在推荐里，未解锁的站完全不显示。
    _windowStart = 0;
    unawaited(_loadWindow());
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
    if (widget.sites != oldWidget.sites) {
      _windowStart = 0;
      unawaited(_loadWindow());
    }
  }

  Future<DramaSiteContentClient?> _clientFor(String siteId) async {
    final injected = widget.clientForSite;
    if (injected != null) return injected(siteId);
    return dramaSiteContentClient(siteId) ??
        await SourceRegistry.instance.clientFor(siteId);
  }

  /// 取一站推荐：null = 该站失败（超时/报错），跳过并记入 `_failed`；
  /// 空列表的 [_FilmSiteItems] = 该站正常回空，不是失败，不记失败——
  /// 核心正常回空与核心调用超时是两回事，别把空列表算成失败。
  Future<_FilmSiteItems?> _fetchOne(
    ({String id, String name, String kind}) site,
  ) async {
    try {
      final client = await _clientFor(site.id);
      if (client == null) return null;
      // 先取真实首分类再取列表：核心站登记里只有「全部」兜底，
      // `catalog('all')` 对多数核心站是空的（mjv011 的 all 地址
      // 只回 1822 字节跳转页、avyan 回「系统提示」页）。分类
      // 取不到就回落 'all'，行为与原来一致；超时按 ApiClient 的
      // 分类预算 + 余量，不盖帽。
      var categoryId = 'all';
      try {
        final categories = await client.categories().timeout(
          ApiClient.dramaCategoriesTimeout + _clientTimeoutMargin,
        );
        final usable = categories
            .where((c) => c.id.isNotEmpty && c.id != 'all')
            .toList();
        if (usable.isNotEmpty) {
          categoryId = usable.first.id;
        } else if (categories.isNotEmpty) {
          categoryId = categories.first.id;
        }
      } catch (_) {}
      final page = await client.catalog(categoryId, 1).timeout(
        ApiClient.dramaCatalogTimeout + _clientTimeoutMargin,
      );
      return _FilmSiteItems(
        siteId: site.id,
        items: page.items.take(_filmItemsPerSite).toList(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadWindow() async {
    final window = _window;
    if (window.isEmpty) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _failed = 0;
    });
    final results = await Future.wait([
      for (final site in window) _fetchOne(site),
    ]);
    if (!mounted || generation != _loadGeneration) return;
    final got = <_FilmSiteItems>[];
    var failed = 0;
    for (final result in results) {
      if (result == null) {
        failed++;
      } else {
        got.add(result);
      }
    }
    setState(() {
      _sections = got;
      _failed = failed;
      _loading = false;
      _loaded = true;
    });
  }

  void _nextWindow() {
    final pool = _pool;
    if (pool.length <= _filmWindowSize) return;
    setState(() {
      _windowStart = (_windowStart + _filmWindowSize) % pool.length;
      _sections = [];
      _loaded = false;
    });
    unawaited(_loadWindow());
  }

  @override
  Widget build(BuildContext context) {
    final pool = _pool;
    final palette = HomePalette.of(context);
    const columns = 3;
    final cardWidth =
        (widget.gridWidth - (columns - 1) * homeGridGap) / columns;
    final scaler = MediaQuery.textScalerOf(context);
    final total = _sections.fold<int>(0, (sum, s) => sum + s.items.length);
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: HomeSectionHeader(
            key: const Key('film-zone-header'),
            title: '影视',
          ),
        ),
        if (pool.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('暂无可显示的影视站'),
            ),
          )
        else if (_loading && !_loaded)
          const SliverToBoxAdapter(child: HomeFeedLoading())
        else if (total == 0)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 全失败（超时/报错）与全回空是两回事：前者说取不到、
                  // 后者如实说暂无内容，不把空列表说成取不到。
                  Text(
                    _failed > 0
                        ? '推荐影视暂时取不到，稍后再试一次。'
                        : '推荐影视暂无内容。',
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _loading ? null : _loadWindow,
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          )
        else ...[
          for (final section in _sections)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: homeGutter),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: homeGridGap,
                  mainAxisSpacing: 20,
                  mainAxisExtent: homeCardExtent(
                    context,
                    cardWidth,
                    scaler,
                  ),
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final item = section.items[index];
                  return HomeMediaCard(
                    item: MediaItem(
                      id: item.id,
                      title: item.title,
                      cover: item.cover,
                      author: '',
                      badge: '',
                      ep: item.remark,
                      kind: 'film',
                    ),
                    coverWidth: cardWidth,
                    onTap: () => openDramaSiteItem(
                      context,
                      section.siteId,
                      item,
                    ),
                  );
                }, childCount: section.items.length),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  if (_failed > 0)
                    Expanded(
                      child: Text(
                        '$_failed 个站取不到，已跳过',
                        style: TextStyle(
                          fontSize: 12,
                          color: palette.muted,
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  if (pool.length > _filmWindowSize)
                    OutlinedButton(
                      key: const ValueKey('film-zone-next-batch'),
                      onPressed: _loading ? null : _nextWindow,
                      child: Text(_loading ? '加载中…' : '换一批'),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
