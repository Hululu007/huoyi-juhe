import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/drama_site_content.dart';
import '../services/drama_site_play.dart';
import '../services/source_registry.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_media_card.dart';
import 'home_provider.dart';

/// 成人分类聚合页（独立分类，不再是三个子 tab 的合集页）：
///
/// 一类一页（成人小说 / 成人漫画 / 成人听书各一页），把该类的全部成人源
/// 首分类第一页混排在一起，不用逐站切换。成人源分两路合并取数：
/// 核心站（火蚁TV 内置 27 个阅读源里该类的成人站，走核心阅读客户端）
/// 与登记源（名字带 🔞、已启用、内容是该类型的导入源）。点卡走站内
/// 详情链路。
///
/// 无门禁：成人书不再设门禁、不再隐藏，本页与入口常显，不取 MidnightGate。
class AdultNovelsPage extends StatelessWidget {
  const AdultNovelsPage({super.key, this.type = ContentType.novel, this.loader});

  final ContentType type;

  /// 预览/页测注入假数据用（同 CoreNovelCategoryPage 的 loader 规矩）：
  /// 不为空时 _load() 直接用它的结果，不走核心与登记源的真实网络；
  /// 为空时生产逻辑原样不动。
  final Future<List<MediaItem>> Function()? loader;

  String get _title => switch (type) {
    ContentType.comic => '成人漫画',
    ContentType.audio => '成人听书',
    _ => '成人小说',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: _AdultTypeGrid(type, loader: loader),
    );
  }
}

/// 阅读区各 tab 顶部的成人分类入口（一类一个，常显，无门禁）。
class AdultNovelsEntrySliver extends StatelessWidget {
  const AdultNovelsEntrySliver({super.key, this.type = ContentType.novel});

  final ContentType type;

  String get _title => switch (type) {
    ContentType.comic => '成人漫画',
    ContentType.audio => '成人听书',
    _ => '成人小说',
  };

  String get _subtitle => switch (type) {
    ContentType.comic => '全部成人漫画，不用切换站点',
    ContentType.audio => '全部成人听书，不用切换站点',
    _ => '全部成人小说，不用切换站点',
  };

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Card(
          key: Key(
            type == ContentType.novel
                ? 'adult-novels-entry'
                : 'adult-entry-${type.name}',
          ),
          child: ListTile(
            leading: const Icon(Icons.nightlight_round),
            title: Text(_title),
            subtitle: Text(_subtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => AdultNovelsPage(type: type),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AdultTypeGrid extends StatefulWidget {
  const _AdultTypeGrid(this.type, {this.loader});

  final ContentType type;

  final Future<List<MediaItem>> Function()? loader;

  @override
  State<_AdultTypeGrid> createState() => _AdultTypeGridState();
}

class _AdultTypeGridState extends State<_AdultTypeGrid> {
  var _loading = true;
  var _items = const <MediaItem>[];

  String get _typeName => switch (widget.type) {
    ContentType.novel => '小说',
    ContentType.comic => '漫画',
    ContentType.audio => '听书',
    _ => '内容',
  };

  String get _kindKey => switch (widget.type) {
    ContentType.comic => 'comic',
    ContentType.audio => 'audio',
    _ => 'novel',
  };

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
    });
    if (widget.loader != null) {
      try {
        final items = await widget.loader!();
        if (!mounted) return;
        setState(() {
          _items = items.take(60).toList();
          _loading = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _loading = false;
        });
      }
      return;
    }
    try {
      await SourceRegistry.instance.load();
      final sources = adultRecommendSources(
        SourceRegistry.instance.custom,
        types: {widget.type},
      );

      /// 首分类第一页：只取首分类时，首分类恰好为空（站方改版、该分类
      /// 下线）整站就被判空。按序试前四个分类，拿到非空第一页即停；
      /// 'author' 是 hsvoice31 的主播索引，里面是 folder 项不是作品，
      /// 跳过（作品分类 home/toplist/latest 都在它之前或之后）。
      Future<List<DramaSiteItem>> firstPageItems(
        DramaSiteContentClient client,
      ) async {
        final categories = await client.categories();
        for (final category in categories.take(4)) {
          if (category.id == 'author') continue;
          final page = await client.catalog(category.id, 1);
          if (page.items.isNotEmpty) return page.items.take(20).toList();
        }
        return const [];
      }

      Future<List<MediaItem>> fetch(SourceEntry entry) async {
        try {
          final client = await SourceRegistry.instance.clientFor(entry.id);
          if (client == null) return const [];
          final items = await firstPageItems(client);
          return [
            for (final item in items) adultRecommendItem(item, entry),
          ];
        } catch (_) {
          return const [];
        }
      }

      // 核心成人站（与登记源合并取数，核心在前）。
      final coreSiteIds = [
        for (final id in coreAdultReadingSiteIds)
          if (coreReadingKinds[id] == _kindKey) id,
      ];
      Future<List<MediaItem>> fetchCore(String siteId) async {
        try {
          final client = readingSiteContentClient(siteId);
          if (client == null) return const [];
          final items = await firstPageItems(client);
          return [
            for (final item in items)
              coreAdultRecommendItem(item, siteId, widget.type),
          ];
        } catch (_) {
          return const [];
        }
      }

      /// 单站 30 秒封顶：hsvoice31 取目录要连走两趟上游（混淆壳首页 +
      /// 解码 JS），hysxs 首跑要逐个探活候选域名，15 秒在手机弱网上
      /// 不够，两站都会被静默判空。30 秒仍比单次请求 20 秒上限宽，
      /// 两站并行跑，总墙钟不超 30 秒。
      Future<List<MediaItem>> timed(Future<List<MediaItem>> f) => f.timeout(
        const Duration(seconds: 30),
        onTimeout: () => const <MediaItem>[],
      );

      final results = await Future.wait([
        ...coreSiteIds.map((id) => timed(fetchCore(id))),
        ...sources.map((entry) => timed(fetch(entry))),
      ]);
      if (!mounted) return;
      setState(() {
        _items = [
          for (final list in results) ...list,
        ].take(60).toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  void _openItem(MediaItem item) {
    // 全部是 engine: 卡：走站内详情链路，不进番茄详情页。
    if (!item.source.startsWith('engine:')) return;
    final siteId = item.source.substring('engine:'.length);
    unawaited(
      openDramaSiteItem(
        context,
        siteId,
        DramaSiteItem(
          id: item.seriesId ?? item.id,
          title: item.title,
          cover: item.cover,
          remark: item.ep,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('暂无成人$_typeName'),
            const SizedBox(height: 4),
            const Text('核心站与已导入的成人源暂无内容'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _load,
              child: const Text('重新加载'),
            ),
          ],
        ),
      );
    }
    return GridView.builder(
      key: Key('adult-grid-${widget.type.name}'),
      padding: const EdgeInsets.all(16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        // 小说路与原始小说界面同一套格子：核心小说分类页
        // （CoreNovelCategoryPage）就是 2 列 / 16 边距 / 12 间距 /
        // 0.55。HomeMediaCard 在 390 宽手机上要 309px 高，0.55 的格子
        // 314.5px 刚好装下（0.62 只有 279px，会裁掉约 30px 作者行，
        // 见 test/preview_capture_test.dart 文件头的已知现状）。
        // 漫画 / 听书路沿用 D 路排行榜卡的 0.52，不动。
        childAspectRatio: widget.type == ContentType.novel ? 0.55 : 0.52,
      ),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        // 小说路：原始小说界面，与小说 tab / 核心小说分类页同一套——
        // HomeMediaCard（5/7 封面 + 两行 15sp 标题 + 作者 / 推荐 /
        // 评分副标题行），外面再叠名次角标与热度行（见 _AdultNovelCard），
        // 不用排行榜样式卡。漫画 / 听书路不动，仍用下面的 _AdultRankCard。
        if (widget.type == ContentType.novel) {
          return _AdultNovelCard(
            item: item,
            rank: index + 1,
            onTap: () => _openItem(item),
          );
        }
        return _AdultRankCard(
          item: item,
          rank: index + 1,
          onTap: () => _openItem(item),
        );
      },
    );
  }
}

/// 小说路卡：原始小说界面 HomeMediaCard + 名次角标 + 热度行。
///
/// HomeMediaCard 本身不改（核心小说分类页共用同一套，见
/// CoreNovelCategoryPage），角标与热度行只叠在成人小说页这一路：
/// 角标用 Stack 叠在封面左上角，热度行接在卡片下方。
///
/// 名次是混排后的真实列表位置（第 1 张卡 TOP 1、第 2 张 TOP 2，以此
/// 类推，每张卡都有，不是只前三名——与首页排行榜 _RankCover 只前三名
/// 戴角标不同）；样式照 _RankCover 的 TOP 角标（黑底白字、左上 6/6、
/// 10sp 加粗），不另发明样式。成人取数不带 tag（见 home_provider.dart
/// 的 adultRecommendItem / coreAdultRecommendItem），封面左上不会与
/// HomeMediaCard 的 tag 角标撞上。
///
/// 热度行只在站方给了数据时出现（_heatLine：rankTags.first 优先，
/// 没有时看备注 ep——`^[\d.]+万$` 的播放量补「热度」二字，其他备注
/// 原样显示，都没有就不渲染该行，不编假数字）。副标题行仍由
/// HomeMediaCard 内部按作者 · 首条推荐 · 评分渲染，全空不渲染。
///
/// 高度账（390 宽手机，格子 314.5px）：封面 242.2 + 8 + 标题 40.5 =
/// 290.5，副标题行与热度行各 18.3。生产数据下作者 / 评分 / 推荐 /
/// rankTags 全空、只有备注 ep 会触发热度行，卡片 308.8px 仍装得下，
/// 与原来带副标题行的卡片同高；只有两者同时出现（取数层补回作者 /
/// 评分后才可能）才会超格子约 13px，届时须同步调格子，不在本项范围。
class _AdultNovelCard extends StatelessWidget {
  const _AdultNovelCard({
    required this.item,
    required this.rank,
    required this.onTap,
  });

  final MediaItem item;
  final int rank;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final heat = _heatLine(item);
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HomeMediaCard(item: item, onTap: onTap),
            if (heat.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                heat,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.3,
                  color: palette.muted,
                ),
              ),
            ],
          ],
        ),
        Positioned(
          left: 6,
          top: 6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xB3000000),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'TOP $rank',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                height: 1.1,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 排行榜同款卡：封面 + TOP 角标 + 标题 + 热度行。
///
/// 照首页排行榜的样子画：封面左上角 TOP 1/2/3 黑底白字角标（只前三名
/// 有，见 home_cell_blocks.dart 的 _RankCover）、标题两行、下方一行
/// 热度数字。名次就是混排后的顺序（核心站在前，登记源在后）。
///
/// 只给漫画 / 听书路用。小说路不用它：小说路用上面的 _AdultNovelCard
///（同一套 HomeMediaCard，外面叠名次角标与热度行），与小说 tab /
/// 核心小说分类页一模一样。
class _AdultRankCard extends StatelessWidget {
  const _AdultRankCard({
    required this.item,
    required this.rank,
    required this.onTap,
  });

  final MediaItem item;
  final int rank;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final meta = _heatLine(item);
    return HomePressable(
      key: ValueKey('adult-rank-$rank'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      semanticLabel: '第$rank名 ${item.title}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 5 / 7,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  StoryCover(item: item, cacheWidth: 200),
                  if (rank <= 3)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xB3000000),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'TOP $rank',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            height: 1.1,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: scaler.scale(13) * 1.35 * 2,
            child: Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: palette.ink,
              ),
            ),
          ),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.3,
                color: palette.muted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 热度行：排行标签优先（服务端给的「9179万热度」这类原文）；没有时看
/// 备注：站方给的播放量（hsvoice31 的「17万」）补「热度」二字；其他
/// 备注（时长「10:48」、集数）原样显示，不硬凑热度；都没有就不渲染该行。
String _heatLine(MediaItem item) {
  if (item.rankTags.isNotEmpty) return item.rankTags.first;
  final ep = item.ep;
  if (ep.isEmpty) return '';
  if (RegExp(r'^[\d.]+万$').hasMatch(ep)) return '$ep热度';
  return ep;
}
