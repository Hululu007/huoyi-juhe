import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/drama_site_play.dart';
import 'package:fqapp/services/engine_site_content.dart';
import 'package:fqapp/services/local_media_proxy.dart';
import 'package:http/http.dart' as http;

void main() {
  group('parseTvboxPlay 头透传', () {
    test('header 是 Map 时逐项进 headers', () {
      final source = parseTvboxPlay({
        'url': 'http://example.com/a.m3u8',
        'header': {
          'Referer': 'http://example.com/',
          'User-Agent': 'test-agent',
        },
      });
      expect(source.url, 'http://example.com/a.m3u8');
      expect(source.headers['Referer'], 'http://example.com/');
      expect(source.headers['User-Agent'], 'test-agent');
    });

    test('无 header 时 headers 为空', () {
      final source = parseTvboxPlay({'url': 'http://example.com/a.m3u8'});
      expect(source.headers, isEmpty);
    });

    test('header 非 Map 时忽略不抛错', () {
      final source = parseTvboxPlay({
        'url': 'http://example.com/a.m3u8',
        'header': 'Referer: http://example.com/',
      });
      expect(source.headers, isEmpty);
    });

    test('parse=1 仍抛错', () {
      expect(
        () => parseTvboxPlay({'url': 'x', 'parse': '1'}),
        throwsStateError,
      );
    });
  });

  group('parseLocalProxyResponse', () {
    test('状态、类型、字节与头齐全', () {
      final body = utf8.encode('#EXTM3U\nseg.ts\n');
      final response = parseLocalProxyResponse({
        'status': 200,
        'mime': 'application/vnd.apple.mpegurl',
        'bodyBase64': base64Encode(body),
        'headers': {'X-Custom': 'v'},
      });
      expect(response.status, 200);
      expect(response.body, body);
      expect(response.headers['X-Custom'], 'v');
    });

    test('bodyBase64 解不开时抛错', () {
      expect(
        () => parseLocalProxyResponse({
          'status': 200,
          'mime': 'text/plain',
          'bodyBase64': '!!!not-base64!!!',
        }),
        throwsStateError,
      );
    });
  });

  group('外来壳代理地址判定', () {
    test('回环 + proxy 路径判外来', () {
      expect(
        isForeignProxyUrl('http://127.0.0.1:9978/proxy?url=x'),
        isTrue,
      );
      expect(
        isForeignProxyUrl('http://localhost:9978/proxy'),
        isTrue,
      );
    });

    test('非回环或路径无 proxy 判非外来', () {
      expect(
        isForeignProxyUrl('https://example.com/proxy?url=x'),
        isFalse,
      );
      expect(
        isForeignProxyUrl('http://127.0.0.1:8080/video.m3u8'),
        isFalse,
      );
      expect(isForeignProxyUrl('not a url'), isFalse);
    });
  });

  group('本地代理 h 会话', () {
    test('owns 认自己会话地址，外来地址不认', () async {
      addTearDown(() async {
        LocalMediaProxy.instance.debugResetForTest();
      });
      final proxy = LocalMediaProxy.instance;
      final sessionUrl = await proxy.registerHandler(
        handler: (uri) async => LocalProxyResponse(
          status: 200,
          mime: 'text/plain',
          body: utf8.encode('ok'),
        ),
      );
      expect(proxy.owns(sessionUrl), isTrue);
      expect(isForeignProxyUrl(sessionUrl), isFalse);
      expect(
        isForeignProxyUrl('http://127.0.0.1:9978/proxy?url=x'),
        isTrue,
      );
    });

    test('h 会话：播放列表改写 + Range 切片', () async {
      addTearDown(() async {
        LocalMediaProxy.instance.debugResetForTest();
      });
      final proxy = LocalMediaProxy.instance;
      final sessionUrl = await proxy.registerHandler(
        handler: (uri) async {
          if (uri.path.endsWith('.m3u8')) {
            return LocalProxyResponse(
              status: 200,
              mime: 'application/vnd.apple.mpegurl',
              body: utf8.encode(
                '#EXTM3U\n'
                '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
                'http://127.0.0.1:9978/proxy?url=seg0.ts\n'
                'seg1.ts\n',
              ),
            );
          }
          return LocalProxyResponse(
            status: 200,
            mime: 'video/MP2T',
            body: utf8.encode('0123456789'),
          );
        },
      );
      final playlist = await http.get(
        Uri.parse('$sessionUrl/list.m3u8'),
      );
      expect(playlist.statusCode, 200);
      final text = utf8.decode(playlist.bodyBytes);
      expect(text, contains('#EXT-X-KEY:METHOD=AES-128,URI="key.bin"'));
      expect(
        text,
        contains('$sessionUrl?url=seg0.ts'),
      );
      // 外壳代理地址必须改写回本会话：断言只盯 `/proxy?url=` 这种原形，
      // 不能盯主机——本代理优先就占 9978，会话地址本身就是
      // `127.0.0.1:9978/h/...`，按主机断言永远过不了。
      expect(text, isNot(contains('/proxy?url=seg0.ts')));
      expect(text, contains('$sessionUrl/seg1.ts'));

      final ranged = await http.get(
        Uri.parse('$sessionUrl/seg.ts'),
        headers: {HttpHeaders.rangeHeader: 'bytes=2-4'},
      );
      expect(ranged.statusCode, HttpStatus.partialContent);
      expect(
        ranged.headers[HttpHeaders.contentRangeHeader],
        'bytes 2-4/10',
      );
      expect(utf8.decode(ranged.bodyBytes), '234');
    });

    test('未实现 localProxy 的站返回 404 不静默', () async {
      addTearDown(() async {
        LocalMediaProxy.instance.debugResetForTest();
      });
      final proxy = LocalMediaProxy.instance;
      final sessionUrl = await proxy.registerHandler(
        handler: (uri) async => null,
      );
      final response = await http.get(Uri.parse('$sessionUrl/x.m3u8'));
      expect(response.statusCode, HttpStatus.notFound);
    });
  });

  group('本地代理带头上游', () {
    test('register 的头原样送到上游', () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await origin.close(force: true);
        LocalMediaProxy.instance.debugResetForTest();
      });
      var seenReferer = '';
      var seenCookie = '';
      origin.listen((request) async {
        seenReferer = request.headers.value('referer') ?? '';
        seenCookie = request.headers.value(HttpHeaders.cookieHeader) ?? '';
        request.response.add(utf8.encode('ok'));
        await request.response.close();
      });
      final proxyUrl = await LocalMediaProxy.instance.register(
        targetUrl: 'http://127.0.0.1:${origin.port}/v.m3u8',
        headers: {
          'Referer': 'http://example.com/',
          'Cookie': 'k=v',
        },
      );
      final response = await http.get(Uri.parse(proxyUrl));
      expect(response.statusCode, 200);
      expect(seenReferer, 'http://example.com/');
      expect(seenCookie, 'k=v');
    });
  });
}
