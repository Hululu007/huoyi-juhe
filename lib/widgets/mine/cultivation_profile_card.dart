import 'package:flutter/material.dart';

import '../../services/cultivation.dart';
import '../cultivation_title_label.dart';
import 'cultivation_profile_card_data.dart';

export 'cultivation_profile_card_data.dart';

/// 我的页顶部深色「道友档案」卡（按用户发的别家截图版式重做）。
///
/// 横向宽卡，占满宽度，深色底 + 金色点缀、圆角；左边约 60% 是信息，
/// 右边约 40% 是精修人物大图（资源图，按性别切换：白发女修 /
/// 蓝金男修），占满卡高，圆角裁切贴合卡片，不用 Flutter 手画小人。
///
/// 左边从上到下：顶部小字“✦ 道友档案 ✦”+ 标题；圆形金边境界徽章；
/// 境界名 + 小档大字（一行，FittedBox 缩小兜底）；观影数据行；
/// 主修 / 境界行；金色进度条；总修为 + 到下一境界差多少；
/// 底部一排小药丸标签（主修 / 灵根 / 宗门 / 职业 / 称号 / 性别）。
/// 只改呈现：境界 / 等级 / 修为 / 称号 / 标签的取值都照现有代码，
/// 不动 cultivation.dart 的算分。
class CultivationProfileCard extends StatelessWidget {
  const CultivationProfileCard({
    super.key,
    required this.totalTitles,
    required this.onOpenTitles,
  });

  /// 看过多少部（去重后的历史条目数，由我的页传入）。
  final int totalTitles;

  /// 打开称号排行榜。
  final VoidCallback onOpenTitles;

  static const _gold = Color(0xFFD4AF37);
  static const _goldBright = Color(0xFFFFD54F);
  static const _muted = Color(0xFF8A93AD);
  static const _subText = Color(0xFFB9C0D6);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CultivationSnapshot>(
      valueListenable: CultivationService.instance.snapshotNotifier,
      builder: (context, snapshot, _) {
        final realm = snapshot.realm;
        final currentTitle = currentTitleTier(
          snapshot.totalXp,
          sect: snapshot.sect,
        );
        final isFemale = snapshot.gender == CultivationGender.female;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF191926), Color(0xFF101018)],
              ),
              border: Border.all(
                color: _gold.withValues(alpha: 0.35),
                width: 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Center(
                      child: Text(
                        '◆ 道友档案 ◆',
                        style: TextStyle(
                          fontSize: 12,
                          letterSpacing: 2,
                          fontWeight: FontWeight.w600,
                          color: _gold,
                        ),
                      ),
                    ),
                  ),
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 6, 10, 14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _titleRow(realm.groupName),
                                const SizedBox(height: 7),
                                _realmRow(context, snapshot, realm),
                                const SizedBox(height: 7),
                                _watchRow(snapshot),
                                const SizedBox(height: 3),
                                _techniqueRow(snapshot, realm),
                                const SizedBox(height: 7),
                                _progressRow(realm, snapshot),
                                const SizedBox(height: 9),
                                _tagsRow(context, snapshot, currentTitle),
                              ],
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 136,
                          child: Image.asset(
                            isFemale
                                ? 'assets/images/cultivation/profile_female.jpg'
                                : 'assets/images/cultivation/profile_male.webp',
                            fit: BoxFit.cover,
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
      },
    );
  }

  Widget _titleRow(String groupName) {
    return Row(
      children: [
        const Icon(Icons.auto_graph, size: 16, color: _goldBright),
        const SizedBox(width: 6),
        const Text(
          '道友档案',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: _gold.withValues(alpha: 0.14),
          ),
          child: Text(
            groupName,
            style: const TextStyle(fontSize: 11, color: _gold),
          ),
        ),
      ],
    );
  }

  Widget _realmRow(
    BuildContext context,
    CultivationSnapshot snapshot,
    RealmInfo realm,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _realmBadge(context, realm),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  realm.displayName,
                  style: const TextStyle(
                    fontSize: 21,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 3),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(9),
                      color: _gold.withValues(alpha: 0.18),
                      border: Border.all(color: _gold.withValues(alpha: 0.5)),
                    ),
                    child: Text(
                      realm.levelLabel,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _gold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: InkWell(
                      onTap: () => _showRenameDialog(context, snapshot),
                      borderRadius: BorderRadius.circular(4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              snapshot.username.isEmpty
                                  ? '道友'
                                  : snapshot.username,
                              style: const TextStyle(
                                fontSize: 13,
                                color: _subText,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 3),
                          const Icon(
                            Icons.edit_outlined,
                            size: 12,
                            color: _muted,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 圆形境界徽章：点开称号排行榜。
  Widget _realmBadge(BuildContext context, RealmInfo realm) {
    return InkWell(
      onTap: onOpenTitles,
      customBorder: const CircleBorder(),
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF23233A),
          border: Border.all(color: _gold, width: 1.5),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              realm.badgeLine1,
              style: const TextStyle(
                fontSize: 11,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: _goldBright,
              ),
            ),
            Text(
              realm.badgeLine2,
              style: const TextStyle(
                fontSize: 10,
                height: 1.2,
                color: _goldBright,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 观影数据行：观影时长 + 看过多少部（照参考图的格式）。
  Widget _watchRow(CultivationSnapshot snapshot) {
    return Text.rich(
      TextSpan(
        children: [
          const TextSpan(
            text: '观影时长 ',
            style: TextStyle(fontSize: 13, color: _gold),
          ),
          TextSpan(
            text: _formatWatchTime(snapshot.totalSeconds),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: _goldBright,
            ),
          ),
          const TextSpan(
            text: ' 观影 ',
            style: TextStyle(fontSize: 13, color: _gold),
          ),
          TextSpan(
            text: '$totalTitles 部',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: _goldBright,
            ),
          ),
        ],
      ),
    );
  }

  /// 主修 / 境界行：主修 + 境界修士（如“主修·小说 · 结丹期修士”）。
  Widget _techniqueRow(CultivationSnapshot snapshot, RealmInfo realm) {
    final main = snapshot.mainCategory;
    final head = main != null
        ? '主修·${cultivationCategoryName(main)}'
        : (snapshot.profession.isNotEmpty ? snapshot.profession : null);
    final text = head == null
        ? '${realm.badgeLine1}修士'
        : '$head · ${realm.badgeLine1}修士';
    return Text(
      text,
      style: const TextStyle(fontSize: 13, color: _gold),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _progressRow(RealmInfo realm, CultivationSnapshot snapshot) {
    if (realm.nextRealmName == null) {
      return const Text(
        '已达顶峰 · 道祖',
        style: TextStyle(fontSize: 12, color: _gold),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: realm.progress,
            minHeight: 6,
            backgroundColor: Colors.white.withValues(alpha: 0.14),
            valueColor: const AlwaysStoppedAnimation<Color>(_gold),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          '总修为 ${formatCultivationXp(snapshot.totalXp)}',
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: _goldBright,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '距离【${realm.nextRealmName}】还差 ${realm.xpToNext} 修为',
          style: const TextStyle(fontSize: 12, color: _subText),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _tagsRow(
    BuildContext context,
    CultivationSnapshot snapshot,
    CultivationTitleTier? currentTitle,
  ) {
    final main = snapshot.mainCategory;
    final tags = <String>[
      if (main != null) '主修·${cultivationCategoryName(main)}',
      '灵根·${snapshot.spiritRoot}',
      if (snapshot.sect.isNotEmpty) '宗门·${snapshot.sect}',
      if (snapshot.profession.isNotEmpty) '职业·${snapshot.profession}',
      if (snapshot.gender != null)
        '性别·${cultivationGenderName(snapshot.gender!)}',
    ];
    // 底部小药丸标签：Wrap 全部露出，不横向滚动藏起来。
    final children = <Widget>[
      for (final tag in tags) _tagPill(tag),
      if (currentTitle?.titleName != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: _gold.withValues(alpha: 0.16),
            border: Border.all(color: _gold.withValues(alpha: 0.4)),
          ),
          child: CultivationTitleLabel(
            title: currentTitle!.titleName!,
            effect: currentTitle.effect,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: _goldBright,
            ),
          ),
        ),
    ];
    return Wrap(spacing: 6, runSpacing: 6, children: children);
  }

  Widget _tagPill(String tag) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Text(tag, style: const TextStyle(fontSize: 10, color: _subText)),
    );
  }

  /// 观影总时长：不足 1 小时显示“x分钟”，否则显示“x.x h”（整小时不带小数）。
  String _formatWatchTime(double totalSeconds) {
    final minutes = totalSeconds / 60;
    if (minutes < 60) return '${minutes.round()}分钟';
    final hours = minutes / 60;
    final value = hours.toStringAsFixed(1);
    final trimmed = value.endsWith('.0')
        ? value.substring(0, value.length - 2)
        : value;
    return '$trimmed h';
  }

  Future<void> _showRenameDialog(
    BuildContext context,
    CultivationSnapshot snapshot,
  ) async {
    final controller = TextEditingController(text: snapshot.username);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('改名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '用户名',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (ok == true) {
      await CultivationService.instance.renameUser(controller.text);
    }
  }
}
