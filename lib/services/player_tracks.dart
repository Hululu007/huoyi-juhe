// 音轨/字幕轨与外挂字幕（同步批 A8）。模型与规则学魔蚁
// easytv-learn 的字幕设计（`subs` 全链同名、归一别名、默认挂载
// 语言偏好、菜单模型），宿主实现按修仙版的 ExoPlayer 原生通道
// 重写（media_kit 只在桌面端，安卓走 NativePlayer）。
//
// 数据链：蜘蛛 playerContent 的 `subs` → parseTvboxPlay →
// DramaPlaySource.subs → toResponse 的 `subs` → EpisodeSource.subs
// → PlayerPage 起播时经 NativePlayer.create 下发宿主挂载；
// 轨道枚举/切换走宿主 getTracks / selectAudioTrack /
// selectSubtitleTrack。挂载与默认选中失败都不挡播放。

/// 一条外挂字幕。字段全链同名 `subs`，元素键 url/name/lang/format。
class ExternalSubtitle {
  const ExternalSubtitle({
    required this.url,
    this.name = '',
    this.lang = '',
    this.format = '',
  });

  final String url;
  final String name;
  final String lang;
  final String format;

  /// 显示名：name → lang → 「外挂字幕」（魔蚁口径）。
  String get label =>
      name.isNotEmpty ? name : (lang.isNotEmpty ? lang : '外挂字幕');

  Map<String, dynamic> toJson() => <String, dynamic>{
    'url': url,
    'name': name,
    'lang': lang,
    'format': format,
  };

  @override
  bool operator ==(Object other) =>
      other is ExternalSubtitle &&
      other.url == url &&
      other.name == name &&
      other.lang == lang &&
      other.format == format;

  @override
  int get hashCode => Object.hash(url, name, lang, format);
}

/// 可挂载的字幕格式白名单（魔蚁口径）；lrc 在列但 ExoPlayer 无
/// 渲染器，宿主挂载时跳过（见 NativePlayerPlugin 的格式映射）。
const Set<String> externalSubtitleFormats = <String>{
  'srt',
  'vtt',
  'ass',
  'ssa',
  'ttml',
  'xml',
  'lrc',
};

String _textOf(Map<dynamic, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value != null) {
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
  }
  return '';
}

String _formatOf(Map<dynamic, dynamic> map, String url) {
  var format = _textOf(map, const ['format', 'type']).toLowerCase();
  if (format.startsWith('.')) format = format.substring(1);
  if (format.isEmpty) {
    final path = Uri.tryParse(url)?.path ?? url;
    final dot = path.lastIndexOf('.');
    if (dot >= 0 && dot < path.length - 1) {
      format = path.substring(dot + 1).toLowerCase();
    }
  }
  return format;
}

/// 归一任意来源的 `subs` 原始值：元素认对象或裸字符串（裸串只有
/// url、格式靠扩展名推断）；别名 url→v→src→address、
/// name→n→title、lang→language、format→type；同 url 去重保序；
/// url 为空或格式不在白名单的条目丢弃。
List<ExternalSubtitle> parseExternalSubtitles(Object? raw) {
  if (raw is! List) return const <ExternalSubtitle>[];
  final seen = <String>{};
  final out = <ExternalSubtitle>[];
  for (final entry in raw) {
    if (entry is String) {
      final url = entry.trim();
      if (url.isEmpty || !seen.add(url)) continue;
      final format = _formatOf(const <String, dynamic>{}, url);
      if (!externalSubtitleFormats.contains(format)) continue;
      out.add(ExternalSubtitle(url: url, format: format));
      continue;
    }
    if (entry is! Map) continue;
    final url = _textOf(entry, const ['url', 'v', 'src', 'address']);
    if (url.isEmpty || !seen.add(url)) continue;
    final format = _formatOf(entry, url);
    if (!externalSubtitleFormats.contains(format)) continue;
    out.add(
      ExternalSubtitle(
        url: url,
        name: _textOf(entry, const ['name', 'n', 'title']),
        lang: _textOf(entry, const ['lang', 'language']),
        format: format,
      ),
    );
  }
  return out;
}

/// 默认挂载语言偏好（魔蚁口径）：偏好表前缀匹配 lang 或 name，
/// 其次 name 含中文/简体/繁体，再次第一条；空表返回 null。
const List<String> defaultSubtitleLangPrefs = <String>[
  'zh',
  'chi',
  'zho',
  'chs',
  'cht',
  'cn',
  '中文',
];

ExternalSubtitle? pickDefaultExternalSubtitle(List<ExternalSubtitle> subs) {
  if (subs.isEmpty) return null;
  for (final sub in subs) {
    final lang = sub.lang.toLowerCase();
    final name = sub.name.toLowerCase();
    for (final pref in defaultSubtitleLangPrefs) {
      if (lang.startsWith(pref) || name.startsWith(pref)) return sub;
    }
  }
  for (final sub in subs) {
    if (sub.name.contains('中文') ||
        sub.name.contains('简体') ||
        sub.name.contains('繁体')) {
      return sub;
    }
  }
  return subs.first;
}

/// 宿主枚举出的一条轨道（音轨或字幕轨）。
class PlayerTrackInfo {
  const PlayerTrackInfo({
    required this.id,
    required this.label,
    this.language = '',
    this.formatId = '',
    this.selected = false,
  });

  /// 宿主轨道 id（组:轨），选择时原样回传宿主。
  final String id;
  final String label;
  final String language;

  /// 宿主侧 format.id：外挂字幕为 `ext:<url>`，内嵌轨为宿主自有 id。
  final String formatId;
  final bool selected;

  bool get isExternal => formatId.startsWith('ext:');
  String get externalUrl =>
      isExternal ? formatId.substring('ext:'.length) : '';

  factory PlayerTrackInfo.fromMap(Map<dynamic, dynamic> map) {
    return PlayerTrackInfo(
      id: '${map['id'] ?? ''}',
      label: '${map['label'] ?? ''}',
      language: '${map['language'] ?? ''}',
      formatId: '${map['formatId'] ?? ''}',
      selected: map['selected'] == true,
    );
  }
}

enum TrackMenuKind {
  audio,
  video,
  subtitleEmbedded,
  subtitleExternal,
  subtitleOff,
}

class TrackMenuEntry {
  const TrackMenuEntry({
    required this.kind,
    required this.id,
    required this.label,
    required this.selected,
  });

  final TrackMenuKind kind;

  /// 宿主轨道 id；字幕关闭项固定 `sub:no`。
  final String id;
  final String label;
  final bool selected;
}

const String subtitleOffTrackId = 'sub:no';

/// 字幕菜单模型（魔蚁口径）：首条恒「关闭字幕」，其后内嵌轨、
/// 外挂轨依次排列，三者互斥（selected 由宿主枚举的选中态决定；
/// 没有任何字幕轨被选中时「关闭字幕」为选中态）。
List<TrackMenuEntry> buildSubtitleMenu(List<PlayerTrackInfo> subtitles) {
  final anySelected = subtitles.any((track) => track.selected);
  return <TrackMenuEntry>[
    TrackMenuEntry(
      kind: TrackMenuKind.subtitleOff,
      id: subtitleOffTrackId,
      label: '关闭字幕',
      selected: !anySelected,
    ),
    for (final track in subtitles)
      TrackMenuEntry(
        kind: track.isExternal
            ? TrackMenuKind.subtitleExternal
            : TrackMenuKind.subtitleEmbedded,
        id: track.id,
        label: track.label.isNotEmpty
            ? track.label
            : (track.language.isNotEmpty ? track.language : '字幕'),
        selected: track.selected,
      ),
  ];
}

/// 音轨菜单模型：无关闭项，宿主枚举什么就列什么。
List<TrackMenuEntry> buildAudioMenu(List<PlayerTrackInfo> audio) {
  return <TrackMenuEntry>[
    for (final track in audio)
      TrackMenuEntry(
        kind: TrackMenuKind.audio,
        id: track.id,
        label: track.label.isNotEmpty
            ? track.label
            : (track.language.isNotEmpty ? track.language : '音轨'),
        selected: track.selected,
      ),
  ];
}

/// 视轨菜单模型（照录屏改造批 M17）：无关闭项；标签优先用宿主给
/// 的 label，没有时用格式 id 兜底（多码率流的轨通常带分辨率标签）。
List<TrackMenuEntry> buildVideoMenu(List<PlayerTrackInfo> video) {
  return <TrackMenuEntry>[
    for (final track in video)
      TrackMenuEntry(
        kind: TrackMenuKind.video,
        id: track.id,
        label: track.label.isNotEmpty
            ? track.label
            : (track.formatId.isNotEmpty ? track.formatId : '视频轨'),
        selected: track.selected,
      ),
  ];
}
