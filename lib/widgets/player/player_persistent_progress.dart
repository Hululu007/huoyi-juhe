import 'package:flutter/material.dart';

import '../../services/native_player.dart';

/// 常驻进度细条：对照 hongguoTV `PlaybackProgressDisplay`
///（`kotlin-tv/core/.../ViewingTools.kt`：控件收起时仍显示一条细进度）。
///
/// 树里原来的进度条（chrome 的 `video-seek`）只在控件可见时出现，
/// 3 秒收起后画面上没有任何进度。本条贴在视频画面底缘，只读不交互
///（不抢 chrome 的手势），进度跟 `NativePlayer.positionStream` 走，
/// 不另起 Timer。
/// 显隐由宿主传 `visible` 定：只在 chrome 的 seek 栏不在屏时显示，
/// seek 栏在屏时藏起来（竖屏浏览态下控制收起后信息区还留着 seek 栏，
/// 所以不能只看控件显隐）；播完/出错时宿主同样传 `visible: false`。
class PlayerPersistentProgress extends StatelessWidget {
  const PlayerPersistentProgress({
    super.key,
    required this.player,
    required this.duration,
    this.visible = true,
  });

  final NativePlayer? player;
  final Duration duration;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final current = player;
    if (!visible || current == null || duration <= Duration.zero) {
      return const SizedBox.shrink();
    }
    return StreamBuilder<Duration>(
      stream: current.positionStream,
      initialData: current.position,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final value = (position.inMilliseconds / duration.inMilliseconds)
            .clamp(0.0, 1.0);
        return LinearProgressIndicator(
          value: value,
          minHeight: 3,
          backgroundColor: const Color(0x4DFFFFFF),
          valueColor: const AlwaysStoppedAnimation<Color>(
            Color(0xFFFA6725),
          ),
        );
      },
    );
  }
}
