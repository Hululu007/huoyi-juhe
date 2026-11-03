import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fqapp/services/legado_content.dart';

const _searchHtml = '''
<div class="books">
<div class="book"><a href="/book/1.html">书名一</a><span class="au">作者甲</span><img src="/c/1.jpg"></div>
<div class="book"><a href="/book/2.html">书名二</a><span class="au">作者乙</span><img src="/c/2.jpg"></div>
</div>
''';

const _bookHtml = '''
<html><head><title>书名一</title></head><body>
<a class="toc" href="/book/1/toc.html">目录</a>
</body></html>
''';

const _tocHtml = '''
<ul class="chapters">
<li><a href="/book/1/1.html">第1章 开始</a></li>
<li><a href="/book/1/2.html">第2章 继续</a></li>
</ul>
''';

const _contentHtml = '''
<div id="readerContent"><p>第一段正文。</p><p>第二段正文。</p></div>
<div><small>共1页</small></div>
''';

Map<String, dynamic> _sourceJson() => {
  'bookSourceName': '测试书源',
  'bookSourceUrl': 'https://demo.example.com/',
  'searchUrl': 'https://demo.example.com/search?keyword={{key}}&page={{page}}',
  'ruleSearch': {
    'bookList': 'div.book',
    'name': 'a@text',
    'author': 'span.au@text',
    'coverUrl': 'img@src',
    'bookUrl': 'a@href',
  },
  'ruleBookInfo': {
    'tocUrl': 'a.toc@href',
  },
  'ruleToc': {
    'chapterList': 'ul.chapters li',
    'chapterName': 'a@text',
    'chapterUrl': 'a@href',
  },
  'ruleContent': {
    'content': '#readerContent@p@text',
  },
};

void main() {
  test('CSS 链：选择器加 @text 取文本，多段落换行连接', () {
    final doc = html_parser.parse(_contentHtml);
    expect(
      legadoEvalCssText(doc, '#readerContent@p@text'),
      '第一段正文。\n第二段正文。',
    );
  });

  test('## 正则替换：从页码文本里抽数字', () {
    final doc = html_parser.parse(_contentHtml);
    expect(
      legadoEvalCssText(doc, r'small@text##(\d+)##$1'),
      '1',
    );
  });

  test('|| 兜底：前一条取空时走后一条', () {
    final doc = html_parser.parse(_contentHtml);
    expect(
      legadoEvalCssText(doc, 'div.missing@text||#readerContent@p@text'),
      '第一段正文。\n第二段正文。',
    );
  });

  test('JSONPath：列表展开与子键取值', () {
    final data = jsonDecode(
      '{"data":[{"title":"甲","url":"/a"},{"title":"乙","url":"/b"}]}',
    );
    final list = legadoEvalJson(data, r'$.data[*]');
    expect(list is List && list.length == 2, true);
    expect(legadoJsonSubValue((list as List).first, 'title'), '甲');
    expect(_jsonValueToStringForTest(legadoEvalJson(data, r'$.data[0].title')), '甲');
  });

  test('模板占位符：关键词与页码', () {
    expect(
      legadoFillUrl(
        'https://demo.example.com/s?k={{key}}&p={{page}}&q={{page-1}}',
        key: '斗破',
        page: 2,
      ),
      'https://demo.example.com/s?k=%E6%96%97%E7%A0%B4&p=2&q=1',
    );
  });

  test('客户端全链：搜索、详情目录、正文进小说载荷', () async {
    final client = MockClient((request) async {
      final url = request.url.toString();
      if (url.contains('/search')) {
        return http.Response.bytes(utf8.encode(_searchHtml), 200);
      }
      if (url.contains('/toc.html')) {
        return http.Response.bytes(utf8.encode(_tocHtml), 200);
      }
      if (url.contains('/book/1.html')) {
        return http.Response.bytes(utf8.encode(_bookHtml), 200);
      }
      return http.Response.bytes(utf8.encode(_contentHtml), 200);
    });
    final legado = LegadoContentClient(
      'legado-demo',
      LegadoSource(_sourceJson()),
      client: client,
    );
    final found = await legado.search('书名');
    expect(found.length, 2);
    expect(found.first.title, '书名一');
    expect(found.first.remark, '作者甲');
    expect(found.first.id, 'https://demo.example.com/book/1.html');
    final detail = await legado.detail(found.first.id);
    expect(detail.episodes.length, 2);
    expect(detail.episodes.first.title, '第1章 开始');
    final source = await legado.playSource(detail.episodes.first);
    expect(source.url.startsWith('novel://'), true);
    final payload =
        jsonDecode(source.url.substring('novel://'.length)) as Map;
    expect(payload['title'], '第1章 开始');
    expect(payload['content'], '第一段正文。\n第二段正文。');
  });
}

String _jsonValueToStringForTest(dynamic value) {
  if (value is String) return value;
  return '$value';
}
