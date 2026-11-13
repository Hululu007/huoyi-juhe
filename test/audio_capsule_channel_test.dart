import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/native_player.dart';

const _methods = MethodChannel('fqapp/native_player');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_methods, null);
  });

  test('showAudioCapsule sends title, episode, cover and playing', () async {
    await NativePlayer.showAudioCapsule(
      title: '凡人修仙传',
      episode: '第1章',
      coverUrl: 'https://example.invalid/cover.jpg',
      playing: true,
    );
    expect(calls, hasLength(1));
    expect(calls.single.method, 'showAudioCapsule');
    expect(calls.single.arguments, {
      'title': '凡人修仙传',
      'episode': '第1章',
      'coverUrl': 'https://example.invalid/cover.jpg',
      'playing': true,
    });
  });

  test('hideAudioCapsule sends no arguments', () async {
    await NativePlayer.hideAudioCapsule();
    expect(calls, hasLength(1));
    expect(calls.single.method, 'hideAudioCapsule');
    expect(calls.single.arguments, isNull);
  });

  test('updateAudioCapsule sends the current state', () async {
    await NativePlayer.updateAudioCapsule(
      title: '凡人修仙传',
      episode: '第2章',
      playing: false,
    );
    expect(calls, hasLength(1));
    expect(calls.single.method, 'updateAudioCapsule');
    expect(calls.single.arguments, {
      'title': '凡人修仙传',
      'episode': '第2章',
      'coverUrl': '',
      'playing': false,
    });
  });

  test('capsule calls swallow platform errors', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_methods, (call) async {
      throw PlatformException(code: 'UNAVAILABLE');
    });
    // Must not throw: capsule calls are best-effort, like the
    // start/stopListenForeground calls.
    await NativePlayer.showAudioCapsule(title: 't', episode: 'e');
    await NativePlayer.hideAudioCapsule();
    await NativePlayer.updateAudioCapsule(title: 't', episode: 'e');
  });
}
