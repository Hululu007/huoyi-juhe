import 'package:flutter/material.dart';

import '../../services/native_player.dart';
import '../../services/player_tracks.dart';
import '../home/home_sheet.dart';

/// 轨道选择层的分段（照录屏改造批）：统一菜单的音轨/视轨/字幕
/// 三行各自只开自己那一段；缺省 all 是原「音轨与字幕」合并层。
enum PlayerTrackSection { all, audio, video, subtitles }

/// 音轨/视轨/字幕轨选择层（同步批 A8，视轨为照录屏改造批补）：
/// 打开时向宿主实时枚举轨道，点选即切、切完重新枚举刷新选中态；
/// 字幕首条恒「关闭字幕」。枚举不到任何轨道时明说「当前视频没有
/// 可选轨道」，不给假入口。
Future<void> showPlayerTrackPicker({
  required BuildContext context,
  required NativePlayer player,
  PlayerTrackSection section = PlayerTrackSection.all,
}) {
  final title = switch (section) {
    PlayerTrackSection.all => '音轨与字幕',
    PlayerTrackSection.audio => '音轨',
    PlayerTrackSection.video => '视轨',
    PlayerTrackSection.subtitles => '字幕',
  };
  return showHomeSheet<void>(
    context: context,
    title: title,
    children: [_TrackPickerBody(player: player, section: section)],
  );
}

class _TrackPickerBody extends StatefulWidget {
  const _TrackPickerBody({required this.player, required this.section});

  final NativePlayer player;
  final PlayerTrackSection section;

  @override
  State<_TrackPickerBody> createState() => _TrackPickerBodyState();
}

class _TrackPickerBodyState extends State<_TrackPickerBody> {
  bool _loading = true;
  List<PlayerTrackInfo> _audio = const [];
  List<PlayerTrackInfo> _video = const [];
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
      _video = tracks.video;
      _subtitles = tracks.subtitles;
    });
  }

  Future<void> _pickAudio(TrackMenuEntry entry) async {
    await widget.player.selectAudioTrack(entry.id);
    await _reload();
  }

  Future<void> _pickVideo(TrackMenuEntry entry) async {
    await widget.player.selectVideoTrack(entry.id);
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
    final section = widget.section;
    final showAudio =
        section == PlayerTrackSection.all ||
        section == PlayerTrackSection.audio;
    final showVideo = section == PlayerTrackSection.video;
    final showSubtitles =
        section == PlayerTrackSection.all ||
        section == PlayerTrackSection.subtitles;
    final audioMenu = buildAudioMenu(_audio);
    final videoMenu = buildVideoMenu(_video);
    final subtitleMenu = buildSubtitleMenu(_subtitles);
    final anyVisible =
        (showAudio && audioMenu.isNotEmpty) ||
        (showVideo && videoMenu.isNotEmpty) ||
        (showSubtitles && _subtitles.isNotEmpty);
    if (!anyVisible) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          switch (section) {
            PlayerTrackSection.audio => '当前视频没有可选的音轨',
            PlayerTrackSection.video => '当前视频没有可选的视轨',
            PlayerTrackSection.subtitles => '当前视频没有可选的字幕轨',
            PlayerTrackSection.all => '当前视频没有可选的音轨或字幕轨',
          },
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showAudio && audioMenu.isNotEmpty) ...[
          const _SectionTitle('音轨'),
          for (final entry in audioMenu)
            _TrackRow(entry: entry, onTap: () => _pickAudio(entry)),
        ],
        if (showVideo && videoMenu.isNotEmpty) ...[
          const _SectionTitle('视轨'),
          for (final entry in videoMenu)
            _TrackRow(entry: entry, onTap: () => _pickVideo(entry)),
        ],
        if (showSubtitles) ...[
          const _SectionTitle('字幕'),
          for (final entry in subtitleMenu)
            _TrackRow(entry: entry, onTap: () => _pickSubtitle(entry)),
        ],
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
