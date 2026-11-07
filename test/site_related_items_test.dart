import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';

/// loadSiteRelatedItems 的桩客户端：分类与目录按构造参数回，
/// catalogCalls 记下每次拉目录用的分类 id（空串 = 本站首页）。
class _StubClient implements DramaSiteContentClient {
  _StubClient({
    this.categoriesResult = const [],
    this.catalogByCategory = const {},
    this.homeItems = const [],
    this.throwOnCatalog = false,
  });

  final List<DramaSiteCategory> categoriesResult;
  final Map<String, List<DramaSiteItem>> catalogByCategory;
  final List<DramaSiteItem> homeItems;
  final bool throwOnCatalog;
  final List<String> catalogCalls = [];

  @override
  Future<List<DramaSiteCategory>> categories() async => categoriesResult;

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    catalogCalls.add(categoryId);
    if (throwOnCatalog) throw Exception('test-no-catalog');
    final items = categoryId.isEmpty
        ? homeItems
        : catalogByCategory[categoryId] ?? const <DramaSiteItem>[];
    return DramaSiteCatalogPage(items: items, hasMore: false);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) =>
      throw UnimplementedError();

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) =>
      throw UnimplementedError();

  @override
  Future<List<DramaSiteItem>> search(String query) async => const [];
}

DramaSiteDetail _detailWith({String category = '', String tags = ''}) =>
    DramaSiteDetail(
      id: 'self',
      title: '本片',
      cover: '',
      extra: {
        if (category.isNotEmpty) 'category': category,
        if (tags.isNotEmpty) 'tags': tags,
      },
      episodes: const [],
    );

void main() {
  test('同分类：按详情分类名匹配站分类，排除本片', () async {
    final client = _StubClient(
      categoriesResult: const [
        DramaSiteCategory('c1', '动漫'),
        DramaSiteCategory('c2', '电影'),
      ],
      catalogByCategory: const {
        'c1': [
          DramaSiteItem(id: 'self', title: '本片', cover: ''),
          DramaSiteItem(id: 'a', title: '同类一', cover: ''),
          DramaSiteItem(id: 'b', title: '同类二', cover: ''),
        ],
      },
      homeItems: const [
        DramaSiteItem(id: 'h1', title: '首页一', cover: ''),
      ],
    );
    final related = await loadSiteRelatedItems(
      client,
      _detailWith(category: '动漫'),
      'self',
    );
    expect(related.map((e) => e.id).toList(), ['a', 'b']);
    // 只拉了同分类，没碰首页。
    expect(client.catalogCalls, ['c1']);
  });

  test('标签名也能匹配到分类', () async {
    final client = _StubClient(
      categoriesResult: const [DramaSiteCategory('c1', '动漫')],
      catalogByCategory: const {
        'c1': [
          DramaSiteItem(id: 'a', title: '同类一', cover: ''),
        ],
      },
    );
    final related = await loadSiteRelatedItems(
      client,
      _detailWith(tags: '动漫，热血'),
      'self',
    );
    expect(related.map((e) => e.id).toList(), ['a']);
    expect(client.catalogCalls, ['c1']);
  });

  test('无匹配分类时退到本站首页', () async {
    final client = _StubClient(
      categoriesResult: const [DramaSiteCategory('c1', '动漫')],
      homeItems: const [
        DramaSiteItem(id: 'self', title: '本片', cover: ''),
        DramaSiteItem(id: 'h1', title: '首页一', cover: ''),
        DramaSiteItem(id: 'h2', title: '首页二', cover: ''),
      ],
    );
    final related = await loadSiteRelatedItems(
      client,
      _detailWith(category: '不存在的分类'),
      'self',
    );
    expect(related.map((e) => e.id).toList(), ['h1', 'h2']);
    expect(client.catalogCalls, ['']);
  });

  test('同分类页为空时退到本站首页', () async {
    final client = _StubClient(
      categoriesResult: const [DramaSiteCategory('c1', '动漫')],
      catalogByCategory: const {'c1': <DramaSiteItem>[]},
      homeItems: const [
        DramaSiteItem(id: 'h1', title: '首页一', cover: ''),
      ],
    );
    final related = await loadSiteRelatedItems(
      client,
      _detailWith(category: '动漫'),
      'self',
    );
    expect(related.map((e) => e.id).toList(), ['h1']);
    expect(client.catalogCalls, ['c1', '']);
  });

  test('全部取不到时回空列表', () async {
    final client = _StubClient(throwOnCatalog: true);
    final related = await loadSiteRelatedItems(
      client,
      _detailWith(category: '动漫'),
      'self',
    );
    expect(related, isEmpty);
  });

  test('去重并最多 10 条', () async {
    final home = [
      for (var i = 0; i < 15; i++)
        DramaSiteItem(id: 'h$i', title: '首页$i', cover: ''),
      const DramaSiteItem(id: 'h0', title: '重复', cover: ''),
      const DramaSiteItem(id: 'self', title: '本片', cover: ''),
    ];
    final client = _StubClient(homeItems: home);
    final related = await loadSiteRelatedItems(
      client,
      _detailWith(),
      'self',
    );
    expect(related.length, 10);
    expect(related.map((e) => e.id).toSet().length, 10);
    expect(related.any((e) => e.id == 'self'), isFalse);
  });
}
