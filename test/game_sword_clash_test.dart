import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/game_sound.dart';

void main() {
  test('sword_clash.mp3 is on disk and non-empty', () {
    final file = File('assets/audio/sword_clash.mp3');
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(0));
  });

  test('pubspec.yaml registers sword_clash.mp3', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- assets/audio/sword_clash.mp3'));
  });

  test('playSwordClash does not throw while sfx muted', () async {
    final sound = GameSoundService.instance;
    sound.sfxMutedNotifier.value = true;
    try {
      await sound.playSwordClash();
    } finally {
      sound.sfxMutedNotifier.value = false;
    }
  });

  test('playSwordClash debounces rapid calls', () async {
    final sound = GameSoundService.instance;
    sound.sfxMutedNotifier.value = false;
    // 等上一轮防抖窗口过去，保证第一次调用一定落在窗口外。
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await sound.playSwordClash();
    final first = sound.lastSwordClashAtForTest;
    expect(first, isNotNull);
    await sound.playSwordClash();
    expect(sound.lastSwordClashAtForTest, first);
  });

  test('playSword/playHit/playCrit/playSkill layer the clash without throwing',
      () async {
    final sound = GameSoundService.instance;
    sound.sfxMutedNotifier.value = false;
    await sound.playSword();
    await sound.playHit();
    await sound.playCrit();
    await sound.playSkill('qingyuan');
  });
}
