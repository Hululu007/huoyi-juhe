import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/comic/comic_curl_pager.dart';
import 'package:fqapp/widgets/reader/reader_page_curl.dart';

void main() {
  Future<PageController> pumpPager(
    WidgetTester tester, {
    ValueChanged<int>? onPageChanged,
    ThemeData? theme,
    Color? backgroundColor,
  }) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = PageController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: ComicCurlPager(
            controller: controller,
            itemCount: 3,
            itemBuilder: (index) => Container(
              key: ValueKey('comic-page-$index'),
              color: const [Colors.red, Colors.green, Colors.blue][index],
            ),
            onPageChanged: onPageChanged ?? (_) {},
            backgroundColor: backgroundColor,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('首显第一页，卷页覆盖层未出现', (tester) async {
    await pumpPager(tester);
    expect(find.byKey(const ValueKey('comic-page-0')), findsOneWidget);
    expect(find.byType(ReaderPageCurl), findsNothing);
  });

  testWidgets('左滑翻到下一页', (tester) async {
    final pages = <int>[];
    await pumpPager(tester, onPageChanged: pages.add);
    await tester.drag(find.byType(ComicCurlPager), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(pages, [1]);
    expect(find.byKey(const ValueKey('comic-page-1')), findsOneWidget);
    expect(find.byType(ReaderPageCurl), findsNothing);
  });

  testWidgets('第一页右滑不卷页、不切章', (tester) async {
    final pages = <int>[];
    await pumpPager(tester, onPageChanged: pages.add);
    await tester.drag(find.byType(ComicCurlPager), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(pages, isEmpty);
    expect(find.byKey(const ValueKey('comic-page-0')), findsOneWidget);
  });

  testWidgets('滑到一半退回则卷回原页', (tester) async {
    final pages = <int>[];
    await pumpPager(tester, onPageChanged: pages.add);
    final center = tester.getCenter(find.byType(ComicCurlPager));
    final gesture = await tester.startGesture(center);
    await gesture.moveTo(center + const Offset(-200, 0));
    await tester.pump();
    expect(find.byType(ReaderPageCurl), findsOneWidget);
    await gesture.moveTo(center + const Offset(-50, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(pages, isEmpty);
    expect(find.byKey(const ValueKey('comic-page-0')), findsOneWidget);
    expect(find.byType(ReaderPageCurl), findsNothing);
  });

  testWidgets('卷页底色默认跟随主题 Scaffold 背景', (tester) async {
    const scaffoldBg = Color(0xFF123456);
    await pumpPager(
      tester,
      theme: ThemeData(scaffoldBackgroundColor: scaffoldBg),
    );
    final center = tester.getCenter(find.byType(ComicCurlPager));
    final gesture = await tester.startGesture(center);
    await gesture.moveTo(center + const Offset(-100, 0));
    await tester.pump();
    final curl = tester.widget<ReaderPageCurl>(find.byType(ReaderPageCurl));
    expect(curl.backgroundColor, scaffoldBg);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('显式底色优先于主题', (tester) async {
    await pumpPager(tester, backgroundColor: Colors.amber);
    final center = tester.getCenter(find.byType(ComicCurlPager));
    final gesture = await tester.startGesture(center);
    await gesture.moveTo(center + const Offset(-100, 0));
    await tester.pump();
    final curl = tester.widget<ReaderPageCurl>(find.byType(ReaderPageCurl));
    expect(curl.backgroundColor, Colors.amber);
    await gesture.up();
    await tester.pumpAndSettle();
  });
}
