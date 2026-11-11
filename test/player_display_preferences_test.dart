import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/player_display_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('没存过画面模式时返回 null，调用方按撑满开关推导', () async {
    expect(await PlayerDisplayPreferences.loadMode(), isNull);
    expect(PlayerDisplayMode.fromStored('zoom'), PlayerDisplayMode.zoom);
    expect(PlayerDisplayMode.fromStored('fill'), PlayerDisplayMode.fill);
    expect(PlayerDisplayMode.fromStored('nope'), isNull);
    expect(PlayerDisplayMode.fromStored(null), isNull);
  });

  test('画面模式三档落盘后能读回；只有拉伸不可立即生效', () async {
    for (final mode in PlayerDisplayMode.values) {
      await PlayerDisplayPreferences.saveMode(mode);
      expect(await PlayerDisplayPreferences.loadMode(), mode);
    }
    expect(PlayerDisplayMode.fit.appliableNow, isTrue);
    expect(PlayerDisplayMode.zoom.appliableNow, isTrue);
    expect(PlayerDisplayMode.fill.appliableNow, isFalse);
  });

  test('旋转角只认 0/90/180/270，其余归 0；只有 0°/180° 可立即生效', () async {
    expect(PlayerRotation.normalize(90), 90);
    expect(PlayerRotation.normalize(270), 270);
    expect(PlayerRotation.normalize(45), 0);
    expect(PlayerRotation.normalize(-90), 0);
    expect(PlayerRotation.appliableNow(0), isTrue);
    expect(PlayerRotation.appliableNow(180), isTrue);
    expect(PlayerRotation.appliableNow(90), isFalse);
    expect(PlayerRotation.appliableNow(270), isFalse);

    await PlayerDisplayPreferences.saveRotation(180);
    expect(await PlayerDisplayPreferences.loadRotation(), 180);
    await PlayerDisplayPreferences.saveRotation(45);
    expect(await PlayerDisplayPreferences.loadRotation(), 0);
  });

  test('旋转角默认 0°', () async {
    expect(await PlayerDisplayPreferences.loadRotation(), 0);
  });
}
