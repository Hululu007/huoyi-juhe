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
}
