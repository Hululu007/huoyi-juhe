import 'package:flutter/material.dart';

import '../services/cultivation.dart';
import '../services/drama_sites.dart';

/// 升境庆祝弹窗：修为跨过境界门槛时弹出，列出新境界与新解锁的内容区
/// （漫画/听书/影视区档位/称号）与新解锁的成人站。
///
/// 成人站只列站名（登记表里查得到名字的用名字，查不到的用 id）；
/// 一档站多时只列前 6 个、后面写「等 N 个」，免得弹窗过长。
/// 调用方（壳层监听修为变化）负责判断跨没跨境界、只在跨过时调；
/// 兑换码成功后修为跳变也会走同一条监听，不用设置页另弹。
///
/// 文案按《凡人修仙传》游戏广告风（草稿 ~/workspace/cultivation_copy/
/// xiuxian_wenan.md，用户 2026-11-06 定稿）：标题按境界换，解锁行
/// 前缀统一为「新开：」，页脚显示下一境与还差修为。
Future<void> showCultivationLevelUpDialog(
  BuildContext context, {
  required List<int> crossedRealmIndexes,
  required List<String> adultRegistryOrder,
  required int newXp,
}) {
  if (crossedRealmIndexes.isEmpty) return Future<void>.value();
  final current = realmForXp(newXp);
  final topRealmIndex = crossedRealmIndexes.reduce(
    (a, b) => a > b ? a : b,
  );
  final dialogTitle =
      _realmLevelUpTitles[topRealmIndex] ?? '恭喜突破！';
  final footerText = current.nextRealmName == null
      ? '当前修为 $newXp · 已登顶，无上之境'
      : '当前修为 $newXp · 下一境${current.nextRealmName}，'
          '还差 ${current.xpToNext} 修为';
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: Text(dialogTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final realmIndex in crossedRealmIndexes) ...[
                _RealmUnlockSection(
                  realmIndex: realmIndex,
                  adultRegistryOrder: adultRegistryOrder,
                  theme: theme,
                ),
                const SizedBox(height: 12),
              ],
              Text(
                footerText,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('入境一观'),
          ),
        ],
      );
    },
  );
}

/// 升境弹窗标题（按境界换；炼气期是开局境界，不会跨入，故从筑基期起）。
const _realmLevelUpTitles = <int, String>{
  1: '筑基已成，道基初铸！',
  2: '金丹已结，道途再进！',
  3: '元婴已成，影视区开！',
  4: '化神在望，全境洞开！',
  5: '炼虚破境，再开一档！',
  6: '合体大成，诸站尽开！',
  7: '大乘再进，离仙又近一步。',
  8: '渡劫在即，天雷亦不惧。',
  9: '真仙已证，位列仙班！',
  10: '金仙不朽，仙光护体！',
  11: '太乙临尘，仙中称尊！',
  12: '超凡入化，大罗金仙！',
  13: '唯我独尊，道祖临世！',
};

/// 升境弹窗副标题（境界标题下一行；与标题一一对应）。
const _realmLevelUpSubtitles = <int, String>{
  1: '苦修不辍，今日筑基。',
  2: '一颗金丹吞入腹，始知我命不由天。',
  3: '元婴出窍，天地任逍遥。',
  4: '化神一成，万境皆通。',
  5: '炼虚合道，登天又一步。',
  6: '合体已成，凡界再无锁。',
  7: '大乘之境，静待渡劫。',
  8: '九死一生，方证真仙。',
  9: '凡尘已了，仙路方开。',
  10: '金身已铸，万劫不磨。',
  11: '太乙之境，俯瞰众生。',
  12: '跳出三界，不在五行。',
  13: '十四境登顶，大道尽在掌中。',
};

class _RealmUnlockSection extends StatelessWidget {
  const _RealmUnlockSection({
    required this.realmIndex,
    required this.adultRegistryOrder,
    required this.theme,
  });

  final int realmIndex;
  final List<String> adultRegistryOrder;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final zones = realmUnlockZones(realmIndex);
    final tier = realmUnlockAdultTier(realmIndex);
    final tierSites = tier == null
        ? const <String>[]
        : adultTierSiteIds(tier, adultRegistryOrder);
    final subtitle = _realmLevelUpSubtitles[realmIndex];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (subtitle != null) ...[
          Text(subtitle, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
        ],
        for (final zone in zones) Text('新开：$zone'),
        if (tierSites.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            '新开：影视区第 ${tier! + 1} 档站（${tierSites.length} 个）：'
            '${_siteNamesPreview(tierSites)}',
          ),
        ],
      ],
    );
  }

  /// 站名预览：前 6 个站名用顿号连起来，多的写「等 N 个」。
  String _siteNamesPreview(List<String> siteIds) {
    const previewCount = 6;
    final names = siteIds.map(_siteDisplayName).toList();
    if (names.length <= previewCount) return names.join('、');
    final shown = names.take(previewCount).join('、');
    return '$shown等 ${names.length} 个';
  }

  /// 站的显示名：短剧站表里查得到用名字，查不到（核心站）用 id。
  String _siteDisplayName(String siteId) {
    for (final site in dramaSites) {
      if (site.id == siteId) return site.name;
    }
    return siteId;
  }
}
