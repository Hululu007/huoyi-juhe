import 'package:flutter/foundation.dart';

import '../actress/whos_local_library.dart';
import 'live_platform.dart';
import 'live_sources.dart';

/// 内置片库在直播里的形态：库里一条作品 = 直播列表里的一个频道，
/// 地址就是已落库的 m3u8 直链，不用订阅、不用现抓。
///
/// 与魔蚁 whos_live_bridge.dart 同口径，字段按修仙版 LiveChannel /
/// LivePlatform 映射：修仙版频道没有 headers/logo/key 字段，直链就是
/// https m3u8，走直播页现有的直连播放链路（NativePlayer.create 直给
/// 地址，与 m3u 列表源同一条路）。
///
/// 源 id 与地址前缀的常量定义在 live_sources.dart（源表要先用 id，
/// 放这里会与 live_sources 循环引用），本文件直接引用。
const whosLibPageSize = 120;

/// 频道名：番号在前、标题在后，太长截断（直播列表一行放不下）。
String whosLibChannelName(WhosLocalWork work) {
  final code = work.code.trim();
  final title = work.displayTitle.trim();
  final head = code.isEmpty ? title : (title.isEmpty ? code : '$code $title');
  if (head.length <= 64) return head;
  return '${head.substring(0, 63)}…';
}

/// 测试注入：指定桥层用的库（内存库），不走 WhosLocalLibrary.shared
/// 的读盘/读库。生产路径始终为 null。
@visibleForTesting
WhosLocalLibrary? whosLibTestLibrary;

Future<WhosLocalLibrary> _whosLib() async {
  final override = whosLibTestLibrary;
  if (override != null) return override;
  final library = WhosLocalLibrary.shared;
  if (!await library.ensureLoaded()) {
    throw StateError('内置片库没读出来，退出直播重进一次看看');
  }
  return library;
}

/// 直播里的分类：最新 / 排行榜 + 条目最多的厂牌。
Future<List<LivePlatform>> fetchWhosLibPlatforms() async {
  final library = await _whosLib();
  final platforms = await whosLibPlatformsAsync(library);
  if (platforms.isEmpty) throw StateError('内置片库暂时没有分类');
  return platforms;
}

/// 取一页频道（异步版，直播页用这个）：数据库模式按页查库，
/// JSON 模式走内存。page 从 1 开始。
Future<List<LiveChannel>> fetchWhosLibChannels(
  LivePlatform platform, {
  int page = 1,
}) async {
  final library = await _whosLib();
  final channels = await whosLibChannelsAsync(
    library,
    category: platform.id,
    page: page,
    source: whosLibSourceId,
  );
  if (channels.isEmpty) throw StateError('这个分类暂时没有频道');
  return channels;
}

/// 取一页频道。category 支持库里的分类 id：`new` / `rank` / `brand:<前缀>`。
List<LiveChannel> whosLibChannels(
  WhosLocalLibrary library, {
  required String category,
  int page = 1,
  String source = whosLibSourceId,
}) {
  final rows = library.page(
    category: category,
    page: page,
    pageSize: whosLibPageSize,
  );
  return [
    for (final work in rows)
      if (work.playUrl.startsWith('http'))
        _whosLibChannel(work, source),
  ];
}

/// 取一页频道（异步版）：数据库模式按页查库，JSON 模式走内存。
Future<List<LiveChannel>> whosLibChannelsAsync(
  WhosLocalLibrary library, {
  required String category,
  int page = 1,
  String source = whosLibSourceId,
}) async {
  final rows = await library.pageAsync(
    category: category,
    page: page,
    pageSize: whosLibPageSize,
  );
  return [
    for (final work in rows)
      if (work.playUrl.startsWith('http'))
        _whosLibChannel(work, source),
  ];
}

LiveChannel _whosLibChannel(WhosLocalWork work, String source) {
  return LiveChannel(
    title: whosLibChannelName(work),
    url: work.playUrl,
    group: work.brand.isEmpty ? '其它' : whosBrandLabel(work.brand),
    sourceId: source,
    cover: work.cover,
    number: work.code,
  );
}

/// 直播里的分类：最新 / 排行榜 + 条目最多的厂牌。
List<LivePlatform> whosLibPlatforms(
  WhosLocalLibrary library, {
  int brandLimit = 30,
}) => [
  for (final row in library.categories(brandLimit: brandLimit))
    LivePlatform(id: row.id, name: '${row.name} · ${row.count}'),
];

/// 直播里的分类（异步版）：数据库模式走库里聚合。
Future<List<LivePlatform>> whosLibPlatformsAsync(
  WhosLocalLibrary library, {
  int brandLimit = 30,
}) async => [
  for (final row in await library.categoriesAsync(brandLimit: brandLimit))
    LivePlatform(id: row.id, name: '${row.name} · ${row.count}'),
];
