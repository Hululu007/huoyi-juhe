import 'package:flutter/material.dart';

import '../../services/native_player.dart';
import '../../services/player_tracks.dart';
import '../home/home_sheet.dart';

/// 音轨/字幕轨选择层（同步批 A8）：打开时向宿主实时枚举轨道，
/// 点选即切、切完重新枚举刷新选中态；字幕首条恒「关闭字幕」。
/// 枚举不到任何轨道时明说「当前视频没有可选轨道」，不给假入口。
Future<void> showPlayerTrackPicker({
  required BuildContext context,
  required NativePlayer player,
}) {
  return showHomeSheet<void>(
    context: context,
    title: '音轨与字幕',
    children: [_TrackPickerBody(player: player)],
  );
}

class _TrackPickerBody extends StatefulWidget {
  const _TrackPickerBody({required this.player});

  final NativePlayer player;

  @override
  State<_TrackPickerBody> createState() => _TrackPickerBodyState();
}

class _TrackPickerBodyState extends State<_TrackPickerBody> {
  bool _loading = true;
  List<PlayerTrackInfo> _audio = const [];
  List<PlayerTrackInfo> _subtitles = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final tracks = await widget.player.getTracks();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _audio = tracks.audio;
      _subtitles = tracks.subtitles;
    });
  }

  Future<void> _pickAudio(TrackMenuEntry entry) async {
    await widget.player.selectAudioTrack(entry.id);
    await _reload();
  }

  Future<void> _pickSubtitle(TrackMenuEntry entry) async {
    await widget.player.selectSubtitleTrack(
      entry.kind == TrackMenuKind.subtitleOff ? null : entry.id,
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final audioMenu = buildAudioMenu(_audio);
    final subtitleMenu = buildSubtitleMenu(_subtitles);
    if (audioMenu.isEmpty && _subtitles.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text('当前视频没有可选的音轨或字幕轨'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (audioMenu.isNotEmpty) ...[
          const _SectionTitle('音轨'),
          for (final entry in audioMenu)
            _TrackRow(entry: entry, onTap: () => _pickAudio(entry)),
        ],
        const _SectionTitle('字幕'),
        for (final entry in subtitleMenu)
          _TrackRow(entry: entry, onTap: () => _pickSubtitle(entry)),
      ],
    );
  }
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

class _TrackRow extends StatelessWidget {
  const _TrackRow({required this.entry, required this.onTap});

  final TrackMenuEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(entry.label),
      trailing: entry.selected
          ? Icon(
              Icons.check,
              color: Theme.of(context).colorScheme.primary,
            )
          : null,
      onTap: onTap,
    );
  }
}
