import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/player/player_persistent_progress.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('visible false hides the bar', (tester) async {
    final player = FakeNativePlayer();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPersistentProgress(
          player: player,
          duration: player.duration,
          visible: false,
        ),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('visible true shows the bar at the current position', (
    tester,
  ) async {
    final player = FakeNativePlayer();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPersistentProgress(
          player: player,
          duration: player.duration,
        ),
      ),
    );
    final indicator = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(indicator.value, closeTo(20 / 120, 0.001));
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });

  testWidgets('zero duration hides the bar', (tester) async {
    final player = FakeNativePlayer();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPersistentProgress(
          player: player,
          duration: Duration.zero,
        ),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });
}
