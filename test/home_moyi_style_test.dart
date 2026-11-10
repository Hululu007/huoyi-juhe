import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/home/home_hero.dart';
import 'package:fqapp/widgets/home/home_moyi_card.dart';
import 'package:fqapp/widgets/home/home_moyi_carousel.dart';
import 'package:fqapp/widgets/home/home_moyi_style.dart';

MediaItem item(
  String id,
  String title, {
  String cover = '',
  String badge = '',
  List<String> categories = const [],
}) => MediaItem(
  id: id,
  title: title,
  cover: cover,
  author: '',
  badge: badge,
  ep: '',
  kind: 'book',
  categories: categories,
);

Future<void> pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(400, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  group('moyiCarouselItems', () {
    test('prefers covers and caps at six', () {
      final items = [
        item('n1', '无封面一'),
        for (var i = 0; i < 8; i++) item('c$i', '有封面$i', cover: 'https://x/$i.jpg'),
      ];
      final picked = moyiCarouselItems(items);
      expect(picked.length, 6);
      expect(picked.first.id, 'c0');
      expect(picked.map((e) => e.cover), everyElement(isNotEmpty));
    });

    test('falls back to the first six when nothing has a cover', () {
      final items = [for (var i = 0; i < 9; i++) item('n$i', '无封面$i')];
      final picked = moyiCarouselItems(items);
      expect(picked.map((e) => e.id), ['n0', 'n1', 'n2', 'n3', 'n4', 'n5']);
    });

    test('empty in, empty out', () {
      expect(moyiCarouselItems(const []), isEmpty);
    });
  });

  group('MoyiHeroCarousel', () {
    testWidgets('shows title, tag dots, watch button and dots', (
      tester,
    ) async {
      await pump(
        tester,
        MoyiHeroCarousel(
          items: [
            item('a', '一念星沉', categories: ['爱情', '都市爱情']),
            item('b', '万籁渐有声', categories: ['爱情']),
            item('c', '0号觉醒', categories: ['脑洞', '系统']),
          ],
          onOpen: (_) {},
        ),
      );
      await tester.pump();

      expect(find.text('一念星沉'), findsOneWidget);
      expect(find.text('爱情'), findsWidgets);
      // PageView 会预建邻页，所以「马上看」不止一个；首张卡的按钮按 key 钉。
      expect(find.text('马上看'), findsWidgets);
      expect(
        find.byKey(const ValueKey('moyi-hero-watch-a')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('moyi-hero-dots')), findsOneWidget);
    });

    testWidgets('watch button opens the current hero item', (tester) async {
      MediaItem? opened;
      await pump(
        tester,
        MoyiHeroCarousel(
          items: [item('a', '一念星沉'), item('b', '万籁渐有声')],
          onOpen: (value) => opened = value,
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('moyi-hero-watch-a')));
      expect(opened?.id, 'a');
    });

    testWidgets('tapping the card opens it too', (tester) async {
      MediaItem? opened;
      await pump(
        tester,
        MoyiHeroCarousel(
          items: [item('a', '一念星沉'), item('b', '万籁渐有声')],
          onOpen: (value) => opened = value,
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('moyi-hero-a')));
      expect(opened?.id, 'a');
    });

    testWidgets('a single item has no dots', (tester) async {
      await pump(
        tester,
        MoyiHeroCarousel(items: [item('a', '一念星沉')], onOpen: (_) {}),
      );
      await tester.pump();

      expect(find.byKey(const Key('moyi-hero-dots')), findsNothing);
    });

    testWidgets('empty items render nothing', (tester) async {
      await pump(
        tester,
        const MoyiHeroCarousel(items: [], onOpen: _noopItem),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('moyi-hero')), findsNothing);
    });
  });

  group('MoyiMediaCard', () {
    testWidgets('HD badge only when the item carries an HD signal', (
      tester,
    ) async {
      await pump(
        tester,
        SizedBox(
          width: 120,
          child: MoyiMediaCard(
            item: item('a', '高清剧', badge: 'HD'),
            onTap: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('moyi_card_hd')), findsOneWidget);

      await pump(
        tester,
        SizedBox(
          width: 120,
          child: MoyiMediaCard(item: item('b', '普通剧'), onTap: () {}),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('moyi_card_hd')), findsNothing);
      expect(find.text('普通剧'), findsOneWidget);
    });

    testWidgets('subtitle prefers real categories', (tester) async {
      await pump(
        tester,
        SizedBox(
          width: 120,
          child: MoyiMediaCard(
            item: item('a', '一念星沉', categories: ['爱情', '都市爱情']),
            onTap: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('爱情 · 都市爱情'), findsOneWidget);
    });

    test('moyiIsHd reads badge and tag, nothing else', () {
      expect(moyiIsHd(item('a', 'x', badge: 'HD')), isTrue);
      expect(moyiIsHd(item('a', 'x', badge: 'hd1080p')), isTrue);
      expect(moyiIsHd(item('a', 'x')), isFalse);
      expect(moyiIsHd(item('a', 'x', badge: '上新')), isFalse);
    });
  });

  group('MoyiSectionHeader', () {
    testWidgets('shows title and all action, tap fires', (tester) async {
      var tapped = false;
      await pump(
        tester,
        MoyiSectionHeader(
          title: '热播推荐',
          actionLabel: '全部',
          onAction: () => tapped = true,
        ),
      );
      await tester.pump();

      expect(find.text('热播推荐'), findsOneWidget);
      expect(find.text('全部'), findsOneWidget);
      await tester.tap(find.byKey(const Key('moyi_section_all')));
      expect(tapped, isTrue);
    });

    testWidgets('no action when none is given', (tester) async {
      await pump(
        tester,
        const MoyiSectionHeader(title: '猜你想看'),
      );
      await tester.pump();

      expect(find.text('猜你想看'), findsOneWidget);
      expect(find.byKey(const Key('moyi_section_all')), findsNothing);
    });
  });

  group('HomeHero brand row', () {
    testWidgets('shows our brand, site subtitle and both round buttons', (
      tester,
    ) async {
      var searched = false;
      var refreshed = false;
      await pump(
        tester,
        HomeHero(
          onSearch: () => searched = true,
          onRefresh: () => refreshed = true,
          brandSubtitle: '红果',
          siteName: '红果',
        ),
        size: const Size(400, 200),
      );
      await tester.pump();

      expect(find.text(HomeHero.brandName), findsOneWidget);
      expect(find.text('魔蚁box'), findsNothing);
      expect(find.text('红果'), findsWidgets);
      expect(find.byKey(const Key('home_brand_avatar')), findsOneWidget);
      await tester.tap(find.byKey(const Key('home_brand_search')));
      expect(searched, isTrue);
      await tester.tap(find.byKey(const Key('home_brand_refresh')));
      expect(refreshed, isTrue);
      // 搜索框仍在：热搜提示语与分类入口都不动。
      expect(find.text(HomeHero.searchHint), findsOneWidget);
    });

    testWidgets('no refresh button when onRefresh is null', (tester) async {
      await pump(
        tester,
        const HomeHero(onSearch: _noop),
        size: const Size(400, 200),
      );
      await tester.pump();

      expect(find.text(HomeHero.brandName), findsOneWidget);
      expect(find.byKey(const Key('home_brand_refresh')), findsNothing);
      expect(find.byKey(const Key('home_brand_search')), findsOneWidget);
    });
  });
}

void _noop() {}

void _noopItem(MediaItem _) {}
