import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'source_registry.dart';

/// 站点透视取数函数：按站 id 拉一次首页、随机挑一张封面地址；
/// 拉不到 / 超时 / 无封面 / 抛错一律回 null，不编假地址。
typedef SiteThumbFetcher = Future<String?> Function(String siteId);

/// 默认取数：走既有首页目录链路（蜘蛛 homeVideoContent / catalog
/// 'all'），15 秒超时；从有封面的条目里等概率随机取一张。随机只
/// 发生在首次取数，取到的地址进缓存后固定，不会每次打开换一张。
Future<String?> fetchSiteHomeCover(String siteId) async {
  if (siteId.isEmpty || siteId.startsWith('__')) return null;
  try {
    final client = await SourceRegistry.instance.clientFor(siteId);
    if (client == null) return null;
    final page = await client
        .catalog('all', 1)
        .timeout(const Duration(seconds: 15));
    final covers = [
      for (final item in page.items)
        if (item.cover.trim().isNotEmpty) item.cover.trim(),
    ];
    if (covers.isEmpty) return null;
    covers.shuffle(math.Random());
    return covers.first;
  } catch (_) {
    return null;
  }
}

/// 站点透视封面地址缓存（魔蚁同步批 C1，设计学魔蚁 SiteThumbCache，
/// 按修仙版结构重写）：只存「站 id → 封面 URL」映射，不存图片本体
/// （图片走 CachedNetworkImage 自己的磁盘缓存）。
///
/// - 内存 Map + 落盘应用支持目录 site_thumbs.json，写串行化；
/// - 只记成功：取数回 null / 抛错不写缓存，下次打开重拉，死站
///   恢复后自然有图；
/// - 在途去重：同站并发共享同一个 Future；并发上限 4；
/// - 无过期、无容量上限（与魔蚁原版同一取舍）；磁盘 JSON 损坏
///   当空缓存，不抛错。
class SiteThumbCache {
  SiteThumbCache({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  static final SiteThumbCache instance = SiteThumbCache();

  static const maxConcurrent = 4;
  static const _fileName = 'site_thumbs.json';

  final Future<Directory> Function() _directoryProvider;
  final Map<String, String> _map = {};
  final Map<String, Future<String?>> _pending = {};
  final List<Completer<void>> _waiters = [];
  int _inFlight = 0;
  bool _loaded = false;
  bool _loading = false;
  Future<void> _writes = Future<void>.value();

  /// 同步快读：只查内存、不触发加载。弹窗首帧画卡用它决定先画图
  /// 还是先占位。
  String? cachedUrl(String siteId) => _map[siteId];

  Future<void> _ensureLoaded() async {
    if (_loaded || _loading) return;
    _loading = true;
    try {
      final directory = await _directoryProvider();
      final file = File('${directory.path}/$_fileName');
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            if (entry.key is String && entry.value is String) {
              _map[entry.key as String] = entry.value as String;
            }
          }
        }
      }
    } catch (_) {
      // 损坏 / 读不到当空缓存。
      _map.clear();
    }
    _loaded = true;
    _loading = false;
  }

  /// 直接写一条（测试 / 预置用）：内存 + 排队落盘。
  Future<void> put(String siteId, String url) async {
    await _ensureLoaded();
    _map[siteId] = url;
    _queueWrite();
  }

  /// 取某站的封面地址：缓存命中直接回；未命中走 [fetcher] 拉一次
  /// （同站并发去重、全站并发限流），成功才记缓存。
  Future<String?> thumbUrlFor(String siteId, SiteThumbFetcher fetcher) async {
    await _ensureLoaded();
    final cached = _map[siteId];
    if (cached != null) return cached;
    final pending = _pending[siteId];
    if (pending != null) return pending;
    final future = _fetchAndCache(siteId, fetcher);
    _pending[siteId] = future;
    try {
      return await future;
    } finally {
      _pending.remove(siteId);
    }
  }

  Future<String?> _fetchAndCache(String siteId, SiteThumbFetcher fetcher) async {
    await _acquire();
    try {
      String? url;
      try {
        url = await fetcher(siteId);
      } catch (_) {
        url = null;
      }
      if (url == null || url.isEmpty) return null;
      _map[siteId] = url;
      _queueWrite();
      return url;
    } finally {
      _release();
    }
  }

  Future<void> _acquire() async {
    if (_inFlight < maxConcurrent) {
      _inFlight++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
    _inFlight++;
  }

  void _release() {
    _inFlight--;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    }
  }

  void _queueWrite() {
    _writes = _writes.then((_) async {
      try {
        final directory = await _directoryProvider();
        final file = File('${directory.path}/$_fileName');
        await file.writeAsString(jsonEncode(_map), flush: true);
      } catch (_) {
        // 写失败只丢本次，内存照常可用。
      }
    });
  }

  /// 等待已排队的落盘完成（测试用）。
  Future<void> settleWrites() => _writes;

  @visibleForTesting
  void resetForTest() {
    _map.clear();
    _pending.clear();
    _waiters.clear();
    _inFlight = 0;
    _loaded = false;
    _loading = false;
    _writes = Future<void>.value();
  }
}
