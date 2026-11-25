import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/site_health.dart';
import 'package:fqapp/services/site_thumb_cache.dart';
import 'package:fqapp/widgets/site_grid_dialog.dart';

/// 站点列表批（C1 透视 + A3 健康点 / 排序）的弹窗测试：
/// 有缓存封面的站显图、无封面的回落首字块；有学习记录的站画
/// 健康点、没记录的不画；开健康排序后组内按健康分重排。

const _entries = <SiteGridEntry>[
  (id: 'bad', name: '差站', zone: SiteGridZone.builtin, group: SiteGridGroup.video),
  (
    id: 'plain',
    name: '无图站',
    zone: SiteGridZone.builtin,
    group: SiteGridGroup.video,
  ),
  (
    id: 'good',
    name: '好站',
    zone: SiteGridZone.builtin,
    group: SiteGridGroup.video,
  ),
];

void main() {
  late Directory tempDir;
  late SiteThumbCache cache;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SiteHealthStore.instance.resetForTest();
    SiteHealthStore.instance.markLoadedForTest();
    SiteHealthPrefs.instance.resetForTest();
    tempDir = await Directory.systemTemp.createTemp('site_grid_thumb_test');
    cache = SiteThumbCache(directoryProvider: () async => tempDir);
    await cache.put('good', 'https://example.com/good.jpg');
    await cache.put('bad', 'https://example.com/bad.jpg');
    // 好站：三类全成功 → 绿；差站：播放全失败 → 红。
    final store = SiteHealthStore.instance;
    for (var i = 0; i < 4; i++) {
      store.recordSearch('good', ok: true, items: 5);
      store.recordDetail('good', ok: true);
      store.recordPlay('good', ok: true);
      store.recordPlay('bad', ok: false);
    }
  });

  tearDown(() async {
    await SiteHealthStore.instance.flush();
    SiteHealthStore.instance.resetForTest();
    SiteHealthPrefs.instance.resetForTest();
    cache.resetForTest();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Widget host() {
    return MaterialApp(
      home: SiteGridDialog(
        sites: _entries,
        selectedId: 'good',
        thumbCache: cache,
        thumbFetcher: (_) async => null,
        thumbImageBuilder: (url) => Container(
          key: ValueKey('thumb-img-$url'),
          color: const Color(0xFF336699),
        ),
      ),
    );
  }

  testWidgets('有封面显图、无封面回落首字块、健康点只画有记录的站', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byKey(const ValueKey('thumb-img-https://example.com/good.jpg')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('thumb-img-https://example.com/bad.jpg')),
      findsOneWidget,
    );
    // 无图站回落首字块：名字首字「无」在封面区出现（站名区也有一份，
    // 所以至少两处）。
    expect(find.text('无'), findsWidgets);
    // 健康点：好站与差站有记录 → 画；无图站没记录 → 不画。
    expect(
      find.byKey(const ValueKey('site-grid-health-dot-good')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('site-grid-health-dot-bad')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('site-grid-health-dot-plain')),
      findsNothing,
    );
  });

  testWidgets('默认不排序：保持登记顺序', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    final badPos = tester.getTopLeft(
      find.byKey(const ValueKey('site-grid-row-bad')),
    );
    final goodPos = tester.getTopLeft(
      find.byKey(const ValueKey('site-grid-row-good')),
    );
    expect(badPos.dx, lessThan(goodPos.dx));
  });

  testWidgets('开健康排序后：好站排到差站前面', (tester) async {
    await SiteHealthPrefs.instance.setPickerSort(true);
    await tester.pumpWidget(host());
    await tester.pump();
    final badPos = tester.getTopLeft(
      find.byKey(const ValueKey('site-grid-row-bad')),
    );
    final plainPos = tester.getTopLeft(
      find.byKey(const ValueKey('site-grid-row-plain')),
    );
    final goodPos = tester.getTopLeft(
      find.byKey(const ValueKey('site-grid-row-good')),
    );
    expect(goodPos.dx, lessThan(plainPos.dx));
    expect(plainPos.dx, lessThan(badPos.dx));
  });
}
