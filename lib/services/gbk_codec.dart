import 'dart:convert';

import 'gbk_table.dart';

String gbkDecode(List<int> bytes) {
  final out = StringBuffer();
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b < 0x80) {
      out.writeCharCode(b);
      i += 1;
      continue;
    }
    if (b == 0x80) {
      out.writeCharCode(0x20AC);
      i += 1;
      continue;
    }
    if (i + 1 >= bytes.length) {
      out.writeCharCode(0xFFFD);
      i += 1;
      continue;
    }
    final trail = bytes[i + 1];
    final validTrail =
        (trail >= 0x40 && trail <= 0x7E) || (trail >= 0x80 && trail <= 0xFE);
    if (b < 0x81 || b > 0xFE || !validTrail) {
      out.writeCharCode(0xFFFD);
      i += 1;
      continue;
    }
    final index = (b - 0x81) * 190 + (trail < 0x7F ? trail - 0x40 : trail - 0x41);
    out.writeCharCode(gbkTwoByteTable.codeUnitAt(index));
    i += 2;
  }
  return out.toString();
}

bool _declaresGbk(String asciiHead) {
  final head = asciiHead.toLowerCase();
  return head.contains('charset=gbk') ||
      head.contains('charset=gb2312') ||
      head.contains('charset="gbk"') ||
      head.contains("charset='gbk'");
}

String decodeHttpBody(List<int> bytes, {String? contentType}) {
  if (contentType != null && _declaresGbk(contentType)) {
    return gbkDecode(bytes);
  }
  try {
    return utf8.decode(bytes);
  } catch (_) {
    final headLen = bytes.length < 2048 ? bytes.length : 2048;
    final head = String.fromCharCodes(bytes.sublist(0, headLen));
    if (_declaresGbk(head)) return gbkDecode(bytes);
    return utf8.decode(bytes, allowMalformed: true);
  }
}
