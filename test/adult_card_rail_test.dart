import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/adult_novels_page.dart';
import 'package:fqapp/services/source_registry.dart';

/// 第 20 轮改版：首页三 tab 顶部不再是大卡片入口（AdultNovelsEntrySliver），
/// 而是排行榜式卡片轨道（AdultCardRailSliver）。loader 注入假数据，
/// 不走核心与登记源的真实网络，只验轨道渲染与「更多」入口。
List<MediaItem> railItems(String prefix, String kind) => [
  for (var i = 1; i <= 4; i++)
    MediaItem(
      id: 'rail-$prefix-$i',
      title: '轨道$prefix$i',
      cover: '',
      author: '',
      badge: '',
      ep: '9080万热度',
      kind: kind,
    ),
];

Future<void> pumpRail(
  WidgetTester tester,
  AdultCardRailSliver rail,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CustomScrollView(slivers: [rail]),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('小说轨道：排行榜版式，TOP 角标只前三名，标题与热度行齐全', (
    tester,
  ) async {
    await pumpRail(
      tester,
      AdultCardRailSliver(loader: () async => railItems('小说', 'book')),
    );
    expect(find.text('成人小说'), findsOneWidget);
    expect(find.text('更多'), findsOneWidget);
    expect(find.byKey(const Key('adult-rail-novel')), findsOneWidget);
    expect(find.text('TOP 1'), findsOneWidget);
    expect(find.text('TOP 2'), findsOneWidget);
    expect(find.text('TOP 3'), findsOneWidget);
    expect(find.text('TOP 4'), findsNothing);
    expect(find.text('轨道小说1'), findsOneWidget);
    expect(find.text('9080万热度'), findsNWidgets(4));
  });

  testWidgets('漫画 / 听书轨道：标题各是自己的，版式与小说轨道一致', (
    tester,
  ) async {
    await pumpRail(
      tester,
      AdultCardRailSliver(
        type: ContentType.comic,
        loader: () async => railItems('漫画', 'manga'),
      ),
    );
    expect(find.text('成人漫画'), findsOneWidget);
    expect(find.byKey(const Key('adult-rail-comic')), findsOneWidget);
    expect(find.text('轨道漫画2'), findsOneWidget);
  });

  testWidgets('听书轨道：标题是成人听书', (tester) async {
    await pumpRail(
      tester,
      AdultCardRailSliver(
        type: ContentType.audio,
        loader: () async => railItems('听书', 'audio'),
      ),
    );
    expect(find.text('成人听书'), findsOneWidget);
    expect(find.byKey(const Key('adult-rail-audio')), findsOneWidget);
  });

  testWidgets('取空：留提示行，「更多」入口仍在，可进聚合页重试', (tester) async {
    await pumpRail(
      tester,
      AdultCardRailSliver(loader: () async => const <MediaItem>[]),
    );
    expect(find.text('暂无内容，点右上角“更多”进聚合页重试'), findsOneWidget);
    expect(find.text('更多'), findsOneWidget);
  });

  testWidgets('更多：点后进聚合页（标题栏成人小说 + 加载中）', (tester) async {
    await pumpRail(
      tester,
      AdultCardRailSliver(loader: () async => railItems('小说', 'book')),
    );
    await tester.tap(find.text('更多'));
    await tester.pump();
    await tester.pump();
    // 轨道标题与聚合页标题栏同名，两处都有；聚合页体正在加载。
    expect(find.text('成人小说'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });
}
