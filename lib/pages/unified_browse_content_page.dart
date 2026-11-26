import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/drama_site_content.dart';
import '../services/drama_site_play.dart';
import '../services/drama_sites.dart';
import '../services/source_registry.dart';
import '../services/unified_video_categories.dart';
import '../widgets/series_detail/moyi_detail_theme.dart';
import '../widgets/home/home_feed_states.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_shelf.dart';

/// 统一浏览内容页：一个分类（或标签）名下，各站内容的汇总。
///
/// 分类和标签共用这一页：调用方把该名下的站 + 路径（分类是 CATS 的
/// path，标签是标签链接 url）拼成 [UnifiedCategorySite] 传进来，
/// 本页按站逐批取 `catalog(path, 1)` 并按站分组展示。
///
/// 站多时不一次全取：首批取 [batchSize] 站（并行），点「加载更多站点」
/// 再取下一批；某站取不到就跳过该站（页脚记一笔，不卡住整页）。
/// 卡片点开走原站详情页（与 [DramaSiteGrid] 同路）。
class UnifiedBrowseContentPage extends StatefulWidget {
  const UnifiedBrowseContentPage({
    super.key,
    required this.title,
    required this.entries,
    this.clientForSite,
  });

  /// 页标题：分类名或标签名。
  final String title;

  /// 该名下的站 + 路径（分类 path / 标签 url）。
  final List<UnifiedCategorySite> entries;

  /// 取数客户端注入（生产默认 [dramaSiteContentClient]，取不到再走
  /// [SourceRegistry.clientFor] 的种子/jar 兜底；测试替换，
  /// 页测不落网络）。
  final DramaSiteContentClient? Function(String siteId)? clientForSite;

  @override
  State<UnifiedBrowseContentPage> createState() =>
      _UnifiedBrowseContentPageState();
}

/// 每批取的站数：并行取 4 站首页，够一屏内容，又不至于一次拉爆。
const int unifiedBrowseBatchSize = 4;

/// 单源总上限：构造客户端 + catalog 整段封顶（与频道分类页
/// `_moyiSourceTimeout` 同口径）。旧实现 catalog 单段就允许
/// `ApiClient.dramaCatalogTimeout + 5s` = 50 秒，且构造客户端那段
/// 不在任何超时里，源卡死时整批陪等、转圈无上限。
const Duration _browseSourceTimeout = Duration(seconds: 25);

/// 一站取数的结果：[section] 为 null 表示该站没内容可展示；
/// [responded] 区分「站正常响应、只是这页没内容」（不算失败）
/// 与「没响应」（无客户端/超时/异常，计入页脚没响应计数）。
typedef _FetchOutcome = ({_SiteSection? section, bool responded});

/// 跨实例缓存的一页快照：看过的汇总页再点进来先出缓存、后台刷新。
typedef _CachedBrowse = ({
  List<_SiteSection> sections,
  int fetched,
  int failed,
});

/// 一站取到的内容。
class _SiteSection {
  const _SiteSection({
    required this.entryIndex,
    required this.siteId,
    required this.siteName,
    required this.items,
  });

  /// 在 widget.entries 里的序号：逐源回来时按它插入，保证站的
  /// 展示顺序始终是入口顺序，不随后到先得乱序。
  final int entryIndex;
  final String siteId;
  final String siteName;
  final List<DramaSiteItem> items;
}

String _siteDisplayName(String siteId) {
  for (final site in allDramaSites) {
    if (site.id == siteId) return site.name;
  }
  return siteId;
}

class _UnifiedBrowseContentPageState extends State<UnifiedBrowseContentPage> {
  /// 跨实例作品缓存：本页每次都是新推入的路由、新 State，不缓存
  /// 的话看过的汇总页退出重进要全量重拉。键见 [_cacheKey]；上限
  /// [_browseCacheCap] 页，FIFO 淘汰。全失败（无内容）不入缓存，
  /// 下次点进来照常重试。
  static final Map<String, _CachedBrowse> _browseCache = {};
  static const int _browseCacheCap = 16;

  final List<_SiteSection> _sections = [];
  int _fetched = 0;
  int _failed = 0;
  bool _loading = false;
  bool _loadingMore = false;
  bool _refreshing = false;
  String? _error;

  bool get _hasMoreSites => _fetched < widget.entries.length;

  /// 缓存键：标题 + 全部站/路径签名。测试注入了取数客户端时再
  /// 掺入注入对象的身份，避免不同测试的假客户端互相污染缓存；
  /// 生产路径 clientForSite 为 null，键就是纯签名。
  String get _cacheKey {
    final signature =
        '${widget.title}\u0000${widget.entries.map((e) => '${e.siteId}|${e.path}').join('\u0001')}';
    final injected = widget.clientForSite;
    return injected == null
        ? signature
        : '$signature\u0002${identityHashCode(injected)}';
  }

  @override
  void initState() {
    super.initState();
    final cached = _browseCache[_cacheKey];
    if (cached != null && cached.sections.isNotEmpty) {
      // 缓存先行：先把看过的内容摆出来、不转圈，已取范围在后台
      // 逐站刷新（见 _refresh），回来逐站换新并回写缓存。
      _sections.addAll(cached.sections);
      _fetched = cached.fetched;
      _failed = cached.failed;
      unawaited(_refresh(cached.fetched));
    } else {
      _loadBatch();
    }
  }

  void _writeCache() {
    if (_sections.isEmpty) return;
    _browseCache[_cacheKey] = (
      sections: List<_SiteSection>.of(_sections),
      fetched: _fetched,
      failed: _failed,
    );
    while (_browseCache.length > _browseCacheCap) {
      _browseCache.remove(_browseCache.keys.first);
    }
  }

  /// 后台刷新已展示范围 [0, upto)：逐站重取，取到新内容就按序号
  /// 换掉旧段；取不到（没响应或空页）保留缓存段不清屏——与频道
  /// 分类页「后台刷新全空不清正在显示的缓存」同口径。刷新失败
  /// 不计入 [_failed]（内容还摆着，报「没响应」自相矛盾）。
  Future<void> _refresh(int upto) async {
    if (upto <= 0) return;
    _refreshing = true;
    var pending = upto;
    for (var index = 0; index < upto; index++) {
      final entry = widget.entries[index];
      unawaited(() async {
        final outcome = await _fetchOne(entry, index);
        if (mounted && outcome.section != null) {
          setState(() => _insertSection(outcome.section!));
        }
        if (--pending == 0 && mounted) {
          // 翻假也要走 setState：加载更多按钮的禁用态靠它恢复。
          setState(() => _refreshing = false);
          _writeCache();
        }
      }());
    }
  }

  Future<DramaSiteContentClient?> _clientFor(String siteId) async =>
      widget.clientForSite?.call(siteId) ??
      dramaSiteContentClient(siteId) ??
      await SourceRegistry.instance.clientFor(siteId);

  /// 按入口序号插入（或替换刷新回来的同序号段），保证展示顺序
  /// 始终是入口顺序。
  void _insertSection(_SiteSection section) {
    final at = _sections.indexWhere(
      (s) => s.entryIndex >= section.entryIndex,
    );
    if (at == -1) {
      _sections.add(section);
    } else if (_sections[at].entryIndex == section.entryIndex) {
      _sections[at] = section;
    } else {
      _sections.insert(at, section);
    }
  }

  Future<void> _loadBatch() async {
    if (_loading || _loadingMore || _refreshing || !_hasMoreSites) return;
    final start = _fetched;
    final batch = widget.entries
        .skip(start)
        .take(unifiedBrowseBatchSize)
        .toList();
    if (batch.isEmpty) return;
    setState(() {
      if (_sections.isEmpty) {
        _loading = true;
      } else {
        _loadingMore = true;
      }
      _error = null;
    });
    // 逐站出结果：哪个站先回，哪个站的段先上屏，不再像旧实现
    // 那样 Future.wait 等一批 4 站全部 settle 才一起渲染——慢站
    // 只拖自己，拖不了整页首屏。批次账目（_fetched 推进、错误
    // 态判定、自动续批）在全批 settle 后统一收尾。
    var pending = batch.length;
    var gotAny = false;
    for (var i = 0; i < batch.length; i++) {
      final index = start + i;
      unawaited(() async {
        final outcome = await _fetchOne(batch[i], index);
        if (mounted) {
          setState(() {
            if (outcome.section != null) {
              _insertSection(outcome.section!);
              gotAny = true;
            }
            if (!outcome.responded) _failed++;
          });
        }
        if (--pending > 0 || !mounted) return;
        setState(() {
          _fetched = start + batch.length;
          _loading = false;
          _loadingMore = false;
          if (_sections.isEmpty && !_hasMoreSites) {
            _error = '这些站现在都打不开，稍后再试';
          }
        });
        _writeCache();
        // 这一批一个站都没取到、后面还有站：自动续取下一批，
        // 不用用户连点 5 次「加载更多站点」才看到内容；取到
        // 内容就停，剩下的站仍由用户点「加载更多站点」接着取。
        if (!gotAny && _hasMoreSites) {
          unawaited(_loadBatch());
        }
      }());
    }
  }

  /// 全部取完仍无内容时的「重试」：从第一批站重新取一遍。
  /// 直接调 [_loadBatch] 重试是没用的——取完后 [_hasMoreSites]
  /// 已为假，[_loadBatch] 开头就直接返回，按钮点了也没反应。
  Future<void> _retry() async {
    if (_loading || _loadingMore || _refreshing) return;
    _browseCache.remove(_cacheKey);
    setState(() {
      _sections.clear();
      _fetched = 0;
      _failed = 0;
      _error = null;
    });
    await _loadBatch();
  }

  /// 取一站该分类/标签的首页：「构造客户端 + catalog」整段套
  /// [_browseSourceTimeout] 总上限——旧实现构造客户端那段不在
  /// 任何超时里、catalog 单段又允许 50 秒，一站卡死能拖住整批。
  Future<_FetchOutcome> _fetchOne(
    UnifiedCategorySite entry,
    int entryIndex,
  ) async {
    try {
      return await _fetchRaw(entry, entryIndex).timeout(_browseSourceTimeout);
    } catch (_) {
      return (section: null, responded: false);
    }
  }

  Future<_FetchOutcome> _fetchRaw(
    UnifiedCategorySite entry,
    int entryIndex,
  ) async {
    final client = await _clientFor(entry.siteId);
    if (client == null) return (section: null, responded: false);
    final page = await client.catalog(entry.path, 1);
    if (page.items.isEmpty) return (section: null, responded: true);
    return (
      section: _SiteSection(
        entryIndex: entryIndex,
        siteId: entry.siteId,
        siteName: _siteDisplayName(entry.siteId),
        items: page.items,
      ),
      responded: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MoyiPageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(widget.title),
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
        ),
        body: _loading && _sections.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : _error != null && _sections.isEmpty
            ? Center(
                child: HomeStateView(
                  icon: Icons.cloud_off,
                  title: _error!,
                  actionLabel: '重试',
                  onAction: _retry,
                ),
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  const columns = 3;
                  final gridWidth = constraints.maxWidth - homeGutter * 2;
                  final cardWidth =
                      (gridWidth - (columns - 1) * homeGridGap) / columns;
                  final scaler = MediaQuery.textScalerOf(context);
                  // 往上滑到底自动取下一批站点：_loadBatch 自带
                  // _loading/_loadingMore/_hasMoreSites 门，不会重复
                  // 取同一批；失败时停住，底部按钮点重试（见 _retry）。
                  // 内容不满一屏滑不动时，仍由底部按钮翻页。
                  return NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification is ScrollUpdateNotification ||
                          notification is ScrollEndNotification) {
                        if (notification.metrics.extentAfter < 400) {
                          unawaited(_loadBatch());
                        }
                      }
                      return false;
                    },
                    child: CustomScrollView(
                      slivers: [
                        for (final section in _sections) ...[
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                homeGutter,
                                20,
                                homeGutter,
                                8,
                              ),
                              child: Text(
                                '${section.siteName}（${section.items.length}）',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: homeGutter,
                            ),
                            sliver: SliverGrid(
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    crossAxisSpacing: homeGridGap,
                                    mainAxisSpacing: 20,
                                    mainAxisExtent: homeCardExtent(
                                      context,
                                      cardWidth,
                                      scaler,
                                    ),
                                  ),
                              delegate: SliverChildBuilderDelegate((
                                context,
                                index,
                              ) {
                                final item = section.items[index];
                                return HomeMediaCard(
                                  item: MediaItem(
                                    id: item.id,
                                    title: item.title,
                                    cover: item.cover,
                                    author: '',
                                    badge: '',
                                    ep: item.remark,
                                    kind: videoCardKindForSite(
                                      section.siteId,
                                      section.siteName,
                                    ),
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
                        ],
                        if (_failed > 0)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                homeGutter,
                                16,
                                homeGutter,
                                0,
                              ),
                              child: Text(
                                '$_failed 个站取不到，已跳过',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: moyiMutedOnDark,
                                ),
                              ),
                            ),
                          ),
                        if (_hasMoreSites)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: OutlinedButton(
                                key: const ValueKey(
                                  'unified_browse_load_more_sites',
                                ),
                                onPressed: _loadingMore || _refreshing
                                    ? null
                                    : _loadBatch,
                                child: Text(
                                  _loadingMore
                                      ? '加载中…'
                                      : '加载更多站点（还剩 ${widget.entries.length - _fetched} 站）',
                                ),
                              ),
                            ),
                          )
                        else
                          const SliverToBoxAdapter(child: SizedBox(height: 24)),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}
