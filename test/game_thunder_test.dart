import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/game_sound.dart';

void main() {
  test('thunder.mp3 is on disk and non-empty', () {
    final file = File('assets/audio/thunder.mp3');
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(0));
  });

  test('pubspec.yaml registers thunder.mp3', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- assets/audio/thunder.mp3'));
  });

  test('playThunder does not throw while sfx muted', () async {
    final sound = GameSoundService.instance;
    sound.sfxMutedNotifier.value = true;
    try {
      await sound.playThunder();
    } finally {
      sound.sfxMutedNotifier.value = false;
    }
  });

  test('playSkill routes bixie and jingzhe to thunder without throwing',
      () async {
    final sound = GameSoundService.instance;
    await sound.playSkill('bixie');
    await sound.playSkill('jingzhe');
  });
}
