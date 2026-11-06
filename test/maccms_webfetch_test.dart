import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fqapp/services/drama_site_content.dart';

const _catalogHtml = '''
<div class="module-item">
  <a href="/index.php/vod/detail/id/123.html" title="测试剧">
    <img src="https://x/cover.jpg" alt="测试剧">
  </a>
</div>
''';

void main() {
  test('伍果目录走网页引擎取页，不走程序化请求', () async {
    final requested = <String>[];
    final client = MaccmsContentClient(
      'wuguo',
      'https://www.duanju55.com',
      MockClient((request) async {
        requested.add(request.url.toString());
        return http.Response('not found', 404);
      }),
    );
    final fetched = <String>[];
    client.webFetch = (url) async {
      fetched.add(url);
      return _catalogHtml;
    };
    final page = await client.catalog('all', 1);
    expect(fetched, ['https://www.duanju55.com/']);
    expect(requested, isEmpty);
    expect(page.items.map((item) => item.title), ['测试剧']);
    expect(page.items.single.id, '123');
  });

  test('非伍果站即使配了取页也不走网页引擎', () async {
    var webFetchCalled = false;
    final client = MaccmsContentClient(
      'huaguo',
      'https://www.zywest263.com',
      MockClient(
        (request) async => http.Response.bytes(
          utf8.encode(_catalogHtml),
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        ),
      ),
    );
    client.webFetch = (url) async {
      webFetchCalled = true;
      return _catalogHtml;
    };
    final page = await client.catalog('all', 1);
    expect(webFetchCalled, false);
    expect(page.items.map((item) => item.title), ['测试剧']);
  });

  test('伍果详情走网页引擎取页，候选地址逐个试', () async {
    final fetched = <String>[];
    final client = MaccmsContentClient(
      'wuguo',
      'https://www.duanju55.com',
      MockClient((request) async => http.Response('not found', 404)),
    );
    client.webFetch = (url) async {
      fetched.add(url);
      // 首个候选返回无详情内容，解析失败后应继续试下一个候选。
      if (fetched.length == 1) return 'no detail here';
      return '''
<title>测试剧详情</title>
<div class="playlist">
  <a href="/index.php/vod/play/id/123/sid/1/nid/1.html">第1集</a>
</div>
''';
    };
    final detail = await client.detail('123');
    expect(fetched.length, greaterThanOrEqualTo(2));
    expect(detail.title, isNotEmpty);
  });
}
