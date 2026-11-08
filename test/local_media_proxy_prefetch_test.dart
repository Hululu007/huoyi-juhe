import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:fqapp/services/local_media_proxy.dart';

/// 起一个带延迟的假上游：每个分片回包前睡 [delay]，并记录同时在途
/// 的最大并发数——用来证明预取是多路并行而不是逐个串行。
class _SlowOrigin {
  _SlowOrigin(this.delay);

  final Duration delay;
  late HttpServer server;
  int inFlight = 0;
  int maxConcurrent = 0;
  final hits = <String, int>{};

  Future<int> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        final path = request.uri.path;
        if (path == '/list.m3u8') {
          request.response.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          request.response.write(
            '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n'
            '#EXTINF:10,\nseg0.ts\n#EXTINF:10,\nseg1.ts\n'
            '#EXTINF:10,\nseg2.ts\n#EXTINF:10,\nseg3.ts\n'
            '#EXTINF:10,\nseg4.ts\n#EXTINF:10,\nseg5.ts\n'
            '#EXTINF:10,\nseg6.ts\n#EXTINF:10,\nseg7.ts\n'
            '#EXT-X-ENDLIST\n',
          );
        } else if (path.startsWith('/seg')) {
          hits[path] = (hits[path] ?? 0) + 1;
          inFlight++;
          if (inFlight > maxConcurrent) maxConcurrent = inFlight;
          await Future<void>.delayed(delay);
          inFlight--;
          request.response.headers.contentType =
              ContentType('video', 'MP2T');
          request.response.add(utf8.encode('$path-body-0123456789'));
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      } catch (_) {}
    });
    return server.port;
  }

  Future<void> close() async => server.close(force: true);
}

List<String> _segmentUrls(String playlistBody) => playlistBody
    .split('\n')
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty && !line.startsWith('#'))
    .toList();

void main() {
  test('多线程拉流：播放列表下发后 4 路并发预取，随后分片走缓存', () async {
    final origin = _SlowOrigin(const Duration(milliseconds: 300));
    final port = await origin.start();
    addTearDown(() async {
      await origin.close();
      LocalMediaProxy.instance.debugResetForTest();
    });

    final proxy = LocalMediaProxy.instance;
    final proxyUrl = await proxy.register(
      targetUrl: 'http://127.0.0.1:$port/list.m3u8',
      headers: const {},
    );
    final playlist = await http.get(Uri.parse(proxyUrl));
    expect(playlist.statusCode, 200);
    final segments = _segmentUrls(playlist.body);
    expect(segments.length, 8);

    // 4 个分片各睡 300ms：串行要 1200ms，并发 4 路约 300ms。
    final sw = Stopwatch()..start();
    await proxy.debugWaitForPrefetchIdle();
    sw.stop();
    expect(sw.elapsedMilliseconds, lessThan(1000));
    expect(origin.maxConcurrent, 4);
    final stats = proxy.prefetchStatsForTest();
    expect(stats['started'], 4);
    expect(stats['completed'], 4);
    expect(stats['cachedEntries'], 4);
    // 预取只取了前 4 个分片：后 4 个上游一次没被敲过。
    expect(origin.hits.containsKey('/seg4.ts'), isFalse);

    // 缓存命中的分片不再等上游 300ms 延迟。
    final hitSw = Stopwatch()..start();
    final seg2 = await http.get(Uri.parse(segments[2]));
    hitSw.stop();
    expect(seg2.statusCode, 200);
    expect(seg2.body, '/seg2.ts-body-0123456789');
    expect(hitSw.elapsedMilliseconds, lessThan(150));
    expect(origin.hits['/seg2.ts'], 1);
    expect(proxy.prefetchStatsForTest()['cacheHits'], 1);
  });

  test('多线程拉流：取到某分片后滑动窗口往后预取', () async {
    final origin = _SlowOrigin(const Duration(milliseconds: 200));
    final port = await origin.start();
    addTearDown(() async {
      await origin.close();
      LocalMediaProxy.instance.debugResetForTest();
    });

    final proxy = LocalMediaProxy.instance;
    final proxyUrl = await proxy.register(
      targetUrl: 'http://127.0.0.1:$port/list.m3u8',
      headers: const {},
    );
    final playlist = await http.get(Uri.parse(proxyUrl));
    final segments = _segmentUrls(playlist.body);
    await proxy.debugWaitForPrefetchIdle();
    expect(proxy.prefetchStatsForTest()['completed'], 4);

    // 取 seg0（缓存命中）→ 窗口滑到 seg4，seg4 被预取进来。
    final seg0 = await http.get(Uri.parse(segments[0]));
    expect(seg0.statusCode, 200);
    await proxy.debugWaitForPrefetchIdle();
    expect(proxy.prefetchStatsForTest()['completed'], 5);
    expect(origin.hits.containsKey('/seg4.ts'), isTrue);
    final seg4 = await http.get(Uri.parse(segments[4]));
    expect(seg4.statusCode, 200);
    expect(seg4.body, '/seg4.ts-body-0123456789');
  });

  test('多线程拉流：缓存命中仍支持 Range 切片', () async {
    final origin = _SlowOrigin(const Duration(milliseconds: 100));
    final port = await origin.start();
    addTearDown(() async {
      await origin.close();
      LocalMediaProxy.instance.debugResetForTest();
    });

    final proxy = LocalMediaProxy.instance;
    final proxyUrl = await proxy.register(
      targetUrl: 'http://127.0.0.1:$port/list.m3u8',
      headers: const {},
    );
    final playlist = await http.get(Uri.parse(proxyUrl));
    final segments = _segmentUrls(playlist.body);
    await proxy.debugWaitForPrefetchIdle();
    final seg1 = await http.get(
      Uri.parse(segments[1]),
      headers: {HttpHeaders.rangeHeader: 'bytes=2-5'},
    );
    expect(seg1.statusCode, 206);
    expect(seg1.body, 'eg1.');
    expect(seg1.headers['content-range'], 'bytes 2-5/24');
  });

  test('多线程拉流：变体播放列表不预取、不缓存，两次取都重改写', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = origin.port;
    origin.listen((request) async {
      try {
        final path = request.uri.path;
        if (path == '/master.m3u8') {
          request.response.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          request.response.write(
            '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=848x480\n'
            'low.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720\n'
            'high.m3u8\n',
          );
        } else if (path == '/low.m3u8' || path == '/high.m3u8') {
          request.response.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          request.response.write(
            '#EXTM3U\n#EXTINF:10,\nseg0.ts\n#EXT-X-ENDLIST\n',
          );
        } else if (path == '/seg0.ts') {
          request.response.add(utf8.encode('0123456789'));
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      } catch (_) {}
    });
    addTearDown(() async {
      await origin.close(force: true);
      LocalMediaProxy.instance.debugResetForTest();
    });

    final proxy = LocalMediaProxy.instance;
    final masterUrl = await proxy.register(
      targetUrl: 'http://127.0.0.1:$port/master.m3u8',
      headers: const {},
    );
    final master = await http.get(Uri.parse(masterUrl));
    expect(master.statusCode, 200);
    await proxy.debugWaitForPrefetchIdle();
    // 主列表只有变体行：一个分片都没预取。
    expect(proxy.prefetchStatsForTest()['started'], 0);
    final variantUrl = _segmentUrls(master.body).first;
    final variant1 = await http.get(Uri.parse(variantUrl));
    expect(variant1.statusCode, 200);
    expect(variant1.body, contains('/r/'));
    expect(variant1.body, isNot(contains('/seg0.ts"')));
    // 变体列表的 1 个分片被预取；变体列表本身没进缓存，再取一次
    // 仍是重新拉取改写后的（不是上游原样）。
    await proxy.debugWaitForPrefetchIdle();
    expect(proxy.prefetchStatsForTest()['started'], 1);
    final variant2 = await http.get(Uri.parse(variantUrl));
    expect(variant2.statusCode, 200);
    expect(variant2.body, contains('/r/'));
  });

  test('多线程拉流：预取的分片 404 不拦播放，其余分片照常', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = origin.port;
    origin.listen((request) async {
      try {
        final path = request.uri.path;
        if (path == '/list.m3u8') {
          request.response.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          request.response.write(
            '#EXTM3U\n#EXTINF:10,\nseg0.ts\n#EXTINF:10,\nseg404.ts\n'
            '#EXTINF:10,\nseg1.ts\n#EXT-X-ENDLIST\n',
          );
        } else if (path == '/seg0.ts' || path == '/seg1.ts') {
          request.response.add(utf8.encode('$path-ok'));
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      } catch (_) {}
    });
    addTearDown(() async {
      await origin.close(force: true);
      LocalMediaProxy.instance.debugResetForTest();
    });

    final proxy = LocalMediaProxy.instance;
    final proxyUrl = await proxy.register(
      targetUrl: 'http://127.0.0.1:$port/list.m3u8',
      headers: const {},
    );
    final playlist = await http.get(Uri.parse(proxyUrl));
    final segments = _segmentUrls(playlist.body);
    expect(segments.length, 3);
    await proxy.debugWaitForPrefetchIdle();
    expect(proxy.prefetchStatsForTest()['started'], 3);
    expect(proxy.prefetchStatsForTest()['completed'], 2);
    final bad = await http.get(Uri.parse(segments[1]));
    expect(bad.statusCode, 404);
    final good = await http.get(Uri.parse(segments[2]));
    expect(good.statusCode, 200);
    expect(good.body, '/seg1.ts-ok');
  });
}
