import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/live_player_page.dart';
import 'package:fqapp/services/live_sources.dart';
import 'package:fqapp/widgets/player/player_feedback.dart';

const _testSource = LiveSource(
  id: 'test',
  name: '测试源',
  description: '测试用',
  protocol: LiveProtocol.list,
);

List<LiveChannel> _channels() => const [
  LiveChannel(title: '频道一', url: 'https://example.invalid/a.m3u8', group: '测试分组'),
  LiveChannel(title: '频道二', url: 'https://example.invalid/b.m3u8', group: '测试分组'),
];

Widget _wrap(Widget child) => MaterialApp(home: child);

/// 播放器一点开就是全屏，控件 3 秒自动藏起：点一下画面空白处再断言。
Future<void> _showControls(WidgetTester tester) async {
  await tester.tapAt(const Offset(50, 100));
  await tester.pump();
}

void main() {
  test('内置直播源只剩三个：秀果、欲火聚合、成人点播（至尊 m3u）', () {
    expect(
      [for (final source in LiveSources.builtin) source.id],
      const ['xiuguo', 'maiyoux', 'user_m3u'],
    );
    expect(
      LiveSources.builtin.map((source) => source.adult).toSet(),
      {true},
    );
  });

  testWidgets('直播播放器显示频道名、直播中、下/上一个频道可切', (tester) async {
    await tester.pumpWidget(
      _wrap(
        LivePlayerPage(
          channels: _channels(),
          startIndex: 0,
          source: _testSource,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _showControls(tester);

    expect(find.text('频道一'), findsOneWidget);
    expect(find.text('直播中'), findsOneWidget);
    expect(find.byTooltip('下一个频道'), findsOneWidget);
    expect(find.byTooltip('上一个频道'), findsOneWidget);
    expect(find.byTooltip('频道列表'), findsOneWidget);
    // 全屏时有两个「退出全屏」：顶栏返回钮与底栏全屏钮。
    expect(find.byTooltip('退出全屏'), findsNWidgets(2));
    // 测试里没有原生播放器，取流必然失败：页面应出诚实报错而不是崩掉。
    // 具体报错标题由原生通道的失败形态决定（超时/缺插件），只断言报错卡出现。
    expect(find.byType(PlayerErrorFeedback), findsOneWidget);

    await tester.tap(find.byTooltip('下一个频道'));
    await tester.pumpAndSettle();
    await _showControls(tester);
    expect(find.text('频道二'), findsOneWidget);

    await tester.tap(find.byTooltip('上一个频道'));
    await tester.pumpAndSettle();
    await _showControls(tester);
    expect(find.text('频道一'), findsOneWidget);
  });

  testWidgets('上下滑切频道：上滑下一个、下滑上一个', (tester) async {
    await tester.pumpWidget(
      _wrap(
        LivePlayerPage(
          channels: _channels(),
          startIndex: 0,
          source: _testSource,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _showControls(tester);
    expect(find.text('频道一'), findsOneWidget);

    // 从画面左边缘起手上滑：报错卡片居中，起手点落在卡片上会被卡片
    // 里的重试按钮吃掉手势；左边缘是纯视频区，上下滑一定到播放器。
    await tester.flingFrom(
      const Offset(100, 300),
      const Offset(0, -300),
      1000,
    );
    await tester.pumpAndSettle();
    await _showControls(tester);
    expect(find.text('频道二'), findsOneWidget);

    await tester.flingFrom(
      const Offset(100, 300),
      const Offset(0, 300),
      1000,
    );
    await tester.pumpAndSettle();
    await _showControls(tester);
    expect(find.text('频道一'), findsOneWidget);
  });

  testWidgets('频道列表弹出三个内置源与全部频道', (tester) async {
    await tester.pumpWidget(
      _wrap(
        LivePlayerPage(
          channels: _channels(),
          startIndex: 0,
          source: _testSource,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _showControls(tester);

    await tester.tap(find.byTooltip('频道列表'));
    await tester.pumpAndSettle();

    expect(find.text('频道'), findsOneWidget);
    expect(find.text('频道一'), findsWidgets);
    expect(find.text('频道二'), findsWidgets);
    expect(find.text('秀果'), findsOneWidget);
    expect(find.text('欲火聚合'), findsOneWidget);
    expect(find.text('成人点播'), findsOneWidget);
  });
}
