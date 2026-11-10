import 'package:flutter/material.dart';

import '../services/game_service.dart';

/// 进站现在免费（游戏节点与影视区进站都不扣元宝），进站被拦的弹窗
/// 已删除：境界不够在游戏节点点按前就显示锁定，进去了就不再拦。
/// 这里只剩看片被拦的弹窗。

/// 影视区看片被拦时的提示：点一部片子进详情页要扣 20 元宝，余额
/// 不足 20 就进不了详情页。写清片名、档位、应扣多少、现在有多少、
/// 还差多少，以及去哪赚元宝。详情页里没有切游戏 tab 的口子，
/// 这里只有“知道了”，文案里写明去影视区右上角点「游戏」。
Future<void> showAdultFilmBlockedDialog(
  BuildContext context,
  AdultSiteEntryOutcome outcome,
) async {
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('元宝不够，看不了这部片子'),
      content: Text(
        '看「${outcome.label}」要扣 ${outcome.cost} 元宝'
        '（${outcome.tierLabel}），你现在有 ${outcome.balance} 元宝，'
        '还差 ${outcome.shortfall} 元宝。\n\n去游戏里打怪、爬塔、'
        '推图主线赚元宝（影视区右上角点「游戏」），回来再看。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}
