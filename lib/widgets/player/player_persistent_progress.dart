import 'package:flutter/material.dart';

import '../../services/native_player.dart';

/// 常驻进度细条：对照 hongguoTV `PlaybackProgressDisplay`
///（`kotlin-tv/core/.../ViewingTools.kt`：控件收起时仍显示一条细进度）。
///
/// 树里原来的进度条（chrome 的 `video-seek`）只在控件可见时出现，
/// 3 秒收起后画面上没有任何进度。本条贴在视频画面底缘、常驻显示，
/// 只读不交互（不抢 chrome 的手势），播完/出错时宿主传 `visible: false`
/// 藏起来。进度跟 `NativePlayer.positionStream` 走，不另起 Timer。
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
