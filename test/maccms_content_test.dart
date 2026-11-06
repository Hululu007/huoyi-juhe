import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fqapp/services/drama_site_content.dart';

MockClient _mockClient({required http.Response secondResponse}) {
  return MockClient((request) async {
    final url = request.url.toString();
    if (url == 'https://www.xzyx168.com/xzyxvd/123.html') {
      throw http.ClientException('连接中断', request.url);
    }
    if (url == 'https://www.xzyx168.com/detail/123.html') {
      return secondResponse;
    }
    return http.Response('not found', 404);
  });
}

void main() {
  test('发果详情：首个候选连接中断后继续试下一个候选', () async {
    final client = MaccmsContentClient(
      'faguo',
      'https://www.xzyx168.com',
      _mockClient(secondResponse: http.Response('not found', 404)),
    );
    await expectLater(
      client.detail('123'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('详情 HTTP 404'),
        ),
      ),
    );
  });

  test('发果详情：首个候选连接中断不会直接抛网络异常', () async {
    final client = MaccmsContentClient(
      'faguo',
      'https://www.xzyx168.com',
      _mockClient(
        secondResponse: http.Response.bytes(
          utf8.encode('garbage'),
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        ),
      ),
    );
    await expectLater(client.detail('123'), throwsA(isA<StateError>()));
  });
}
