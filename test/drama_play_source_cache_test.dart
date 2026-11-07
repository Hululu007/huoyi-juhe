import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/episode_source_cache.dart';

void main() {
  group('DramaPlaySourceCache（解析结果跨页缓存）', () {
    test('同一站+视频+集只解析一次，第二次不触发取流', () async {
      var now = Duration.zero;
      var calls = 0;
      final cache = DramaPlaySourceCache.forTest(now: () => now);
      Future<DramaPlaySource> loader() async {
        calls++;
        return DramaPlaySource(
          url: 'https://example.invalid/s1/v1/e1.m3u8',
          keyHex: 'abcd',
          headers: const {'Referer': 'https://example.invalid/'},
        );
      }

      final first = await cache.resolve(
        siteId: 'site-a',
        seriesId: 'v1',
        videoId: 'e1',
        loader: loader,
      );
      final second = await cache.resolve(
        siteId: 'site-a',
        seriesId: 'v1',
        videoId: 'e1',
        loader: loader,
      );
      expect(calls, 1);
      expect(second.url, first.url);
      expect(second.keyHex, 'abcd');
      expect(second.headers['Referer'], 'https://example.invalid/');
    });

    test('并发请求同键只解析一次', () async {
      var calls = 0;
      final cache = DramaPlaySourceCache.forTest(now: () => Duration.zero);
      final results = await Future.wait([
        cache.resolve(
          siteId: 'site-a',
          seriesId: 'v1',
          videoId: 'e1',
          loader: () async {
            calls++;
            await Future<void>.delayed(Duration.zero);
            return const DramaPlaySource(
              url: 'https://example.invalid/e1.m3u8',
            );
          },
        ),
        cache.resolve(
          siteId: 'site-a',
          seriesId: 'v1',
          videoId: 'e1',
          loader: () async {
            calls++;
            return const DramaPlaySource(
              url: 'https://example.invalid/other.m3u8',
            );
          },
        ),
      ]);
      expect(calls, 1);
      expect(results[0].url, results[1].url);
    });

    test('站、视频、集任一不同都要重新解析', () async {
      var calls = 0;
      final cache = DramaPlaySourceCache.forTest(now: () => Duration.zero);
      Future<DramaPlaySource> loader(String tag) async {
        calls++;
        return DramaPlaySource(url: 'https://example.invalid/$tag.m3u8');
      }

      await cache.resolve(
        siteId: 'site-a',
        seriesId: 'v1',
        videoId: 'e1',
        loader: () => loader('a-v1-e1'),
      );
      await cache.resolve(
        siteId: 'site-b',
        seriesId: 'v1',
        videoId: 'e1',
        loader: () => loader('b-v1-e1'),
      );
      await cache.resolve(
        siteId: 'site-a',
        seriesId: 'v2',
        videoId: 'e1',
        loader: () => loader('a-v2-e1'),
      );
      await cache.resolve(
        siteId: 'site-a',
        seriesId: 'v1',
        videoId: 'e2',
        loader: () => loader('a-v1-e2'),
      );
      expect(calls, 4);
    });

    test('10 分钟内命中、过期后重新解析', () async {
      var now = Duration.zero;
      var calls = 0;
      final cache = DramaPlaySourceCache.forTest(now: () => now);
      Future<DramaPlaySource> loader() async {
        calls++;
        return DramaPlaySource(
          url: 'https://example.invalid/e1-$calls.m3u8',
        );
      }

      final first = await cache.resolve(
        siteId: 'site-a',
        seriesId: 'v1',
        videoId: 'e1',
        loader: loader,
      );
      now = const Duration(minutes: 9, seconds: 59);
      final stillCached = await cache.resolve(
        siteId: 'site-a',
        seriesId: 'v1',
        videoId: 'e1',
        loader: loader,
      );
      expect(calls, 1);
      expect(stillCached.url, first.url);
      now = const Duration(minutes: 10);
      final expired = await cache.resolve(
        siteId: 'site-a',
        seriesId: 'v1',
        videoId: 'e1',
        loader: loader,
      );
      expect(calls, 2);
      expect(expired.url, isNot(first.url));
    });

    test('解析失败不缓存，失败后再次调用重新取流', () async {
      var calls = 0;
      final cache = DramaPlaySourceCache.forTest(now: () => Duration.zero);
      Future<DramaPlaySource> loader() async {
        calls++;
        if (calls == 1) throw StateError('解析失败');
        return const DramaPlaySource(url: 'https://example.invalid/e1.m3u8');
      }

      await expectLater(
        () => cache.resolve(
          siteId: 'site-a',
          seriesId: 'v1',
          videoId: 'e1',
          loader: loader,
        ),
        throwsStateError,
      );
      final retry = await cache.resolve(
        siteId: 'site-a',
        seriesId: 'v1',
        videoId: 'e1',
        loader: loader,
      );
      expect(calls, 2);
      expect(retry.url, 'https://example.invalid/e1.m3u8');
      // 成功后再次调用命中缓存，不再解析。
      await cache.resolve(
        siteId: 'site-a',
        seriesId: 'v1',
        videoId: 'e1',
        loader: loader,
      );
      expect(calls, 2);
    });

    test('预取暖缓存：预取后点播不再触发取流，预取失败不影响点播', () async {
      var calls = 0;
      final cache = DramaPlaySourceCache.forTest(now: () => Duration.zero);
      cache.prefetch(
        siteId: 'site-a',
        seriesId: 'v1',
        videoId: 'e2',
        loader: () async {
          calls++;
          return const DramaPlaySource(
            url: 'https://example.invalid/e2.m3u8',
          );
        },
      );
      cache.prefetch(
        siteId: 'site-a',
        seriesId: 'v1',
        videoId: 'e3',
        loader: () async {
          calls++;
          throw StateError('预取失败');
        },
      );
      await Future<void>.delayed(Duration.zero);
      final hit = await cache.resolve(
        siteId: 'site-a',
        seriesId: 'v1',
        videoId: 'e2',
        loader: () async {
          calls++;
          return const DramaPlaySource(
            url: 'https://example.invalid/e2-again.m3u8',
          );
        },
      );
      expect(hit.url, 'https://example.invalid/e2.m3u8');
      expect(calls, 2);
      final retried = await cache.resolve(
        siteId: 'site-a',
        seriesId: 'v1',
        videoId: 'e3',
        loader: () async {
          calls++;
          return const DramaPlaySource(
            url: 'https://example.invalid/e3.m3u8',
          );
        },
      );
      expect(retried.url, 'https://example.invalid/e3.m3u8');
      expect(calls, 3);
    });

    test('容量上限：最旧的条目先被淘汰', () async {
      final cache = DramaPlaySourceCache.forTest(now: () => Duration.zero);
      Future<DramaPlaySource> loader(String id) async =>
          DramaPlaySource(url: 'https://example.invalid/$id.m3u8');
      for (var i = 0; i <= DramaPlaySourceCache.capacity; i++) {
        await cache.resolve(
          siteId: 'site-a',
          seriesId: 'v1',
          videoId: 'e$i',
          loader: () => loader('e$i'),
        );
      }
      var calls = 0;
      await cache.resolve(
        siteId: 'site-a',
        seriesId: 'v1',
        videoId: 'e0',
        loader: () async {
          calls++;
          return loader('e0');
        },
      );
      expect(calls, 1, reason: '最旧的 e0 应已被淘汰、重新解析');
      await cache.resolve(
        siteId: 'site-a',
        seriesId: 'v1',
        videoId: 'e${DramaPlaySourceCache.capacity}',
        loader: () async {
          calls++;
          return loader('latest');
        },
      );
      expect(calls, 1, reason: '最新的条目应仍在缓存里');
    });

    test('键含站+视频+集，拼法一致', () {
      expect(
        DramaPlaySourceCache.keyFor(
          siteId: 'a',
          seriesId: 'v',
          videoId: 'e',
        ),
        isNot(
          DramaPlaySourceCache.keyFor(
            siteId: 'a',
            seriesId: 'v',
            videoId: 'e2',
          ),
        ),
      );
    });
  });
}
