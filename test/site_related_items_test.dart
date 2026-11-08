import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';

/// loadSiteRelatedItems 的桩客户端：分类与目录按构造参数回，
/// catalogCalls 记下每次拉目录用的分类 id（'all' = 本站首页）。
class _StubClient implements DramaSiteContentClient {
  _StubClient({
    this.categoriesResult = const [],
    this.catalogByCategory = const {},
    this.homeItems = const [],
    this.throwOnCatalog = false,
    this.throwOnCategories = const {},
  });

  final List<DramaSiteCategory> categoriesResult;
  final Map<String, List<DramaSiteItem>> catalogByCategory;
  final List<DramaSiteItem> homeItems;
  final bool throwOnCatalog;
  final Set<String> throwOnCategories;
  final List<String> catalogCalls = [];

  @override
  Future<List<DramaSiteCategory>> categories() async => categoriesResult;

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    catalogCalls.add(categoryId);
    if (throwOnCatalog || throwOnCategories.contains(categoryId)) {
      throw Exception('test-no-catalog');
    }
    // 'all' = 本站首页（py / 核心 / JS 站转空串、jar 站走
    // homeVideoContent，桩里统一按首页回）。
    final items = (categoryId.isEmpty || categoryId == 'all')
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
    expect(client.catalogCalls, ['all']);
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
    expect(client.catalogCalls, ['c1', 'all']);
  });

  test('首页兜底回空时退分类表第一项（mjv011 情形）', () async {
    final client = _StubClient(
      categoriesResult: const [
        DramaSiteCategory('chinese_random/all', '中文字幕'),
        DramaSiteCategory('c2', '电影'),
      ],
      catalogByCategory: const {
        'chinese_random/all': [
          DramaSiteItem(id: 'r1', title: '推荐一', cover: ''),
          DramaSiteItem(id: 'r2', title: '推荐二', cover: ''),
        ],
      },
      homeItems: const [],
    );
    // 详情无分类无标签，首页兜底回空，退第一分类。
    final related = await loadSiteRelatedItems(
      client,
      _detailWith(),
      'self',
    );
    expect(related.map((e) => e.id).toList(), ['r1', 'r2']);
    expect(client.catalogCalls, ['all', 'chinese_random/all']);
  });

  test('首页抛错时仍退分类表第一项', () async {
    final client = _StubClient(
      categoriesResult: const [DramaSiteCategory('c1', '动漫')],
      catalogByCategory: const {
        'c1': [DramaSiteItem(id: 'a', title: '同类一', cover: '')],
      },
      throwOnCategories: const {'all'},
    );
    final related = await loadSiteRelatedItems(
      client,
      _detailWith(),
      'self',
    );
    expect(related.map((e) => e.id).toList(), ['a']);
    expect(client.catalogCalls, ['all', 'c1']);
  });

  test('分类表只有 all 伪分类时不重复拉首页', () async {
    final client = _StubClient(
      categoriesResult: const [DramaSiteCategory('all', '全部')],
      homeItems: const [],
    );
    final related = await loadSiteRelatedItems(
      client,
      _detailWith(),
      'self',
    );
    expect(related, isEmpty);
    expect(client.catalogCalls, ['all']);
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

  test('findSiteCategoryIdIn：精确匹配 name / displayName / 路径末段', () {
    const cats = [
      DramaSiteCategory('c1', '动漫'),
      DramaSiteCategory('m', '电影'),
      DramaSiteCategory('a', '动作', parentId: 'm', path: '电影/动作'),
    ];
    expect(findSiteCategoryIdIn(cats, '动漫'), 'c1');
    // 多级分类的展示名是完整路径，精确匹配路径也认。
    expect(findSiteCategoryIdIn(cats, '电影/动作'), 'a');
    // 标签只有末段（详情页标签点按就是这个情形）也认。
    expect(findSiteCategoryIdIn(cats, '动作'), 'a');
    expect(findSiteCategoryIdIn(cats, '不存在'), isNull);
    expect(findSiteCategoryIdIn(cats, '  '), isNull);
  });

  test('findSiteCategoryIdForName：取一次分类表再匹配', () async {
    final client = _StubClient(
      categoriesResult: const [
        DramaSiteCategory('c1', '动漫'),
        DramaSiteCategory('c2', '电影'),
      ],
    );
    expect(await findSiteCategoryIdForName(client, '电影'), 'c2');
    expect(await findSiteCategoryIdForName(client, '剧集'), isNull);
  });
}
