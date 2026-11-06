import 'dart:async';

import 'package:flutter/material.dart';

/// 直播睡眠定时：对齐火蚁TV 的 SleepTimerController。
///
/// 火蚁TV 的定时器是纯 Dart Timer + ChangeNotifier，不依赖账号与存储；
/// 直播只给关闭 / 15 / 30 / 60 / 90 分钟五档（不含点播的「播完本集」）。
/// 内嵌页与全屏页共用同一个单例：到期时调当前播放页登记的
/// [pausePlayback]（内嵌页登记暂停内嵌播放器，全屏页登记暂停全屏播放器），
/// 并置 [sleepPaused]，切回内嵌后不再自动续播，手动点播放才恢复。
class LiveSleepTimer extends ChangeNotifier {
  LiveSleepTimer._();

  static final LiveSleepTimer instance = LiveSleepTimer._();

  DateTime? _deadline;
  Timer? _ticker;
  Timer? _expiry;

  /// 到期时由当前播放页执行的暂停动作。
  VoidCallback? pausePlayback;

  /// 定时到期后暂停过一次。手动点播放 / 换台时清掉。
  bool sleepPaused = false;

  bool get active => _deadline != null;

  Duration? get remaining {
    final deadline = _deadline;
    if (deadline == null) return null;
    final value = deadline.difference(DateTime.now());
    return value.isNegative ? Duration.zero : value;
  }

  String get label {
    final value = remaining;
    if (value == null) return '';
    final minutes = (value.inSeconds / 60).ceil();
    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      final rest = minutes % 60;
      return rest == 0 ? '$hours 时' : '$hours 时 $rest 分';
    }
    return '$minutes 分';
  }

  /// 当前落在哪一档，用于弹层里打勾。没定时返回 off。
  LiveSleepTimerChoice get current {
    final value = remaining;
    if (value == null) return LiveSleepTimerChoice.off;
    final minutes = (value.inSeconds / 60).ceil();
    if (minutes <= 15) return LiveSleepTimerChoice.minutes15;
    if (minutes <= 30) return LiveSleepTimerChoice.minutes30;
    if (minutes <= 60) return LiveSleepTimerChoice.minutes60;
    return LiveSleepTimerChoice.minutes90;
  }

  void select(LiveSleepTimerChoice choice) {
    if (choice == LiveSleepTimerChoice.off) {
      cancel();
    } else {
      startMinutes(choice.minutes!);
    }
  }

  void startMinutes(int minutes) {
    cancel();
    sleepPaused = false;
    _deadline = DateTime.now().add(Duration(minutes: minutes));
    _expiry = Timer(Duration(minutes: minutes), () {
      cancel();
      sleepPaused = true;
      pausePlayback?.call();
      notifyListeners();
    });
    _startTicker();
    notifyListeners();
  }

  void cancel() {
    _expiry?.cancel();
    _expiry = null;
    _ticker?.cancel();
    _ticker = null;
    final wasActive = _deadline != null;
    _deadline = null;
    if (wasActive) notifyListeners();
  }

  void clearSleepPaused() {
    sleepPaused = false;
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 15), (_) {
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _expiry?.cancel();
    _ticker?.cancel();
    _ticker = null;
    super.dispose();
  }
}

enum LiveSleepTimerChoice {
  off,
  minutes15,
  minutes30,
  minutes60,
  minutes90;

  String get label => switch (this) {
    LiveSleepTimerChoice.off => '关闭睡眠定时',
    LiveSleepTimerChoice.minutes15 => '15 分钟',
    LiveSleepTimerChoice.minutes30 => '30 分钟',
    LiveSleepTimerChoice.minutes60 => '60 分钟',
    LiveSleepTimerChoice.minutes90 => '90 分钟',
  };

  int? get minutes => switch (this) {
    LiveSleepTimerChoice.minutes15 => 15,
    LiveSleepTimerChoice.minutes30 => 30,
    LiveSleepTimerChoice.minutes60 => 60,
    LiveSleepTimerChoice.minutes90 => 90,
    _ => null,
  };
}

/// 睡眠定时弹层：选项与文案与火蚁TV 的 showSleepTimerSheet 一致
///（关闭 / 15 / 30 / 60 / 90 分钟，标题「睡眠定时」或「睡眠定时 · X」）。
/// 弹层形态与火蚁TV 一致：GlassDialog 对话框（淡入 + 0.96→1 缩放），
/// 不是底部弹层。修仙版没有 GlassDialog 组件，这里按火蚁TV
/// glass_panel.dart 的 GlassDialog 原样做了一个本地同款
///（深色底 0xFF16171B、圆角 24、白色描边、最大宽 320）。
Future<void> showLiveSleepTimerDialog(BuildContext context) async {
  final timer = LiveSleepTimer.instance;
  final options = const [
    LiveSleepTimerChoice.off,
    LiveSleepTimerChoice.minutes15,
    LiveSleepTimerChoice.minutes30,
    LiveSleepTimerChoice.minutes60,
    LiveSleepTimerChoice.minutes90,
  ];
  final picked = await showGeneralDialog<LiveSleepTimerChoice>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black26,
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: .96, end: 1).animate(curved),
          child: child,
        ),
      );
    },
    pageBuilder: (dialogContext, _, _) => Theme(
      data: ThemeData.dark(),
      child: AnimatedBuilder(
        animation: timer,
        builder: (_, _) => _LiveGlassDialog(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 10, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 4),
                  child: Text(
                    timer.active ? '睡眠定时 · ${timer.label}' : '睡眠定时',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                for (final option in options)
                  InkWell(
                    key: ValueKey('live-sleep-timer-${option.name}'),
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => Navigator.pop(dialogContext, option),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 9,
                        horizontal: 10,
                      ),
                      child: Text(
                        option.label,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('返回播放'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  if (picked == null) return;
  timer.select(picked);
}

/// 火蚁TV GlassDialog 的本地同款（见 tree_104 glass_panel.dart）：
/// 不透明底色加高光描边，播放视频等明暗不断变化的背景上不产生闪烁。
class _LiveGlassDialog extends StatelessWidget {
  const _LiveGlassDialog({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Dialog(
      elevation: 0,
      backgroundColor: dark ? const Color(0xFF16171B) : const Color(0xFFF8F6F5),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(24)),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(24)),
          border: Border.all(
            color: Colors.white.withValues(alpha: dark ? .14 : .9),
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: child,
        ),
      ),
    );
  }
}
