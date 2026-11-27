/// B 站弹幕 XML 解析：根 `<i>` 下的
/// `<d p="发送时间秒,类型,字号,颜色,时间戳,池,用户,行id">文本</d>`。
///
/// 类型（p 第二段）4=底部静态、5=顶部静态，其余一律滚动（0）。
/// 坏行（缺 p、时间不可解析等）逐条跳过；整体解析失败回空表，不抛错。
library;

import 'package:xml/xml.dart';

import '../models/playlet_comment.dart';

List<PlayletComment> parseDanmakuXml(String source) {
  if (source.trim().isEmpty) return const [];
  final XmlDocument document;
  try {
    document = XmlDocument.parse(source);
  } catch (_) {
    return const [];
  }
  final comments = <PlayletComment>[];
  var index = 0;
  for (final element in document.findAllElements('d')) {
    final rowIndex = index++;
    final raw = element.getAttribute('p');
    if (raw == null) continue;
    final parts = raw.split(',');
    if (parts.length < 2) continue;
    final seconds = double.tryParse(parts[0].trim());
    if (seconds == null || !seconds.isFinite) continue;
    final text = element.innerText;
    if (text.isEmpty) continue;
    final rawMode = int.tryParse(parts[1].trim()) ?? 0;
    final mode = rawMode == 4 || rawMode == 5 ? rawMode : 0;
    final rowId = parts.length >= 8 ? parts[7].trim() : '';
    comments.add(
      PlayletComment(
        id: 'xml-${rowId.isNotEmpty ? rowId : rowIndex}',
        text: text,
        offsetMs: (seconds * 1000).round(),
        danmakuMode: mode,
      ),
    );
  }
  comments.sort((a, b) {
    final offset = a.offsetMs.compareTo(b.offsetMs);
    return offset == 0 ? a.id.compareTo(b.id) : offset;
  });
  return comments;
}
