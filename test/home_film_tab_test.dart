import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/widgets/home/home_tab_bar.dart';

/// 首页顶部「影视」tab：短剧与漫剧之间多一个影视 tab，点进去左上角
/// 切换器改切影视站（走影视区站表，含午夜区站，按修为分档过滤），
/// 内容是该站的目录网格，点卡片进现有影视详情页。
void main() {
  /// 一个内置导入影视站（py，builtin），进影视区统一站表；没有真实
  /// 客户端（path 为空），网格应报「该站源当前不可用」，不触网。
  void seedFilmSite() {
    SharedPreferences.setMockInitialValues({
      'juhe_custom_sources': jsonEncode([
        {
          'id': 'seed_testfilm',
          'name': '测试影视',
          'kind': 'pyImport',
          'address': 'testfilm.py',
          'detail': '测试',
          'enabled': true,
          'extra': {'builtin': true, 'contentType': 'video'},
        },
      ]),
      'video_zone_site_id': 'seed_testfilm',
    });
  }

  setUp(seedFilmSite);

  HomeNotifier testNotifier() => HomeNotifier(
    usesLocalTabs: true,
    homepageLoader:
        ({
          int tabType = 2,
          int offset = 0,
          String? sessionId,
        }) async => HomepagePage(
          items: const [],
          nextOffset: null,
          sessionId: null,
        ),
    searchLoader: (query, {int page = 1}) async => const [],
  );

  test('顶栏顺序：影视在短剧与漫剧之间', () {
    final labels = [for (final c in homeCategories) c.label];
    expect(labels, ['推荐', '小说', '短剧', '影视', '漫剧', '漫画', '听书']);
    expect(
      labels.indexOf('影视'),
      labels.indexOf('短剧') + 1,
    );
    expect(
      labels.indexOf('影视'),
      labels.indexOf('漫剧') - 1,
    );
  });

  test('本地 tab 表：影视在下标 3，与顶栏一一对应', () {
    expect(HomeNotifier.tabs.indexOf('影视'), 3);
    expect(HomeNotifier.tabs.indexOf('短剧'), 2);
    expect(HomeNotifier.tabs.indexOf('漫剧'), 4);
    expect(HomeNotifier.tabs.indexOf('漫画'), 5);
    expect(HomeNotifier.tabs.indexOf('听书'), 6);
  });

  test('影视 tab 的身份：video 种类、无书城流（站驱动）', () {
    final container = ProviderContainer(
      overrides: [homeProvider.overrideWith(testNotifier)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(homeProvider.notifier);
    final identity = notifier.identityOf(HomeNotifier.tabs.indexOf('影视'));
    expect(identity.name, '影视');
    expect(identity.kind, 'video');
    // 没有对应的书城流：内容不走 provider 的推荐流，走站目录网格。
    expect(identity.tabType, isNull);
  });

  testWidgets('点影视 tab：左上角药丸切成影视站，点药丸弹出影视站切换器', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [homeProvider.overrideWith(testNotifier)],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();
    final filmTab = find.byKey(const ValueKey('home_category_3'));
    await tester.ensureVisible(filmTab);
    await tester.pumpAndSettle();
    await tester.tap(filmTab);
    await tester.pumpAndSettle();
    // 药丸显示当前影视站名（不是短剧站名）；药丸内限定，避免与
    // 另一处同名 11px 副文本重名。
    expect(
      find.descendant(
        of: find.byKey(const Key('home_site_button')),
        matching: find.text('测试影视'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    // 点药丸弹出影视站切换器（站表来自影视区统一表）。
    await tester.tap(find.byKey(const Key('home_site_button')));
    await tester.pumpAndSettle();
    expect(find.text('切换站点'), findsOneWidget);
    expect(find.text('测试影视'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
