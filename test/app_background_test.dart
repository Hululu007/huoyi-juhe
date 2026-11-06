import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/app_theme.dart';

void main() {
  test('decode default falls back to default', () {
    final bg = AppBackground.decode(null, null);
    expect(bg.isDefault, isTrue);
    expect(bg.isImage, isFalse);
    expect(bg.presetColor, isNull);
  });

  test('decode preset returns its color', () {
    final bg = AppBackground.decode('warm', null);
    expect(bg.id, 'warm');
    expect(bg.isDefault, isFalse);
    expect(bg.isImage, isFalse);
    expect(bg.presetColor, const Color(0xFFFCFAF7));
  });

  test('decode custom with path is image', () {
    final bg = AppBackground.decode('custom', '/docs/app_background.jpg');
    expect(bg.isImage, isTrue);
    expect(bg.imagePath, '/docs/app_background.jpg');
    expect(bg.presetColor, isNull);
  });

  test('decode custom with empty path falls back to default', () {
    final bg = AppBackground.decode('custom', '');
    expect(bg.isDefault, isTrue);
    expect(bg.isImage, isFalse);
  });

  test('decode unknown id falls back to default', () {
    final bg = AppBackground.decode('bogus', null);
    expect(bg.isDefault, isTrue);
  });

  test('preset lists match brightness split', () {
    expect(
      backgroundPresets.where((preset) => !preset.dark).length,
      5,
    );
    expect(backgroundPresets.where((preset) => preset.dark).length, 3);
  });

  test('background notifier starts at default', () {
    expect(backgroundNotifier.value.isDefault, isTrue);
  });
}
