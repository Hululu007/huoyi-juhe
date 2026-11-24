import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

/// 单次图片请求的超时：30 秒。
///
/// cached_network_image 4.0.3 / flutter_cache_manager 3.5.0 没有任何超时
/// 参数，Config 也没有超时项；这里不改库，只用库公开的 Config.fileService
/// 扩展点包一层：get() 30 秒内没回响应头就抛 TimeoutException，缓存库按
/// 失败处理（不进缓存），StoryCover 收到失败后按退避重试。
/// 注意：这只卡“拿到响应头”的时间，正文流中途卡住不在此限，仍靠系统 TCP 超时。
class TimeoutFileService extends HttpFileService {
  static const requestTimeout = Duration(seconds: 30);

  TimeoutFileService({super.httpClient});

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) => super.get(url, headers: headers).timeout(requestTimeout);
}

/// The app's single image cache.
///
/// Covers, posters, avatars and comic pages all share one budgeted store
/// instead of `DefaultCacheManager`'s defaults (200 objects / 30 days):
/// 2000 entries, 30 days, and a 256 MiB byte budget that a maintenance sweep
/// enforces by deleting the least recently modified files. A swept file leaves
/// its database entry behind; the manager notices the missing file on the next
/// read and re-downloads, so the sweep needs no database surgery.
class PosterCache extends CacheManager with ImageCacheManager {
  /// Where [Config]'s default `IOFileSystem` puts the files. Must mirror the
  /// cache key below: the sweep walks this directory directly.
  static const cacheKey = 'fqapp_images_v1';

  /// How long an unused image stays cached.
  static const stalePeriod = Duration(days: 30);

  /// Entry budget, mirroring the reference implementation's 2000 posters.
  static const maxEntries = 2000;

  /// Byte budget for the whole store.
  static const maxBytes = 256 << 20;

  static final PosterCache instance = PosterCache._();

  PosterCache._()
    : super(
        Config(
          cacheKey,
          stalePeriod: stalePeriod,
          maxNrOfCacheObjects: maxEntries,
          fileService: TimeoutFileService(),
        ),
      );

  /// Deletes the oldest files under the cache directory until it fits
  /// [limit]. Returns the number of files removed. Best-effort: an
  /// unremovable file stops the sweep.
  ///
  /// Call this once per launch; the store grows between launches.
  Future<int> enforceBudget({int limit = maxBytes}) async {
    if (kIsWeb) return 0;
    io.Directory root;
    try {
      final temporary = await getTemporaryDirectory();
      root = _join(temporary, cacheKey);
    } catch (_) {
      return 0;
    }
    return enforceImageCacheBudget(root: root, limit: limit);
  }
}

/// The sweep proper, split from [PosterCache.enforceBudget] so tests can run
/// it against a scratch directory without touching `path_provider`.
Future<int> enforceImageCacheBudget({
  required io.Directory root,
  required int limit,
}) async {
  if (!await root.exists()) return 0;
  final entries = <({io.File file, int size, DateTime modified})>[];
  var total = 0;
  await for (final entity in root.list()) {
    if (entity is! io.File) continue;
    try {
      final stat = await entity.stat();
      if (stat.type != io.FileSystemEntityType.file) continue;
      total += stat.size;
      entries.add((file: entity, size: stat.size, modified: stat.modified));
    } catch (_) {
      // A file that vanishes mid-sweep neither counts nor blocks.
    }
  }
  if (total <= limit) return 0;

  entries.sort((a, b) => a.modified.compareTo(b.modified));
  var removed = 0;
  for (final entry in entries) {
    if (total <= limit) break;
    try {
      await entry.file.delete();
      total -= entry.size;
      removed++;
    } catch (_) {
      break;
    }
  }
  return removed;
}

io.Directory _join(io.Directory base, String key) {
  final separator = io.Platform.pathSeparator;
  final parent = base.path.endsWith(separator)
      ? base.path.substring(0, base.path.length - separator.length)
      : base.path;
  return io.Directory('$parent$separator$key');
}
