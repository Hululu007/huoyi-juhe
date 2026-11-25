import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/playback_fallback.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('失败分类 classifyPlaybackFailureText', () {
    test('格式优先于解码：带 codec 的格式错误判格式', () {
      expect(
        classifyPlaybackFailureText('unsupported format for codec h264'),
        PlaybackFailureKind.formatUnsupported,
      );
      expect(
        classifyPlaybackFailureText('moov atom not found'),
        PlaybackFailureKind.formatUnsupported,
      );
    });

    test('解码类', () {
      expect(
        classifyPlaybackFailureText('MediaCodec decoder_init_failed'),
        PlaybackFailureKind.decode,
      );
      expect(
        classifyPlaybackFailureText('视频解码失败'),
        PlaybackFailureKind.decode,
      );
    });

    test('解码优先于网络：解码文案带 http 仍判解码', () {
      expect(
        classifyPlaybackFailureText('decoder error opening http stream'),
        PlaybackFailureKind.decode,
      );
    });

    test('网络类', () {
      expect(
        classifyPlaybackFailureText('SocketException: connection reset by peer'),
        PlaybackFailureKind.network,
      );
      expect(
        classifyPlaybackFailureText('HTTP 503 Service Unavailable'),
        PlaybackFailureKind.network,
      );
    });

    test('都不命中回 other（含空串）', () {
      expect(classifyPlaybackFailureText(''), PlaybackFailureKind.other);
      expect(
        classifyPlaybackFailureText('something weird happened'),
        PlaybackFailureKind.other,
      );
    });
  });

  group('档位 allows', () {
    test('all 全放行、off 全拦', () {
      for (final kind in PlaybackFailureKind.values) {
        expect(PlaybackFallbackMode.all.allows(kind), isTrue);
        expect(PlaybackFallbackMode.off.allows(kind), isFalse);
      }
    });

    test('decodeOnly 只放解码与格式', () {
      expect(
        PlaybackFallbackMode.decodeOnly.allows(PlaybackFailureKind.decode),
        isTrue,
      );
      expect(
        PlaybackFallbackMode.decodeOnly.allows(
          PlaybackFailureKind.formatUnsupported,
        ),
        isTrue,
      );
      expect(
        PlaybackFallbackMode.decodeOnly.allows(PlaybackFailureKind.network),
        isFalse,
      );
      expect(
        PlaybackFallbackMode.decodeOnly.allows(PlaybackFailureKind.other),
        isFalse,
      );
    });

    test('playerOnly 只拦网络', () {
      expect(
        PlaybackFallbackMode.playerOnly.allows(PlaybackFailureKind.network),
        isFalse,
      );
      expect(
        PlaybackFallbackMode.playerOnly.allows(PlaybackFailureKind.other),
        isTrue,
      );
    });
  });

  group('控制器 PlaybackFallbackController', () {
    test('按阶梯顺序走，每步只试一次，走完回 null', () {
      final controller = PlaybackFallbackController();
      expect(
        controller.advance(PlaybackFailureKind.network),
        PlaybackFallbackStep.refreshSource,
      );
      expect(
        controller.advance(PlaybackFailureKind.network),
        PlaybackFallbackStep.switchVariant,
      );
      expect(
        controller.advance(PlaybackFailureKind.decode),
        PlaybackFallbackStep.decoderSoft,
      );
      expect(controller.advance(PlaybackFailureKind.decode), isNull);
      expect(controller.hasUntried, isFalse);
      expect(controller.attemptOrder, PlaybackFallbackStep.values);
    });

    test('档位拦截：off 档第一步就回 null 且不记已试', () {
      final controller = PlaybackFallbackController(
        mode: PlaybackFallbackMode.off,
      );
      expect(controller.advance(PlaybackFailureKind.decode), isNull);
      expect(controller.attemptOrder, isEmpty);
      expect(controller.hasUntried, isTrue);
    });

    test('decodeOnly 档网络失败被拦、解码失败放行', () {
      final controller = PlaybackFallbackController(
        mode: PlaybackFallbackMode.decodeOnly,
      );
      expect(controller.advance(PlaybackFailureKind.network), isNull);
      expect(
        controller.advance(PlaybackFailureKind.decode),
        PlaybackFallbackStep.refreshSource,
      );
    });

    test('收窄阶梯：去掉 switchVariant 后直接到 decoderSoft', () {
      final controller = PlaybackFallbackController();
      controller.configure(
        ladder: const [
          PlaybackFallbackStep.refreshSource,
          PlaybackFallbackStep.decoderSoft,
        ],
      );
      expect(
        controller.advance(PlaybackFailureKind.other),
        PlaybackFallbackStep.refreshSource,
      );
      expect(
        controller.advance(PlaybackFailureKind.other),
        PlaybackFallbackStep.decoderSoft,
      );
      expect(controller.advance(PlaybackFailureKind.other), isNull);
    });

    test('reset 清已试、可换档位', () {
      final controller = PlaybackFallbackController();
      controller.advance(PlaybackFailureKind.other);
      controller.reset(mode: PlaybackFallbackMode.decodeOnly);
      expect(controller.attemptOrder, isEmpty);
      expect(controller.mode, PlaybackFallbackMode.decodeOnly);
      expect(
        controller.advance(PlaybackFailureKind.decode),
        PlaybackFallbackStep.refreshSource,
      );
    });
  });

  group('档位存储', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('默认 all；存读往返；坏值回默认', () async {
      expect(await PlaybackFallbackMode.load(), PlaybackFallbackMode.all);
      await PlaybackFallbackMode.save(PlaybackFallbackMode.playerOnly);
      expect(
        await PlaybackFallbackMode.load(),
        PlaybackFallbackMode.playerOnly,
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        PlaybackFallbackMode.prefsKey: 'nonsense',
      });
      expect(await PlaybackFallbackMode.load(), PlaybackFallbackMode.all);
    });
  });
}
