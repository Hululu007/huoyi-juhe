import 'package:shared_preferences/shared_preferences.dart';

// 播放失败自动回退（同步批 A6）。失败分类与档位语义学魔蚁
// easytv-learn 的 player_core_fallback（分类判定序、四档门禁、
// 每步只试一次的编排），阶梯按修仙版自己的播放路重定义——
// 修仙版没有多核，页内能自动执行的只有三步：
//   1. refreshSource 换新地址重取（源地址可能过期/被限流）
//   2. switchVariant 换变体（同集另一档清晰度/另一路流）
//   3. decoderSoft   换解码路（会话内切软解重建，退出播放页恢复）
// 「换线路/换源」在修仙版是详情页与换源弹层的手动动作，播放页
// 内没有线路模型，不假装能自动切：三步走完回 null，错误交给
// 既有报错界面（那里有重试与换源入口）。
// 与用户侧报错分类（PlaybackIssue）分工：那套决定报错文案，
// 这套只决定还试不试下一步，两套不合并。

/// 失败分类。判定顺序定死：格式 → 解码 → 网络 → 其他。
/// 格式先于解码：「格式不支持」常与 codec 同现，先判格式才能
/// 让「仅解码类」档位把它算作可回退的格式问题；网络后于解码：
/// 解码错误文案偶尔带流地址里的 http 字样，先判解码避免误判。
enum PlaybackFailureKind { decode, network, formatUnsupported, other }

const List<String> _formatKeywords = <String>[
  '格式不支持',
  '不支持该格式',
  '容器不支持',
  'unsupported format',
  'format not supported',
  'unsupported container',
  'unknown format',
  'unrecognized format',
  'invalid data found',
  'moov atom not found',
  'error_code_parser',
  'parser_exception',
  'no playable stream',
  'demuxer failed',
  'failed to open demuxer',
];

const List<String> _decodeKeywords = <String>[
  '解码',
  '无法解码',
  '解码器',
  '渲染失败',
  'decode',
  'decoder',
  'codec',
  'mediacodec',
  'hwdec',
  'video_decoder',
  'audio_decoder',
  'error_code_decoder',
  'decoder_init_failed',
  'decoder_query_failed',
  'no decoder',
  'rendering failed',
  'renderer error',
  'error_code_renderer',
];

const List<String> _networkKeywords = <String>[
  '网络',
  '连接',
  '超时',
  '断网',
  '无法加载',
  '加载失败',
  'network',
  'timeout',
  'timed out',
  'socket',
  'dns',
  'failed host lookup',
  'connection refused',
  'connection reset',
  'reset by peer',
  'unreachable',
  'http error',
  'error_code_io',
  'io_network',
  '502 bad',
  '503 service',
  '504 gateway',
  '500 internal',
  '404 not found',
  'failed to load resource',
];

/// 把错误文本（+可选结构化错误码）拼成小写串做关键词分类。
PlaybackFailureKind classifyPlaybackFailureText(String text, {int? code}) {
  final haystack = '${code ?? ''} $text'.toLowerCase();
  bool hits(List<String> keywords) =>
      keywords.any((keyword) => haystack.contains(keyword));
  if (hits(_formatKeywords)) return PlaybackFailureKind.formatUnsupported;
  if (hits(_decodeKeywords)) return PlaybackFailureKind.decode;
  if (hits(_networkKeywords)) return PlaybackFailureKind.network;
  return PlaybackFailureKind.other;
}

PlaybackFailureKind classifyPlaybackFailure(Object error) =>
    classifyPlaybackFailureText(error.toString());

/// 回退档位（魔蚁四档同语义）：存 SharedPreferences 键
/// `playerCoreFallbackMode`，解析不到回默认 all。
enum PlaybackFallbackMode {
  all('all', '全回退', '任何播放失败都自动按阶梯重试'),
  decodeOnly('decode_only', '仅解码类回退', '只有解码失败或格式不支持才自动重试'),
  playerOnly('player_only', '仅播放器回退', '网络失败不重试（换路解决不了断网），其余自动重试'),
  off('off', '关', '不自动重试，失败直接报错');

  const PlaybackFallbackMode(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  bool allows(PlaybackFailureKind kind) => switch (this) {
    PlaybackFallbackMode.all => true,
    PlaybackFallbackMode.decodeOnly =>
      kind == PlaybackFailureKind.decode ||
          kind == PlaybackFailureKind.formatUnsupported,
    PlaybackFallbackMode.playerOnly => kind != PlaybackFailureKind.network,
    PlaybackFallbackMode.off => false,
  };

  static PlaybackFallbackMode fromId(String? id) =>
      PlaybackFallbackMode.values.firstWhere(
        (mode) => mode.id == id,
        orElse: () => PlaybackFallbackMode.all,
      );

  static const String prefsKey = 'playerCoreFallbackMode';

  static Future<PlaybackFallbackMode> load() async {
    final prefs = await SharedPreferences.getInstance();
    return fromId(prefs.getString(prefsKey));
  }

  static Future<void> save(PlaybackFallbackMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, mode.id);
  }
}

/// 修仙版回退阶梯（顺序定死，见文件头）。
enum PlaybackFallbackStep { refreshSource, switchVariant, decoderSoft }

/// 一集一次的回退会话：换集/重新装载即 reset。每步最多执行
/// 一次，绝不回头重试同一步；档位不允许该类失败时 advance
/// 直接回 null（错误抛给用户）。
class PlaybackFallbackController {
  PlaybackFallbackController({
    this.mode = PlaybackFallbackMode.all,
    List<PlaybackFallbackStep> ladder = PlaybackFallbackStep.values,
  }) : _ladder = List<PlaybackFallbackStep>.unmodifiable(ladder);

  PlaybackFallbackMode mode;
  List<PlaybackFallbackStep> _ladder;
  final Set<PlaybackFallbackStep> _tried = <PlaybackFallbackStep>{};
  final List<PlaybackFallbackStep> _attemptOrder = <PlaybackFallbackStep>[];

  /// 按当前集的实际条件收窄阶梯（如没有第二档变体就去掉
  /// switchVariant、解码已是软解就去掉 decoderSoft）。
  void configure({List<PlaybackFallbackStep>? ladder}) {
    if (ladder != null) {
      _ladder = List<PlaybackFallbackStep>.unmodifiable(ladder);
    }
  }

  void reset({PlaybackFallbackMode? mode}) {
    if (mode != null) this.mode = mode;
    _tried.clear();
    _attemptOrder.clear();
  }

  List<PlaybackFallbackStep> get attemptOrder =>
      List<PlaybackFallbackStep>.unmodifiable(_attemptOrder);

  bool get hasUntried => _ladder.any((step) => !_tried.contains(step));

  /// 取下一步：档位拦截或阶梯走完回 null。
  PlaybackFallbackStep? advance(PlaybackFailureKind kind) {
    if (!mode.allows(kind)) return null;
    for (final step in _ladder) {
      if (_tried.add(step)) {
        _attemptOrder.add(step);
        return step;
      }
    }
    return null;
  }
}
