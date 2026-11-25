import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/intro_outro_skip.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('片头判定 introSkipTargetMs', () {
    const settings = IntroOutroSkipSettings(introSeconds: 90, outroSeconds: 60);

    test('总开关关：不跳', () {
      expect(
        introSkipTargetMs(
          enabled: false,
          settings: settings,
          startMs: 0,
          durationMs: 600000,
        ),
        isNull,
      );
    });

    test('未设置片头：不跳', () {
      expect(
        introSkipTargetMs(
          enabled: true,
          settings: const IntroOutroSkipSettings(outroSeconds: 60),
          startMs: 0,
          durationMs: 600000,
        ),
        isNull,
      );
    });

    test('从头起播：跳到片头秒数', () {
      expect(
        introSkipTargetMs(
          enabled: true,
          settings: settings,
          startMs: 0,
          durationMs: 600000,
        ),
        90000,
      );
    });

    test('续播点在片头内：仍跳到片头（不回拉、只前跳）', () {
      expect(
        introSkipTargetMs(
          enabled: true,
          settings: settings,
          startMs: 30000,
          durationMs: 600000,
        ),
        90000,
      );
    });

    test('续播点已越过片头：不跳（绝不回拉）', () {
      expect(
        introSkipTargetMs(
          enabled: true,
          settings: settings,
          startMs: 120000,
          durationMs: 600000,
        ),
        isNull,
      );
    });

    test('总闸：片头+片尾超过总时长一半，整段抑制', () {
      expect(
        introSkipTargetMs(
          enabled: true,
          settings: const IntroOutroSkipSettings(
            introSeconds: 300,
            outroSeconds: 300,
          ),
          startMs: 0,
          durationMs: 1000000,
        ),
        isNull,
      );
    });

    test('片头比整集还长：不跳', () {
      expect(
        introSkipTargetMs(
          enabled: true,
          settings: const IntroOutroSkipSettings(introSeconds: 700),
          startMs: 0,
          durationMs: 600000,
        ),
        isNull,
      );
    });

    test('时长未知：片头照跳（片尾另判）', () {
      expect(
        introSkipTargetMs(
          enabled: true,
          settings: settings,
          startMs: 0,
          durationMs: 0,
        ),
        90000,
      );
    });
  });

  group('片尾判定 outroSkipDue', () {
    const settings = IntroOutroSkipSettings(introSeconds: 90, outroSeconds: 60);

    bool due({
      bool enabled = true,
      IntroOutroSkipSettings s = settings,
      int positionMs = 545000,
      int durationMs = 600000,
      bool hasNext = true,
    }) => outroSkipDue(
      enabled: enabled,
      settings: s,
      positionMs: positionMs,
      durationMs: durationMs,
      hasNextEpisode: hasNext,
    );

    test('到触发点（时长-片尾）：跳', () => expect(due(), isTrue));
    test('未到触发点：不跳', () => expect(due(positionMs: 500000), isFalse));
    test('没有下一集：不跳', () => expect(due(hasNext: false), isFalse));
    test('总开关关：不跳', () => expect(due(enabled: false), isFalse));
    test('时长未知：不跳', () => expect(due(durationMs: 0), isFalse));
    test('未设置片尾：不跳', () {
      expect(
        due(s: const IntroOutroSkipSettings(introSeconds: 90)),
        isFalse,
      );
    });
    test('总闸超限：不跳', () {
      expect(
        due(
          s: const IntroOutroSkipSettings(
            introSeconds: 300,
            outroSeconds: 300,
          ),
          durationMs: 1000000,
          positionMs: 750000,
        ),
        isFalse,
      );
    });
  });

  group('存储 IntroOutroSkipStore', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('总开关默认开、存读往返', () async {
      expect(await IntroOutroSkipStore.loadEnabled(), isTrue);
      await IntroOutroSkipStore.saveEnabled(false);
      expect(await IntroOutroSkipStore.loadEnabled(), isFalse);
    });

    test('按剧存读、键隔离', () async {
      await IntroOutroSkipStore.saveFor(
        'siteA::d1',
        const IntroOutroSkipSettings(introSeconds: 90, outroSeconds: 45),
      );
      await IntroOutroSkipStore.saveFor(
        'siteA::d2',
        const IntroOutroSkipSettings(introSeconds: 30),
      );
      expect(
        await IntroOutroSkipStore.loadFor('siteA::d1'),
        const IntroOutroSkipSettings(introSeconds: 90, outroSeconds: 45),
      );
      expect(
        await IntroOutroSkipStore.loadFor('siteA::d2'),
        const IntroOutroSkipSettings(introSeconds: 30),
      );
      expect(
        await IntroOutroSkipStore.loadFor('siteA::d3'),
        const IntroOutroSkipSettings(),
      );
    });

    test('设为空即剔除条目', () async {
      await IntroOutroSkipStore.saveFor(
        'k',
        const IntroOutroSkipSettings(introSeconds: 10),
      );
      await IntroOutroSkipStore.saveFor('k', const IntroOutroSkipSettings());
      final prefs = await SharedPreferences.getInstance();
      expect(
        IntroOutroSkipStore.decodeMap(
          prefs.getString(IntroOutroSkipStore.mapKey),
        ),
        isNot(contains('k')),
      );
    });

    test('秒数钳制 0..3600（存时与读坏数据时都钳）', () async {
      await IntroOutroSkipStore.saveFor(
        'k',
        const IntroOutroSkipSettings(introSeconds: 10).copyWith(
          introSeconds: 7200,
          outroSeconds: -5,
        ),
      );
      final loaded = await IntroOutroSkipStore.loadFor('k');
      expect(loaded.introSeconds, introOutroMaxSeconds);
      expect(loaded.outroSeconds, 0);
    });

    test('坏 JSON：回空设置不抛', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        IntroOutroSkipStore.mapKey: '{oops',
      });
      expect(
        await IntroOutroSkipStore.loadFor('k'),
        const IntroOutroSkipSettings(),
      );
    });
  });
}
