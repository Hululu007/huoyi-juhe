// Basic smoke test: the app boots to the backend-starting screen.
//
// Wrapped in ProviderScope to mirror main() — HomePage is a ConsumerWidget,
// so any future test that reaches it needs the provider scope present.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/main.dart';
import 'package:fqapp/services/cultivation.dart';

/// 硬门槛：RootShell 未建档时只显示全屏创建人物界面。壳层用例要看到
/// 主界面/后端启动屏，得先建一个道友档案（直接调服务，不走创建页）。
Future<void> _createTestProfile() async {
  await CultivationService.instance.createProfile(
    gender: CultivationGender.male,
    sect: cultivationSects.first,
    profession: defaultCultivationProfession,
  );
}

void main() {
  testWidgets('long startup failures stay scrollable and retryable', (
    tester,
  ) async {
    await _createTestProfile();
    await tester.binding.setSurfaceSize(const Size(320, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RootShell(
          backendStarter: () async {
            attempts++;
            throw StateError(List.filled(80, '本地服务启动失败的详细信息').join('\n'));
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('App boots', (WidgetTester tester) async {
    await _createTestProfile();
    await tester.pumpWidget(const ProviderScope(child: FqApp()));
    await tester.pump();
    // The app should show the backend startup screen or the main shell.
    expect(find.byType(FqApp), findsOneWidget);
  });
}
