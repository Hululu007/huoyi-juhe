import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/hongguo_account.dart';
import 'package:fqapp/services/playback_resume.dart';

void main() {
  List<Chapter> episodes() => [
    Chapter(itemId: '1001', title: '第1集', volumeName: ''),
    Chapter(itemId: '1002', title: '第2集', volumeName: ''),
    Chapter(itemId: '1003', title: '第3集', volumeName: ''),
  ];

  Map<String, dynamic> localSaved({
    String episodeId = '1002',
    int episode = 1,
    double position = 30,
    double duration = 120,
    int time = 1000,
  }) => {
    'episodeId': episodeId,
    'episode': episode,
    'position': position,
    'duration': duration,
    'time': time,
  };

  HongguoCloudProgress cloud({
    String episodeId = '1003',
    int episodeIndex = 2,
    int positionMs = 50000,
    int durationMs = 120000,
    int updatedAtMs = 2000,
  }) => HongguoCloudProgress(
    seriesId: '123',
    episodeId: episodeId,
    episodeIndex: episodeIndex,
    positionMs: positionMs,
    durationMs: durationMs,
    updatedAtMs: updatedAtMs,
  );

  group('PlaybackResume.resolve', () {
    test('local only: resumes the saved episode at the saved second', () {
      final point = PlaybackResume.resolve(
        saved: localSaved(),
        cloud: null,
        seriesId: '123',
        episodes: episodes(),
      );
      expect(point, isNotNull);
      expect(point!.episodeIndex, 1);
      expect(point.positionMs, 30000);
      expect(point.durationMs, 120000);
      expect(point.fromCloud, isFalse);
    });

    test('newer cloud wins over local', () {
      final point = PlaybackResume.resolve(
        saved: localSaved(),
        cloud: cloud(),
        seriesId: '123',
        episodes: episodes(),
      );
      expect(point, isNotNull);
      expect(point!.episodeIndex, 2);
      expect(point.positionMs, 50000);
      expect(point.fromCloud, isTrue);
    });

    test('older cloud loses to local', () {
      final point = PlaybackResume.resolve(
        saved: localSaved(),
        cloud: cloud(updatedAtMs: 500),
        seriesId: '123',
        episodes: episodes(),
      );
      expect(point, isNotNull);
      expect(point!.episodeIndex, 1);
      expect(point.fromCloud, isFalse);
    });

    test('equal timestamps prefer local (the one just watched)', () {
      final point = PlaybackResume.resolve(
        saved: localSaved(),
        cloud: cloud(updatedAtMs: 1000),
        seriesId: '123',
        episodes: episodes(),
      );
      expect(point, isNotNull);
      expect(point!.episodeIndex, 1);
      expect(point.fromCloud, isFalse);
    });

    test('finished cloud record restarts that episode from zero', () {
      final point = PlaybackResume.resolve(
        saved: localSaved(),
        cloud: cloud(positionMs: 118000),
        seriesId: '123',
        episodes: episodes(),
      );
      expect(point, isNotNull);
      expect(point!.episodeIndex, 2);
      expect(point.positionMs, 0);
    });

    test('cloud pointing outside the episode list falls back to local', () {
      final point = PlaybackResume.resolve(
        saved: localSaved(),
        cloud: cloud(episodeId: '9999', episodeIndex: 99),
        seriesId: '123',
        episodes: episodes(),
      );
      expect(point, isNotNull);
      expect(point!.episodeIndex, 1);
      expect(point.fromCloud, isFalse);
    });

    test('cloud episode id locates the episode even if the index moved', () {
      final point = PlaybackResume.resolve(
        saved: localSaved(),
        cloud: cloud(episodeId: '1001', episodeIndex: 99),
        seriesId: '123',
        episodes: episodes(),
      );
      expect(point, isNotNull);
      expect(point!.episodeIndex, 0);
      expect(point.fromCloud, isTrue);
    });

    test('no records at all returns null (play from the start)', () {
      expect(
        PlaybackResume.resolve(
          saved: null,
          cloud: null,
          seriesId: '123',
          episodes: episodes(),
        ),
        isNull,
      );
    });

    test('local position at zero is not a resume point', () {
      expect(
        PlaybackResume.resolve(
          saved: localSaved(position: 0),
          cloud: null,
          seriesId: '123',
          episodes: episodes(),
        ),
        isNull,
      );
    });
  });

  group('PlaybackResume.localProgress', () {
    test('builds a cloud-shaped record from the saved map', () {
      final progress = PlaybackResume.localProgress(
        saved: localSaved(),
        seriesId: '123',
        episodes: episodes(),
      );
      expect(progress, isNotNull);
      expect(progress!.episodeId, '1002');
      expect(progress.episodeIndex, 1);
      expect(progress.positionMs, 30000);
      expect(progress.updatedAtMs, 1000);
    });
  });
}
