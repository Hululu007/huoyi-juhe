import 'dart:convert';
import 'dart:io';

/// 统一导入口的认库结果（2026-11-28 统一导入口批）：数据库管理
/// 页只留一个导入入口，用户选哪份文件都由软件按内容认库、走
/// 各自原有的导入路（校验、版本门、签名、落位语义一字不改，
/// 本文件只负责「认」，不负责「导」）。
enum UnifiedImportKind {
  /// 三段合并文件（bundle_manifest 在场）：走站点库服务的
  /// 分段导入器，三段各落各位。
  bundle,

  /// 站点库单段文件：走站点库服务单段路。
  siteLibrary,

  /// 女优库 .db 本体（SQLite 文件头）：走女优库 .db 收编路。
  actressDb,

  /// 女优库 .sql/.sql.gz（标准表、播放地址是 http 直链）：
  /// 走女优库 SQL 导入路。
  actressSql,

  /// 磁力库 .sql/.sql.gz（标准表、播放地址是 magnet 链接）：
  /// 走磁力并存合并路。
  magnetSql,

  /// 认不出：不许瞎导，页面给中文提示。
  unknown,
}

extension UnifiedImportKindLabel on UnifiedImportKind {
  /// 给用户看的中文名（进度与结果回报用）。
  String get labelZh => switch (this) {
    UnifiedImportKind.bundle => '三库合并文件',
    UnifiedImportKind.siteLibrary => '站点库',
    UnifiedImportKind.actressDb => '女优库',
    UnifiedImportKind.actressSql => '女优库',
    UnifiedImportKind.magnetSql => '磁力库',
    UnifiedImportKind.unknown => '未知文件',
  };
}

/// 流式认库嗅探器：按块扫文件（.sql.gz 先流式解压），每块按
/// latin1 解码做 ASCII 模式匹配（字节与字符一一对应、模式全
/// 是 ASCII，不会误码），内存里只留一小段尾巴做跨块匹配，
/// 绝不整文件读入、绝不走系统文件选择器。判定规则（按真实
/// 文件形态定，逐条有实证）：
///
/// 1. 文件头是 SQLite 魔数（`SQLite format 3`）→ 女优库 .db。
/// 2. 扫到 `bundle_manifest` → 合并文件。它在合并文件第 32
///    字节处，必然先于一切段表出现，命中即定。
/// 3. 扫到站点库独有表名（`station_code` / `schema_meta` /
///    `INSERT INTO stations`）→ 站点库单段。女优/磁力文件没有
///    这些表；合并文件的段表带 seg_ 前缀且 bundle 清单在更
///    前面，第 2 条先定，不会误判。
/// 4. 女优与磁力同结构（videos 等标准表），唯一干净的区分是
///    播放地址：磁力库的地址值以 `'magnet:` 开头（真磁力库
///    9.9 万条、真女优库 0 条）。扫到 25 条即定磁力（提前收）；
///    扫完一条都没有、且有标准表 → 女优库。中间情形（1–24
///    条）看 video_play_urls 首批样本的地址形态定：样本是
///    magnet → 磁力，样本是 http → 女优（样本只看标记之后的
///    字节，videos 行里的封面/试看 http 地址不算证据）。
/// 5. 以上都不命中（没有标准表、或读不出内容）→ unknown。
class UnifiedImportSniffer {
  UnifiedImportSniffer._();

  static const _sqliteMagic = 'SQLite format 3';

  /// 扫到这么多条 magnet 地址值就提前定磁力（真女优库是 0
  /// 条，25 条不可能是女优库里夹带的零星链接）。
  static const magnetDecisiveHits = 25;

  /// video_play_urls 样本窗口：标记后这么多字节内找地址形态。
  static const _sampleWindowBytes = 600;

  static Future<UnifiedImportKind> sniff(String path) async {
    final file = File(path);
    if (!await file.exists() || await file.length() == 0) {
      return UnifiedImportKind.unknown;
    }
    // 1. SQLite 文件头（.db 本体；.sql.gz 的头是 gzip 魔数，
    //    不会撞）。
    try {
      final head = await file.openRead(0, 16).fold<List<int>>(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );
      if (head.length >= _sqliteMagic.length &&
          String.fromCharCodes(head.take(_sqliteMagic.length)) ==
              _sqliteMagic) {
        return UnifiedImportKind.actressDb;
      }
    } catch (_) {
      return UnifiedImportKind.unknown;
    }
    // 2–5. 流式扫描（.gz 流式解压，解压失败按认不出）。
    try {
      return await _scanStream(file, isGz: path.toLowerCase().endsWith('.gz'));
    } catch (_) {
      return UnifiedImportKind.unknown;
    }
  }

  static Future<UnifiedImportKind> _scanStream(
    File file, {
    required bool isGz,
  }) async {
    Stream<List<int>> stream = file.openRead();
    if (isGz) stream = stream.transform(gzip.decoder);

    const bundlePattern = 'bundle_manifest';
    const sitePatterns = ['station_code', 'schema_meta', 'INSERT INTO stations'];
    const videosPatterns = ['INSERT INTO videos', 'CREATE TABLE videos'];
    const magnetPattern = "'magnet:";
    const playUrlsMarker = 'video_play_urls';
    const httpPattern = "'http";

    const tailKeep = 32; // 最长模式 20 字符，尾巴留够跨块匹配。
    // bundle 清单与站点库表都在文件最头部（合并文件第 32 字
    // 节、站点单段开头建表）：只在前 8MB 查这两组标记，之后
    // 不再逐块白扫，省全程大半扫描量。
    const headWindowBytes = 8 * 1024 * 1024;
    var scannedBytes = 0;
    var tail = '';
    var videosSeen = false;
    var magnetHits = 0;
    // video_play_urls 首个样本：null=还没采到，true=magnet，
    // false=http。
    bool? playUrlSampleIsMagnet;
    var sampleBuffer = '';
    var sampleWindowOpen = false;

    await for (final chunk in stream) {
      scannedBytes += chunk.length;
      final data = tail + latin1.decode(chunk);
      if (scannedBytes <= headWindowBytes) {
        if (data.contains(bundlePattern)) {
          return UnifiedImportKind.bundle;
        }
        for (final pattern in sitePatterns) {
          if (data.contains(pattern)) return UnifiedImportKind.siteLibrary;
        }
      }
      if (!videosSeen) {
        for (final pattern in videosPatterns) {
          if (data.contains(pattern)) {
            videosSeen = true;
            break;
          }
        }
      }
      magnetHits += magnetPattern.allMatches(data).length;
      if (magnetHits >= magnetDecisiveHits) {
        return UnifiedImportKind.magnetSql;
      }
      if (playUrlSampleIsMagnet == null) {
        if (!sampleWindowOpen) {
          final markerAt = data.indexOf(playUrlsMarker);
          if (markerAt >= 0) {
            sampleWindowOpen = true;
            sampleBuffer = data.substring(markerAt + playUrlsMarker.length);
          }
        } else {
          sampleBuffer += latin1.decode(chunk);
        }
        if (sampleWindowOpen) {
          final magnetAt = sampleBuffer.indexOf(magnetPattern);
          final httpAt = sampleBuffer.indexOf(httpPattern);
          if (magnetAt >= 0 && (httpAt < 0 || magnetAt < httpAt)) {
            playUrlSampleIsMagnet = true;
          } else if (httpAt >= 0) {
            playUrlSampleIsMagnet = false;
          } else if (sampleBuffer.length >= _sampleWindowBytes) {
            // 窗口内没采到地址形态：放弃这次样本，下一个
            // video_play_urls 标记再采，计数兜底还在。
            sampleWindowOpen = false;
            sampleBuffer = '';
          }
        }
      }
      tail = data.length <= tailKeep
          ? data
          : data.substring(data.length - tailKeep);
    }

    if (!videosSeen) return UnifiedImportKind.unknown;
    if (playUrlSampleIsMagnet == true) return UnifiedImportKind.magnetSql;
    if (playUrlSampleIsMagnet == false) return UnifiedImportKind.actressSql;
    if (magnetHits > 0) return UnifiedImportKind.magnetSql;
    return UnifiedImportKind.actressSql;
  }
}
