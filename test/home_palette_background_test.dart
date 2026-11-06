import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/home/home_design.dart';

void main() {
  tearDown(() {
    backgroundNotifier.value = const AppBackground(id: 'default');
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
  });

  Future<Color?> probeCanvas(
    WidgetTester tester, {
    required Brightness brightness,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        darkTheme: ThemeData(brightness: brightness),
        themeMode: ThemeMode.light,
        home: Builder(
          builder: (context) => Container(
            key: const Key('palette-canvas-probe'),
            color: HomePalette.of(context).canvas,
          ),
        ),
      ),
    );
    await tester.pump();
    final container = tester.widget<Container>(
      find.byKey(const Key('palette-canvas-probe')),
    );
    return container.color;
  }

  testWidgets('default light canvas is F6F6F6', (tester) async {
    backgroundNotifier.value = const AppBackground(id: 'default');
    expect(
      await probeCanvas(tester, brightness: Brightness.light),
      const Color(0xFFEAF2F8),
    );
  });

  testWidgets('preset warm replaces canvas', (tester) async {
    backgroundNotifier.value = const AppBackground(id: 'warm');
    expect(
      await probeCanvas(tester, brightness: Brightness.light),
      const Color(0xFFFCFAF7),
    );
  });

  testWidgets('image background makes canvas transparent', (tester) async {
    backgroundNotifier.value = const AppBackground(
      id: 'custom',
      imagePath: '/docs/app_background.jpg',
    );
    expect(
      await probeCanvas(tester, brightness: Brightness.light),
      Colors.transparent,
    );
  });

  testWidgets('default dark canvas is 1E1D38', (tester) async {
    backgroundNotifier.value = const AppBackground(id: 'default');
    expect(
      await probeCanvas(tester, brightness: Brightness.dark),
      const Color(0xFF1E1D38),
    );
  });
}
