import 'package:flutter/material.dart';

import '../home/home_sheet.dart';
import '../../services/player_display_preferences.dart';
import '../../services/player_sleep_timer.dart';

/// 播放控制弹层：画面模式、旋转、定时停止、跨季连播四组。
///
/// chrome 的「更多」面板不在本次归属内，改不了，所以这四组先落
/// 在这个独立弹层里，由播放页左缘的浮钮打开；状态与落盘都在
/// `lib/services/player_*` 里，chrome 接线后同一批回调可以原样
/// 搬进更多面板。
///
/// 拉伸铺满与 90°/270° 旋转本次接不上播放器布局（见
/// `player_display_preferences.dart` 文件头），行置灰并注明，
/// 不给点上去没反应的假入口。
Future<void> showPlayerPlaybackExtras({
  required BuildContext context,
  required PlayerDisplayMode displayMode,
  required ValueChanged<PlayerDisplayMode> onDisplayModeChanged,
  required int rotation,
  required ValueChanged<int> onRotationChanged,
  required PlayerSleepTimer sleepTimer,
  required ValueChanged<PlayerSleepChoice> onSleepChoice,
  required bool seasonAutoplay,
  required ValueChanged<bool> onSeasonAutoplayChanged,
  required bool autoAdvance,
}) {
  var mode = displayMode;
  var rotationValue = rotation;
  var season = seasonAutoplay;
  return showHomeSheet<void>(
    context: context,
    title: '播放控制',
    children: [
      StatefulBuilder(
        builder: (context, setSheetState) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionTitle('画面模式'),
              _ModeRow(
                modes: PlayerDisplayMode.values,
                current: mode,
                label: (value) => value.label,
                enabled: (value) => value.appliableNow,
                disabledNote: '拉伸铺满待播放器布局接线',
                onSelected: (value) {
                  setSheetState(() => mode = value);
                  onDisplayModeChanged(value);
                },
              ),
              _SectionTitle('旋转'),
              _ModeRow(
                modes: const [0, 90, 180, 270],
                current: rotationValue,
                label: (degrees) => '$degrees°',
                enabled: PlayerRotation.appliableNow,
                disabledNote: '90°/270° 待画面布局接线',
                onSelected: (value) {
                  setSheetState(() => rotationValue = value);
                  onRotationChanged(value);
                },
              ),
              _SectionTitle(
                '定时停止${sleepTimer.active ? ' · ${sleepTimer.label}' : ''}',
              ),
              _ModeRow(
                modes: PlayerSleepChoice.values,
                current: PlayerSleepChoice.currentOf(sleepTimer),
                label: (choice) => choice.label,
                enabled: (_) => true,
                onSelected: (choice) {
                  setSheetState(() {});
                  onSleepChoice(choice);
                },
              ),
              SwitchListTile(
                title: const Text('跨季连播'),
                subtitle: Text(
                  autoAdvance
                      ? '本季播完后自动播放下一季（默认关；当前剧集未提供下一季信息时不触发）'
                      : '需先开启自动连播才生效（当前自动连播是关的）',
                ),
                value: season,
                onChanged: (value) {
                  setSheetState(() => season = value);
                  onSeasonAutoplayChanged(value);
                },
              ),
            ],
          );
        },
      ),
    ],
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// 一组横向排布的选项片：选中的高亮，置灰的不可点并在下方给一句原因。
class _ModeRow<T> extends StatelessWidget {
  const _ModeRow({
    required this.modes,
    required this.current,
    required this.onSelected,
    required this.label,
    this.enabled,
    this.disabledNote,
  });

  final List<T> modes;
  final T current;
  final ValueChanged<T> onSelected;
  final String Function(T value) label;
  final bool Function(T value)? enabled;
  final String? disabledNote;

  @override
  Widget build(BuildContext context) {
    final hasDisabled = modes.any((mode) => !(enabled?.call(mode) ?? true));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final mode in modes)
              ChoiceChip(
                label: Text(label(mode)),
                selected: mode == current,
                onSelected: (enabled?.call(mode) ?? true)
                    ? (_) => onSelected(mode)
                    : null,
              ),
          ],
        ),
        if (hasDisabled && disabledNote != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              disabledNote!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}
