import 'actress_adapter_models.dart';
import 'whos_local_library.dart';

/// whos 站源 id（内置 py 源）。
const whosSourceId = 'whos';

/// nvku 站源 id（内置 py 源，2026-11-21 用户令内置进站点列表）。
/// 与 whos 同一套编码：封面/播放都是 hash 直拼 hersav，取不到在线时
/// 一样降级到本地库。
const nvkuSourceId = 'nvku';

/// whos 系站源：在线内容同一套编码、同一套本地兜底。
const whosLikeSourceIds = <String>{whosSourceId, nvkuSourceId};

bool isWhosLikeSource(String id) => whosLikeSourceIds.contains(id);

/// 本地兜底条目的 id 前缀：目录、详情、播放全靠它认出「这条不是在线来的」，
/// 直接走本地直链，不再往 py 侧要地址。
const whosLocalIdPrefix = 'whoslocal:';

bool isWhosLocalDrama(Drama drama) =>
    isWhosLikeSource(drama.source) &&
    (drama.sourceId.startsWith(whosLocalIdPrefix) ||
        drama.id.startsWith(whosLocalIdPrefix));

String whosLocalId(String workId) => '$whosLocalIdPrefix$workId';

String whosLocalWorkIdOf(Drama drama) {
  for (final raw in [drama.sourceId, drama.id]) {
    if (raw.startsWith(whosLocalIdPrefix)) {
      return raw.substring(whosLocalIdPrefix.length);
    }
  }
  return '';
}

/// 本地作品 → 列表卡。番号放 tags，卡片上照常能看见。
Drama whosLocalToDrama(WhosLocalWork work, {String source = whosSourceId}) {
  final code = work.code.trim();
  return Drama(
    id: whosLocalId(work.id),
    source: source,
    sourceId: whosLocalId(work.id),
    title: work.displayTitle,
    cover: work.cover,
    description: '',
    category: work.brand.isEmpty ? '' : whosBrandLabel(work.brand),
    onlineDate: work.year,
    tags: [if (code.isNotEmpty) code, if (work.area.isNotEmpty) work.area],
  );
}

/// 本地作品 → 详情：一条直链集，播放走本地地址，不经过 py。
DramaDetail whosLocalDetail(Drama drama, WhosLocalWork work) {
  final url = work.playUrl;
  return DramaDetail(drama, [
    if (url.isNotEmpty)
      Episode({
        'id': url,
        'title': '正片',
        'flag': 'whos',
        'playId': url,
        'currentEpisode': 1,
      }, 1),
  ]);
}

/// 本地分页结果。hasMore 按剩余条数算，翻到最后一页停住。
CatalogPage whosLocalPage({
  required WhosLocalLibrary library,
  required String category,
  required String query,
  required int page,
  int pageSize = 24,
  String source = whosSourceId,
}) {
  final total = library.countFor(category: category, query: query);
  final items = library
      .page(category: category, query: query, page: page, pageSize: pageSize)
      .map((work) => whosLocalToDrama(work, source: source))
      .toList(growable: false);
  return CatalogPage(
    items,
    hasMore: page * pageSize < total,
    page: page,
    warning: items.isEmpty ? '本地库里没有匹配的作品' : '',
  );
}

/// 本地分类清单：最新 / 排行榜 / 厂牌，计数拼在名字后面方便看。
List<CatalogCategory> whosLocalCategories(WhosLocalLibrary library) => [
  for (final row in library.categories())
    CatalogCategory(row.id, '${row.name} · ${row.count}'),
];

/// 本地分页结果（异步版，2026-11-23）：数据库模式按页查库。
Future<CatalogPage> whosLocalPageAsync({
  required WhosLocalLibrary library,
  required String category,
  required String query,
  required int page,
  int pageSize = 24,
  String source = whosSourceId,
}) async {
  final total = await library.countForAsync(
    category: category,
    query: query,
  );
  final items = (await library.pageAsync(
    category: category,
    query: query,
    page: page,
    pageSize: pageSize,
  ))
      .map((work) => whosLocalToDrama(work, source: source))
      .toList(growable: false);
  return CatalogPage(
    items,
    hasMore: page * pageSize < total,
    page: page,
    warning: items.isEmpty ? '本地库里没有匹配的作品' : '',
  );
}

/// 本地分类清单（异步版，2026-11-23）：数据库模式走库里聚合。
Future<List<CatalogCategory>> whosLocalCategoriesAsync(
  WhosLocalLibrary library,
) async => [
  for (final row in await library.categoriesAsync())
    CatalogCategory(row.id, '${row.name} · ${row.count}'),
];
