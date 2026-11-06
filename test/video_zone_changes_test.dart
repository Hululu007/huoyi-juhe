import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/category_page.dart';
import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:fqapp/services/unified_video_categories.dart';
import 'package:fqapp/services/video_category_tags.dart';
import 'package:fqapp/widgets/home/drama_site_grid.dart';

class _FakeClient extends DramaSiteContentClient {
  @override
  Future<List<DramaSiteCategory>> categories() async =>
      const [DramaSiteCategory('all', '全部')];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    return DramaSiteCatalogPage(
      items: [
        for (var i = 0; i < 8; i++)
          DramaSiteItem(id: 'v$i', title: '剧$i', cover: ''),
      ],
      hasMore: false,
    );
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async =>
      const DramaSiteDetail(id: '', title: '', cover: '', episodes: []);

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async =>
      const DramaPlaySource(url: '');
}

SourceEntry _entry({
  required String id,
  required String name,
  required SourceKind kind,
  Map<String, Object?> extra = const {},
}) {
  return SourceEntry(
    id: id,
    name: name,
    kind: kind,
    address: '$id.addr',
    detail: '',
    extra: extra,
  );
}

void main() {
  test('影视 tab 标签：成人站追加熟女，非成人站不加', () async {
    SharedPreferences.setMockInitialValues({
      'juhe_custom_sources': jsonEncode([
        _entry(
          id: 'seed_91crdjai',
          name: '🔞91成人短剧',
          kind: SourceKind.pyImport,
          extra: {
            'contentType': 'video',
            'builtin': true,
            'seedId': '91crdjai',
            'extractedCategories': [
              {'id': 'duanju', 'name': '成人短剧'},
              {'id': 'manju', 'name': '成人漫剧'},
            ],
            'videoTags': {
              'theme': ['都市'],
              'role': <String>[],
              'plot': <String>[],
            },
          },
        ).toJson(),
        _entry(
          id: 'plain_site',
          name: '普通站',
          kind: SourceKind.customMaccms,
          extra: {
            'contentType': 'video',
            'extractedCategories': [
              {'id': 'c1', 'name': '都市'},
            ],
          },
        ).toJson(),
      ]),
    });
    final adult = await loadVideoCategoryData('seed_91crdjai');
    expect(adult.hotTags, contains('成人短剧'));
    expect(adult.hotTags, contains('成人漫剧'));
    expect(adult.hotTags, contains('熟女'));
    expect(adult.themes, ['都市']);
    expect(adult.roles, isEmpty);
    final plain = await loadVideoCategoryData('plain_site');
    expect(plain.hotTags, ['都市']);
    expect(plain.hotTags, isNot(contains('熟女')));
  });

  test('注册分类读提取结果，不再只有全部', () {
    List<(String, String)> pairs(List<DramaSiteCategory> cats) =>
        [for (final c in cats) (c.id, c.name)];
    expect(
      pairs(
        SourceRegistry.categoriesFromExtra({
          'extractedCategories': [
            {'id': 'duanju', 'name': '成人短剧'},
            {'id': '', 'name': '空 id 跳过'},
          ],
        }),
      ),
      [('duanju', '成人短剧')],
    );
    expect(
      pairs(SourceRegistry.categoriesFromExtra({})),
      [('all', '全部')],
    );
  });

  test('统一影视区站表：内置导入视频站在 jar 站之后', () {
    final entries = [
      _entry(
        id: 'jar:zakatv:demo',
        name: '预置 jar 站',
        kind: SourceKind.jarImport,
        extra: {'builtin': true, 'contentType': 'video'},
      ),
      _entry(
        id: 'seed_91crdjai',
        name: '🔞91成人影院',
        kind: SourceKind.pyImport,
        extra: {'builtin': true, 'contentType': 'video'},
      ),
      _entry(
        id: 'import_user_py',
        name: '用户导入的 py 站',
        kind: SourceKind.pyImport,
        extra: {'contentType': 'video'},
      ),
    ];
    final unified = unifiedVideoZoneSites(entries);
    final ids = unified.map((site) => site.id).toList();
    expect(ids, contains('jar:zakatv:demo'));
    expect(ids, contains('seed_91crdjai'));
    expect(ids, isNot(contains('import_user_py')));
    expect(
      ids.indexOf('seed_91crdjai'),
      greaterThan(ids.indexOf('jar:zakatv:demo')),
    );
  });

  test('短剧名内置导入站不进影视区站表', () {
    final entries = [
      _entry(
        id: 'jar:zakatv:demo',
        name: '预置 jar 站',
        kind: SourceKind.jarImport,
        extra: {'builtin': true, 'contentType': 'video'},
      ),
      _entry(
        id: 'seed_91crdjai',
        name: '🔞91成人短剧',
        kind: SourceKind.pyImport,
        extra: {'builtin': true, 'contentType': 'video'},
      ),
    ];
    final ids =
        unifiedVideoZoneSites(entries).map((site) => site.id).toList();
    // 显示名带「短剧」即短剧站，归短剧区，不进影视区。
    expect(ids, contains('jar:zakatv:demo'));
    expect(ids, isNot(contains('seed_91crdjai')));
  });

  testWidgets('影视页网格 4 列，默认仍 3 列', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    Future<void> pumpGrid({int? columns}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                DramaSiteGrid(
                  siteId: 'fake_site',
                  categoryId: 'all',
                  gridWidth: 400,
                  client: _FakeClient(),
                  showFilterBar: false,
                  columns: columns ?? 3,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpGrid(columns: 4);
    var delegate = tester.widget<SliverGrid>(
      find.byType(SliverGrid),
    ).gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 4);

    await pumpGrid();
    delegate = tester.widget<SliverGrid>(
      find.byType(SliverGrid),
    ).gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 3);
  });

  testWidgets('分类页影视 tab：左栏四组 + 含熟女的热门标签', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: CategoryPage(
          videoSiteId: 'seed_91crdjai',
          openVideoTab: true,
          // 统一资产默认走 rootBundle，在 widget 测试的 fake async 下
          // 读不到会挂起：这里直接给 empty，走单站模式（本站四组），
          // 本用例验的就是单站模式。
          unifiedLoader: () async => UnifiedVideoCategories.empty,
          videoLoader: (_) async => const VideoCategoryData(
            siteId: 'seed_91crdjai',
            siteName: '🔞91成人短剧',
            hotTags: ['成人短剧', '成人漫剧', '熟女'],
            themes: ['都市'],
            roles: [],
            plots: [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('影视'), findsWidgets);
    expect(find.text('热门标签'), findsWidgets);
    expect(find.text('主题'), findsWidgets);
    expect(find.text('角色'), findsWidgets);
    expect(find.text('情节'), findsWidgets);
    expect(find.text('熟女'), findsOneWidget);
    expect(find.text('成人短剧'), findsOneWidget);
    expect(find.text('都市'), findsOneWidget);
  });
}
