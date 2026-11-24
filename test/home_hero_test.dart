import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/search_discovery.dart';
import 'package:fqapp/widgets/home/home_hero.dart';

/// 首页顶栏（品牌行）：右端三个 40dp 圆钮——搜索、刷新、分类；头像是站点
/// 列表入口。2026-11-24 搜索行整行删除：搜索框胶囊、站点药丸、分类胶囊与
/// 热搜词轮换一并去掉，这里钉住新布局——圆钮按回调有无占位、点头像调
/// onSiteTap、标题点按不做任何事。
void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(400, 200),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  }

  group('brand row buttons', () {
    testWidgets('search button is always there and calls onSearch', (
      tester,
    ) async {
      var searched = false;
      await pump(tester, HomeHero(onSearch: () => searched = true));

      expect(find.byKey(const Key('home_brand_search')), findsOneWidget);
      expect(find.byTooltip('搜索'), findsOneWidget);
      await tester.tap(find.byKey(const Key('home_brand_search')));
      expect(searched, isTrue);
    });

    testWidgets('no refresh or category button without their callbacks', (
      tester,
    ) async {
      await pump(tester, const HomeHero(onSearch: _Noop._));

      expect(find.byKey(const Key('home_brand_refresh')), findsNothing);
      // 搜索圆钮常驻，分类圆钮只在给了回调时出现。
      expect(find.byKey(const Key('home_brand_search')), findsOneWidget);
      expect(find.byKey(const Key('home_brand_category')), findsNothing);
    });

    testWidgets('category round button appears only with a callback', (
      tester,
    ) async {
      var tapped = false;
      await pump(
        tester,
        HomeHero(onSearch: _Noop._, onCategory: () => tapped = true),
      );

      expect(find.byKey(const Key('home_brand_category')), findsOneWidget);
      expect(find.byTooltip('分类'), findsOneWidget);
      await tester.tap(find.byKey(const Key('home_brand_category')));
      expect(tapped, isTrue);
    });

    testWidgets('buttons sit in search, refresh, category order', (
      tester,
    ) async {
      await pump(
        tester,
        HomeHero(onSearch: _Noop._, onRefresh: () {}, onCategory: () {}),
      );

      final searchX = tester
          .getCenter(find.byKey(const Key('home_brand_search')))
          .dx;
      final refreshX = tester
          .getCenter(find.byKey(const Key('home_brand_refresh')))
          .dx;
      final categoryX = tester
          .getCenter(find.byKey(const Key('home_brand_category')))
          .dx;
      expect(searchX, lessThan(refreshX));
      expect(refreshX, lessThan(categoryX));
    });
  });

  group('avatar is the site entry', () {
    testWidgets('tapping the avatar calls onSiteTap', (tester) async {
      var tapped = false;
      await pump(
        tester,
        HomeHero(onSearch: _Noop._, onSiteTap: () => tapped = true),
      );

      expect(find.byKey(const Key('home_brand_avatar')), findsOneWidget);
      expect(find.byTooltip('切换站点'), findsOneWidget);
      await tester.tap(find.byKey(const Key('home_brand_avatar')));
      expect(tapped, isTrue);
    });

    testWidgets('avatar is not tappable without onSiteTap', (tester) async {
      await pump(tester, const HomeHero(onSearch: _Noop._));

      expect(find.byKey(const Key('home_brand_avatar')), findsOneWidget);
      expect(find.byTooltip('切换站点'), findsNothing);
      await tester.tap(find.byKey(const Key('home_brand_avatar')));
      expect(tester.takeException(), isNull);
    });
  });

  group('brand row has no midnight entry', () {
    testWidgets('no midnight text in the top bar', (tester) async {
      await pump(tester, const HomeHero(onSearch: _Noop._));

      expect(find.text('午夜区'), findsNothing);
    });
  });

  group('SearchCue payload', () {
    test('reads data_v1 words and rotate_interval_ms', () {
      final cue = SearchCue.fromPayload(const {
        'code': 0,
        'rotate_interval_ms': 8000,
        'data_v1': [
          {'display_text': '词一', 'text': 'ignored'},
          {'display_text_v2': '词二优先'},
          {'text': '词三兜底'},
          {'display_text': ''},
          {'display_text': '词一'},
        ],
      });
      expect(cue.words, ['词一', '词二优先', '词三兜底']);
      expect(cue.rotateIntervalMs, 8000);
    });

    test('falls back to the default interval and empty on bad payloads', () {
      expect(SearchCue.empty.isEmpty, isTrue);
      expect(SearchCue.empty.rotateIntervalMs, SearchCue.defaultIntervalMs);
      expect(
        SearchCue.fromPayload(const {'code': 1, 'data_v1': []}).isEmpty,
        isTrue,
      );
      expect(
        SearchCue.fromPayload(const {
          'data_v1': [],
          'rotate_interval_ms': 0,
        }).rotateIntervalMs,
        SearchCue.defaultIntervalMs,
      );
    });
  });
}

class _Noop {
  static void _() {}
}
