import 'dart:async';

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

/// 单次库操作（打开 / 取页）的超时上限：诊断口径 ≤10 秒。
/// 超时只让这一次调用落报错，底层加载还在继续，下次重试能接上。
const whosLibQueryTimeout = Duration(seconds: 10);

void _logStep(String step, Stopwatch watch) {
  debugPrint('[直播耗时] 源=内置片库 步骤=$step 耗时=${watch.elapsedMilliseconds}ms');
}

Future<WhosLocalLibrary> _whosLib() async {
  final override = whosLibTestLibrary;
  if (override != null) return override;
  final library = WhosLocalLibrary.shared;
  final watch = Stopwatch()..start();
  final loaded = await library.ensureLoaded().timeout(
    whosLibQueryTimeout,
    onTimeout: () => throw TimeoutException(
      '内置片库打开超时：读女优库数据库（MYTV/db/女优库.db）'
      '超过 10 秒没有返回，请稍后重试',
    ),
  );
  _logStep('打开片库', watch);
  if (!loaded) {
    // 透出真实原因（魔蚁 5523531 同款）：以前这里吞掉底层原因、
    // 只报一句“退出直播重进一次看看”，用户根本不知道是库没放好
    // 还是结构对不上。修仙版是 .db 口径，原因文案走 loadFailureNote。
    final note = library.loadFailureNote;
    throw StateError(
      note == null || note.isEmpty
          ? '内置片库没读出来：本地女优库数据库（MYTV/db/女优库.db）读不到'
          : note,
    );
  }
  return library;
}

/// 直播首屏分类：只出固定分类（最新 / 排行榜），不算厂牌聚合。
/// 厂牌聚合是对 44.9 万行 videos 表的表达式 GROUP BY，以前排在
/// 首屏链第一步，冷库上秒级到数十秒、还零超时，页面就永久停在
/// 「载入中…」。现在首屏先用这两类 + 第一页频道出列表，厂牌由
/// [fetchWhosLibBrandPlatforms] 在首屏之后异步补进分组栏。
Future<List<LivePlatform>> fetchWhosLibPlatforms() async {
  final library = await _whosLib();
  final total = library.count;
  return [
    LivePlatform(id: whosLocalNewCategory, name: '最新作品 · $total'),
    LivePlatform(id: whosLocalRankCategory, name: '排行榜 · $total'),
  ];
}

/// 首屏之后异步补的厂牌分类：单独超时、单独失败，不挡首屏；
/// 补不上就只有最新 / 排行榜两类，用户点品牌筛选时也会走到它。
Future<List<LivePlatform>> fetchWhosLibBrandPlatforms() async {
  final library = await _whosLib();
  final watch = Stopwatch()..start();
  try {
    final rows = await library
        .brandCategoriesAsync(brandLimit: 30)
        .timeout(whosLibQueryTimeout);
    _logStep('厂牌聚合(异步补)', watch);
    return [
      for (final row in rows)
        LivePlatform(id: row.id, name: '${row.name} · ${row.count}'),
    ];
  } catch (error) {
    debugPrint('[直播耗时] 源=内置片库 步骤=厂牌聚合(异步补) 失败：$error');
    return const [];
  }
}

/// 取一页频道（异步版，直播页用这个）：数据库模式按页查库，
/// JSON 模式走内存。page 从 1 开始。单次查询 ≤10 秒超时。
Future<List<LiveChannel>> fetchWhosLibChannels(
  LivePlatform platform, {
  int page = 1,
}) async {
  final library = await _whosLib();
  final watch = Stopwatch()..start();
  final channels = await whosLibChannelsAsync(
    library,
    category: platform.id,
    page: page,
    source: whosLibSourceId,
  ).timeout(
    whosLibQueryTimeout,
    onTimeout: () => throw TimeoutException(
      '内置片库取频道超时：查库超过 10 秒没有返回，请稍后重试',
    ),
  );
  _logStep('取频道(${platform.id} 第 $page 页)', watch);
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
