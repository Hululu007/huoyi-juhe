import 'dart:io';

import 'drama_site_content.dart';
import 'drama_sites.dart';
import 'm3u_export_db.dart';
import 'm3u_export_download.dart';
import 'midnight_gate.dart';
import 'one_click_py.dart';
import 'site_identity.dart';
import 'source_registry.dart';

const _callTimeout = Duration(seconds: 30);
const _maxPagesPerCategory = 20;

class M3uExportCancellation {
  var cancelled = false;

  void cancel() {
    cancelled = true;
  }
}

class M3uExportProgress {
  const M3uExportProgress({
    required this.categoryName,
    required this.categoriesDone,
    required this.categoriesTotal,
    required this.successCount,
    required this.skippedCount,
    this.downloadTitle = '',
    this.downloadDone = 0,
    this.downloadTotal = 0,
  });

  final String categoryName;
  final int categoriesDone;
  final int categoriesTotal;
  final int successCount;
  final int skippedCount;
  final String downloadTitle;
  final int downloadDone;
  final int downloadTotal;
}

class M3uExportResult {
  const M3uExportResult({
    required this.siteName,
    required this.downloadPath,
    required this.categoriesTotal,
    required this.emptyCategories,
    required this.truncatedCategories,
    required this.successCount,
    required this.skippedCount,
    required this.nonM3u8Count,
    required this.duplicateCount,
    required this.dbVideoCount,
    required this.dbError,
    required this.downloadedCount,
    required this.downloadFailedCount,
    required this.downloadBasePath,
    required this.cancelled,
  });

  final String siteName;
  final String? downloadPath;
  final int categoriesTotal;
  final List<String> emptyCategories;
  final List<String> truncatedCategories;
  final int successCount;
  final int skippedCount;
  final int nonM3u8Count;
  final int duplicateCount;
  final int dbVideoCount;
  final String? dbError;
  final int downloadedCount;
  final int downloadFailedCount;
  final String? downloadBasePath;
  final bool cancelled;
}

bool _hasControlChars(String value) {
  return RegExp(r'[\x00-\x1F\x7F]').hasMatch(value);
}

bool isExportableM3u8(String url) {
  final trimmed = url.trim();
  if (_hasControlChars(trimmed)) return false;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (uri.host.isEmpty) return false;
  return uri.path.toLowerCase().endsWith('.m3u8');
}

bool isHttpPlayableUrl(String url) {
  final trimmed = url.trim();
  if (_hasControlChars(trimmed)) return false;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  return uri.host.isNotEmpty;
}

String m3uFileNameForSite(String siteName) {
  var base = siteName
      .replaceAll(RegExp(r'[\/\\:*?"<>|\x00-\x1F]'), '_')
      .trim()
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (base.isEmpty) base = 'site';
  return '$base.m3u';
}

String _cleanTitle(String title) {
  return title.replaceAll(RegExp(r'[\r\n]'), ' ').trim();
}

List<SourceEntry> filterM3uExportSites(
  List<SourceEntry> entries,
  bool gateOpen, {
  bool includeJar = true,
}) {
  bool jarReady(SourceEntry entry) {
    return (entry.extra['className'] as String? ?? '').isNotEmpty &&
        (entry.extra['configId'] as String? ?? '').isNotEmpty &&
        (entry.extra['jarUrl'] as String? ?? '').isNotEmpty;
  }

  bool isVideoEntry(SourceEntry entry) {
    return entry.contentType == ContentType.video ||
        entry.contentType == ContentType.mixed;
  }

  bool hasLocalCopy(SourceEntry entry) {
    return (entry.extra['path'] as String? ?? '').isNotEmpty;
  }

  return [
    for (final entry in entries)
      if (entry.enabled &&
          isVideoEntry(entry) &&
          (gateOpen || !MidnightGate.isAdultName(entry.name)) &&
          ((entry.kind == SourceKind.pyImport && hasLocalCopy(entry)) ||
              (includeJar &&
                  entry.kind == SourceKind.jarImport &&
                  jarReady(entry)) ||
              (entry.kind == SourceKind.customMaccms &&
                  entry.address.isNotEmpty) ||
              (entry.kind == SourceKind.jsImport && hasLocalCopy(entry)) ||
              (entry.kind == SourceKind.xbpqImport && hasLocalCopy(entry)) ||
              (entry.kind == SourceKind.legadoImport && hasLocalCopy(entry))))
        entry,
  ];
}

/// 内置影视站的导出目标：全部内置短剧站都可导出进本地库，
/// 只有番茄短剧除外——它走原生番茄接口，没有蜘蛛客户端，
/// 导出链（分类、列表、详情、取流）接不上。
class M3uExportBuiltinTarget {
  const M3uExportBuiltinTarget({
    required this.siteId,
    required this.label,
    required this.allowNonM3u8,
  });

  final String siteId;
  final String label;

  /// 红果走网页线 + 360p 兜底，会出非 m3u8 直链，故放行。
  final bool allowNonM3u8;
}

List<M3uExportBuiltinTarget> m3uExportBuiltinTargets(
  List<DramaSite> sites,
  bool Function(String siteId) isEnabled,
  bool gateOpen,
) {
  return [
    for (final site in sites)
      if (site.id != 'original' &&
          isEnabled(site.id) &&
          (gateOpen || !MidnightGate.isAdultName(site.name)))
        M3uExportBuiltinTarget(
          siteId: site.id,
          label: site.name,
          allowNonM3u8: site.id == 'hongguo',
        ),
  ];
}

class _ResolvedVideo {
  const _ResolvedVideo({
    required this.url,
    required this.cover,
    required this.synopsis,
    required this.headers,
    this.extra = const {},
    this.episodeCount = 0,
  });

  final String url;
  final String cover;
  final String synopsis;
  final Map<String, String> headers;
  final Map<String, String> extra;
  final int episodeCount;
}

String _cleanSynopsis(String synopsis) {
  return synopsis
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

Future<_ResolvedVideo?> _resolveVideo(
  DramaSiteContentClient client,
  DramaSiteItem item,
  bool allowNonM3u8,
  bool fetchDetail,
) async {
  bool accepted(String url) {
    return isExportableM3u8(url) || (allowNonM3u8 && isHttpPlayableUrl(url));
  }

  Future<_ResolvedVideo?> tryPlay(
    DramaSiteEpisode episode, {
    required String fallbackCover,
    required String fallbackSynopsis,
    Map<String, String> fallbackExtra = const {},
    int fallbackEpisodeCount = 0,
  }) async {
    try {
      final play =
          await client.playSource(episode).timeout(_callTimeout);
      if (accepted(play.url)) {
        return _ResolvedVideo(
          url: play.url,
          cover: fallbackCover,
          synopsis: fallbackSynopsis,
          headers: play.headers,
          extra: fallbackExtra,
          episodeCount: fallbackEpisodeCount,
        );
      }
    } catch (_) {}
    return null;
  }

  DramaSiteDetail? fetchedDetail;
  Future<DramaSiteDetail?> fetchDetailOnce() async {
    if (fetchedDetail != null) return fetchedDetail;
    try {
      fetchedDetail = await client.detail(item.id).timeout(_callTimeout);
    } catch (_) {}
    return fetchedDetail;
  }

  Future<_ResolvedVideo?> tryEpisodes(DramaSiteDetail detail) async {
    final cover = detail.cover.isNotEmpty ? detail.cover : item.cover;
    final synopsis = _cleanSynopsis(detail.synopsis);
    for (final episode in detail.episodes) {
      final resolved = await tryPlay(
        episode,
        fallbackCover: cover,
        fallbackSynopsis: synopsis,
        fallbackExtra: detail.extra,
        fallbackEpisodeCount: detail.episodes.length,
      );
      if (resolved != null) return resolved;
    }
    return null;
  }

  final fastEpisode = DramaSiteEpisode(
    videoId: '\u0001${item.id}',
    title: item.title,
    seriesId: item.id,
  );
  if (fetchDetail) {
    final detail = await fetchDetailOnce();
    if (detail != null) {
      final viaEpisodes = await tryEpisodes(detail);
      if (viaEpisodes != null) return viaEpisodes;
      return tryPlay(
        fastEpisode,
        fallbackCover:
            detail.cover.isNotEmpty ? detail.cover : item.cover,
        fallbackSynopsis: _cleanSynopsis(detail.synopsis),
        fallbackExtra: detail.extra,
        fallbackEpisodeCount: detail.episodes.length,
      );
    }
    return tryPlay(
      fastEpisode,
      fallbackCover: item.cover,
      fallbackSynopsis: '',
    );
  }
  final fast = await tryPlay(
    fastEpisode,
    fallbackCover: item.cover,
    fallbackSynopsis: '',
  );
  if (fast != null) return fast;
  final detail = await fetchDetailOnce();
  if (detail != null) return tryEpisodes(detail);
  return null;
}

Future<M3uExportResult> exportSiteM3u({
  required String siteId,
  required String siteName,
  required DramaSiteContentClient client,
  OneClickDownloadSink? downloadSink,
  M3uExportDbSink? dbSink,
  M3uExportDownloadOptions? downloadOptions,
  required bool gateOpen,
  bool allowNonM3u8 = false,
  void Function(M3uExportProgress)? onProgress,
  M3uExportCancellation? cancellation,

  /// 登记条目的地址与它是不是内容站地址（见 site_identity 的
  /// 适用范围）：同站多入口导出时，db 记录按归一键写同一批，
  /// 不另存第二份。
  String siteAddress = '',
  bool addressIsSiteAddress = false,
}) async {
  if (!gateOpen && MidnightGate.isAdultName(siteName)) {
    throw StateError('午夜未开，成人站不导出');
  }
  final dbSiteId = canonicalSiteKey(
    siteId: siteId,
    address: siteAddress,
    addressIsSiteAddress: addressIsSiteAddress,
  );
  final fetchDetail = dbSink != null;
  final categories = await client.categories();
  final lines = <String>['#EXTM3U'];

  /// 去重边界：只认条目编号与站点身份，不认播放链接。
  /// 不同条目、不同分类、不同站点共用同一个播放链接时全部保留，
  /// 链接相同不等于同一条数据，绝不按链接合并；
  /// 同一条目编号重复列出才记重复（翻页重叠的卫生处理）。
  final seenItemIds = <String>{};
  final records = <M3uExportVideoRecord>[];
  var success = 0;
  var skipped = 0;
  var nonM3u8 = 0;
  var duplicates = 0;
  var downloaded = 0;
  var downloadFailed = 0;
  Directory? downloadBase;
  final emptyCategories = <String>[];
  final truncatedCategories = <String>[];
  var cancelled = false;
  for (var ci = 0; ci < categories.length; ci++) {
    if (cancellation?.cancelled == true) {
      cancelled = true;
      break;
    }
    final category = categories[ci];
    final seenPages = <String>{};
    var page = 1;
    var categorySuccess = 0;
    while (page <= _maxPagesPerCategory) {
      if (cancellation?.cancelled == true) {
        cancelled = true;
        break;
      }
      DramaSiteCatalogPage catalogPage;
      try {
        catalogPage =
            await client.catalog(category.id, page).timeout(_callTimeout);
      } catch (_) {
        break;
      }
      final items = catalogPage.items;
      if (items.isEmpty) break;
      final signature = items.map((item) => item.id).join('\u0000');
      if (!seenPages.add(signature)) break;
      for (final item in items) {
        if (cancellation?.cancelled == true) {
          cancelled = true;
          break;
        }
        if (!seenItemIds.add(item.id)) {
          duplicates++;
          continue;
        }
        final resolved = await _resolveVideo(
          client,
          item,
          allowNonM3u8,
          fetchDetail,
        );
        if (resolved == null) {
          skipped++;
        } else {
          var finalUrl = resolved.url;
          var downloadedThis = false;
          if (downloadOptions != null &&
              downloadOptions.appliesTo(category.id, item.id)) {
            try {
              downloadBase ??= Directory(
                '${(await downloadOptions.directoryResolver()).path}'
                '/m3u_export_downloads/${sanitizeDownloadStem(siteName)}',
              );
              final targetDir = Directory(
                '${downloadBase.path}/${sanitizeDownloadStem(item.id)}',
              );
              finalUrl = await downloadOptions.downloader.downloadVideo(
                url: resolved.url,
                headers: resolved.headers,
                targetDir: targetDir,
                onProgress: (done, total) {
                  onProgress?.call(
                    M3uExportProgress(
                      categoryName: category.name,
                      categoriesDone: ci,
                      categoriesTotal: categories.length,
                      successCount: success,
                      skippedCount: skipped,
                      downloadTitle: item.title,
                      downloadDone: done,
                      downloadTotal: total,
                    ),
                  );
                },
                isCancelled: () => cancellation?.cancelled == true,
              );
              downloaded++;
              downloadedThis = true;
            } on M3uExportDownloadCancelled {
              cancelled = true;
              break;
            } catch (_) {
              downloadFailed++;
            }
          }
          if (cancelled) break;
          lines.add('#EXTINF:-1,${_cleanTitle(item.title)}');
          if (downloadedThis) {
            lines.add('#ONLINE-URL:${resolved.url}');
          }
          lines.add(finalUrl);
          success++;
          categorySuccess++;
          if (!isExportableM3u8(resolved.url)) nonM3u8++;
          if (dbSink != null) {
            records.add(
              M3uExportVideoRecord(
                siteId: dbSiteId,
                siteName: siteName,
                categoryId: category.id,
                categoryName: category.name,
                categoryPath: category.path.isNotEmpty
                    ? category.path
                    : category.name,
                videoId: item.id,
                title: item.title,
                url: resolved.url,
                localPath: downloadedThis ? finalUrl : '',
                cover: resolved.cover,
                synopsis: resolved.synopsis,
                extra: resolved.extra,
                episodeCount: resolved.episodeCount,
                updatedAt: DateTime.now().millisecondsSinceEpoch,
              ),
            );
          }
        }
        onProgress?.call(
          M3uExportProgress(
            categoryName: category.name,
            categoriesDone: ci,
            categoriesTotal: categories.length,
            successCount: success,
            skippedCount: skipped,
          ),
        );
      }
      if (cancelled) break;
      page++;
    }
    if (page > _maxPagesPerCategory) {
      truncatedCategories.add(category.name);
    }
    if (categorySuccess == 0 && !cancelled) {
      emptyCategories.add(category.name);
    }
    onProgress?.call(
      M3uExportProgress(
        categoryName: category.name,
        categoriesDone: ci + 1,
        categoriesTotal: categories.length,
        successCount: success,
        skippedCount: skipped,
      ),
    );
  }
  String? downloadPath;
  var dbVideoCount = 0;
  String? dbError;
  if (!cancelled) {
    downloadPath = await (downloadSink ?? const PlatformOneClickDownloadSink())
        .saveText(
      fileName: m3uFileNameForSite(siteName),
      text: '${lines.join('\n')}\n',
    );
    if (dbSink != null) {
      try {
        final now = DateTime.now().millisecondsSinceEpoch;
        await dbSink.saveExport(
          siteId: dbSiteId,
          siteName: siteName,
          categories: [
            for (final category in categories)
              M3uExportCategoryInfo(
                siteId: dbSiteId,
                siteName: siteName,
                categoryId: category.id,
                categoryName: category.name,
                categoryPath: category.path.isNotEmpty
                    ? category.path
                    : category.name,
                parentId: category.parentId,
                extra: category.extra,
                updatedAt: now,
              ),
          ],
          videos: records,
        );
        dbVideoCount = records.length;
      } catch (error) {
        dbError = error.toString();
      }
    }
  }
  return M3uExportResult(
    siteName: siteName,
    downloadPath: downloadPath,
    categoriesTotal: categories.length,
    emptyCategories: emptyCategories,
    truncatedCategories: truncatedCategories,
    successCount: success,
    skippedCount: skipped,
    nonM3u8Count: nonM3u8,
    duplicateCount: duplicates,
    dbVideoCount: dbVideoCount,
    dbError: dbError,
    downloadedCount: downloaded,
    downloadFailedCount: downloadFailed,
    downloadBasePath: downloadBase?.path,
    cancelled: cancelled,
  );
}
