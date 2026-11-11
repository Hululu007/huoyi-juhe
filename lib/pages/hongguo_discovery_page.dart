import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../models/search_discovery.dart';
import '../services/drama_site_content.dart';
import '../services/drama_site_play.dart';
import '../services/drama_sites.dart';
import '../services/user_facing_error.dart';
import '../widgets/home/home_back_button.dart';
import '../widgets/home/home_chip.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_media_card.dart' show StoryCover;
import '../widgets/home/home_shelf.dart' show homeGutter;
import '../widgets/series_detail/moyi_detail_theme.dart';
import 'hongguo_rank_page.dart';
import 'search_page.dart';

/// 红果发现页：对照 hongguoTV 找剧（`DiscoveryScreen` + `HomeFeedScreen`
/// 的手机版）。
///
/// 电视与手机的对应关系：
/// - 电视三栏（类型/题材/筛选组）→ 手机两行横滑 chips：分类行 + 题材行。
///   站方多维筛选组（主题/设定/背景/排序/受众/时间/状态）走带签名的
///   筛选接口，签名是另一组的活，这里不编假筛选——只做分类 + 题材。
/// - 电视首页自动试播首集 → 手机不自动播（流量与前台播放器冲突），
///   改为每张卡上的「试播首集」钮：点一下直接播第 1 集，不进详情页。
/// - 电视遥控搜索（三栏搜索入口 + 服务端联想）→ 手机 AppBar 搜索钮，
///   进搜索页即弹键盘落在输入框（`autofocus`），联想词走红果服务端接口。
class HongguoDiscoveryPage extends StatefulWidget {
  final HongguoContentClient? client;
  final String? initialCategoryId;

  const HongguoDiscoveryPage({super.key, this.client, this.initialCategoryId});

  @override
  State<HongguoDiscoveryPage> createState() => _HongguoDiscoveryPageState();
}

class _HongguoDiscoveryPageState extends State<HongguoDiscoveryPage> {
  late final HongguoContentClient _client;

  List<DramaSiteCategory> _categories = const [];
  String _categoryId = 'all';
  List<HongguoDramaTopic> _topics = const [];
  String _topicId = '';

  List<DramaSiteItem> _items = const [];
  int _page = 0;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  int _generation = 0;

  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? HongguoContentClient();
    _scrollController.addListener(_onScroll);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final categories = await _client.categories();
    if (!mounted) return;
    setState(() {
      _categories = categories.isEmpty
          ? const [
              DramaSiteCategory('all', '全部'),
              DramaSiteCategory('real-drama', '真人剧'),
              DramaSiteCategory('comic-drama', '漫剧'),
              DramaSiteCategory('ai-drama', 'AI剧'),
            ]
          : categories;
      if (widget.initialCategoryId != null &&
          _categories.any((c) => c.id == widget.initialCategoryId)) {
        _categoryId = widget.initialCategoryId!;
      }
    });
    unawaited(_load(reset: true));
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final metrics = _scrollController.position;
    if (metrics.pixels >= metrics.maxScrollExtent - 600) {
      unawaited(_load());
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading || _loadingMore) return;
    if (!reset && !_hasMore) return;
    final generation = ++_generation;
    setState(() {
      if (reset) {
        _loading = true;
        _error = null;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final nextPage = reset ? 1 : _page + 1;
      final result = _topicId.isEmpty
          ? await _client.catalog(_categoryId, nextPage)
          : await _client.discover(_categoryId, _topicId, nextPage);
      if (!mounted || generation != _generation) return;
      setState(() {
        _page = nextPage;
        _items = reset ? result.items : [..._items, ...result.items];
        _hasMore = result.hasMore;
        _topics = result.topics;
        _loading = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = userFacingError(error);
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  void _selectCategory(String id) {
    if (id == _categoryId) return;
    setState(() {
      _categoryId = id;
      _topicId = '';
      _topics = const [];
    });
    unawaited(_load(reset: true));
  }

  void _selectTopic(String id) {
    if (id == _topicId) return;
    setState(() => _topicId = id);
    unawaited(_load(reset: true));
  }

  void _openSearch() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SearchPage(
          // 站源页签只搜红果；联想词走红果服务端接口，不走番茄上游。
          initialCategory: SearchCategory.sites,
          initialSiteIds: const {'hongguo'},
          suggestLoader: (query) async {
            final words = await _client.searchSuggestions(query);
            return [for (final word in words) SearchSuggestion(text: word)];
          },
          autofocus: true,
        ),
      ),
    );
  }

  void _openRank() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => HongguoRankPage(client: _client),
      ),
    );
  }

  /// 点卡进详情（`openDramaSiteItem`，与多站内容汇总页同路，不新写播放）。
  void _openItem(DramaSiteItem item) {
    unawaited(openDramaSiteItem(context, 'hongguo', item));
  }

  /// 试播首集：绕过详情页直接播第 1 集，复用站内播放入口
  /// `openDramaSitePlayback`（不另造播放器）。
  void _trialPlay(DramaSiteItem item) {
    unawaited(
      openDramaSitePlayback(
        context,
        siteId: 'hongguo',
        seriesId: item.id,
        title: item.title,
        cover: item.cover,
        startIndex: 0,
      ),
    );
  }

  MediaItem _toMediaItem(DramaSiteItem item) => MediaItem(
    id: item.id,
    title: item.title,
    cover: item.cover,
    author: '',
    badge: '',
    ep: item.remark,
    kind: 'video',
    seriesId: item.id,
  );

  @override
  Widget build(BuildContext context) {
    return MoyiPageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          leading: const HomeBackButton(),
          title: const Text(
            '红果发现',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          actions: [
            IconButton(
              tooltip: '搜索',
              icon: const Icon(LucideIcons.search, size: 20),
              onPressed: _openSearch,
            ),
            IconButton(
              tooltip: '红果榜',
              icon: const Icon(LucideIcons.trophy, size: 20),
              onPressed: _openRank,
            ),
          ],
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Column(
              children: [
                _chipRow(
                  key: const Key('hongguo_categories'),
                  labels: [for (final c in _categories) c.name],
                  selectedIndex: _categories.indexWhere(
                    (c) => c.id == _categoryId,
                  ),
                  onSelect: (index) => _selectCategory(_categories[index].id),
                  semanticPrefix: '分类',
                ),
                if (_topics.isNotEmpty)
                  _chipRow(
                    key: const Key('hongguo_topics'),
                    labels: [
                      '全部题材',
                      for (final topic in _topics) topic.label,
                    ],
                    selectedIndex: _topicId.isEmpty
                        ? 0
                        : _topics.indexWhere((t) => t.id == _topicId) + 1,
                    onSelect: (index) => _selectTopic(
                      index == 0 ? '' : _topics[index - 1].id,
                    ),
                    semanticPrefix: '题材',
                  ),
                Expanded(child: _body()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _chipRow({
    required Key key,
    required List<String> labels,
    required int selectedIndex,
    required ValueChanged<int> onSelect,
    required String semanticPrefix,
  }) {
    if (labels.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: HomeChip.minTapTarget,
      child: ListView.separated(
        key: key,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: homeGutter),
        itemCount: labels.length,
        separatorBuilder: (context, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) => Center(
          child: HomeChip(
            label: labels[index],
            selected: index == selectedIndex,
            semanticLabel: '$semanticPrefix${labels[index]}',
            onTap: () => onSelect(index),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: HomePalette.accent),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('hongguo_retry'),
                onPressed: () => unawaited(_load(reset: true)),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(
        child: Text('暂无内容', style: TextStyle(color: Colors.white70)),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: GridView.builder(
        controller: _scrollController,
        padding: EdgeInsets.fromLTRB(
          homeGutter,
          12,
          homeGutter,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 8,
          mainAxisSpacing: 16,
          childAspectRatio: 0.52,
        ),
        itemCount: _items.length + (_loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return const Center(
              child: CircularProgressIndicator(color: HomePalette.accent),
            );
          }
          final item = _items[index];
          return _DiscoveryCard(
            item: item,
            mediaItem: _toMediaItem(item),
            onTap: () => _openItem(item),
            onTrialPlay: () => _trialPlay(item),
          );
        },
      ),
    );
  }
}

/// 发现卡：竖版海报 + 片名 + 集数，右下角「试播首集」钮。
class _DiscoveryCard extends StatelessWidget {
  final DramaSiteItem item;
  final MediaItem mediaItem;
  final VoidCallback onTap;
  final VoidCallback onTrialPlay;

  const _DiscoveryCard({
    required this.item,
    required this.mediaItem,
    required this.onTap,
    required this.onTrialPlay,
  });

  @override
  Widget build(BuildContext context) {
    return HomePressable(
      key: ValueKey('hongguo_item_${item.id}'),
      semanticLabel: item.title,
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: StoryCover(
                    item: mediaItem,
                    cacheWidth:
                        (MediaQuery.sizeOf(context).width /
                                    3 *
                                    MediaQuery.devicePixelRatioOf(context))
                                .ceil(),
                  ),
                ),
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Material(
                    color: Colors.black54,
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: ValueKey('hongguo_trial_${item.id}'),
                      customBorder: const CircleBorder(),
                      onTap: onTrialPlay,
                      child: Tooltip(
                        message: '试播首集',
                        child: Semantics(
                          button: true,
                          label: '试播首集：${item.title}',
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(
                              LucideIcons.play,
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (item.remark.isNotEmpty)
            Text(
              item.remark,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: moyiMutedOnDark, fontSize: 11),
            ),
        ],
      ),
    );
  }
}
