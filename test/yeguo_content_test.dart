import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/yeguo_content.dart';

const _envelope =
    '{"status": "1", "data": "JlbIaUdX0Xuan5fDBVG0SN745f6w5YnbPlAszXGjo19+1HlPN0riNIFXDurCoyRmH68hfR8xSvBf9W0d1v9r2uZcGqV0TO1dbUqD3zhA8up7YIILZKuvLtJQh2SX8l5/czFCqUI8pQaRw0fcsTsJ5RGL+ZgsmpaYxcGLE0h/9pM=", "sign": "b7acdd601a83f069661d67172ea79c47"}';

const _homepage = '''
<html><head>
<script id="__NUXT_DATA__" type="application/json">[null,{"apiBaseURL":2},"https://api.yeguo.test"]</script>
<script type="module" src="/_nuxt/entry.abc.js"></script>
</head></html>
''';

const _entryJs = 'import {foo} from "/_nuxt/chunk.xyz.js";';

const _configJs = '''
const cfg = {version:"v0",mode:"CBC",padding:"Pkcs7",
key:"0123456789abcdef",iv:"abcdef0123456789",sign_key:"signkey1234567890"};
''';

MockClient _mockClient() {
  return MockClient((request) async {
    final url = request.url.toString();
    if (url == 'https://analyze.buxefaex.cc/') {
      return http.Response(_homepage, 200);
    }
    if (url == 'https://analyze.buxefaex.cc/_nuxt/entry.abc.js') {
      return http.Response(_entryJs, 200);
    }
    if (url == 'https://analyze.buxefaex.cc/_nuxt/chunk.xyz.js') {
      return http.Response(_configJs, 200);
    }
    if (url.startsWith('https://api.yeguo.test/api/home/contentOptions')) {
      return http.Response(_envelope, 200);
    }
    return http.Response('not found', 404);
  });
}

void main() {
  test('野果发现+签名验算+解密：Mock 全链出分类', () async {
    final client = YeguoContentClient(client: _mockClient());
    final categories = await client.categories();
    expect(categories.map((c) => c.id), ['theme:1']);
    expect(categories.single.name, '都市');
  });

  test('野果签名被改：解码失败', () async {
    final tampered = _envelope.replaceFirst(
      'b7acdd601a83f069661d67172ea79c47',
      '00000000000000000000000000000000',
    );
    final client = MockClient((request) async {
      final url = request.url.toString();
      if (url == 'https://analyze.buxefaex.cc/') {
        return http.Response(_homepage, 200);
      }
      if (url == 'https://analyze.buxefaex.cc/_nuxt/entry.abc.js') {
        return http.Response(_entryJs, 200);
      }
      if (url == 'https://analyze.buxefaex.cc/_nuxt/chunk.xyz.js') {
        return http.Response(_configJs, 200);
      }
      if (url.startsWith('https://api.yeguo.test/api/home/contentOptions')) {
        return http.Response(tampered, 200);
      }
      return http.Response('not found', 404);
    });
    final yeguo = YeguoContentClient(client: client);
    await expectLater(yeguo.categories(), throwsA(isA<StateError>()));
  });

  test('野果注册：dramaSiteContentClient 能拿到客户端', () {
    expect(dramaSiteContentClient('yeguo'), isA<YeguoContentClient>());
    expect(dramaSiteContentClient('huangju'), isNotNull);
  });
}
