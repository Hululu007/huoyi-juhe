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
}
