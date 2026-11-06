import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/core_novel_category_page.dart';
import 'package:fqapp/services/core_novel_categories.dart';
import 'package:fqapp/services/drama_sites.dart';

MediaItem _item(String title) => MediaItem(
  id: title,
  title: title,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'book',
  seriesId: title,
  source: 'engine:aabook',
);

void main() {
  test('合并分类：首位是全部（每站首分类），同名跨站合并', () {
    final merged = mergeNovelCategories(
      {
        'aabook': [
          const DramaSiteCategory('a1', '都市'),
          const DramaSiteCategory('a2', '玄幻'),
        ],
        'ylxs': [
          const DramaSiteCategory('y1', '都市'),
          const DramaSiteCategory('y2', '仙侠'),
        ],
      },
      ['aabook', 'ylxs'],
    );
    expect(merged.first.name, '全部');
    expect(
      merged.first.entries.map((e) => '${e.siteId}:${e.categoryId}'),
      ['aabook:a1', 'ylxs:y1'],
    );
    final urban = merged.firstWhere((c) => c.name == '都市');
    expect(urban.entries.length, 2);
    expect(
      merged.map((c) => c.name),
      ['全部', '都市', '玄幻', '仙侠'],
    );
  });

  test('合并分类：站自带全部不另起一条，空名与空站跳过', () {
    final merged = mergeNovelCategories(
      {
        'aabook': [
          const DramaSiteCategory('a0', '全部'),
          const DramaSiteCategory('a1', '都市'),
          const DramaSiteCategory('a2', ''),
        ],
        'ylxs': const [],
      },
      ['aabook', 'ylxs'],
    );
    expect(
      merged.map((c) => c.name),
      ['全部', '都市'],
    );
    expect(merged.first.entries.length, 1);
  });

  test('合并分类：站数多的在前，同站数按首次出现顺序', () {
    final merged = mergeNovelCategories(
      {
        'aabook': [
          const DramaSiteCategory('a1', '冷门'),
          const DramaSiteCategory('a2', '热门'),
        ],
        'ylxs': [
          const DramaSiteCategory('y1', '热门'),
        ],
      },
      ['aabook', 'ylxs'],
    );
    expect(
      merged.map((c) => c.name),
      ['全部', '热门', '冷门'],
    );
  });

  test('混排：轮流取条，空站跳过，总量 60 封顶', () {
    final mixed = interleaveCatalogItems([
      [_item('a1'), _item('a2'), _item('a3')],
      const [],
      [_item('b1'), _item('b2')],
    ]);
    expect(
      mixed.map((i) => i.title),
      ['a1', 'b1', 'a2', 'b2', 'a3'],
    );
    final capped = interleaveCatalogItems([
      List.generate(40, (i) => _item('a$i')),
      List.generate(40, (i) => _item('b$i')),
    ]);
    expect(capped.length, 60);
    expect(capped.first.title, 'a0');
    expect(capped[1].title, 'b0');
  });

  testWidgets('混排目录页：注入数据直接出卡，不落网络', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CoreNovelCategoryPage(
          category: const MergedNovelCategory('都市', [
            NovelCategoryEntry('aabook', 'a1'),
            NovelCategoryEntry('ylxs', 'y1'),
          ]),
          loader: (_) async => [_item('书一'), _item('书二')],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('都市'), findsWidgets);
    expect(find.text('书一'), findsOneWidget);
    expect(find.text('书二'), findsOneWidget);
  });
}
