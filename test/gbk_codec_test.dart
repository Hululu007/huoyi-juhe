import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/gbk_codec.dart';

void main() {
  test('GBK 双字节解码：常用中文', () {
    expect(
      gbkDecode([0xD6, 0xD0, 0xCE, 0xC4, 0xC4, 0xE3, 0xBA, 0xC3]),
      '中文你好',
    );
    expect(gbkDecode([0xD0, 0xA1, 0xCB, 0xB5]), '小说');
  });

  test('GBK 与 ASCII 混排、0x80 欧元符、残字节容错', () {
    expect(gbkDecode([0x61, 0xD6, 0xD0, 0x62]), 'a中b');
    expect(gbkDecode([0x80]), '€');
    expect(gbkDecode([0xD6]), '�');
  });

  test('响应体解码：响应头声明 gbk、meta 声明 gbk、UTF-8 直通', () {
    expect(
      decodeHttpBody(
        [0xD6, 0xD0, 0xCE, 0xC4],
        contentType: 'text/html; charset=gbk',
      ),
      '中文',
    );
    expect(
      decodeHttpBody([
        ...'<meta charset="gbk">'.codeUnits,
        0xD6,
        0xD0,
      ]),
      '<meta charset="gbk">中',
    );
    expect(decodeHttpBody(utf8.encode('中文')), '中文');
  });
}
