import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../services/drama_site_content.dart';
import '../services/drama_site_play.dart';
import '../services/user_facing_error.dart';
import '../widgets/home/home_back_button.dart';
import '../widgets/home/home_chip.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_media_card.dart' show StoryCover;
import '../widgets/home/home_shelf.dart' show homeGutter;
import '../widgets/home/home_stream_footer.dart';
import '../widgets/series_detail/moyi_detail_theme.dart';
import 'hongguo_discovery_page.dart';

/// 红果榜：对照 hongguoTV `RankingScreen` + `RankBrowserState` 的手机版。
///
/// - 四榜：综合 / 真人剧 / 漫剧 / AI剧（`HongguoRankBoard.all`）。
/// - 每榜独立缓存：切榜零请求（TTL 内不重拉在电视端；手机端按会话缓存，
///   手动刷新才重拉），在途去重，失败保留旧榜。
/// - 题材筛选：只按各条 tags 的完整 token 匹配，不按标题猜；
///   筛选保留原榜名次（名次是整榜的，不因筛选重排）。
/// - 名次 1–3 名用金色，与排行榜页同口径。
class HongguoRankPage extends StatefulWidget {
  final HongguoContentClient? client;
  final String? initialBoardId;

  const HongguoRankPage({super.key, this.client, this.initialBoardId});

  @override
  State<HongguoRankPage> createState() => _HongguoRankPageState();
}

class _HongguoRankPageState extends State<HongguoRankPage> {
  late final HongguoContentClient _client;

  HongguoRankBoard _board = HongguoRankBoard.all.first;
  String _topic = '';

  /// 每榜独立的会话缓存：榜单数据、已拉页数、是否还有下一页、更新文案。
  final _entriesByBoard = <String, List<HongguoRankEntry>>{};
  final _pagesByBoard = <String, int>{};
  final _hasMoreByBoard = <String, bool>{};
  final _updatedByBoard = <String, String>{};

  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  String? _loadMoreError;
  int _generation = 0;

  List<HongguoRankEntry> get _entries => _entriesByBoard[_board.id] ?? const [];

  List<HongguoRankEntry> get _visible => _topic.isEmpty
      ? _entries
      : [for (final entry in _entries) if (entry.tags.contains(_topic)) entry];

  List<String> get _topics {
    final counts = <String, int>{};
    for (final entry in _entries) {
      for (final tag in entry.tags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    final sorted = counts.entries.toList()
      ..sort(
        (a, b) => b.value != a.value
            ? b.value.compareTo(a.value)
            : a.key.compareTo(b.key),
      );
    return [for (final entry in sorted) entry.key];
  }

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? HongguoContentClient();
    if (widget.initialBoardId != null) {
      _board = HongguoRankBoard.byId(widget.initialBoardId!);
    }
    unawaited(_loadFirst());
  }

  Future<void> _loadFirst({bool force = false}) async {
    final generation = ++_generation;
    if (!force && _entriesByBoard.containsKey(_board.id)) return;
    setState(() {
      _loading = true;
      _error = null;
      _loadMoreError = null;
    });
    try {
      final data = await _client.rankPage(_board, page: 1);
      if (!mounted || generation != _generation) return;
      setState(() {
        _entriesByBoard[_board.id] = data.entries;
        _pagesByBoard[_board.id] = 1;
        _hasMoreByBoard[_board.id] = data.hasMore;
        _updatedByBoard[_board.id] = data.updatedText;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        // 失败保留旧榜：有缓存时只留错误提示，不清空列表。
        if (_entriesByBoard[_board.id] == null) {
          _error = userFacingError(error);
        }
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore) return;
    if (!(_hasMoreByBoard[_board.id] ?? false)) return;
    final generation = _generation;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    try {
      final nextPage = (_pagesByBoard[_board.id] ?? 1) + 1;
      final data = await _client.rankPage(_board, page: nextPage);
      if (!mounted || generation != _generation) return;
      setState(() {
        _entriesByBoard[_board.id] = [..._entries, ...data.entries];
        _pagesByBoard[_board.id] = nextPage;
        _hasMoreByBoard[_board.id] = data.hasMore;
        if (data.updatedText.isNotEmpty) {
          _updatedByBoard[_board.id] = data.updatedText;
        }
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadMoreError = userFacingError(error);
        _loadingMore = false;
      });
    }
  }

  void _selectBoard(HongguoRankBoard board) {
    if (board.id == _board.id) return;
    setState(() {
      _board = board;
      // 新榜没有该题材时回全部题材（电视端同口径）。
      if (_topic.isNotEmpty && !_topics.contains(_topic)) _topic = '';
    });
    unawaited(_loadFirst());
  }

  void _selectTopic(String topic) {
    if (topic == _topic) return;
    setState(() => _topic = topic);
  }

  void _openDiscovery() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => HongguoDiscoveryPage(client: _client),
      ),
    );
  }

  void _openEntry(HongguoRankEntry entry) {
    unawaited(openDramaSiteItem(context, 'hongguo', entry.item));
  }

  void _trialPlay(HongguoRankEntry entry) {
    unawaited(
      openDramaSitePlayback(
        context,
        siteId: 'hongguo',
        seriesId: entry.item.id,
        title: entry.item.title,
        cover: entry.item.cover,
        startIndex: 0,
      ),
    );
  }

  MediaItem _toMediaItem(HongguoRankEntry entry) => MediaItem(
    id: entry.item.id,
    title: entry.item.title,
    cover: entry.item.cover,
    author: '',
    badge: '',
    ep: entry.item.remark,
    kind: 'video',
    seriesId: entry.item.id,
  );

  @override
  Widget build(BuildContext context) {
    final updated = _updatedByBoard[_board.id] ?? '';
    final subtitle = [
      if (updated.isNotEmpty) updated,
      '${_entries.length} 部',
      if (_topic.isNotEmpty) '$_topic ${_visible.length} 部（保留原榜名次）',
    ].join(' · ');
    return MoyiPageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          leading: const HomeBackButton(),
          title: Text(
            '${_board.label}热播榜',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          actions: [
            IconButton(
              tooltip: '红果发现',
              icon: const Icon(LucideIcons.compass, size: 20),
              onPressed: _openDiscovery,
            ),
            IconButton(
              tooltip: '刷新',
              icon: const Icon(LucideIcons.refresh_cw, size: 20),
              onPressed: () => unawaited(_loadFirst(force: true)),
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
                  key: const Key('hongguo_rank_boards'),
                  labels: [
                    for (final board in HongguoRankBoard.all) board.label,
                  ],
                  selectedIndex: HongguoRankBoard.all.indexWhere(
                    (board) => board.id == _board.id,
                  ),
                  onSelect: (index) =>
                      _selectBoard(HongguoRankBoard.all[index]),
                  semanticPrefix: '榜单',
                ),
                if (_topics.isNotEmpty)
                  _chipRow(
                    key: const Key('hongguo_rank_topics'),
                    labels: ['全部题材', ..._topics],
                    selectedIndex: _topic.isEmpty
                        ? 0
                        : _topics.indexOf(_topic) + 1,
                    onSelect: (index) =>
                        _selectTopic(index == 0 ? '' : _topics[index - 1]),
                    semanticPrefix: '题材',
                  ),
                if (subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      homeGutter,
                      9,
                      homeGutter,
                      9,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: moyiMutedOnDark,
                          fontSize: 12,
                        ),
                      ),
                    ),
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
                key: const Key('hongguo_rank_retry'),
                onPressed: () => unawaited(_loadFirst(force: true)),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_visible.isEmpty) {
      return const Center(
        child: Text('本榜暂无符合条件的作品，可切换题材', style: TextStyle(color: Colors.white70)),
      );
    }
    final hasFooter =
        _loadingMore || _loadMoreError != null || !(_hasMoreByBoard[_board.id] ?? false);
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        final metrics = notification.metrics;
        if (metrics.axis == Axis.vertical &&
            metrics.pixels >= metrics.maxScrollExtent - 400) {
          unawaited(_loadMore());
        }
        return false;
      },
      child: ListView.builder(
        key: const Key('hongguo_rank_list'),
        padding: EdgeInsets.fromLTRB(
          homeGutter,
          4,
          homeGutter,
          hasFooter ? 0 : 24 + MediaQuery.paddingOf(context).bottom,
        ),
        itemCount: _visible.length + (hasFooter ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _visible.length) return _footer();
          final entry = _visible[index];
          return _HongguoRankRow(
            entry: entry,
            mediaItem: _toMediaItem(entry),
            onTap: () => _openEntry(entry),
            onTrialPlay: () => _trialPlay(entry),
          );
        },
      ),
    );
  }

  Widget _footer() {
    if (_loadMoreError != null) {
      return HomeStreamFooter.retry(
        key: const Key('hongguo_rank_load_more_retry'),
        onRetry: () => unawaited(_loadMore()),
        includeBottomSafeArea: true,
      );
    }
    if (_loadingMore) {
      return const HomeStreamFooter.loading(includeBottomSafeArea: true);
    }
    return HomeStreamFooter.done(includeBottomSafeArea: true);
  }
}

/// 一行榜单：名次、封面、标题与热度，右侧「试播首集」钮。
class _HongguoRankRow extends StatelessWidget {
  final HongguoRankEntry entry;
  final MediaItem mediaItem;
  final VoidCallback onTap;
  final VoidCallback onTrialPlay;

  const _HongguoRankRow({
    required this.entry,
    required this.mediaItem,
    required this.onTap,
    required this.onTrialPlay,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final rank = entry.rank;
    final top = rank != null && rank <= 3;
    final meta = [
      if (entry.heat.isNotEmpty) entry.heat,
      if (entry.metrics.isNotEmpty) entry.metrics,
      if (entry.item.remark.isNotEmpty) entry.item.remark,
    ].join(' · ');
    return HomePressable(
      key: ValueKey('hongguo_rank_${entry.item.id}'),
      semanticLabel: rank == null
          ? entry.item.title
          : '第$rank名 ${entry.item.title}',
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 30,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  rank == null ? '–' : '$rank',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: top
                        ? (palette.eink ? Colors.black : moyiGold)
                        : (palette.eink ? Colors.black : moyiMutedOnDark),
                    fontSize: top ? 17 : 15,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 56,
                height: 78,
                child: StoryCover(
                  item: mediaItem,
                  cacheWidth: (56 * MediaQuery.devicePixelRatioOf(context))
                      .ceil(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: moyiMutedOnDark,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                  if (entry.tags.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Text(
                      entry.tags.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: moyiMutedOnDark,
                        fontSize: 12,
                        height: 1.6,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              key: ValueKey('hongguo_rank_trial_${entry.item.id}'),
              tooltip: '试播首集',
              icon: const Icon(LucideIcons.play, size: 20, color: Colors.white),
              onPressed: onTrialPlay,
            ),
          ],
        ),
      ),
    );
  }
}
