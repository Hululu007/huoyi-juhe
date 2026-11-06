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
Future<void> showCultivationLevelUpDialog(
  BuildContext context, {
  required List<int> crossedRealmIndexes,
  required List<String> adultRegistryOrder,
  required int newXp,
}) {
  if (crossedRealmIndexes.isEmpty) return Future<void>.value();
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: const Text('恭喜突破！'),
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
                '当前总修为 $newXp',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      );
    },
  );
}

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
    final realm = cultivationRealms[realmIndex];
    final info = realmForXp(realm.threshold);
    final zones = realmUnlockZones(realmIndex);
    final tier = realmUnlockAdultTier(realmIndex);
    final tierSites = tier == null
        ? const <String>[]
        : adultTierSiteIds(tier, adultRegistryOrder);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '突破${info.displayName}',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        for (final zone in zones) Text('· $zone'),
        if (tierSites.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            '· 影视区第 ${tier! + 1} 档站（${tierSites.length} 个）：'
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
