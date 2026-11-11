import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/player_sleep_timer.dart';

void main() {
  test('分钟档到期前 poll 为 false，到期后为 true 且只触发一次', () {
    var now = DateTime(2026, 11, 11, 12, 0);
    final timer = PlayerSleepTimer(now: () => now);
    timer.afterMinutes(30);
    expect(timer.active, isTrue);
    expect(timer.label, '30 分钟后');
    expect(timer.poll(), isFalse);
    now = now.add(const Duration(minutes: 29));
    expect(timer.poll(), isFalse);
    expect(timer.remaining, const Duration(minutes: 1));
    now = now.add(const Duration(minutes: 1));
    expect(timer.poll(), isTrue);
    expect(timer.active, isFalse);
    expect(timer.label, '关闭');
    expect(timer.poll(), isFalse);
  });

  test('集数档每集播完扣一集，扣到 0 才停', () {
    final timer = PlayerSleepTimer();
    timer.afterEpisodes(3);
    expect(timer.label, '再播完 3 集');
    expect(timer.episodeEnded(), isFalse);
    expect(timer.episodesLeft, 2);
    expect(timer.episodeEnded(), isFalse);
    expect(timer.episodeEnded(), isTrue);
    expect(timer.active, isFalse);
  });

  test('播完本集就是再播 1 集；分钟档到期时 episodeEnded 同样返回 true', () {
    var now = DateTime(2026, 11, 11, 12, 0);
    final byEpisode = PlayerSleepTimer(now: () => now);
    PlayerSleepChoice.endOfEpisode.applyTo(byEpisode);
    expect(byEpisode.episodesLeft, 1);
    expect(byEpisode.episodeEnded(), isTrue);

    final byMinutes = PlayerSleepTimer(now: () => now);
    PlayerSleepChoice.minutes15.applyTo(byMinutes);
    expect(byMinutes.episodeEnded(), isFalse);
    now = now.add(const Duration(minutes: 15));
    expect(byMinutes.episodeEnded(), isTrue);
  });

  test('后设的档覆盖先设的；cancel 后全清', () {
    final timer = PlayerSleepTimer();
    timer.afterMinutes(60);
    timer.afterEpisodes(2);
    expect(timer.remaining, isNull);
    expect(timer.episodesLeft, 2);
    timer.cancel();
    expect(timer.active, isFalse);
  });

  test('档位越界抛错；currentOf 能从计时器反推档位', () {
    final timer = PlayerSleepTimer();
    expect(() => timer.afterMinutes(0), throwsArgumentError);
    expect(() => timer.afterMinutes(181), throwsArgumentError);
    expect(() => timer.afterEpisodes(0), throwsArgumentError);
    expect(() => timer.afterEpisodes(11), throwsArgumentError);
    expect(PlayerSleepChoice.currentOf(timer), PlayerSleepChoice.off);
    timer.afterMinutes(30);
    expect(PlayerSleepChoice.currentOf(timer), PlayerSleepChoice.minutes30);
    timer.afterEpisodes(1);
    expect(
      PlayerSleepChoice.currentOf(timer),
      PlayerSleepChoice.endOfEpisode,
    );
  });
}
