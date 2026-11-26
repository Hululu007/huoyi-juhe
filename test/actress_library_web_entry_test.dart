// 合并演员库入口页（ActressLibraryWebEntryPage）小部件测试：
// 资源加载成功进宿主页、失败落回退页、加载中显示进度。
// WebView 平台视图与回退页都用替身，不建真 WebView、不开真库。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_library_web_entry.dart';
import 'package:fqapp/actress/actress_library_web_page.dart';

import 'actress_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child) {
    return MaterialApp(home: Scaffold(body: child));
  }

  testWidgets('资源加载成功 → 进合并页宿主', (tester) async {
    await tester.pumpWidget(
      wrap(
        ActressLibraryWebEntryPage(
          repository: FixtureRepository(),
          store: LocalStore(),
          htmlLoader: () async => '<html>merged</html>',
          webViewBuilder: (_) =>
              const Center(child: Text('WEB_HOST', key: ValueKey('web-host'))),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(ActressLibraryWebPage), findsOneWidget);
    expect(find.byKey(const ValueKey('web-host')), findsOneWidget);
  });

  testWidgets('资源加载失败 → 落回退页（原生页保留的接法）', (tester) async {
    await tester.pumpWidget(
      wrap(
        ActressLibraryWebEntryPage(
          repository: FixtureRepository(),
          store: LocalStore(),
          htmlLoader: () async => throw Exception('asset missing'),
          fallbackBuilder: (_) =>
              const Center(child: Text('NATIVE', key: ValueKey('native'))),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('native')), findsOneWidget);
    expect(find.byType(ActressLibraryWebPage), findsNothing);
  });

  testWidgets('加载中 → 进度指示，完成后切宿主页', (tester) async {
    final completer = Completer<String>();
    await tester.pumpWidget(
      wrap(
        ActressLibraryWebEntryPage(
          repository: FixtureRepository(),
          store: LocalStore(),
          htmlLoader: () => completer.future,
          webViewBuilder: (_) =>
              const Center(child: Text('WEB_HOST', key: ValueKey('web-host'))),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    completer.complete('<html>merged</html>');
    await tester.pump();
    expect(find.byKey(const ValueKey('web-host')), findsOneWidget);
  });
}
