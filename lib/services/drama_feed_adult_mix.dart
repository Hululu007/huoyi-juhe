import 'dart:async';
import 'dart:math';

import '../models/media_item.dart';
import '../pages/video_page.dart';
import 'api_client.dart';
import 'cultivation.dart';
import 'drama_site_content.dart';
import 'source_registry.dart';

/// 短剧首页「推荐」feed 里混入的成人站点推荐。
///
/// 混入只发生在推荐 feed（`kChannelVideoFeed`）的轮播里，不是新开页签：
/// 每次打开短剧页 / 下拉刷新时随机重挑，已解锁的成人站才进池子，取不到
/// 时回落纯短剧。只读现有境界门禁状态（[visibleFilmZoneSites] 与
/// [adultTierForSiteId]），绝不改门禁逻辑本身；境界不够的站完全不可见。
///
/// 取数口径与推荐页「影视」区（`HomeFilmZone._fetchOne`）一致：每站先取
/// 真实首分类再取第 1 页，单站超时跳过、不卡住整条 feed。

/// 一次混入取数的站数：与「影视」区同窗 3 站。
const int adultMixSiteCount = 3;

/// 每站最多留的条目数：3 站 × 2 条 = 一轮最多 6 条混入。
const int adultMixItemsPerSite = 2;

/// 混入步长：每 4 条短剧后插 1 条成人推荐。
const int adultMixStride = 4;

/// widget 层超时余量：与 `HomeFilmZone` 同口径（ApiClient 预算 + 5 秒兜底，
/// 防非核心客户端没有自己的超时一直挂起，不盖帽 ApiClient 的预算）。
const Duration _clientTimeoutMargin = Duration(seconds: 5);

/// 一条混入条目：feed 里的卡片 + 点开详情要的原站条目。
class AdultMixEntry {
  const AdultMixEntry({
    required this.item,
    required this.siteId,
    required this.siteItem,
  });

  /// feed 卡片用的条目（`kind: 'film'`，下标「影视」；`ep` 置空，药丸
  /// 恒显示「观看全片」，不谎报集数；`categories` 只放站名作来源 chip）。
  final MediaItem item;

  /// 原站 id（`openDramaSiteItem` 用它取客户端、扣元宝、进详情页）。
  final String siteId;

  /// 原站条目原样（详情页的初始标题/封面/备注都从它来，不重建）。
  final DramaSiteItem siteItem;
}

/// 混入池：只留已解锁的成人视频站。
///
/// [sites] 是 `visibleFilmZoneSites(xp)` 的结果（门禁已在该函数里按修为
/// 读过）；这里只做成人/视频筛选——在分档表里（`adultTierForSiteId` 非空）
/// 的才是成人站，不在表里的视频站不进混入池。
List<({String id, String name})> adultMixPool(
  List<({String id, String name, String kind})> sites,
) => [
  for (final site in sites)
    if (site.kind == 'video' &&
        adultTierForSiteId(site.id, adultVideoSiteOrder) != null)
      (id: site.id, name: site.name),
];

/// 把混入条目插进短剧列表：每 [stride] 条短剧后插 1 条。
///
/// 纯函数：给定同一份短剧列表与混入列表，结果固定——`loadMore` 续上新
/// 短剧时，前缀位置不变，已上屏的卡不跳位。短剧不够长时剩余混入条目不
/// 硬塞尾部（等列表续长后重算自然出现）；短剧列表为空时原样回空，混入
/// 条目不单独撑起一条 feed（空态/错态仍由短剧流自己说了算）。
List<MediaItem> interleaveAdultMix(
  List<MediaItem> dramas,
  List<MediaItem> mixed, {
  int stride = adultMixStride,
}) {
  if (mixed.isEmpty || dramas.isEmpty) return dramas;
  final out = <MediaItem>[];
  var mixIndex = 0;
  for (var i = 0; i < dramas.length; i++) {
    out.add(dramas[i]);
    if ((i + 1) % stride == 0 && mixIndex < mixed.length) {
      out.add(mixed[mixIndex++]);
    }
  }
  return out;
}

/// 取一轮混入：从已解锁成人站里随机挑 [adultMixSiteCount] 个站，各取首
/// 分类第 1 页的前 [adultMixItemsPerSite] 条。
///
/// 池子空 / 全站失败 / 全回空时都回空列表，调用方回落纯短剧，不转圈、
/// 不报错。本函数永不抛错：站表读取失败也按空池处理（调用方是 unawaited
/// 的首帧取数，抛错只会变成未处理异步错误）。`sites` 与 `clientForSite`
/// 是测试注入缝（为空时按当前修为从核心登记表现取站表、按站 id 现取
/// 客户端）；`random` 为空时用默认随机源。
Future<List<AdultMixEntry>> fetchAdultMix({
  required int xp,
  List<({String id, String name, String kind})>? sites,
  Future<DramaSiteContentClient?> Function(String siteId)? clientForSite,
  Random? random,
}) async {
  try {
    final pool = adultMixPool(sites ?? visibleFilmZoneSites(xp));
    if (pool.isEmpty) return const [];
    final shuffled = pool.toList()..shuffle(random ?? Random());
    final results = await Future.wait([
      for (final site in shuffled.take(adultMixSiteCount))
        _fetchOneSite(site, clientForSite),
    ]);
    return [for (final result in results) ...result];
  } catch (_) {
    return const [];
  }
}

Future<List<AdultMixEntry>> _fetchOneSite(
  ({String id, String name}) site,
  Future<DramaSiteContentClient?> Function(String siteId)? clientForSite,
) async {
  try {
    final client = clientForSite != null
        ? await clientForSite(site.id)
        : dramaSiteContentClient(site.id) ??
              await SourceRegistry.instance.clientFor(site.id);
    if (client == null) return const [];
    // 先取真实首分类再取列表：核心站登记里只有「全部」兜底，
    // `catalog('all')` 对多数核心站是空的（mjv011 的 all 地址只回跳转页、
    // avyan 回「系统提示」页）。分类取不到就回落 'all'；超时按 ApiClient
    // 的分类预算 + 余量，不盖帽。
    var categoryId = 'all';
    try {
      final categories = await client.categories().timeout(
        ApiClient.dramaCategoriesTimeout + _clientTimeoutMargin,
      );
      final usable = categories
          .where((c) => c.id.isNotEmpty && c.id != 'all')
          .toList();
      if (usable.isNotEmpty) {
        categoryId = usable.first.id;
      } else if (categories.isNotEmpty) {
        categoryId = categories.first.id;
      }
    } catch (_) {}
    final page = await client
        .catalog(categoryId, 1)
        .timeout(ApiClient.dramaCatalogTimeout + _clientTimeoutMargin);
    return [
      for (final item in page.items.take(adultMixItemsPerSite))
        AdultMixEntry(
          item: MediaItem(
            id: 'adultmix:${site.id}:${item.id}',
            title: item.title,
            cover: item.cover,
            author: '',
            badge: '',
            ep: '',
            kind: 'film',
            categories: [site.name],
          ),
          siteId: site.id,
          siteItem: item,
        ),
    ];
  } catch (_) {
    return const [];
  }
}
