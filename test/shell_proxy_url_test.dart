import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/shell_proxy_url.dart';

String shellUrl(String payloadJson) {
  final packed = base64.encode(utf8.encode(payloadJson));
  return 'http://127.0.0.1:9978/proxy?type=img&site=puapua&p=$packed';
}

void main() {
  test('解开壳代理封面地址，还原真实地址与 Referer', () {
    final unwrapped = unwrapShellProxyUrl(
      shellUrl(
        '{"s":"puapua","u":"https://img.example.com/1.jpg","r":"https://puapua8.cc/"}',
      ),
    );
    expect(unwrapped, isNotNull);
    expect(unwrapped!.url, 'https://img.example.com/1.jpg');
    expect(unwrapped.headers['Referer'], 'https://puapua8.cc/');
  });

  test('sex8 封面代理地址解开后带站方 Referer', () {
    final unwrapped = unwrapShellProxyUrl(
      shellUrl(
        '{"s":"sex8","u":"https://img.example.com/sex8/cover1.jpg","r":"https://kongsjieie.bar/"}',
      ),
    );
    expect(unwrapped, isNotNull);
    expect(unwrapped!.url, 'https://img.example.com/sex8/cover1.jpg');
    expect(unwrapped.headers['Referer'], 'https://kongsjieie.bar/');
  });

  test('没有 Referer 时只回地址', () {
    final unwrapped = unwrapShellProxyUrl(
      shellUrl('{"s":"puapua","u":"https://img.example.com/2.jpg"}'),
    );
    expect(unwrapped, isNotNull);
    expect(unwrapped!.url, 'https://img.example.com/2.jpg');
    expect(unwrapped.headers, isEmpty);
  });

  test('URL 安全 base64（无补位）也能解', () {
    final packed = base64Url
        .encode(
          utf8.encode(
            '{"s":"puapua","u":"https://img.example.com/3.jpg","r":"https://puapua8.cc/"}',
          ),
        )
        .replaceAll('=', '');
    final unwrapped = unwrapShellProxyUrl(
      'http://127.0.0.1:9978/proxy?type=img&site=puapua&p=$packed',
    );
    expect(unwrapped, isNotNull);
    expect(unwrapped!.url, 'https://img.example.com/3.jpg');
  });

  test('普通直链原样返回 null', () {
    expect(
      unwrapShellProxyUrl('https://video.huangju.net/posters/yanyu/drama-1259.jpg'),
      isNull,
    );
    expect(
      unwrapShellProxyUrl('https://media-server.t7ggv.com/Resource/Image/x/origin.new?type=webp'),
      isNull,
    );
  });

  test('缺 p 参数、坏 base64、u 不是 http 都返回 null', () {
    expect(
      unwrapShellProxyUrl('http://127.0.0.1:9978/proxy?type=img&site=puapua'),
      isNull,
    );
    expect(
      unwrapShellProxyUrl(
        'http://127.0.0.1:9978/proxy?type=img&site=puapua&p=!!!not-base64!!!',
      ),
      isNull,
    );
    expect(
      unwrapShellProxyUrl(
        shellUrl('{"s":"puapua","u":"/relative/path.jpg"}'),
      ),
      isNull,
    );
    expect(unwrapShellProxyUrl(''), isNull);
    expect(unwrapShellProxyUrl('not a url'), isNull);
  });

  group('resolveCoverUrl：封面统一换地址', () {
    const proxyBase = 'http://127.0.0.1:9978';

    test('proxy:// 形态转本地 /proxy，走蜘蛛 localProxy', () {
      final resolved = resolveCoverUrl(
        'proxy://do=py&siteKey=danai&u=https%3A%2F%2Fimg.example.com%2F1.jpg',
        proxyBase: proxyBase,
      );
      expect(
        resolved.url,
        '$proxyBase/proxy?do=py&siteKey=danai&u=https%3A%2F%2Fimg.example.com%2F1.jpg',
      );
      expect(resolved.headers, isNull);
    });

    test('http 明文图改走本地代理打包取回（系统禁明文直取）', () {
      final resolved = resolveCoverUrl(
        'http://img.example.com/cover.jpg',
        proxyBase: proxyBase,
      );
      expect(resolved.url.startsWith('$proxyBase/proxy?p='), isTrue);
      // 打包载荷解开后就是原图地址。
      final packed = Uri.parse(resolved.url).queryParameters['p']!;
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64.normalize(packed))),
      );
      expect(payload['u'], 'http://img.example.com/cover.jpg');
    });

    test('回环 proxy 不透明形态改写到当前实际端口', () {
      final resolved = resolveCoverUrl(
        'http://127.0.0.1:9978/proxy?do=py&siteKey=danai&u=https%3A%2F%2Fimg.example.com%2F1.jpg',
        proxyBase: 'http://127.0.0.1:9991',
      );
      expect(
        resolved.url,
        'http://127.0.0.1:9991/proxy?do=py&siteKey=danai&u=https%3A%2F%2Fimg.example.com%2F1.jpg',
      );
    });

    test('p= 包解开是 https 时原样直取带 Referer', () {
      final resolved = resolveCoverUrl(
        shellUrl(
          '{"s":"puapua","u":"https://img.example.com/1.jpg","r":"https://puapua8.cc/"}',
        ),
        proxyBase: proxyBase,
      );
      expect(resolved.url, 'https://img.example.com/1.jpg');
      expect(resolved.headers?['Referer'], 'https://puapua8.cc/');
    });

    test('p= 包解开是 http 明文图时改走代理打包取回并保留 Referer', () {
      final resolved = resolveCoverUrl(
        shellUrl(
          '{"s":"puapua","u":"http://img.example.com/1.jpg","r":"https://puapua8.cc/"}',
        ),
        proxyBase: proxyBase,
      );
      expect(resolved.url.startsWith('$proxyBase/proxy?p='), isTrue);
      final packed = Uri.parse(resolved.url).queryParameters['p']!;
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64.normalize(packed))),
      );
      expect(payload['u'], 'http://img.example.com/1.jpg');
      expect(payload['r'], 'https://puapua8.cc/');
    });

    test('https 直链与空地址不动', () {
      expect(
        resolveCoverUrl(
          'https://img.example.com/1.jpg',
          proxyBase: proxyBase,
        ).url,
        'https://img.example.com/1.jpg',
      );
      expect(resolveCoverUrl('', proxyBase: proxyBase).url, isEmpty);
    });

    test('本地代理没起时退化为老行为：只解包不改写', () {
      final resolved = resolveCoverUrl(
        'http://img.example.com/cover.jpg',
      );
      expect(resolved.url, 'http://img.example.com/cover.jpg');
      expect(
        resolveCoverUrl(
          'proxy://do=py&siteKey=danai&u=https%3A%2F%2Fimg.example.com%2F1.jpg',
        ).url,
        startsWith('proxy://'),
      );
    });
  });
}
