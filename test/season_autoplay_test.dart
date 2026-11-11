import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/season_autoplay.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('跨季连播默认关（对照 ViewingPreferences.seasonAutoplay=false）', () async {
    expect(await SeasonAutoplayPreference.load(), isFalse);
  });

  test('开关落盘后能读回', () async {
    await SeasonAutoplayPreference.save(true);
    expect(await SeasonAutoplayPreference.load(), isTrue);
    await SeasonAutoplayPreference.save(false);
    expect(await SeasonAutoplayPreference.load(), isFalse);
  });

  test('门禁：五道门缺一道都不跨季', () {
    // 全开才放行。
    expect(
      shouldContinueToNextSeason(
        seasonAutoplay: true,
        autoAdvance: true,
        isLastEpisode: true,
        sleepStopped: false,
        hasNextSeason: true,
      ),
      isTrue,
    );
    // 开关关。
    expect(
      shouldContinueToNextSeason(
        seasonAutoplay: false,
        autoAdvance: true,
        isLastEpisode: true,
        sleepStopped: false,
        hasNextSeason: true,
      ),
      isFalse,
    );
    // 自动连播关（对照 finishSeason 要求 autoNext 同开）。
    expect(
      shouldContinueToNextSeason(
        seasonAutoplay: true,
        autoAdvance: false,
        isLastEpisode: true,
        sleepStopped: false,
        hasNextSeason: true,
      ),
      isFalse,
    );
    // 不是末集。
    expect(
      shouldContinueToNextSeason(
        seasonAutoplay: true,
        autoAdvance: true,
        isLastEpisode: false,
        sleepStopped: false,
        hasNextSeason: true,
      ),
      isFalse,
    );
    // 定时停止拦住。
    expect(
      shouldContinueToNextSeason(
        seasonAutoplay: true,
        autoAdvance: true,
        isLastEpisode: true,
        sleepStopped: true,
        hasNextSeason: true,
      ),
      isFalse,
    );
    // 没有下一季数据源（树里当前状态）：恒不触发。
    expect(
      shouldContinueToNextSeason(
        seasonAutoplay: true,
        autoAdvance: true,
        isLastEpisode: true,
        sleepStopped: false,
        hasNextSeason: false,
      ),
      isFalse,
    );
  });
}
