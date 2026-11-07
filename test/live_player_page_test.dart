import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/live_player_page.dart';
import 'package:fqapp/pages/live_status_panel.dart';
import 'package:fqapp/services/live_sources.dart';

const _testSource = LiveSource(
  id: 'test',
  name: '测试源',
  description: '测试用',
  protocol: LiveProtocol.list,
);

List<LiveChannel> _channels() => [
  LiveChannel(title: '频道一', url: 'https://example.invalid/a.m3u8', group: '测试分组'),
  LiveChannel(title: '频道二', url: 'https://example.invalid/b.m3u8', group: '测试分组'),
];

Widget _wrap(Widget child) => MaterialApp(home: child);

/// 测试里没有原生播放器，取流必然失败：页面出 LiveStatusPanel 报错卡
/// （「直播暂时中断」），控制层（顶栏标题、上一集/下一集、选集）被报错卡
/// 盖住不显示；切台走报错卡上的「换个频道」选集表，当前台以 selected 标记。
Future<void> _pumpPlayer(WidgetTester tester) async {
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
}

/// 选集表里当前台的 ListTile（selected 为真且标题是 [title]）。
Finder _selectedChannel(String title) => find.byWidgetPredicate(
  (widget) =>
      widget is ListTile &&
      widget.selected &&
      widget.title is Text &&
      (widget.title as Text).data == title,
);

/// 点报错卡上的「换个频道」，等选集表弹出来。
Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('换个频道'));
  await tester.pumpAndSettle();
}

void main() {
  test('内置直播源只剩四个：秀果、欲火聚合、百年直播、成人点播（至尊 m3u）', () {
    expect(
      [for (final source in LiveSources.builtin) source.id],
      const ['xiuguo', 'maiyoux', 'bnzb', 'user_m3u'],
    );
    expect(
      LiveSources.builtin.map((source) => source.adult).toSet(),
      {true},
    );
  });

  testWidgets('直播播放器取流失败出报错卡，选集表切台', (tester) async {
    await _pumpPlayer(tester);

    // 报错卡出现，不再是旧的 PlayerErrorFeedback；「直播中」角标已按火蚁TV去掉，
    // 控制层被报错卡盖住，顶栏标题与上一集/下一集/选集都不显示。
    expect(find.byType(LiveStatusPanel), findsOneWidget);
    expect(find.text('直播暂时中断'), findsOneWidget);
    expect(find.text('重新连接'), findsOneWidget);
    expect(find.text('换个频道'), findsOneWidget);
    expect(find.text('直播中'), findsNothing);
    expect(find.text('频道一 · 测试源'), findsNothing);
    expect(find.byTooltip('上一集'), findsNothing);
    expect(find.byTooltip('下一集'), findsNothing);
    expect(find.byTooltip('选集'), findsNothing);
    expect(find.byTooltip('退出全屏'), findsNothing);

    // 选集表切到频道二：当前台标记跟着走。
    await _openSheet(tester);
    expect(find.text('测试源 · 2 个频道'), findsOneWidget);
    expect(find.text('频道一'), findsOneWidget);
    expect(find.text('频道二'), findsOneWidget);
    expect(_selectedChannel('频道一'), findsOneWidget);
    await tester.tap(find.text('频道二'));
    await tester.pumpAndSettle();
    expect(find.text('测试源 · 2 个频道'), findsNothing);

    await _openSheet(tester);
    expect(_selectedChannel('频道二'), findsOneWidget);
    await tester.tap(find.text('频道一'));
    await tester.pumpAndSettle();
    expect(find.text('测试源 · 2 个频道'), findsNothing);

    await _openSheet(tester);
    expect(_selectedChannel('频道一'), findsOneWidget);
  });

  testWidgets('上下滑切频道：上滑下一个、下滑上一个', (tester) async {
    // 报错卡是全屏 SingleChildScrollView（与火蚁TV 的 StatusPanel 同构），
    // 报错态下上下滑会被它当滚动吃掉，切台走「换个频道」；真机正常播放时
    // 没有报错卡盖屏，上下滑直达播放器手势层。下面在首帧加载态（报错卡
    // 还没画出来）起手滑，验的就是这条手势链路；起手点与旧测试一致。
    await tester.pumpWidget(
      _wrap(
        LivePlayerPage(
          channels: _channels(),
          startIndex: 0,
          source: _testSource,
        ),
      ),
    );
    await tester.flingFrom(
      const Offset(100, 300),
      const Offset(0, -300),
      1000,
    );
    await tester.pumpAndSettle();

    await _openSheet(tester);
    expect(_selectedChannel('频道二'), findsOneWidget);
    await tester.tap(find.text('频道二'));
    await tester.pumpAndSettle();

    // 下滑方向另起一页（startIndex: 1）验：先 pump 占位页再起新页，
    // 否则同型 widget 会复用旧 State、报错卡还挂在树上；同样在首帧加载态起手。
    await tester.pumpWidget(_wrap(const SizedBox()));
    await tester.pumpWidget(
      _wrap(
        LivePlayerPage(
          channels: _channels(),
          startIndex: 1,
          source: _testSource,
        ),
      ),
    );
    await tester.flingFrom(
      const Offset(100, 300),
      const Offset(0, 300),
      1000,
    );
    await tester.pumpAndSettle();

    await _openSheet(tester);
    expect(_selectedChannel('频道一'), findsOneWidget);
  });

  testWidgets('选集表是纯频道列表，不含源切换', (tester) async {
    await _pumpPlayer(tester);

    await _openSheet(tester);

    expect(find.text('测试源 · 2 个频道'), findsOneWidget);
    expect(find.text('频道一'), findsOneWidget);
    expect(find.text('频道二'), findsOneWidget);
    expect(find.text('秀果'), findsNothing);
    expect(find.text('欲火聚合'), findsNothing);
    expect(find.text('成人点播'), findsNothing);
  });

  testWidgets('系统返回键两步走：先退出沉浸式，再按退出播放页', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => LivePlayerPage(
                      channels: _channels(),
                      startIndex: 0,
                      source: _testSource,
                    ),
                  ),
                ),
                child: const Text('打开直播播放页'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开直播播放页'));
    await tester.pumpAndSettle();
    expect(find.byType(LiveStatusPanel), findsOneWidget);

    // 第一步：退出沉浸式（恢复系统栏），仍在播放页。
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(LiveStatusPanel), findsOneWidget);

    // 第二步：退出播放页，回到首页。
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(LiveStatusPanel), findsNothing);
    expect(find.text('打开直播播放页'), findsOneWidget);
  });
}
