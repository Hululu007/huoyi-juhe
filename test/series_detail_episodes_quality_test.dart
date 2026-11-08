import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/series_detail/series_detail_episodes.dart';

/// 影视详情页选集格：蜘蛛把多清晰度展开成“集”时（如 mjv011 的
/// 480P / 720P / 1080P），格子显示档名而不是序号；集数顺序与点选
/// 行为不动。
void main() {
  testWidgets('quality-titled episodes show the quality in the grid', (
    tester,
  ) async {
    final selected = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SeriesDetailEpisodes(
              episodes: [
                Chapter(itemId: 'v1', title: '480P', volumeName: ''),
                Chapter(itemId: 'v2', title: '720P', volumeName: ''),
                Chapter(itemId: 'v3', title: '1080P', volumeName: ''),
              ],
              currentIndex: 0,
              watched: const {},
              initialRange: 0,
              pageSize: 50,
              statusText: '共3集',
              hasRelatedSeries: false,
              onOpenRelatedSeries: () {},
              loading: false,
              failed: false,
              onRetry: () {},
              onSelect: selected.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('480P'), findsOneWidget);
    expect(find.text('720P'), findsOneWidget);
    expect(find.text('1080P'), findsOneWidget);
    expect(find.text('1'), findsNothing);
    expect(find.text('2'), findsNothing);
    expect(find.text('3'), findsNothing);
    // 点 1080P 那格选中第 3 格（集数顺序不动）。
    await tester.tap(find.byKey(const ValueKey('series-episode-2')));
    await tester.pump();
    expect(selected, [2]);
  });

  testWidgets('ordinary episode titles still show numbers', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SeriesDetailEpisodes(
              episodes: [
                Chapter(itemId: 'v1', title: '第 1 集', volumeName: ''),
                Chapter(itemId: 'v2', title: '第 2 集', volumeName: ''),
              ],
              currentIndex: 0,
              watched: const {},
              initialRange: 0,
              pageSize: 50,
              statusText: null,
              hasRelatedSeries: false,
              onOpenRelatedSeries: () {},
              loading: false,
              failed: false,
              onRetry: () {},
              onSelect: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });
}
