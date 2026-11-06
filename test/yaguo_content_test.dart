import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fqapp/services/drama_site_content.dart';

MockClient _mockClient({required String loginBody}) {
  return MockClient((request) async {
    final url = request.url.toString();
    if (url == 'https://u.shytkjgs.com/user/v1/account/login') {
      return http.Response.bytes(
        utf8.encode(loginBody),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (url.startsWith('https://app.whjzjx.cn/cloud/v2/theater/home_page')) {
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          'data': {
            'list': [
              {
                'theater': {
                  'id': 't1',
                  'title': '剧A',
                  'total': 10,
                  'cover_url': 'https://x/a.jpg',
                },
              },
            ],
            'total': 10,
            'is_end': true,
          },
        })),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response('not found', 404);
  });
}

void main() {
  test('芽果：顶层令牌照常用', () async {
    final client = YaguoContentClient(
      _mockClient(loginBody: '{"token":"tok-1"}'),
    );
    final page = await client.catalog('1', 1);
    expect(page.items.single.id, 't1');
    expect(page.items.single.title, '剧A');
  });

  test('芽果：data 嵌套令牌也接受', () async {
    final client = YaguoContentClient(
      _mockClient(
        loginBody: '{"code":200,"data":{"token":"tok-2"}}',
      ),
    );
    final page = await client.catalog('1', 1);
    expect(page.items.single.id, 't1');
  });

  test('芽果：无令牌时报错带服务端信息', () async {
    final client = YaguoContentClient(
      _mockClient(
        loginBody: '{"code":1001,"msg":"设备受限"}',
      ),
    );
    await expectLater(
      client.catalog('1', 1),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('设备受限'),
        ),
      ),
    );
  });
}
