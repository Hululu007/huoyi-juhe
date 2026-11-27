import 'package:flutter/material.dart';

import '../../actress/actress_avatar.dart';
import '../../actress/actress_global_search.dart';
import '../../actress/actress_neon.dart';
import '../home/home_shelf.dart';
import '../series_detail/moyi_detail_theme.dart';

/// 首页全局搜索结果里的演员库两段（演员 / 作品）的 sliver 组。
///
/// 版式口径：与搜索页既有分段（番茄网格、全部站点）同一套
/// 段头与网格；卡片本体照演员库现行卡片——演员卡是圆头像 +
/// 名字 + 「作品 N 部」，作品卡是海报 + 标题 + 番号·日期副行
/// （与演员库页 _localCard / 演员网格卡同形态）。两段各有上
/// 限，段头带「更多」进演员库继续看；结果为空/没库时整组不
/// 出（调用方传 result == null 且非 loading 时返回空组）。
List<Widget> actressSearchSectionSlivers({
  required BuildContext context,
  required double width,
  required bool loading,
  required ActressGlobalSearchResult? result,
  required void Function(String name) onActress,
  required void Function(Map<String, dynamic> work) onWork,
  required VoidCallback onMoreActresses,
  required VoidCallback onMoreWorks,
}) {
  if (result == null) {
    if (!loading) return const [];
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(homeGutter, 20, homeGutter, 8),
          child: Row(
            children: [
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: moyiMutedOnDark,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                '正在搜索演员库…',
                style: TextStyle(fontSize: 13, color: moyiMutedOnDark),
              ),
            ],
          ),
        ),
      ),
    ];
  }
  if (result.isEmpty) return const [];
  return [
    if (result.actresses.isNotEmpty) ...[
      _sectionHeader(
        title: '演员库 · 演员',
        hasMore: result.actressesHasMore,
        moreKey: const ValueKey('global-actress-more'),
        onMore: onMoreActresses,
      ),
      SliverToBoxAdapter(
        child: SizedBox(
          height: 136,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: homeGutter),
            itemCount: result.actresses.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) =>
                ActressSearchActressCard(row: result.actresses[i], onTap: onActress),
          ),
        ),
      ),
    ],
    if (result.works.isNotEmpty) ...[
      _sectionHeader(
        title: '演员库 · 作品',
        hasMore: result.worksHasMore,
        moreKey: const ValueKey('global-work-more'),
        onMore: onMoreWorks,
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: homeGutter),
        sliver: SliverGrid(
          gridDelegate: homeShelfDelegate(context, width),
          delegate: SliverChildBuilderDelegate((context, i) {
            final row = result.works[i];
            return ActressSearchWorkCard(
              row: row,
              onTap: () => onWork(row),
            );
          }, childCount: result.works.length),
        ),
      ),
    ],
  ];
}

Widget _sectionHeader({
  required String title,
  required bool hasMore,
  required Key moreKey,
  required VoidCallback onMore,
}) {
  return SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(homeGutter, 20, homeGutter, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
          if (hasMore)
            TextButton(
              key: moreKey,
              onPressed: onMore,
              style: TextButton.styleFrom(
                foregroundColor: moyiGold,
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                '更多 ›',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    ),
  );
}

/// 演员卡：与演员库演员网格卡同形态（霓虹卡面 + 圆头像 +
/// 名字 + 作品数）。点卡进该演员的演员页（外部由调用方接）。
class ActressSearchActressCard extends StatelessWidget {
  const ActressSearchActressCard({
    super.key,
    required this.row,
    required this.onTap,
  });

  final Map<String, dynamic> row;
  final void Function(String name) onTap;

  @override
  Widget build(BuildContext context) {
    final name = (row['name'] ?? '').toString();
    final avatar = (row['avatar'] ?? '').toString();
    final count = (row['count'] as num?)?.toInt() ?? 0;
    return InkWell(
      key: ValueKey('global-actress-$name'),
      onTap: () => onTap(name),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 84,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: actressNeonCardDecoration(radius: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 52,
              height: 52,
              child: ClipOval(
                child: ActressAvatar(name: name, avatarUrl: avatar),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Neon.text,
                fontSize: 12.5,
                height: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '作品 $count 部',
              style: const TextStyle(
                color: Neon.textDim,
                fontSize: 11,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 作品卡：与演员库本地作品卡同形态（海报 + 标题 + 番号·
/// 日期/女优副行，无封面时番号占位）。点卡进作品详情页。
class ActressSearchWorkCard extends StatelessWidget {
  const ActressSearchWorkCard({super.key, required this.row, required this.onTap});

  final Map<String, dynamic> row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final vodId = (row['vodId'] ?? '').toString();
    final code = (row['code'] ?? '').toString();
    final date = (row['date'] ?? '').toString();
    final actress = (row['actress'] ?? '').toString();
    final pic = (row['pic'] ?? '').toString();
    final subtitle = [
      if (code.isNotEmpty) code,
      if (date.isNotEmpty) date else if (actress.isNotEmpty) actress,
    ].join(' · ');
    return InkWell(
      key: ValueKey('global-work-$vodId'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: actressNeonCardDecoration(radius: 10),
              clipBehavior: Clip.antiAlias,
              child: Container(
                color: Neon.surface,
                width: double.infinity,
                height: double.infinity,
                child: pic.isEmpty
                    ? Center(
                        child: Text(
                          code.isEmpty ? 'NV' : code,
                          style: const TextStyle(
                            color: Neon.textDim,
                            fontSize: 12,
                          ),
                        ),
                      )
                    : Image.network(
                        pic,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            (row['title'] ?? '').toString(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Neon.text, fontSize: 12, height: 1.3),
          ),
          if (subtitle.isNotEmpty)
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Neon.textDim, fontSize: 10.5),
            ),
        ],
      ),
    );
  }
}
