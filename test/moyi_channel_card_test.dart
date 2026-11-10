import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/widgets/home/moyi_channel_card.dart';

/// 魔蚁风频道卡片单测：角标/完结/日期/集数只按备注里的真实信号判；
/// 卡片画出标题 + 分类小字 + 角标；网格左高右矮两列分流。
void main() {
  test('备注信号：日期 NEW、画质 HD、完结只认完结词', () {
    expect(moyiBadgeForRemark('2026-11-09'), MoyiChannelBadge.fresh);
    expect(moyiBadgeForRemark('11-09 更新'), MoyiChannelBadge.fresh);
    expect(moyiBadgeForRemark('高清'), MoyiChannelBadge.hd);
    expect(moyiBadgeForRemark('1080P'), MoyiChannelBadge.hd);
    expect(moyiBadgeForRemark('更新至12集'), isNull);
    expect(moyiIsFinished('已完结'), isTrue);
    expect(moyiIsFinished('全集'), isTrue);
    expect(moyiIsFinished('大结局'), isTrue);
    expect(moyiIsFinished('共24集'), isFalse);
    expect(moyiIsFinished('更新至12集'), isFalse);
    expect(moyiRemarkDate('2026-11-09'), DateTime(2026, 11, 9));
    expect(moyiRemarkDate('更新至12集'), isNull);
    expect(moyiEpisodeNumber('更新至12集'), 12);
    expect(moyiEpisodeNumber('共24集'), 24);
    expect(moyiEpisodeNumber('2026-11-09'), isNull);
  });

  testWidgets('卡片画出标题、分类小字与角标', (tester) async {
    const work = MoyiChannelWork(
      item: DramaSiteItem(
        id: 'v1',
        title: '0号觉醒',
        cover: '',
        remark: '2026-11-09',
      ),
      siteId: 'a',
      siteName: '测试站',
      category: '漫剧',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            child: MoyiChannelCard(
              work: work,
              aspectRatio: 9 / 16,
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('0号觉醒'), findsOneWidget);
    expect(find.text('漫剧 · 2026-11-09'), findsOneWidget);
    expect(find.text('NEW'), findsOneWidget);
    expect(find.text('HD'), findsNothing);
  });

  testWidgets('网格左高右矮：偶数位左列、奇数位右列', (tester) async {
    final works = [
      for (var i = 0; i < 4; i++)
        MoyiChannelWork(
          item: DramaSiteItem(id: 'v$i', title: '作品$i', cover: ''),
          siteId: 'a',
          siteName: '测试站',
          category: '漫剧',
        ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MoyiChannelWorksGrid(works: works, onTap: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 左列首卡比右列首卡高（9:16 高卡 vs 9:10 矮卡），且分居左右两列。
    final left = tester.getRect(
      find.byKey(const ValueKey('moyi_card_a_v0')),
    );
    final right = tester.getRect(
      find.byKey(const ValueKey('moyi_card_a_v1')),
    );
    expect(left.left < right.left, isTrue);
    expect(left.height > right.height, isTrue);
    expect(find.byKey(const ValueKey('moyi_works_grid')), findsOneWidget);
  });
}
