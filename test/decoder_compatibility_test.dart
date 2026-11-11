import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/decoder_compatibility.dart';
import 'package:fqapp/services/episode_source_cache.dart';

void main() {
  group('DecoderLessons', () {
    test('remembers a sized failure without blocking other sizes', () {
      final lessons = DecoderLessons();
      lessons.remember('avc1', 1080, 1920);
      expect(lessons.fails('avc1', 1080, 1920), isTrue);
      // 横屏同编解码不同尺寸不受连坐。
      expect(lessons.fails('avc1', 1920, 1080), isFalse);
      expect(lessons.fails('hevc', 1080, 1920), isFalse);
    });

    test('a sizeless verdict covers the whole codec', () {
      final lessons = DecoderLessons();
      lessons.remember('avc1', null, null);
      expect(lessons.fails('avc1', 1920, 1080), isTrue);
      expect(lessons.fails('avc1', null, null), isTrue);
    });

    test('empty codec records nothing', () {
      final lessons = DecoderLessons();
      expect(lessons.remember('', 1080, 1920), isNull);
      expect(lessons.size, 0);
    });

    test('restore and reset round-trip', () {
      final lessons = DecoderLessons();
      lessons.restore({'avc1|1080|1920', 'hevc'});
      expect(lessons.size, 2);
      expect(lessons.fails('hevc', 720, 1280), isTrue);
      lessons.reset();
      expect(lessons.size, 0);
      expect(lessons.fails('avc1', 1080, 1920), isFalse);
    });
  });

  group('PlaybackStallGuard', () {
    test('position advancing never reports a stall', () {
      final guard = PlaybackStallGuard();
      final start = DateTime(2026, 11, 11, 12);
      expect(
        guard.offer(
          episodeId: 'e1',
          positionMs: 1000,
          playing: true,
          buffering: false,
          now: start,
        ),
        isFalse,
      );
      expect(
        guard.offer(
          episodeId: 'e1',
          positionMs: 6000,
          playing: true,
          buffering: false,
          now: start.add(const Duration(seconds: 25)),
        ),
        isFalse,
      );
    });

    test('frozen position while playing fires after the timeout', () {
      final guard = PlaybackStallGuard();
      final start = DateTime(2026, 11, 11, 12);
      guard.offer(
        episodeId: 'e1',
        positionMs: 1000,
        playing: true,
        buffering: false,
        now: start,
      );
      // 19 秒还不够（超时 20 秒）。
      expect(
        guard.offer(
          episodeId: 'e1',
          positionMs: 1000,
          playing: true,
          buffering: false,
          now: start.add(const Duration(seconds: 19)),
        ),
        isFalse,
      );
      expect(
        guard.offer(
          episodeId: 'e1',
          positionMs: 1000,
          playing: true,
          buffering: false,
          now: start.add(const Duration(seconds: 21)),
        ),
        isTrue,
      );
    });

    test('buffering or pausing resets the observation', () {
      final guard = PlaybackStallGuard();
      final start = DateTime(2026, 11, 11, 12);
      guard.offer(
        episodeId: 'e1',
        positionMs: 1000,
        playing: true,
        buffering: false,
        now: start,
      );
      guard.offer(
        episodeId: 'e1',
        positionMs: 1000,
        playing: true,
        buffering: true,
        now: start.add(const Duration(seconds: 30)),
      );
      // 缓冲打断后重新计时：再冻 21 秒才报。
      expect(
        guard.offer(
          episodeId: 'e1',
          positionMs: 1000,
          playing: true,
          buffering: false,
          now: start.add(const Duration(seconds: 31)),
        ),
        isFalse,
      );
      expect(
        guard.offer(
          episodeId: 'e1',
          positionMs: 1000,
          playing: true,
          buffering: false,
          now: start.add(const Duration(seconds: 52)),
        ),
        isTrue,
      );
    });

    test('at most two recoveries per episode', () {
      final guard = PlaybackStallGuard();
      final start = DateTime(2026, 11, 11, 12);
      var now = start;
      var fires = 0;
      for (var i = 0; i < 10; i++) {
        if (guard.offer(
          episodeId: 'e1',
          positionMs: 1000,
          playing: true,
          buffering: false,
          now: now,
        )) {
          fires++;
        }
        now = now.add(const Duration(seconds: 21));
      }
      expect(fires, 2);
    });

    test('switching episodes resets the recovery budget', () {
      final guard = PlaybackStallGuard(maxRecoveries: 1);
      final start = DateTime(2026, 11, 11, 12);
      guard.offer(
        episodeId: 'e1',
        positionMs: 1000,
        playing: true,
        buffering: false,
        now: start,
      );
      expect(
        guard.offer(
          episodeId: 'e1',
          positionMs: 1000,
          playing: true,
          buffering: false,
          now: start.add(const Duration(seconds: 21)),
        ),
        isTrue,
      );
      // 同集已用完预算，换集后重新有一次。
      expect(
        guard.offer(
          episodeId: 'e1',
          positionMs: 1000,
          playing: true,
          buffering: false,
          now: start.add(const Duration(seconds: 42)),
        ),
        isFalse,
      );
      guard.offer(
        episodeId: 'e2',
        positionMs: 0,
        playing: true,
        buffering: false,
        now: start.add(const Duration(seconds: 43)),
      );
      expect(
        guard.offer(
          episodeId: 'e2',
          positionMs: 0,
          playing: true,
          buffering: false,
          now: start.add(const Duration(seconds: 64)),
        ),
        isTrue,
      );
    });
  });

  group('DecoderFallbackPlan.nextAfterFailure', () {
    EpisodeVariant variant(String name) =>
        EpisodeVariant(name: name, url: 'u-$name', keyHex: '', height: 0);

    test('steps down past learned-failed renditions', () {
      final lessons = DecoderLessons();
      lessons.remember(
        DecoderFallbackPlan.lessonKeyForName('720p'),
        null,
        null,
      );
      final variants = [variant('1080p'), variant('720p'), variant('480p')];
      final next = DecoderFallbackPlan.nextAfterFailure(
        variants: variants,
        failedName: '1080p',
        lessons: lessons,
      );
      // 720p 学到过失败，直接跳到 480p。
      expect(next?.name, '480p');
    });

    test('returns null when every other rendition failed', () {
      final lessons = DecoderLessons();
      for (final name in ['720p', '480p']) {
        lessons.remember(
          DecoderFallbackPlan.lessonKeyForName(name),
          null,
          null,
        );
      }
      final variants = [variant('1080p'), variant('720p'), variant('480p')];
      expect(
        DecoderFallbackPlan.nextAfterFailure(
          variants: variants,
          failedName: '1080p',
          lessons: lessons,
        ),
        isNull,
      );
    });

    test('no lessons means the plain next-lower rendition', () {
      final variants = [variant('1080p'), variant('720p'), variant('480p')];
      expect(
        DecoderFallbackPlan.nextAfterFailure(
          variants: variants,
          failedName: '1080p',
          lessons: DecoderLessons(),
        )?.name,
        '720p',
      );
    });
  });
}
