import 'live_platform.dart' show isPlayableLiveUrl;
import 'live_sources.dart';

/// 按回看模板生成某个节目时段的回看地址（与魔蚁定版同口径）：
/// - 模板占位：`${(b)格式}` 是节目开始时间、`${(e)格式}` 是结束
///   时间；格式为 `timestamp` 时是秒级时间戳，否则按
///   yyyy/MM/dd/HH/mm/ss 记号拼（如 yyyyMMddHHmmss）。
/// - type 为 `default`：source 模板本身就是完整的回看地址。
/// - 其余（`append` 或空）：先按 replace（「正则,替换」）改直播
///   地址，再把生成好的 source 拼到地址后面；地址已有查询串时
///   source 开头的 `?` 换成 `&`。
/// 模板为空、或生成结果不是可播地址时返回 null（调用方据此提示
/// 不支持回看，不许拿空地址起播）。纯函数，无副作用。
String? formatLiveCatchupUrl({
  required LiveCatchup catchup,
  required String liveUrl,
  required DateTime start,
  required DateTime end,
}) {
  if (catchup.isEmpty || liveUrl.isEmpty) return null;
  final source = _fillTemplate(catchup.source, start, end);
  if (source.isEmpty) return null;
  if (catchup.type == 'default') {
    return isPlayableLiveUrl(source) ? source : null;
  }
  var url = liveUrl;
  final replace = catchup.replace;
  if (replace.isNotEmpty) {
    final at = replace.indexOf(',');
    if (at > 0) {
      try {
        url = url.replaceAll(
          RegExp(replace.substring(0, at)),
          replace.substring(at + 1),
        );
      } catch (_) {
        // replace 的正则写坏了就不改地址，只拼 source。
      }
    }
  }
  var tail = source;
  if (url.contains('?') && tail.startsWith('?')) {
    tail = '&${tail.substring(1)}';
  }
  final result = '$url$tail';
  return isPlayableLiveUrl(result) ? result : null;
}

final _tokenPattern = RegExp(r'\$\{\((b|e)\)([^}]*)\}');

String _fillTemplate(String template, DateTime start, DateTime end) =>
    template.replaceAllMapped(_tokenPattern, (match) {
      final when = match.group(1) == 'b' ? start : end;
      final pattern = match.group(2) ?? '';
      if (pattern == 'timestamp') {
        return '${when.millisecondsSinceEpoch ~/ 1000}';
      }
      return _formatTime(when, pattern);
    });

String _formatTime(DateTime time, String pattern) {
  String two(int value) => value.toString().padLeft(2, '0');
  var out = pattern;
  out = out.replaceAll('yyyy', '${time.year}');
  out = out.replaceAll('MM', two(time.month));
  out = out.replaceAll('dd', two(time.day));
  out = out.replaceAll('HH', two(time.hour));
  out = out.replaceAll('mm', two(time.minute));
  out = out.replaceAll('ss', two(time.second));
  return out;
}
