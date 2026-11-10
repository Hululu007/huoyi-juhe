import 'package:flutter/material.dart';

import '../widgets/series_detail/moyi_detail_theme.dart';

/// 直播状态面板：对齐火蚁TV 的 StatusPanel（图标 + 标题 + 说明 +
/// 主按钮 + 可选次要操作），供直播列表页与播放页共用。
/// 修仙版没有 StatusPanel / AppNotice，用同版式同文案的本地实现。
class LiveStatusPanel extends StatelessWidget {
  const LiveStatusPanel({
    super.key,
    required this.title,
    this.message = '',
    this.icon = Icons.live_tv_rounded,
    this.action,
    this.onRetry,
    this.secondaryAction,
  });

  final String title;
  final String message;
  final IconData icon;
  final String? action;
  final VoidCallback? onRetry;
  final Widget? secondaryAction;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: moyiCyan),
          const SizedBox(height: 20),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (message.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: moyiBodyOnDark),
            ),
          ],
          if (onRetry != null) ...[
            const SizedBox(height: 24),
            MoyiGradientButton(
              label: action ?? '重试',
              icon: Icons.refresh_rounded,
              onPressed: onRetry,
            ),
          ],
          if (secondaryAction != null) ...[
            const SizedBox(height: 8),
            secondaryAction!,
          ],
        ],
      ),
    ),
  );
}
