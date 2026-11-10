import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import '../../services/drama_site_content.dart';
import 'home_design.dart';
import 'home_media_card.dart';

/// 魔蚁风频道分类卡片（只借图里的版式，不拷魔蚁代码）。
///
/// 图里样式：2 列大卡、圆角 14、紫色描边、右上角角标（HD 青 / NEW 粉）、
/// 底部标题白字 + 分类小字灰字（盖在海报下缘的黑色渐变上）。
/// 左列卡高、右列卡矮（左列约 9:16、右列约 9:10），两列错开排。
///
/// 角标只按站方备注（`DramaSiteItem.remark`）里的真实信号判，不编数据：
/// 备注里有日期（`2026-11-09` / `11-09`）→ NEW；否则备注里有
/// 高清/超清/蓝光/1080/4K/720P/HD → HD；都没有就不挂角标。
/// 完结只按备注里「完结/全集/已完结/大结局」判；「共 N 集」不是完结。
enum MoyiChannelBadge { hd, fresh }

/// 备注里是否写着完结。
bool moyiIsFinished(String remark) =>
    remark.contains('完结') ||
    remark.contains('全集') ||
    remark.contains('大结局');

/// 备注里的日期（`yyyy-MM-dd` / `yyyy/MM/dd` / `MM-dd`，后者按当年算）；
/// 没有日期返回 null。最新排序就用它——站方没给时间字段时，
/// 这是备注里唯一的时间信号，解析不到的排在后面、保持原顺序。
DateTime? moyiRemarkDate(String remark) {
  final full = RegExp(
    r'(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})',
  ).firstMatch(remark);
  if (full != null) {
    final date = DateTime.tryParse(
      '${full[1]}-${full[2]!.padLeft(2, '0')}-${full[3]!.padLeft(2, '0')}',
    );
    if (date != null) return date;
  }
  final short = RegExp(r'(\d{1,2})[-/.](\d{1,2})').firstMatch(remark);
  if (short != null) {
    return DateTime.tryParse(
      '${DateTime.now().year}-${short[1]!.padLeft(2, '0')}-${short[2]!.padLeft(2, '0')}',
    );
  }
  return null;
}

/// 备注里的集数（「更新至 N 集」「共 N 集」「第 N 集」）；没有返回 null。
int? moyiEpisodeNumber(String remark) {
  final match = RegExp(r'(?:更新至|共|第)\s*(\d+)\s*集').firstMatch(remark);
  if (match == null) return null;
  return int.tryParse(match[1]!);
}

/// 备注 → 角标：有日期 NEW，否则有画质词 HD，否则无角标。
MoyiChannelBadge? moyiBadgeForRemark(String remark) {
  if (moyiRemarkDate(remark) != null) return MoyiChannelBadge.fresh;
  final lower = remark.toLowerCase();
  if (lower.contains('高清') ||
      lower.contains('超清') ||
      lower.contains('蓝光') ||
      lower.contains('1080') ||
      lower.contains('4k') ||
      lower.contains('720p') ||
      lower.contains('hd')) {
    return MoyiChannelBadge.hd;
  }
  return null;
}

/// 频道分类网格里的一部作品：站方条目 + 它所属的分类 + 取数时的位置。
///
/// [categorySiteCount] 是该分类在统一数据里的站数（热门排序的热度信号：
/// 越多站有这个分类越热）；[index] 是它在站内目录页里的位置。
class MoyiChannelWork {
  const MoyiChannelWork({
    required this.item,
    required this.siteId,
    required this.siteName,
    required this.category,
    this.categorySiteCount = 0,
    this.index = 0,
  });

  final DramaSiteItem item;
  final String siteId;
  final String siteName;
  final String category;
  final int categorySiteCount;
  final int index;

  DateTime? get remarkDate => moyiRemarkDate(item.remark);
  int? get episodeNumber => moyiEpisodeNumber(item.remark);
  bool get isFinished => moyiIsFinished(item.remark);
  MoyiChannelBadge? get badge => moyiBadgeForRemark(item.remark);

  /// 底部第二行小字：分类 + 备注（有备注才拼，没有只剩分类）。
  String get subtitle => item.remark.isEmpty
      ? category
      : '$category · ${item.remark}';
}

/// 魔蚁风频道分类卡片：海报 + 右上角标 + 底部标题/分类小字。
class MoyiChannelCard extends StatelessWidget {
  const MoyiChannelCard({
    super.key,
    required this.work,
    required this.aspectRatio,
    required this.onTap,
  });

  final MoyiChannelWork work;
  final double aspectRatio;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final badge = work.badge;
    return HomePressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      semanticLabel: work.item.title,
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: Container(
          key: ValueKey('moyi_card_${work.siteId}_${work.item.id}'),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: const Color(0xFF8B5CF6),
              width: 1.5,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              StoryCover(
                item: MediaItem(
                  id: work.item.id,
                  title: work.item.title,
                  cover: work.item.cover,
                  author: '',
                  badge: '',
                  ep: work.item.remark,
                  kind: 'film',
                ),
                cacheWidth: 360,
              ),
              // 底部黑色渐变：标题/分类小字压在上面才读得清。
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Color(0x66000000),
                      Color(0xD9000000),
                    ],
                    stops: [0.55, 0.78, 1],
                  ),
                ),
              ),
              if (badge != null)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    key: ValueKey(
                      'moyi_badge_${work.siteId}_${work.item.id}',
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: badge == MoyiChannelBadge.fresh
                          ? const Color(0xFFFF4D8D)
                          : const Color(0xFF22D3EE),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      badge == MoyiChannelBadge.fresh ? 'NEW' : 'HD',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      work.item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      work.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFFC9C4DE),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 频道分类作品网格：两列错开排——偶数位进左列（高卡 9:16），
/// 奇数位进右列（矮卡 9:10），与图里左高右矮两列一致。
class MoyiChannelWorksGrid extends StatelessWidget {
  const MoyiChannelWorksGrid({
    super.key,
    required this.works,
    required this.onTap,
  });

  final List<MoyiChannelWork> works;
  final ValueChanged<MoyiChannelWork> onTap;

  @override
  Widget build(BuildContext context) {
    final left = <MoyiChannelWork>[];
    final right = <MoyiChannelWork>[];
    for (var i = 0; i < works.length; i++) {
      if (i.isEven) {
        left.add(works[i]);
      } else {
        right.add(works[i]);
      }
    }
    Widget column(List<MoyiChannelWork> items, double aspectRatio) {
      return Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            MoyiChannelCard(
              work: items[i],
              aspectRatio: aspectRatio,
              onTap: () => onTap(items[i]),
            ),
          ],
        ],
      );
    }

    return SingleChildScrollView(
      key: const ValueKey('moyi_works_grid'),
      padding: const EdgeInsets.fromLTRB(10, 10, 12, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: column(left, 9 / 16)),
          const SizedBox(width: 10),
          Expanded(child: column(right, 9 / 10)),
        ],
      ),
    );
  }
}
