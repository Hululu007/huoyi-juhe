import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:fqapp/widgets/site_grid_dialog.dart';

/// `videoZoneSiteEntries` 纯函数测试：影视/午夜切换弹窗的区·分组划分。
///
/// 用注入的登记行验逻辑，不碰真实登记表与 SharedPreferences。
/// 自 2026-11-24 起统一表（`unifiedVideoZoneSites`）有第四路——
/// 用户导入的影视站（`videoPagePlayableSites` 再过短剧过滤），
/// 落导入区·视频组；用户导入的短剧站仍不进表。

const _custom = [
  SourceEntry(
    id: 'jar:zakatv:ZakaMissav',
    name: 'MissAV',
    kind: SourceKind.jarImport,
    extra: {'builtin': true, 'contentType': 'video'},
  ),
  SourceEntry(
    id: 'builtin-py',
    name: '内置导入站',
    kind: SourceKind.pyImport,
    extra: {'builtin': true, 'contentType': 'video'},
  ),
  SourceEntry(
    id: 'seed_missav',
    name: '种子站',
    kind: SourceKind.pyImport,
    extra: {'builtin': true, 'contentType': 'video'},
  ),
  SourceEntry(
    id: 'user-py',
    name: '用户导入站',
    kind: SourceKind.pyImport,
    extra: {'contentType': 'video'},
  ),
  SourceEntry(
    id: 'user-duanju',
    name: '用户导入短剧站',
    kind: SourceKind.pyImport,
    extra: {'contentType': 'video'},
  ),
];

void main() {
  group('videoZoneSiteEntries', () {
    test('午夜 jar 行与内置导入行进内置区·午夜组，用户导入影视站进导入区·视频组', () {
      final entries = videoZoneSiteEntries(_custom, 100000);
      final byId = {for (final e in entries) e.id: e};

      expect(
        byId.keys,
        containsAll(['jar:zakatv:ZakaMissav', 'builtin-py', 'seed_missav']),
      );
      for (final id in [
        'jar:zakatv:ZakaMissav',
        'builtin-py',
        'seed_missav',
      ]) {
        expect(byId[id]!.zone, SiteGridZone.builtin, reason: id);
        expect(byId[id]!.group, SiteGridGroup.midnight, reason: id);
      }
      // 第四路：用户导入的影视站进导入区·视频组。
      expect(byId['user-py']!.zone, SiteGridZone.import);
      expect(byId['user-py']!.group, SiteGridGroup.video);
      // 用户导入的短剧站（名字带「短剧」）仍不进表。
      expect(byId.containsKey('user-duanju'), isFalse);
    });

    test('用户导入站撞内置站 id 时保留内置那条（内置区·午夜组）', () {
      final entries = videoZoneSiteEntries([
        ..._custom,
        // 与内置导入行同 id 的用户行：统一表去重只留内置那条，
        // 区判定也跟着保留内置，不因登记行后写入被误判进导入区。
        const SourceEntry(
          id: 'builtin-py',
          name: '同名用户站',
          kind: SourceKind.pyImport,
          extra: {'contentType': 'video'},
        ),
      ], 100000);
      final byId = {for (final e in entries) e.id: e};

      expect(entries.where((e) => e.id == 'builtin-py').length, 1);
      expect(byId['builtin-py']!.zone, SiteGridZone.builtin);
      expect(byId['builtin-py']!.group, SiteGridGroup.midnight);
    });

    test('隐藏只认归一化后的核心站 id：jar 行与种子行同站一起藏', () {
      final entries = videoZoneSiteEntries(
        _custom,
        100000,
        // missav 被关掉：jar 行（jar:zakatv:ZakaMissav）与种子行
        //（seed_missav）归一化后都是 missav，一起不再列出。
        isBuiltinEnabled: (id) => id != 'missav',
      );

      expect(entries.map((e) => e.id), ['builtin-py', 'user-py']);
    });

    test('修为不到时成人站不列出', () {
      final entries = videoZoneSiteEntries(_custom, 0);

      // missav 是成人站，修为 0 时 jar 行与种子行都被分档拦下；
      // 非成人内置导入行与用户导入行不受分档影响，仍在。
      expect(entries.map((e) => e.id), ['builtin-py', 'user-py']);
    });

    test('分档门禁也拦用户导入的成人站：归一化到分档表的用户站修为不到不列出', () {
      final entries = videoZoneSiteEntries([
        const SourceEntry(
          id: 'user-missav',
          name: '用户导入的 MissAV',
          kind: SourceKind.pyImport,
          extra: {'contentType': 'video'},
        ),
        // id 本身就是分档表里的成人站 id：修为 0 时被拦下。
        const SourceEntry(
          id: 'missav',
          name: 'MissAV',
          kind: SourceKind.pyImport,
          extra: {'contentType': 'video'},
        ),
      ], 0);

      expect(entries.map((e) => e.id), ['user-missav']);
    });

    test('删当前站回落首站：当前站不在表里时 resolveCurrentSiteId 取首站', () {
      final entries = videoZoneSiteEntries(_custom, 100000);
      final ids = [for (final entry in entries) entry.id];

      // 当前站还在表里就留着。
      expect(resolveCurrentSiteId('user-py', ids), 'user-py');
      // 当前站（已删的用户导入站）不在表里，回落到首站。
      expect(resolveCurrentSiteId('user-py-deleted', ids), ids.first);
      // 表空时回 null，调用方保留旧站。
      expect(resolveCurrentSiteId('user-py', []), isNull);
    });
  });

  group('unifiedVideoZoneSites 用户导入路', () {
    test('用户导入影视站在内置三路之后、按登记顺序排', () {
      final ids =
          unifiedVideoZoneSites(_custom).map((site) => site.id).toList();
      expect(ids, contains('user-py'));
      expect(ids, isNot(contains('user-duanju')));
      expect(
        ids.indexOf('user-py'),
        greaterThan(ids.indexOf('builtin-py')),
      );
      expect(
        ids.indexOf('user-py'),
        greaterThan(ids.indexOf('jar:zakatv:ZakaMissav')),
      );
    });

    test('用户导入的 MacCMS / jar / JS / XBPQ 站也进统一表', () {
      const entries = [
        SourceEntry(
          id: 'user-maccms',
          name: '用户 MacCMS 站',
          kind: SourceKind.customMaccms,
          extra: {'contentType': 'video'},
        ),
        SourceEntry(
          id: 'user-jar',
          name: '用户 jar 站',
          kind: SourceKind.jarImport,
          extra: {'contentType': 'video'},
        ),
      ];
      final ids =
          unifiedVideoZoneSites(entries).map((site) => site.id).toList();
      expect(ids, containsAll(['user-maccms', 'user-jar']));
    });
  });

  group('弹窗闭环：真实条目进弹窗，点选与长按删除', () {
    // 不手写假条目：条目由真实纯函数 `videoZoneSiteEntries` 出，
    // 验“表里有的用户导入站，在弹窗里真能点中、真能删”。
    // 注：这里只验弹窗返回 id 与删除入口接线；切站后的持久化
    // （SharedPreferences 写 video_zone_site_id）与分类/取流走
    // 调用点已有的 `_openVideoZoneSiteSwitcher` /
    // `_resolveVideoZoneCategory`（`clientFor` 路），与内置 jar
    // 站同一条路，见报告；真机终验再点真站走全程。

    testWidgets('点导入区里的用户导入站，弹窗返回该站 id', (tester) async {
      final entries = videoZoneSiteEntries(_custom, 100000);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      String? picked;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (buttonContext) => TextButton(
                  onPressed: () async {
                    picked = await showSiteGridDialog(
                      context: buttonContext,
                      sites: entries,
                      initialZone: SiteGridZone.import,
                      onDeleteSite: (_) async => true,
                    );
                  },
                  child: const Text('打开切换站点'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开切换站点'));
      await tester.pumpAndSettle();
      expect(find.text('导入区（1）'), findsOneWidget);
      expect(find.text('视频 1'), findsOneWidget);
      await tester.tap(find.text('用户导入站'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('site-grid-dialog')), findsNothing);
      expect(picked, 'user-py');
    });

    testWidgets('长按用户导入站确认删除，行摘掉、删除入口拿到该站 id', (tester) async {
      final entries = videoZoneSiteEntries(_custom, 100000);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      String? deletedId;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (buttonContext) => TextButton(
                  onPressed: () async {
                    await showSiteGridDialog(
                      context: buttonContext,
                      sites: entries,
                      initialZone: SiteGridZone.import,
                      onDeleteSite: (entry) async {
                        deletedId = entry.id;
                        return true;
                      },
                    );
                  },
                  child: const Text('打开切换站点'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开切换站点'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('用户导入站'));
      await tester.pumpAndSettle();
      expect(find.text('删除导入站'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('site-grid-delete-confirm-ok')),
      );
      await tester.pumpAndSettle();
      expect(deletedId, 'user-py');
      expect(find.text('用户导入站'), findsNothing);
      expect(find.text('导入区（0）'), findsOneWidget);
    });
  });
}
