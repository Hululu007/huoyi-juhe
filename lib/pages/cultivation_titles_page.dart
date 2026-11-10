import 'package:flutter/material.dart';

import '../services/cultivation.dart';
import '../widgets/cultivation_title_label.dart';
import '../widgets/series_detail/moyi_detail_theme.dart';

/// 称号排行榜页：按修为从低到高列 14 档（每境一行）。
///
/// 每行写名次、称号名（无称号的行写「—」）、所需修为与对应境界、
/// 达成状态。当前境界行高亮并标「当前」，已达成的行标「已达成」，
/// 未达成的行灰掉（称号用 [CultivationTitleLabel] 的 dimmed 显示）。
///
/// [snapshot] 为空时读 [CultivationService.instance] 的实时快照；
/// 单测可直接传假快照，不碰 SharedPreferences。
class CultivationTitlesPage extends StatefulWidget {
  const CultivationTitlesPage({super.key, this.snapshot});

  /// 注入的快照（单测用）；为空时读修为服务。
  final CultivationSnapshot? snapshot;

  /// 每行固定高度，首次进页按它算偏移跳到当前行附近。
  static const double rowHeight = 72;

  @override
  State<CultivationTitlesPage> createState() => _CultivationTitlesPageState();
}

class _CultivationTitlesPageState extends State<CultivationTitlesPage> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final snapshot = widget.snapshot ?? CultivationService.instance.snapshot;
      final ladder = cultivationTitleLadder(
        sect: snapshot.sect.isEmpty ? null : snapshot.sect,
      );
      final current = currentTitleTierIndex(snapshot.totalXp, ladder);
      final offset = ((current - 1) * CultivationTitlesPage.rowHeight).clamp(
        0.0,
        _controller.position.maxScrollExtent,
      );
      _controller.jumpTo(offset);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.snapshot != null) {
      return _buildScaffold(widget.snapshot!);
    }
    return ValueListenableBuilder<CultivationSnapshot>(
      valueListenable: CultivationService.instance.snapshotNotifier,
      builder: (context, snapshot, _) => _buildScaffold(snapshot),
    );
  }

  Widget _buildScaffold(CultivationSnapshot snapshot) {
    final ladder = cultivationTitleLadder(
      sect: snapshot.sect.isEmpty ? null : snapshot.sect,
    );
    final xp = snapshot.totalXp;
    final current = currentTitleTierIndex(xp, ladder);
    final theme = Theme.of(context);
    return MoyiPageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          title: const Text('称号排行'),
        ),
        // 只有 14 行，一次建全：单测不用先滚就能找到每一行，
        // 行高固定，首次进页仍按行高算偏移跳到当前行附近。
        body: ListView(
          controller: _controller,
          children: [
            for (var index = 0; index < ladder.length; index++)
              SizedBox(
                height: CultivationTitlesPage.rowHeight,
                child: _TitleRow(
                  key: ValueKey('cultivation_title_row_${ladder[index].rank}'),
                  tier: ladder[index],
                  isCurrent: index == current,
                  achieved: xp >= ladder[index].requiredXp,
                  // 前三特效称号是榜单最后三档：道祖第 1 名、大罗第 2 名、
                  // 太乙第 3 名（太乙的称号用户还没想起名字，先留占位）。
                  topThreePlace: ladder[index].isTopThree
                      ? ladder.length - index
                      : null,
                  theme: theme,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({
    super.key,
    required this.tier,
    required this.isCurrent,
    required this.achieved,
    required this.theme,
    this.topThreePlace,
  });

  final CultivationTitleTier tier;
  final bool isCurrent;
  final bool achieved;
  final ThemeData theme;

  /// 前三名次（1/2/3，第 1 名是道祖）；不是前三为 null。
  final int? topThreePlace;

  @override
  Widget build(BuildContext context) {
    final titleStyle = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w700,
      color: achieved ? Colors.white : moyiMutedOnDark,
    );
    final subStyle = TextStyle(
      fontSize: 12,
      color: achieved ? moyiBodyOnDark : moyiMutedOnDark,
    );
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: topThreePlace == null
                ? Text(
                    '${tier.rank}',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: achieved ? moyiGold : moyiMutedOnDark,
                    ),
                  )
                : _TopThreeMedal(place: topThreePlace!),
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (tier.hasTitle)
                  Row(
                    children: [
                      Flexible(
                        child: CultivationTitleLabel(
                          title: tier.titleName!,
                          effect: tier.effect,
                          style: titleStyle,
                          dimmed: !achieved,
                        ),
                      ),
                      // 前三特效称号单独标注；太乙的称号还是占位，
                      // 标「待起名」，等用户想起名字再换。
                      if (topThreePlace != null) ...[
                        const SizedBox(width: 6),
                        _MiniTag(label: '前三特效', color: const Color(0xFFD4AF37)),
                      ],
                      if (tier.isPlaceholderTitle) ...[
                        const SizedBox(width: 6),
                        const _MiniTag(label: '待起名', color: moyiMutedOnDark),
                      ],
                    ],
                  )
                else
                  Text('—', style: titleStyle),
                const SizedBox(height: 2),
                Text(
                  '${tier.requiredXp} 修为 · ${tier.realmName}',
                  style: subStyle,
                ),
              ],
            ),
          ),
          _StatusChip(isCurrent: isCurrent, achieved: achieved),
        ],
      ),
    );
    if (!isCurrent) return row;
    return Container(
      decoration: const BoxDecoration(
        color: moyiDarkCardFill,
        border: Border(left: BorderSide(color: moyiGold, width: 3)),
      ),
      child: row,
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.isCurrent, required this.achieved});

  final bool isCurrent;
  final bool achieved;

  @override
  Widget build(BuildContext context) {
    final label = isCurrent ? '当前' : (achieved ? '已达成' : '未达成');
    final color = isCurrent
        ? moyiGold
        : (achieved ? Colors.green : moyiMutedOnDark);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// 前三名次奖牌：第 1 名金、第 2 名银、第 3 名铜（圆形底 + 白色名次数字）。
class _TopThreeMedal extends StatelessWidget {
  const _TopThreeMedal({required this.place});

  final int place;

  @override
  Widget build(BuildContext context) {
    final color = switch (place) {
      1 => const Color(0xFFD4AF37),
      2 => const Color(0xFF9AA5B1),
      _ => const Color(0xFFB87333),
    };
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      child: Text(
        '$place',
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// 称号旁的小标签（「前三特效」「待起名」）。
class _MiniTag extends StatelessWidget {
  const _MiniTag({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
