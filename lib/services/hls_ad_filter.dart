import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// HLS 播放去广告（同步批 B1）。判据学魔蚁落地版（Go 核
/// app_adfilter.go，提交 2dedc6b）：没有域名/关键词黑名单，唯一
/// 判据是「来源指纹多数决」——分片来源（host+目录）与主来源不同
/// 的判为插播广告；再加两道保守总闸防误删正片。按修仙版结构
/// 重写为 Dart 纯函数，挂在本地媒体代理的直拉清单改写之前
/// （那是修仙版唯一能看到原始分片地址的清单层）。
///
/// 保守口径（任一命中整单原样放行）：
/// - master 清单（多码率）不处理，由变体清单各自处理；
/// - 含 #EXT-X-BYTERANGE 或 LL-HLS 标签（SKIP/PART/PRELOAD-HINT）；
/// - 分片 < 2；主指纹占比 < 40%（结构不可信，多半是多 CDN 切片）；
/// - 待删占比 > 35% 或待删总时长 > 90 秒；删完无分片剩余；
/// - 清洗后清单里再无 #EXTINF（宁可不删也不黑屏）。
/// 同 host 同目录的贴片/插播与正片无法区分，不猜删（宁漏不误杀）。

/// 过滤结果：[removed] 为删掉的分片数；为 0 时 [text] 即原文，
/// 调用方应使用原文（函数在放弃清洗时也原样返回）。
typedef HlsAdFilterResult = ({String text, int removed});

const double _mainFingerprintMinRatio = 0.40;
const double _maxRemovedRatio = 0.35;
const double _maxRemovedSeconds = 90;

String _fingerprintOf(Uri? uri, String fallback) {
  if (uri == null || uri.host.isEmpty) return fallback;
  final path = uri.path.toLowerCase();
  final slash = path.lastIndexOf('/');
  final dir = slash >= 0 ? path.substring(0, slash + 1) : '/';
  return '${uri.host.toLowerCase()}|$dir';
}

HlsAdFilterResult filterHlsAdSegments(String text, String baseUrl) {
  final original = (text: text, removed: 0);
  final normalized = text.replaceAll('\r\n', '\n');
  final lines = normalized.split('\n');
  if (lines.isEmpty || !lines.first.trim().startsWith('#EXTM3U')) {
    return original;
  }
  // 整单放行：字节范围与 LL-HLS 与播放器状态强绑定，删片会错位。
  if (normalized.contains('#EXT-X-BYTERANGE') ||
      normalized.contains('#EXT-X-SKIP:') ||
      normalized.contains('#EXT-X-PART:') ||
      normalized.contains('#EXT-X-PRELOAD-HINT:')) {
    return original;
  }

  final baseUri = Uri.tryParse(baseUrl);
  final baseFingerprint = _fingerprintOf(baseUri, '');

  String fingerprint(String rawUri) {
    final trimmed = rawUri.trim();
    if (trimmed.startsWith('data:')) return baseFingerprint;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return baseFingerprint;
    final resolved = uri.hasScheme
        ? uri
        : (baseUri == null ? uri : baseUri.resolveUri(uri));
    return _fingerprintOf(resolved, baseFingerprint);
  }

  // 扫一遍：master 标签整单放行；分片 = #EXTINF 之后紧随的 URI 行。
  final segments = <({int lineIndex, double duration, String fingerprint})>[];
  var pendingDuration = -1.0;
  var pendingIsSegment = false;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.startsWith('#EXT-X-STREAM-INF') ||
        line.startsWith('#EXT-X-MEDIA:') ||
        line.startsWith('#EXT-X-I-FRAME-STREAM-INF') ||
        line.startsWith('#EXT-X-IMAGE-STREAM-INF')) {
      return original; // master 清单
    }
    if (line.startsWith('#EXTINF:')) {
      final raw = line.substring('#EXTINF:'.length).split(',').first;
      pendingDuration = double.tryParse(raw.trim()) ?? 0;
      pendingIsSegment = true;
      continue;
    }
    if (line.startsWith('#')) continue;
    if (line.isEmpty) continue;
    if (pendingIsSegment) {
      segments.add((
        lineIndex: i,
        duration: pendingDuration < 0 ? 0 : pendingDuration,
        fingerprint: fingerprint(line),
      ));
    }
    pendingIsSegment = false;
    pendingDuration = -1;
  }
  if (segments.length < 2) return original;

  final counts = <String, int>{};
  for (final segment in segments) {
    counts[segment.fingerprint] = (counts[segment.fingerprint] ?? 0) + 1;
  }
  var mainFingerprint = '';
  var mainCount = 0;
  for (final entry in counts.entries) {
    if (entry.value > mainCount) {
      mainCount = entry.value;
      mainFingerprint = entry.key;
    }
  }
  if (mainCount / segments.length < _mainFingerprintMinRatio) {
    return original;
  }
  final removedSegments = <int, double>{}; // lineIndex -> duration
  for (final segment in segments) {
    if (segment.fingerprint != mainFingerprint) {
      removedSegments[segment.lineIndex] = segment.duration;
    }
  }
  if (removedSegments.isEmpty) return original;
  if (removedSegments.length / segments.length > _maxRemovedRatio) {
    return original;
  }
  final removedSeconds = removedSegments.values.fold<double>(
    0,
    (sum, d) => sum + d,
  );
  if (removedSeconds > _maxRemovedSeconds) return original;
  if (removedSegments.length >= segments.length) return original;

  // 重写：删广告分片 URI 行，并回溯删它前置的分片级标签
  // （EXTINF / BYTERANGE / KEY / DISCONTINUITY）；普通注释保留并
  // 继续回溯，碰到其它 #EXT 头部标签停（头部标签可能全挂在
  // 第一个广告分片前面，误删会让整张清单失效）。
  bool isSegmentTag(String line) =>
      line.startsWith('#EXTINF:') ||
      line.startsWith('#EXT-X-BYTERANGE') ||
      line.startsWith('#EXT-X-KEY') ||
      line.startsWith('#EXT-X-DISCONTINUITY');
  bool isUriLine(String line) =>
      line.isNotEmpty && !line.startsWith('#');

  final deleted = <int>{...removedSegments.keys};
  for (final uriIndex in removedSegments.keys) {
    var j = uriIndex - 1;
    while (j >= 0 && !deleted.contains(j)) {
      final line = lines[j].trim();
      if (isUriLine(line)) break;
      if (isSegmentTag(line)) {
        deleted.add(j);
        j--;
        continue;
      }
      if (line.startsWith('#') && !line.startsWith('#EXT')) {
        j--; // 普通注释：保留，但继续往上回溯
        continue;
      }
      break; // 其它 #EXT 头部标签 / 空行：停
    }
  }
  final kept = <String>[
    for (var i = 0; i < lines.length; i++)
      if (!deleted.contains(i)) lines[i],
  ];
  final cleaned = kept.join('\n');
  if (!cleaned.contains('#EXTINF')) return original;
  return (text: cleaned, removed: removedSegments.length);
}

/// 去广告开关（默认开）：设置页与代理共用一份。切换后对新拉取
/// 的清单生效（已下发的清单不回溯），与魔蚁「重建会话才生效」
/// 的口径等价但更宽容。
class AdBlockPreference {
  AdBlockPreference._();

  static const String enabledKey = 'ad_block_enabled';

  static final ValueNotifier<bool> enabledListenable = ValueNotifier<bool>(
    true,
  );

  static Future<bool> load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool(enabledKey) ?? true;
    enabledListenable.value = value;
    return value;
  }

  static Future<void> setEnabled(bool enabled) async {
    enabledListenable.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(enabledKey, enabled);
  }
}
