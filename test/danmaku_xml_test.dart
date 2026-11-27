import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/danmaku_xml.dart';

void main() {
  group('parseDanmakuXml', () {
    test('parses scroll, top and bottom entries and sorts by offset', () {
      final out = parseDanmakuXml(
        '<i>'
        '<d p="3.25,4,25,16777215,1700000000,0,user-c,row-c">底部弹幕</d>'
        '<d p="1.5,1,25,16777215,1700000000,0,user-a,row-a">滚动弹幕</d>'
        '<d p="2,5,25,16777215,1700000000,0,user-b,row-b">顶部弹幕</d>'
        '<d p="4,7,25,16777215,1700000000,0,user-d,row-d">其他类型</d>'
        '</i>',
      );
      expect(out.map((e) => e.id), [
        'xml-row-a',
        'xml-row-b',
        'xml-row-c',
        'xml-row-d',
      ]);
      expect(out.map((e) => e.offsetMs), [1500, 2000, 3250, 4000]);
      expect(out.map((e) => e.danmakuMode), [0, 5, 4, 0]);
      expect(out.map((e) => e.text), ['滚动弹幕', '顶部弹幕', '底部弹幕', '其他类型']);
    });

    test('decodes XML entities in the text', () {
      final out = parseDanmakuXml(
        '<i><d p="0.5,1,25,0,0,0,u,r1">'
        'a &amp; b &lt;tag&gt; &quot;q&quot;'
        '</d></i>',
      );
      expect(out, hasLength(1));
      expect(out.single.text, 'a & b <tag> "q"');
    });

    test('skips bad rows and falls back to the row index for the id', () {
      final out = parseDanmakuXml(
        '<i>'
        '<d p="oops,1,25,0,0,0,u,bad-time">坏时间</d>'
        '<d>没有 p 属性</d>'
        '<d p="">空 p</d>'
        '<d p="1,1,25,0,0,0,u,">没行号</d>'
        '</i>',
      );
      expect(out, hasLength(1));
      expect(out.single.text, '没行号');
      // 第四条 <d>（序号 3）没有行 id，用序号兜底。
      expect(out.single.id, 'xml-3');
      expect(out.single.offsetMs, 1000);
    });

    test('empty and malformed input returns an empty list', () {
      expect(parseDanmakuXml(''), isEmpty);
      expect(parseDanmakuXml('   '), isEmpty);
      expect(parseDanmakuXml('not xml at all'), isEmpty);
      expect(parseDanmakuXml('<i><d p="1,1">未闭合'), isEmpty);
      expect(parseDanmakuXml('<i></i>'), isEmpty);
    });
  });
}
