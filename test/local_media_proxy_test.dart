import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:fqapp/services/local_media_proxy.dart';

void main() {
  test('本地代理：m3u8 改写、子资源透传、Range 透传', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = origin.port;
    origin.listen((request) async {
      final path = request.uri.path;
      if (path == '/list.m3u8') {
        request.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        request.response.write(
          '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
          '#EXTINF:10,\nseg0.ts\n',
        );
      } else if (path == '/seg0.ts') {
        final bytes = utf8.encode('0123456789');
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) {
          final match =
              RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
          if (match != null) {
            final start = int.parse(match.group(1)!);
            final end = match.group(2)!.isEmpty
                ? bytes.length - 1
                : int.parse(match.group(2)!);
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${bytes.length}',
            );
            request.response.add(bytes.sublist(start, end + 1));
          } else {
            request.response.add(bytes);
          }
        } else {
          request.response.add(bytes);
        }
      } else if (path == '/key.bin') {
        request.response.add(List<int>.filled(16, 7));
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    addTearDown(() async {
      await origin.close(force: true);
      LocalMediaProxy.instance.debugResetForTest();
    });

    final proxy = LocalMediaProxy.instance;
    final proxyUrl = await proxy.register(
      targetUrl: 'http://127.0.0.1:$port/list.m3u8',
      headers: {'Cookie': 'CloudFront-Policy=POL'},
    );
    final playlist = await http.get(Uri.parse(proxyUrl));
    expect(playlist.statusCode, 200);
    expect(playlist.body, contains('/r/'));
    expect(playlist.body, isNot(contains('127.0.0.1:$port/seg0.ts')));
    final segmentUrl = playlist.body
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => !line.startsWith('#') && line.isNotEmpty);
    final segment = await http.get(
      Uri.parse(segmentUrl),
      headers: {HttpHeaders.rangeHeader: 'bytes=2-5'},
    );
    expect(segment.statusCode, 206);
    expect(segment.body, '2345');
    expect(segment.headers['content-range'], 'bytes 2-5/10');
  });

  test('本地代理：gzip 的 AES-128 m3u8 代理地址带 .m3u8 后缀，密钥与分片可取', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = origin.port;
    // 真站原样：m3u8 经 gzip 下发；密钥是跨站绝对地址；分片是相对名。
    final playlistText =
        '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:8\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="http://127.0.0.1:$port/api/hlskey/index?id=3439",IV=0x3655b0e6aa9f4b77f736d49d6fd01e2c\n'
        '#EXTINF:6.4,\ne1793877055_000.ts\n#EXT-X-ENDLIST\n';
    origin.listen((request) async {
      final path = request.uri.path;
      if (path == '/storage/3439/index.m3u8') {
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
        request.response.add(gzip.encode(utf8.encode(playlistText)));
      } else if (path == '/storage/3439/e1793877055_000.ts') {
        request.response.add(utf8.encode('0123456789'));
      } else if (path == '/api/hlskey/index') {
        request.response.add(List<int>.filled(16, 7));
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    addTearDown(() async {
      await origin.close(force: true);
      LocalMediaProxy.instance.debugResetForTest();
    });

    final proxy = LocalMediaProxy.instance;
    final proxyUrl = await proxy.register(
      targetUrl: 'http://127.0.0.1:$port/storage/3439/index.m3u8',
      headers: {'User-Agent': 'test', 'Referer': 'https://example.test/'},
    );
    // 播放器只凭地址后缀认 HLS：代理地址必须以 .m3u8 结尾，否则
    // ExoPlayer 会把它当 Progressive 流读 m3u8 文本而报解析失败。
    expect(proxyUrl, endsWith('.m3u8'));
    final playlist = await http.get(Uri.parse(proxyUrl));
    expect(playlist.statusCode, 200);
    expect(playlist.body, contains('#EXTM3U'));
    expect(playlist.body, contains('#EXT-X-KEY:METHOD=AES-128'));
    expect(playlist.body, contains('/r/'));
    expect(playlist.body, isNot(contains('/api/hlskey/index?id=3439"')));
    final keyUri = RegExp(r'URI="([^"]+)"')
        .firstMatch(playlist.body)!
        .group(1)!;
    final key = await http.get(Uri.parse(keyUri));
    expect(key.statusCode, 200);
    expect(key.bodyBytes.length, 16);
    final segmentUrl = playlist.body
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => !line.startsWith('#') && line.isNotEmpty);
    final segment = await http.get(Uri.parse(segmentUrl));
    expect(segment.statusCode, 200);
    expect(segment.body, '0123456789');
  });
}
