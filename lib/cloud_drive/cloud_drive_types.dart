/// 网盘文件识别层：类型识别 + 疑似广告视频评分 + 封面来源。
///
/// 本文件是纯逻辑，不依赖 Flutter 控件与网络，可直接单测。
/// 识别规则如实写在注释里：认不出来的类型一律归为 [CloudFileKind.other]，
/// 绝不猜成可播类型。
library;

/// 网盘里一个条目的类型。
enum CloudFileKind {
  /// 文件夹：下钻。
  folder,

  /// 视频：进详情/播放。
  video,

  /// 音频：走播放器音频模式。
  audio,

  /// 图片：走 pics:// 浏览。
  image,

  /// 字幕/歌词：只展示，不冒充可播。
  subtitle,

  /// 其它：只展示，不冒充可播。
  other,
}

/// 封面来源（诚实标注用，详情页 tags 里展示）。
enum CloudCoverSource {
  /// 网盘接口返回的缩略图地址。
  providerThumbnail,

  /// 同文件夹内与视频同名的图片文件。
  sameNameImage,

  /// 没有任何封面数据，走现有占位渲染。
  placeholder,
}

extension CloudCoverSourceLabel on CloudCoverSource {
  String get label {
    switch (this) {
      case CloudCoverSource.providerThumbnail:
        return '网盘缩略图';
      case CloudCoverSource.sameNameImage:
        return '同名图片';
      case CloudCoverSource.placeholder:
        return '无封面';
    }
  }
}

/// 网盘文件/文件夹的统一模型（五家网盘的列表结果都先归一到这里）。
class CloudDriveFile {
  const CloudDriveFile({
    required this.id,
    required this.name,
    required this.isFolder,
    required this.kind,
    this.sizeBytes = 0,
    this.modifiedMs = 0,
    this.durationSeconds,
    this.thumbnailUrl = '',
    this.extra = const {},
  });

  /// 网盘侧的条目 id（115= fid/cid，夸克= fid，阿里= file_id，百度= fs_id）。
  final String id;

  /// 文件名/文件夹名（原样，不改写）。
  final String name;
  final bool isFolder;
  final CloudFileKind kind;

  /// 字节数；文件夹与未知时为 0。
  final int sizeBytes;

  /// 修改时间（毫秒时间戳）；未知时为 0。
  final int modifiedMs;

  /// 视频/音频市场（秒）；网盘没给该字段时为 null，表示“未知”，
  /// 广告评分里不参与、不猜。
  final int? durationSeconds;

  /// 网盘返回的缩略图地址；没有时为空。
  final String thumbnailUrl;

  /// 各家取直链需要的私有字段（如 115 的 pickcode、百度的 path），
  /// 只有对应网盘的客户端认识，引擎不解析。
  final Map<String, String> extra;

  CloudDriveFile withKind(CloudFileKind value) => CloudDriveFile(
    id: id,
    name: name,
    isFolder: isFolder,
    kind: value,
    sizeBytes: sizeBytes,
    modifiedMs: modifiedMs,
    durationSeconds: durationSeconds,
    thumbnailUrl: thumbnailUrl,
    extra: extra,
  );
}

/// 扩展名 → 类型映射（小写比较，不带点）。
const _videoExtensions = <String>{
  'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v',
  'ts', 'm2ts', 'rmvb', 'rm', '3gp', 'mpg', 'mpeg', 'f4v',
  'vob', 'asf', 'm3u8',
  // strm 是流地址指针文件（内容第一行是 http(s) 地址，播放时展开），
  // iso 是光盘镜像（只走 mpv）；两者都按可播视频识别。
  'strm', 'iso',
};
const _audioExtensions = <String>{
  'mp3', 'flac', 'wav', 'aac', 'm4a', 'ogg', 'opus', 'wma',
  'ape', 'amr', 'aiff', 'dts',
};
const _imageExtensions = <String>{
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'avif', 'heic', 'heif',
};
const _subtitleExtensions = <String>{
  'srt', 'ass', 'ssa', 'vtt', 'sub', 'smi', 'sbv', 'lrc',
};

/// 文件扩展名（小写、不带点）；没有扩展名时为空。
String fileExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// 是否 STRM 指针文件。
bool isStrmFile(String name) => fileExtension(name) == 'strm';

/// 是否 ISO 光盘镜像。
bool isIsoFile(String name) => fileExtension(name) == 'iso';

/// 是否 DVD 的 VOB 分段文件。
bool isVobFile(String name) => fileExtension(name) == 'vob';

/// 是否光盘元数据文件（IFO/BUP）：VOB 分组时不单独成卡。
bool isDiscMetadataFile(String name) {
  final ext = fileExtension(name);
  return ext == 'ifo' || ext == 'bup';
}

/// 光盘文件夹类型：VIDEO_TS → 'dvd'，BDMV → 'bd'，其它为 null。
/// 名字大小写不敏感、前后空白忽略；只有整名相等才认（带后缀的
/// 同名文件夹不认，避免把用户自建文件夹误当成光盘）。
String? discTypeOfFolder(String name) {
  final normalized = name.trim().toUpperCase();
  if (normalized == 'VIDEO_TS') return 'dvd';
  if (normalized == 'BDMV') return 'bd';
  return null;
}

/// 解析 STRM 文件内容：取第一个非空行作为流地址。
///
/// 容错：开头的 BOM、空行、前后空白一律跳过/去掉；只有解析出
/// http(s) 地址且带 host 时才返回，其余（空文件、相对地址、磁力
/// 链等）一律返回 null，调用方按“内容不是有效的流地址”诚实报错，
/// 不假播。只取第一行：多行内容不作播放列表。
String? parseStrmContent(String content) {
  for (final rawLine in content.split('\n')) {
    var line = rawLine.trim();
    // 行首 BOM（文件开头或空行后都可能出现）去掉再判。
    while (line.startsWith('\uFEFF')) {
      line = line.substring(1).trimLeft();
    }
    if (line.isEmpty) continue;
    final uri = Uri.tryParse(line);
    if (uri == null) return null;
    if ((uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty) {
      return line;
    }
    return null;
  }
  return null;
}

/// 推广/说明类文件扩展名：网盘里常见的“点击进入”“地址发布页”都
/// 是这类文件，不进列表。只排除这张表：视频/音频/图片/字幕/光盘
/// 元数据/无扩展名文件一律保留成卡，各自按 kind 走播放或详情——
/// 白名单（只留视频）会误杀图片浏览、字幕详情与 IFO 卡。
const _promoExtensions = <String>{
  'html', 'htm', 'shtml', 'mht', 'mhtml', 'chm', 'url', 'txt', 'lnk',
};

/// 网盘列表是否列出该文件：推广类扩展名不列，其余一律列出。
/// 不看 kind：网盘提示与扩展名不一致时以扩展名为准，kind 只决定
/// 成卡后的播放/详情走法。
bool isListableDriveFile(CloudDriveFile file) {
  return !_promoExtensions.contains(fileExtension(file.name));
}

/// 按扩展名识别类型；扩展名不在表里的一律 [CloudFileKind.other]。
CloudFileKind kindFromExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return CloudFileKind.other;
  final ext = name.substring(dot + 1).toLowerCase();
  if (_videoExtensions.contains(ext)) return CloudFileKind.video;
  if (_audioExtensions.contains(ext)) return CloudFileKind.audio;
  if (_imageExtensions.contains(ext)) return CloudFileKind.image;
  if (_subtitleExtensions.contains(ext)) return CloudFileKind.subtitle;
  return CloudFileKind.other;
}

/// 综合判定：文件夹标志优先；网盘自带类别提示次之（网盘侧已验过内容）；
/// 都没有时按扩展名；最后兜底 other。
///
/// [providerHint] 是各家客户端把自家类别字段归一后的提示，null 表示没有。
CloudFileKind classifyCloudFile({
  required String name,
  required bool isFolder,
  CloudFileKind? providerHint,
}) {
  if (isFolder) return CloudFileKind.folder;
  if (providerHint != null && providerHint != CloudFileKind.other) {
    return providerHint;
  }
  return kindFromExtension(name);
}

// ---------------------------------------------------------------------------
// 疑似广告视频评分
//
// 背景（用户实情）：网盘里的视频是磁力离线保存的，广告嵌在文件里，
// 直链播放去不掉；广告视频通常几十 M、极短、文件名带推广信息。
// 本评分只做“显示过滤”，绝不删文件；判错的用设置里的开关放回来。
// 规则是经验启发式，不是百分之百，误判可能见 [AdVideoVerdict] 注释。
// ---------------------------------------------------------------------------

/// 文件名里的推广特征（命中一条即计 1 分，上限 3 分）。
///
/// 只收“推广意图明确”的模式：网址/域名、联系方式、引导性推广词。
/// 单个“官方”“最新”这种日常词不收，避免误伤正常剧名。
final _adNamePatterns = <Pattern>[
  // 网址/域名：xxx.com / www.xxx.top / https://...
  RegExp(
    r'(https?://|www\.)?[a-z0-9-]+\.(com|net|cc|xyz|top|vip|me|io|tv|app|live|club|site|online)\b',
    caseSensitive: false,
  ),
  // 联系方式：QQ/微信/电报/TG + 号码或引导词。
  RegExp(r'(qq|微信|wechat|vx|tg|telegram|电报)\s*[:：]?\s*\d{5,}', caseSensitive: false),
  RegExp(r'加\s*(微信|qq|群|v)', caseSensitive: false),
  RegExp(r'(进群|加群)', caseSensitive: false),
  // 引导性推广词组（成词组才算，单个词不算）。
  RegExp(r'(最新地址|永久地址|防走失|请记住|点击进入|更多精彩|官方网址|备用地址|收藏地址)'),
  RegExp(r'(推广|广告|赞助商)', caseSensitive: false),
];

/// 疑似广告视频的判定结果。
class AdVideoVerdict {
  const AdVideoVerdict({
    required this.suspected,
    required this.score,
    required this.reasons,
  });

  /// 是否判为疑似广告。
  final bool suspected;

  /// 总分（文件名分 + 大小分 + 时长分）。
  final int score;

  /// 命中原因（人话，供“显示疑似广告”模式下标注与排障）。
  final List<String> reasons;
}

/// 多信号综合判定疑似广告视频。
///
/// 信号与分值：
/// - 文件名：命中一条推广模式计 1 分，上限 3 分；
/// - 大小：≤30MB 计 2 分，≤80MB 计 1 分，超过 80MB 计 0 分；
/// - 时长（仅网盘给了该字段时参与）：≤60 秒计 2 分，≤180 秒计 1 分，
///   超过 180 秒计 0 分；网盘没给时长时该信号为“未知”，不计分也不猜。
///
/// 判定：文件名至少 1 分，且大小分 + 时长分 ≥ 2 分，才判疑似。
/// 也就是说，单靠“小”或单靠“短”或单靠“名字像”都不判，必须至少两个
/// 信号同时命中。
///
/// 否决项（满足任一即不判，避免误伤正片）：
/// - 时长已知且超过 10 分钟；
/// - 文件超过 500MB。
///
/// 误判可能（必须如实说明）：短预告片、花絮、片头曲这类“又小又短、名字
/// 又带推广词”的合法视频会被误判；网盘不给时长时，只剩“文件名+大小”
/// 两个信号，误判率更高。被误判的视频只是在列表里默认隐藏，文件本身
/// 不动，打开设置里的“显示疑似广告视频”开关即可全部找回。
AdVideoVerdict scoreAdVideo({
  required String name,
  required int sizeBytes,
  int? durationSeconds,
}) {
  final reasons = <String>[];
  // 否决项先行。
  if (durationSeconds != null && durationSeconds > 600) {
    return const AdVideoVerdict(
      suspected: false,
      score: 0,
      reasons: ['时长超过 10 分钟，不判广告'],
    );
  }
  if (sizeBytes > 500 * 1024 * 1024) {
    return const AdVideoVerdict(
      suspected: false,
      score: 0,
      reasons: ['文件超过 500MB，不判广告'],
    );
  }
  var nameScore = 0;
  for (final pattern in _adNamePatterns) {
    if (pattern.allMatches(name).isNotEmpty) {
      nameScore++;
      if (nameScore >= 3) break;
    }
  }
  if (nameScore > 0) reasons.add('文件名带推广特征');
  var sizeScore = 0;
  if (sizeBytes > 0 && sizeBytes <= 30 * 1024 * 1024) {
    sizeScore = 2;
    reasons.add('文件很小（≤30MB）');
  } else if (sizeBytes > 0 && sizeBytes <= 80 * 1024 * 1024) {
    sizeScore = 1;
    reasons.add('文件较小（≤80MB）');
  }
  var durationScore = 0;
  if (durationSeconds != null) {
    if (durationSeconds <= 60) {
      durationScore = 2;
      reasons.add('时长极短（≤60 秒）');
    } else if (durationSeconds <= 180) {
      durationScore = 1;
      reasons.add('时长很短（≤180 秒）');
    }
  }
  final score = nameScore + sizeScore + durationScore;
  final suspected = nameScore >= 1 && sizeScore + durationScore >= 2;
  return AdVideoVerdict(
    suspected: suspected,
    score: score,
    reasons: suspected ? reasons : const [],
  );
}

/// 判断一个文件是否应默认隐藏（仅视频参与评分，其它类型永不判广告）。
/// STRM 指针文件不参与：它只有几字节、大小信号无意义，文件名带推广
/// 词也不判（播的是它指向的流，不是文件本身）。
bool isSuspectedAdVideo(CloudDriveFile file) {
  if (file.kind != CloudFileKind.video) return false;
  if (isStrmFile(file.name)) return false;
  return scoreAdVideo(
    name: file.name,
    sizeBytes: file.sizeBytes,
    durationSeconds: file.durationSeconds,
  ).suspected;
}
