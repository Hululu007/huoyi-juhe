import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/adult_novels_page.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';

/// loader 注入的假数据：不走核心与登记源的真实网络，只验页面渲染。
MediaItem novelItem({
  String id = 'n1',
  String title = '书一',
  String author = '',
  String ep = '',
  String kind = 'book',
  double? score,
  List<String> rankTags = const [],
}) => MediaItem(
  id: id,
  title: title,
  cover: '',
  author: author,
  badge: '',
  ep: ep,
  kind: kind,
  score: score,
  rankTags: rankTags,
);

void main() {
  testWidgets('无门禁：聚合页直接显示空态，不取数也不锁', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: AdultNovelsPage()),
    );
    // 核心取数走真实网络（本机无核心在跑）：先用真实时间等取数落空
    // （后端启动超时 15 秒 + 单站超时 15 秒，20 秒足够），再泵一帧刷新。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 20));
    });
    await tester.pump();
    expect(find.text('暂无成人小说'), findsOneWidget);
    expect(find.text('核心站与已导入的成人源暂无内容'), findsOneWidget);
    expect(find.text('午夜区未开启'), findsNothing);
  });

  testWidgets('入口：不再设门，直接出现', (tester) async {
    const sliver = MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [AdultNovelsEntrySliver()],
        ),
      ),
    );
    await tester.pumpWidget(sliver);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('adult-novels-entry')), findsOneWidget);
  });

  testWidgets('漫画入口：标题与键各是自己的', (tester) async {
    const sliver = MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [AdultNovelsEntrySliver(type: ContentType.comic)],
        ),
      ),
    );
    await tester.pumpWidget(sliver);
    await tester.pumpAndSettle();
    expect(find.text('成人漫画'), findsOneWidget);
    expect(find.byKey(const Key('adult-entry-comic')), findsOneWidget);
  });

  testWidgets('小说路：每张卡按列表位置戴 TOP 角标，仍是 HomeMediaCard 网格', (
    tester,
  ) async {
    // 页面内容高于默认 800x600 视口，GridView 外的行不会被构建；
    // 拉高测试视口让整页一次排完，断言才能覆盖每一行。
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 1800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: AdultNovelsPage(
          loader: () async => [
            novelItem(id: 'n1', title: '书一'),
            novelItem(id: 'n2', title: '书二'),
            novelItem(id: 'n3', title: '书三'),
            novelItem(id: 'n4', title: '书四'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 名次是真实列表位置：第 1 张 TOP 1，第 4 张也有 TOP 4（不只前三名）。
    expect(find.text('TOP 1'), findsOneWidget);
    expect(find.text('TOP 2'), findsOneWidget);
    expect(find.text('TOP 3'), findsOneWidget);
    expect(find.text('TOP 4'), findsOneWidget);
    // 卡片仍是原始小说界面的 HomeMediaCard，不是排行榜样式卡。
    expect(find.byType(HomeMediaCard), findsNWidgets(4));
    // 网格不动：2 列 / 16 边距 / 12 间距 / 0.55。
    final grid = tester.widget<GridView>(
      find.byKey(const Key('adult-grid-novel')),
    );
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 2);
    expect(delegate.mainAxisSpacing, 12);
    expect(delegate.crossAxisSpacing, 12);
    expect(delegate.childAspectRatio, 0.55);
    expect(tester.takeException(), isNull);
  });

  testWidgets('小说路热度行：rankTags 优先于备注', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AdultNovelsPage(
          loader: () async => [
            novelItem(title: '书一', rankTags: const ['9179万热度'], ep: '17万'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('9179万热度'), findsOneWidget);
    expect(find.text('17万热度'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('小说路热度行：备注是万级播放量时补“热度”二字', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AdultNovelsPage(
          loader: () async => [novelItem(title: '书一', ep: '17万')],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('17万热度'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('小说路热度行：其他备注原样显示，不硬凑热度', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AdultNovelsPage(
          loader: () async => [novelItem(title: '书一', ep: '10:48')],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('10:48'), findsOneWidget);
    expect(find.textContaining('热度'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('小说路热度行：没数据就不渲染假行，角标仍在', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AdultNovelsPage(
          loader: () async => [novelItem(title: '书一')],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('书一'), findsOneWidget);
    expect(find.text('TOP 1'), findsOneWidget);
    expect(find.textContaining('热度'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('小说路副标题行：作者 · 评分仍走 HomeMediaCard 的规则', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AdultNovelsPage(
          loader: () async => [
            novelItem(title: '书一', author: '某作者', score: 9.3),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('某作者 · 9.3分'), findsOneWidget);
    expect(find.textContaining('热度'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('漫画路不动：仍是排行榜卡，TOP 角标只前三名', (tester) async {
    // 页面内容高于默认 800x600 视口，GridView 外的行不会被构建；
    // 拉高测试视口让整页一次排完，断言才能覆盖每一行。
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 1800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: AdultNovelsPage(
          type: ContentType.comic,
          loader: () async => [
            novelItem(id: 'c1', title: '漫一', kind: 'manga'),
            novelItem(id: 'c2', title: '漫二', kind: 'manga'),
            novelItem(id: 'c3', title: '漫三', kind: 'manga'),
            novelItem(id: 'c4', title: '漫四', kind: 'manga'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HomeMediaCard), findsNothing);
    expect(find.text('TOP 1'), findsOneWidget);
    expect(find.text('TOP 3'), findsOneWidget);
    expect(find.text('TOP 4'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
