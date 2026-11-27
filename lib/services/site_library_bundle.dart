import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../actress/actress_database.dart' show SqfliteActressDatabase;
import '../actress/actress_db_import.dart';
import '../actress/actress_db_source.dart';
import '../actress/actress_magnet_library.dart';
import 'site_library.dart';

/// 合并文件（bundle）分段导入器（2026-11-27 站点库续办批）：
/// 一份「凡人修仙站点.sql」装三段（site/actress/magnet），格式
/// 见 SEGMENT_SPEC.md 段格式规格 v1。导入算法照规格 §5：
/// 流式执行整文件进 staging 临时库 → 验整文件签名（不过全拒）
/// → 逐段验（payload/签名/版本门，不过只拒该段、中文原因）
/// → 逐段落位（site 剥前缀建站点库.db 先验后换；actress 剥
/// 前缀建段 .db 交女优库导入链；magnet 剥前缀建段 .db 交磁力
/// 并存合并链）。旧无前缀单段文件不走这里（服务层粗扫不到
/// bundle_manifest 字样时直接走现行单段路；粗扫误报时本类
/// staging 后查无 bundle_manifest 表、回 null 交回单段路）。
///
/// 落位三件都可注入（测试用假件）：段物化器、演员库落位、
/// 磁力落位。生产缺省实现在本文件下半段。

/// actress/magnet 段的标准索引（与女优库/磁力库源文件同款六条）：
/// 段物化只搬表不搬索引（生成器并段口径），落位前按此补建，
/// 与 .sql 直导（dump 自带 CREATE INDEX）与 .db 直导（文件
/// 自带）的结果对齐。索引是结构衍生物，不进段 payload。
const actressSegmentIndexDdl = <String>[
  'CREATE INDEX IF NOT EXISTS idx_va_c ON video_actress(cate_id)',
  'CREATE INDEX IF NOT EXISTS idx_va_v ON video_actress(vod_id)',
  'CREATE INDEX IF NOT EXISTS idx_vt_t ON video_tag(tag_name)',
  'CREATE INDEX IF NOT EXISTS idx_vt_v ON video_tag(vod_id)',
  'CREATE INDEX IF NOT EXISTS idx_ic_type ON index_categories(category_type)',
  'CREATE INDEX IF NOT EXISTS idx_vc_main ON video_category(main_category)',
];

/// UTF-8 字节序比较（与 site_library.dart 同口径，段 payload 的
/// T 行排序必须与生成器一致，不能用 Dart 默认字符串序）。
int compareUtf8Bytes(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  final n = x.length < y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    if (x[i] != y[i]) return x[i] - y[i];
  }
  return x.length - y.length;
}

/// 规范序列化里一个值的文本形态（SEGMENT_SPEC §4）：NULL 记
/// \x00，其余按原样文本（整数十进制、文本原样；演员/磁力两段
/// 载荷表只有 TEXT/INTEGER 列，与生成器 Python str() 口径一致）。
String canonicalSegmentValue(Object? value) {
  if (value == null) return '\x00';
  if (value is Uint8List) return utf8.decode(value, allowMalformed: true);
  return '$value';
}

/// 一张表的规范哈希：列按建表顺序、行按 rowid 顺序、值以
/// \x1f 分隔、行以 '\n' 分隔、UTF-8 取 sha256。
Future<String> computeSegmentTableSha256(
  SiteLibrarySqlExecutor executor,
  String table,
) async {
  final cols = await executor.query('PRAGMA table_info("$table")');
  final colNames = [for (final row in cols) '${row['name']}'];
  final select = colNames.map((c) => '"$c"').join(', ');
  final rows = await executor.query(
    'SELECT $select FROM "$table" ORDER BY rowid',
  );
  final lines = [
    for (final row in rows)
      colNames.map((c) => canonicalSegmentValue(row[c])).join('\x1f'),
  ];
  return sha256.convert(utf8.encode(lines.join('\n'))).toString();
}

/// actress/magnet 段 payload（SEGMENT_SPEC §4 的 T 行定义）：
/// 每张载荷表一行 `T|{原表名}|{行数}|{表哈希}`（表名去段前缀），
/// 全部行按 UTF-8 字节序排序、'\n' 连接取 sha256。
/// [prefixedTables] 是 staging 里的实际表名（带 seg_<段>_ 前缀）。
Future<String> computeBundleSegmentPayload(
  SiteLibrarySqlExecutor executor, {
  required String segment,
  required List<String> prefixedTables,
}) async {
  final prefix = 'seg_${segment}_';
  final lines = <String>[];
  for (final table in prefixedTables) {
    final bare = table.startsWith(prefix)
        ? table.substring(prefix.length)
        : table;
    final countRows = await executor.query(
      'SELECT COUNT(*) AS c FROM "$table"',
    );
    final count = (countRows.first['c'] as num?)?.toInt() ?? 0;
    final hash = await computeSegmentTableSha256(executor, table);
    lines.add('T|$bare|$count|$hash');
  }
  lines.sort(compareUtf8Bytes);
  return sha256.convert(utf8.encode(lines.join('\n'))).toString();
}

/// 整文件 payload：每个在场段一行 `SEG|{段}|{段 payload}`，
/// 排序连接取 sha256（SEGMENT_SPEC §2）。
String computeBundlePayloadSha256(Map<String, String> segmentPayloads) {
  final lines = [
    for (final entry in segmentPayloads.entries)
      'SEG|${entry.key}|${entry.value}',
  ];
  lines.sort(compareUtf8Bytes);
  return sha256.convert(utf8.encode(lines.join('\n'))).toString();
}

/// 段物化器：把 staging 库里 seg_<段>_ 的载荷表（不含段
/// manifest）剥前缀建成 [targetPath] 的独立 .db（表＋索引）。
abstract class SiteLibrarySegmentMaterializer {
  Future<void> materialize({
    required String stagingPath,
    required String segment,
    required String targetPath,
  });
}

/// sqflite 实现：新库 ATTACH staging 后逐表 CREATE（改名）＋
/// INSERT SELECT；索引按 staging 里的定义改名后重建。
class SqfliteSegmentMaterializer implements SiteLibrarySegmentMaterializer {
  const SqfliteSegmentMaterializer();

  @override
  Future<void> materialize({
    required String stagingPath,
    required String segment,
    required String targetPath,
  }) async {
    final target = File(targetPath);
    if (await target.exists()) await target.delete();
    await target.parent.create(recursive: true);
    final db = await openDatabase(targetPath, singleInstance: false);
    try {
      final escaped = stagingPath.replaceAll("'", "''");
      await db.execute("ATTACH DATABASE '$escaped' AS stage");
      try {
        final prefix = 'seg_${segment}_';
        final tables = await db.rawQuery(
          "SELECT name, sql FROM stage.sqlite_master "
          "WHERE type='table' AND name LIKE ? AND name <> ?",
          ['$prefix%', '${prefix}manifest'],
        );
        for (final row in tables) {
          final prefixed = '${row['name']}';
          final bare = prefixed.substring(prefix.length);
          await db.execute(
            _rewriteCreatedName('${row['sql']}', prefixed, bare),
          );
          await db.execute(
            'INSERT INTO "$bare" SELECT * FROM stage."$prefixed"',
          );
        }
        final indexes = await db.rawQuery(
          "SELECT name, sql, tbl_name FROM stage.sqlite_master "
          "WHERE type='index' AND sql IS NOT NULL AND tbl_name LIKE ?",
          ['$prefix%'],
        );
        for (final row in indexes) {
          final tbl = '${row['tbl_name']}';
          if (tbl == '${prefix}manifest') continue;
          final bare = tbl.substring(prefix.length);
          try {
            await db.execute(_rewriteIndexTable('${row['sql']}', tbl, bare));
          } catch (_) {
            // 索引重建失败不挡落位（查询退化为全表扫，功能在）。
          }
        }
      } finally {
        await db.execute('DETACH DATABASE stage');
      }
    } finally {
      await db.close();
    }
  }

  /// CREATE TABLE 语句里把被建表名从带前缀改成裸名（名字可能
  /// 带引号，也可能不带）。
  static String _rewriteCreatedName(
    String sql,
    String prefixed,
    String bare,
  ) {
    final pattern = RegExp(
      '(CREATE\\s+TABLE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?)["\'\\[\\]]?'
      '${RegExp.escape(prefixed)}["\'\\[\\]]?',
      caseSensitive: false,
    );
    final out = sql.replaceFirstMapped(
      pattern,
      (m) => '${m.group(1)}"$bare"',
    );
    if (!out.contains('"$bare"')) {
      throw StateError('段表建表改名失败：$prefixed');
    }
    return out;
  }

  /// CREATE INDEX 语句里 ON 后面的表名改裸名。
  static String _rewriteIndexTable(String sql, String prefixed, String bare) {
    final pattern = RegExp(
      '(\\bON\\s+)["\'\\[\\]]?${RegExp.escape(prefixed)}["\'\\[\\]]?',
      caseSensitive: false,
    );
    return sql.replaceFirstMapped(pattern, (m) => '${m.group(1)}"$bare"');
  }
}

/// 演员库段落位：入参是物化好的段 .db 路径，回成败＋中文原因
/// ＋成功时的人话计数。
typedef SiteLibraryActressLander =
    Future<({bool ok, String? error, String? detail})> Function(
      String segmentDbPath,
    );

/// 磁力段落位：同上。
typedef SiteLibraryMagnetLander =
    Future<({bool ok, String? error, String? detail})> Function(
      String segmentDbPath,
    );

/// 生产演员库段落位：走女优库既有 .db 导入链（结构校验→先验
/// 后换进导入槽）；版本门已在段校验层过（段 manifest 的版本
/// 字段），段 .db 自带 schema_meta、组装激活批后其链内门也认。
Future<({bool ok, String? error, String? detail})>
productionActressSegmentLander(String segmentDbPath) async {
  final outcome = await ActressDbImportService().importLocalFile(
    localPath: segmentDbPath,
    closeDatabase: () => SqfliteActressDatabase.instance.close(),
  );
  if (!outcome.ok) {
    return (
      ok: false,
      error: outcome.error ?? '演员库导入失败',
      detail: null,
    );
  }
  ActressDbSource.instance.notifyChanged();
  return (ok: true, error: null, detail: '作品 ${outcome.videos} 部');
}

/// 磁力合并目标库的标准空表（与磁力管理页同款）：导入槽还
/// 没有库文件时先建空目标再并。
const _magnetEmptyTargetDdl = <String>[
  'CREATE TABLE videos (vod_id TEXT PRIMARY KEY, title TEXT, pic_url TEXT, m3u8_url TEXT, vod_remarks TEXT, vod_pubdate TEXT, vod_area TEXT, vod_year TEXT, vod_content TEXT, vod_play_from TEXT, vod_play_url TEXT, type_name TEXT, created_at TEXT)',
  'CREATE TABLE actresses (cate_id TEXT PRIMARY KEY, name TEXT, avatar TEXT, created_at TEXT, sex TEXT, roster_id TEXT, claimed INTEGER)',
  'CREATE TABLE video_actress (vod_id TEXT, cate_id TEXT, PRIMARY KEY (vod_id, cate_id))',
  'CREATE TABLE video_play_urls (vod_id TEXT, play_url TEXT, play_from TEXT, PRIMARY KEY (vod_id, play_url))',
  'CREATE TABLE video_category (vod_id TEXT PRIMARY KEY, main_category TEXT)',
  'CREATE TABLE video_tag (vod_id TEXT, tag_name TEXT, PRIMARY KEY (vod_id, tag_name))',
];

/// 生产磁力段落位：段 .db 先验有磁力线路，再开导入槽目标库
/// （没有先建标准空表）走 ActressMagnetLibraryStore.mergeStaging
/// 并存合并（只新增不覆盖）。
Future<({bool ok, String? error, String? detail})>
productionMagnetSegmentLander(String segmentDbPath) async {
  final source = ActressDbSource.instance;
  final importedPath = await source.importedDbPath();
  if (importedPath.isEmpty) {
    return (ok: false, error: '导入落点不可用，磁力段没并入', detail: null);
  }
  if (!await ActressMagnetLibraryStore.stagingIsMagnetLibrary(segmentDbPath)) {
    return (ok: false, error: '磁力段里没有磁力链接，已跳过', detail: null);
  }
  final file = File(importedPath);
  final existed = file.existsSync() && file.lengthSync() > 0;
  if (!existed) await file.parent.create(recursive: true);
  try {
    await SqfliteActressDatabase.instance.close();
  } catch (_) {
    // 主库连接没开着：关失败不挡合并。
  }
  final db = await openDatabase(importedPath, singleInstance: false);
  try {
    if (!existed) {
      for (final ddl in _magnetEmptyTargetDdl) {
        await db.execute(ddl);
      }
    }
    await ActressMagnetLibraryStore.ensureSchema(db);
    final outcome = await const ActressMagnetLibraryStore().mergeStaging(
      db,
      segmentDbPath,
      sourceName: '凡人修仙站点.sql',
    );
    if (!outcome.ok) {
      return (
        ok: false,
        error: outcome.error ?? '磁力合并失败',
        detail: null,
      );
    }
    source.notifyChanged();
    return (
      ok: true,
      error: null,
      detail: '新增作品 ${outcome.addedWorks} 部、磁力线路 '
          '${outcome.addedPlayUrls} 条',
    );
  } finally {
    await db.close();
  }
}

/// 段 .db 落位前处理（生产缺省）：actress/magnet 段按标准索引
/// 集补建索引（物化只搬表，见 actressSegmentIndexDdl 注释）。
Future<void> productionSegmentDbPostProcess(
  String segment,
  String segmentDbPath,
) async {
  if (segment != 'actress' && segment != 'magnet') return;
  final db = await openDatabase(segmentDbPath, singleInstance: false);
  try {
    for (final ddl in actressSegmentIndexDdl) {
      try {
        await db.execute(ddl);
      } catch (_) {
        // 缺表的那条跳过（段表不全时落位链自己会报错）。
      }
    }
  } finally {
    await db.close();
  }
}

/// 一段通过校验后的落位材料（段 manifest 的值）。
class _SegmentPlan {
  const _SegmentPlan({
    required this.segment,
    required this.formatVersion,
    required this.coreVersion,
    required this.libraryVersion,
    required this.rowCount,
    required this.payloadSha256,
    required this.signature,
    required this.tables,
  });

  final String segment;
  final String formatVersion;
  final String coreVersion;
  final String libraryVersion;
  final int rowCount;
  final String payloadSha256;
  final String signature;

  /// staging 里的载荷表名（带前缀，不含段 manifest）。
  final List<String> tables;
}

/// 合并文件分段导入器。staging 用独立临时文件
/// （`<库目录>/bundle_staging.db`），与站点库本体、女优库双槽
/// 都不相干；落位完成后 staging 与段 .db 临时文件一律清掉。
class SiteLibraryBundleImporter {
  SiteLibraryBundleImporter({
    this.batchSize = 1000,
    this.currentCoreVersion = siteLibraryDefaultCoreVersion,
    this.supportedFormatVersion = siteLibrarySupportedFormatVersion,
    Future<SiteLibrarySqlExecutor> Function(String tempPath)?
    executorFactory,
    SiteLibrarySegmentMaterializer? materializer,
    SiteLibraryActressLander? actressLander,
    SiteLibraryMagnetLander? magnetLander,
    Future<void> Function(String segment, String segmentDbPath)?
    segmentDbPostProcess,
  }) : _executorFactory =
           executorFactory ??
           ((tempPath) async {
             final db = await openDatabase(
               tempPath,
               singleInstance: false,
             );
             return SqfliteSiteLibraryExecutor(db);
           }),
       _materializer = materializer ?? const SqfliteSegmentMaterializer(),
       _actressLander = actressLander ?? productionActressSegmentLander,
       _magnetLander = magnetLander ?? productionMagnetSegmentLander,
       _segmentDbPostProcess =
           segmentDbPostProcess ?? productionSegmentDbPostProcess;

  final int batchSize;
  final String currentCoreVersion;
  final String supportedFormatVersion;
  final Future<SiteLibrarySqlExecutor> Function(String tempPath)
  _executorFactory;
  final SiteLibrarySegmentMaterializer _materializer;
  final SiteLibraryActressLander _actressLander;
  final SiteLibraryMagnetLander _magnetLander;
  final Future<void> Function(String segment, String segmentDbPath)
  _segmentDbPostProcess;

  static const _knownSegments = ['site', 'actress', 'magnet'];

  /// 粗扫：文件里有没有 bundle_manifest 字样（流式、认 .gz）。
  /// 只是路由提示——权威判定是 staging 后查 sqlite_master；
  /// 粗扫命中但查无此表时 importBundle 回 null 交回单段路。
  static Future<bool> mightBeBundle(String sqlPath) async {
    final file = File(sqlPath);
    if (!await file.exists()) return false;
    Stream<List<int>> stream = file.openRead();
    if (sqlPath.toLowerCase().endsWith('.gz')) {
      stream = stream.transform(gzip.decoder);
    }
    const needle = 'bundle_manifest';
    var tail = '';
    await for (final chunk in stream.transform(utf8.decoder)) {
      final text = tail + chunk;
      if (text.contains(needle)) return true;
      tail = text.length <= needle.length
          ? text
          : text.substring(text.length - needle.length);
    }
    return false;
  }

  /// 导入合并文件。不是合并文件（staging 后无 bundle_manifest
  /// 表）回 null，调用方走单段路。整文件层失败（签名/版本门）
  /// 回 ok=false 的结果、任何段都不落位；段层失败只进该段的
  /// segmentResults。
  Future<SiteLibraryImportOutcome?> importBundle({
    required String sqlPath,
    required String siteDbPath,
    required String workDir,
    required void Function(SiteLibraryProgress) onProgress,
    bool Function()? isCancelled,
  }) async {
    final sqlFile = File(sqlPath);
    if (!await sqlFile.exists() || await sqlFile.length() == 0) {
      return const SiteLibraryImportOutcome(
        ok: false,
        error: '选中的文件不存在或为空',
      );
    }
    try {
      await Directory(workDir).create(recursive: true);
    } catch (_) {}
    final stagingPath = '$workDir/bundle_staging.db';
    final stagingFile = File(stagingPath);
    try {
      if (await stagingFile.exists()) await stagingFile.delete();
    } catch (_) {
      return const SiteLibraryImportOutcome(
        ok: false,
        error: '临时库文件删不掉，请先确认没有别的导入在跑',
      );
    }
    SiteLibrarySqlExecutor? executor;
    try {
      executor = await _executorFactory(stagingPath);
      await _stageFile(
        executor: executor,
        sqlFile: sqlFile,
        sqlPath: sqlPath,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      void checkCancelled() {
        if (isCancelled != null && isCancelled()) {
          throw SiteLibraryImportCancelled();
        }
      }

      checkCancelled();
      final hasBundle = await _tableExists(executor, 'bundle_manifest');
      if (!hasBundle) return null;

      onProgress(
        SiteLibraryProgress(
          phase: '正在校验',
          statements: 0,
          bytesRead: await sqlFile.length(),
          totalBytes: await sqlFile.length(),
        ),
      );

      // ---- 整文件层：清单/格式/整签/整文件版本门，不过全拒 ----
      final bundleRows = await executor.query(
        'SELECT bundle_format, format_version, core_version, '
        'bundle_version, segments, payload_sha256, signature '
        'FROM bundle_manifest WHERE id=1',
      );
      if (bundleRows.isEmpty) {
        return const SiteLibraryImportOutcome(
          ok: false,
          error: '合并文件缺整文件清单（bundle_manifest），已整份拒收',
        );
      }
      final bundle = bundleRows.first;
      if ('${bundle['bundle_format']}' != 'fanren_bundle') {
        return const SiteLibraryImportOutcome(
          ok: false,
          error: '合并文件清单不对（不是凡人修仙合并文件），已整份拒收',
        );
      }
      final bundleFormatVersion = '${bundle['format_version'] ?? ''}';
      final bundleCoreVersion = '${bundle['core_version'] ?? ''}';
      final bundleVersion = '${bundle['bundle_version'] ?? ''}';
      final segmentNames = '${bundle['segments'] ?? ''}'
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (segmentNames.isEmpty) {
        return const SiteLibraryImportOutcome(
          ok: false,
          error: '合并文件没写明含哪几段，已整份拒收',
        );
      }
      for (final seg in segmentNames) {
        if (!_knownSegments.contains(seg)) {
          return SiteLibraryImportOutcome(
            ok: false,
            error: '合并文件含不认识的段「$seg」，已整份拒收',
          );
        }
        if (!await _tableExists(executor, 'seg_${seg}_manifest')) {
          return SiteLibraryImportOutcome(
            ok: false,
            error: '合并文件缺 $seg 段清单，已整份拒收',
          );
        }
      }
      // 段 manifest 先读出来算整文件 payload（缺一段都算不出，
      // 上面已挡）。
      final plans = <String, _SegmentPlan>{};
      final declaredPayloads = <String, String>{};
      for (final seg in segmentNames) {
        final rows = await executor.query(
          'SELECT segment, format_version, core_version, '
          'library_version, row_count, payload_sha256, signature '
          'FROM seg_${seg}_manifest WHERE id=1',
        );
        if (rows.isEmpty) {
          return SiteLibraryImportOutcome(
            ok: false,
            error: '合并文件缺 $seg 段清单行，已整份拒收',
          );
        }
        final row = rows.first;
        final tables = await _segmentTables(executor, seg);
        plans[seg] = _SegmentPlan(
          segment: seg,
          formatVersion: '${row['format_version'] ?? ''}',
          coreVersion: '${row['core_version'] ?? ''}',
          libraryVersion: '${row['library_version'] ?? ''}',
          rowCount: (row['row_count'] as num?)?.toInt() ?? -1,
          payloadSha256: '${row['payload_sha256'] ?? ''}',
          signature: '${row['signature'] ?? ''}',
          tables: tables,
        );
        declaredPayloads[seg] = '${row['payload_sha256'] ?? ''}';
      }
      final bundlePayload = computeBundlePayloadSha256(declaredPayloads);
      if (bundlePayload != '${bundle['payload_sha256']}') {
        return const SiteLibraryImportOutcome(
          ok: false,
          error: '整文件内容哈希对不上，已整份拒收（文件可能被改过）',
        );
      }
      final bundleSignature = '${bundle['signature'] ?? ''}';
      if (bundleSignature.isEmpty ||
          bundleSignature != computeSiteLibrarySignature(bundlePayload)) {
        return const SiteLibraryImportOutcome(
          ok: false,
          error: '整文件签名不对，已整份拒收',
        );
      }
      if (bundleFormatVersion != supportedFormatVersion) {
        return SiteLibraryImportOutcome(
          ok: false,
          error: '合并文件格式版本 $bundleFormatVersion 与当前软件支持的 '
              '$supportedFormatVersion 不符，已整份拒收',
        );
      }
      if (bundleCoreVersion != currentCoreVersion) {
        return SiteLibraryImportOutcome(
          ok: false,
          error: '合并文件要求核心版本 $bundleCoreVersion，'
              '当前软件版本是 $currentCoreVersion，不匹配，已整份拒收',
        );
      }

      // ---- 逐段验：不过只拒该段 ----
      final verified = <String, _SegmentPlan>{};
      final results = <String, SiteLibrarySegmentResult>{};
      for (final seg in segmentNames) {
        final plan = plans[seg]!;
        final rejection = await _verifySegment(executor, plan);
        if (rejection != null) {
          results[seg] = SiteLibrarySegmentResult(
            segment: seg,
            ok: false,
            error: rejection,
          );
        } else {
          verified[seg] = plan;
        }
      }

      // ---- 逐段落位（site → actress → magnet 固定序） ----
      await executor.close();
      executor = null;
      var stationCount = 0;
      String? siteLibraryVersion;
      for (final seg in _knownSegments) {
        final plan = verified[seg];
        if (plan == null) continue;
        checkCancelled();
        onProgress(
          SiteLibraryProgress(
            phase: '正在落位',
            statements: 0,
            bytesRead: await sqlFile.length(),
            totalBytes: await sqlFile.length(),
          ),
        );
        final result = await _landSegment(
          stagingPath: stagingPath,
          siteDbPath: siteDbPath,
          workDir: workDir,
          plan: plan,
        );
        results[seg] = result;
        if (seg == 'site' && result.ok) {
          stationCount = _siteStationCounts[plan.payloadSha256] ?? 0;
          siteLibraryVersion = plan.libraryVersion;
        }
      }
      final ordered = [
        for (final seg in segmentNames)
          if (results[seg] != null) results[seg]!,
      ];
      final anyLanded = ordered.any((r) => r.ok);
      if (!anyLanded) {
        final firstError = ordered
            .map((r) => r.error)
            .firstWhere((e) => e != null, orElse: () => null);
        return SiteLibraryImportOutcome(
          ok: false,
          error: '没有一段通过校验：${firstError ?? '未知原因'}',
          segmentResults: ordered,
        );
      }
      return SiteLibraryImportOutcome(
        ok: true,
        stationCount: stationCount,
        libraryVersion: siteLibraryVersion ?? bundleVersion,
        segmentResults: ordered,
      );
    } on SiteLibraryImportCancelled {
      return const SiteLibraryImportOutcome(
        ok: false,
        error: '已取消，数据库未改动',
      );
    } catch (e) {
      return SiteLibraryImportOutcome(
        ok: false,
        error: '导入失败：${e.toString().split('\n').first}',
      );
    } finally {
      try {
        await executor?.close();
      } catch (_) {}
      try {
        if (await stagingFile.exists()) await stagingFile.delete();
      } catch (_) {}
    }
  }

  /// site 段落位成功时的站数（按 payload 索引，_landSegment 写）。
  final _siteStationCounts = <String, int>{};

  Future<bool> _tableExists(
    SiteLibrarySqlExecutor executor,
    String table,
  ) async {
    final rows = await executor.query(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name='$table'",
    );
    return rows.isNotEmpty;
  }

  /// staging 里一段的载荷表（带前缀、排除段 manifest 自身）。
  Future<List<String>> _segmentTables(
    SiteLibrarySqlExecutor executor,
    String segment,
  ) async {
    final prefix = 'seg_${segment}_';
    final rows = await executor.query(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name LIKE '$prefix%'",
    );
    final tables = [
      for (final row in rows)
        if ('${row['name']}' != '${prefix}manifest') '${row['name']}',
    ];
    tables.sort();
    return tables;
  }

  /// 逐段三关：payload 重算 → 签名 → 版本门（＋行数对账）。
  /// 过关回 null，不过回中文拒因（写明段名与两边版本）。
  Future<String?> _verifySegment(
    SiteLibrarySqlExecutor executor,
    _SegmentPlan plan,
  ) async {
    final seg = plan.segment;
    final label = SiteLibrarySegmentResult(segment: seg, ok: false).segmentLabel;
    var actualRows = 0;
    for (final table in plan.tables) {
      final rows = await executor.query(
        'SELECT COUNT(*) AS c FROM "$table"',
      );
      actualRows += (rows.first['c'] as num?)?.toInt() ?? 0;
    }
    if (actualRows != plan.rowCount) {
      return '$label段行数对不上：清单写 ${plan.rowCount}、实际 $actualRows，'
          '已拒收这一段';
    }
    final String payload;
    if (seg == 'site') {
      payload = await _siteSegmentPayload(executor, plan);
      // 代码逐行哈希（与单段路同尺）：code_text 与 code_sha256
      // 对不上＝段被动过。
      final codeRows = await executor.query(
        'SELECT site_id, code_sha256, code_text FROM seg_site_station_code',
      );
      for (final row in codeRows) {
        final codeText = row['code_text'];
        if (codeText == null) continue;
        final actual = sha256.convert(utf8.encode('$codeText')).toString();
        if (actual != '${row['code_sha256']}') {
          return '站点库段代码哈希对不上：${row['site_id']}，已拒收这一段';
        }
      }
      final stationRows = await executor.query(
        'SELECT COUNT(*) AS c FROM seg_site_stations',
      );
      _siteStationCounts[plan.payloadSha256] =
          (stationRows.first['c'] as num?)?.toInt() ?? 0;
    } else {
      payload = await computeBundleSegmentPayload(
        executor,
        segment: seg,
        prefixedTables: plan.tables,
      );
    }
    if (payload != plan.payloadSha256) {
      return '$label段内容哈希对不上，已拒收这一段（文件可能被改过）';
    }
    if (plan.signature.isEmpty ||
        plan.signature != computeSiteLibrarySignature(payload)) {
      return '$label段签名不对，已拒收这一段';
    }
    if (plan.formatVersion != supportedFormatVersion) {
      return '$label段格式版本 ${plan.formatVersion} 与当前软件支持的 '
          '$supportedFormatVersion 不符，已拒收这一段';
    }
    if (plan.coreVersion != currentCoreVersion) {
      return '$label段要求核心版本 ${plan.coreVersion}，'
          '当前软件版本是 $currentCoreVersion，不匹配，已拒收这一段';
    }
    return null;
  }

  /// site 段 payload：沿单段口径（S/C/A/M parts），数据读
  /// seg_site_ 前缀表，M 行用段 manifest 的版本三字段。
  Future<String> _siteSegmentPayload(
    SiteLibrarySqlExecutor executor,
    _SegmentPlan plan,
  ) async {
    final stationRows = await executor.query(
      'SELECT site_id, kind, name FROM seg_site_stations',
    );
    final codeRows = await executor.query(
      'SELECT site_id, code_sha256 FROM seg_site_station_code',
    );
    final assetRows = await executor.query(
      'SELECT asset_id, md5 FROM seg_site_station_assets',
    );
    return computeSiteLibraryPayloadSha256(
      stations: [
        for (final row in stationRows)
          (
            siteId: '${row['site_id']}',
            kind: '${row['kind']}',
            name: '${row['name']}',
          ),
      ],
      codes: [
        for (final row in codeRows)
          (siteId: '${row['site_id']}', codeSha256: '${row['code_sha256']}'),
      ],
      assets: [
        for (final row in assetRows)
          (assetId: '${row['asset_id']}', md5: '${row['md5']}'),
      ],
      manifest: (
        formatVersion: plan.formatVersion,
        coreVersion: plan.coreVersion,
        libraryVersion: plan.libraryVersion,
      ),
    );
  }

  /// 一段落位。site：物化→补 manifest 表→先验后换；actress/
  /// magnet：物化→补索引→交各自落位链。失败回该段的拒因，
  /// 已落位的别段不回滚（各段独立、与规格口径一致）。
  Future<SiteLibrarySegmentResult> _landSegment({
    required String stagingPath,
    required String siteDbPath,
    required String workDir,
    required _SegmentPlan plan,
  }) async {
    final seg = plan.segment;
    try {
      if (seg == 'site') {
        final tempPath = '$siteDbPath.importing';
        await _materializer.materialize(
          stagingPath: stagingPath,
          segment: seg,
          targetPath: tempPath,
        );
        // 补旧单段格式的 manifest 表（服务层 load() 读它判版本）。
        final executor = await _executorFactory(tempPath);
        try {
          await executor.execute(
            'CREATE TABLE manifest('
            'id INTEGER PRIMARY KEY CHECK(id=1), '
            'library_version TEXT NOT NULL, '
            'station_count INTEGER NOT NULL, '
            'payload_sha256 TEXT NOT NULL, signature TEXT, '
            'format_version TEXT NOT NULL, core_version TEXT NOT NULL)',
          );
          final count = _siteStationCounts[plan.payloadSha256] ?? 0;
          await executor.execute(
            'INSERT INTO manifest VALUES(1, '
            "'${_sqlText(plan.libraryVersion)}', $count, "
            "'${_sqlText(plan.payloadSha256)}', "
            "'${_sqlText(plan.signature)}', "
            "'${_sqlText(plan.formatVersion)}', "
            "'${_sqlText(plan.coreVersion)}')",
          );
        } finally {
          await executor.close();
        }
        // 先验后换（与单段路同款）：旧库拷 .bak → 临时库改名。
        final liveFile = File(siteDbPath);
        final bakPath = '$siteDbPath.bak';
        final liveExists = await liveFile.exists();
        if (liveExists) await liveFile.copy(bakPath);
        try {
          await File(tempPath).rename(siteDbPath);
        } catch (e) {
          if (!await liveFile.exists() && liveExists) {
            try {
              await File(bakPath).copy(siteDbPath);
            } catch (_) {}
          }
          try {
            await File(tempPath).delete();
          } catch (_) {}
          return SiteLibrarySegmentResult(
            segment: seg,
            ok: false,
            error: '站点库段换库失败：$e（已恢复原库）',
          );
        }
        final count = _siteStationCounts[plan.payloadSha256] ?? 0;
        return SiteLibrarySegmentResult(
          segment: seg,
          ok: true,
          detail: '$count 个站',
        );
      }
      final segmentDbPath = '$workDir/segment_$seg.db';
      await _materializer.materialize(
        stagingPath: stagingPath,
        segment: seg,
        targetPath: segmentDbPath,
      );
      try {
        await _segmentDbPostProcess(seg, segmentDbPath);
        final landed = seg == 'actress'
            ? await _actressLander(segmentDbPath)
            : await _magnetLander(segmentDbPath);
        return SiteLibrarySegmentResult(
          segment: seg,
          ok: landed.ok,
          error: landed.error,
          detail: landed.detail,
        );
      } finally {
        try {
          await File(segmentDbPath).delete();
        } catch (_) {}
      }
    } catch (e) {
      return SiteLibrarySegmentResult(
        segment: seg,
        ok: false,
        error: '${SiteLibrarySegmentResult(segment: seg, ok: false).segmentLabel}'
            '段落位失败：${e.toString().split('\n').first}',
      );
    }
  }

  static String _sqlText(String value) => value.replaceAll("'", "''");

  /// 流式执行整文件进 staging（与单段导入器同款分批/过滤口径：
  /// BEGIN/COMMIT 跳过、统计语句过滤、INSERT 攒批）。
  Future<void> _stageFile({
    required SiteLibrarySqlExecutor executor,
    required File sqlFile,
    required String sqlPath,
    required void Function(SiteLibraryProgress) onProgress,
    bool Function()? isCancelled,
  }) async {
    await executor.execute('PRAGMA foreign_keys=OFF');
    final totalBytes = await sqlFile.length();
    var statements = 0;
    var bytesRead = 0;
    var lastReportedBytes = 0;
    final splitter = SiteLibrarySqlSplitter();
    final pendingInserts = <String>[];

    Future<void> flushInserts() async {
      if (pendingInserts.isEmpty) return;
      final batch = List<String>.of(pendingInserts);
      pendingInserts.clear();
      await executor.executeBatch(batch);
      statements += batch.length;
      onProgress(
        SiteLibraryProgress(
          phase: '正在导入',
          statements: statements,
          bytesRead: bytesRead,
          totalBytes: totalBytes,
        ),
      );
    }

    void checkCancelled() {
      if (isCancelled != null && isCancelled()) {
        throw SiteLibraryImportCancelled();
      }
    }

    Stream<List<int>> byteStream = sqlFile.openRead();
    if (sqlPath.toLowerCase().endsWith('.gz')) {
      byteStream = byteStream.transform(gzip.decoder);
    }
    final lines = byteStream
        .map((chunk) {
          bytesRead += chunk.length;
          return chunk;
        })
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      checkCancelled();
      for (final statement in splitter.addLine(line)) {
        final head = _statementHead(statement);
        if (head == 'BEGIN' || head == 'COMMIT') continue;
        if (_isStatisticsStatement(statement, head)) continue;
        if (head == 'INSERT') {
          pendingInserts.add(statement);
          if (pendingInserts.length >= batchSize) {
            await flushInserts();
            checkCancelled();
          }
        } else {
          await flushInserts();
          await executor.execute(statement);
          statements++;
        }
      }
      if (bytesRead - lastReportedBytes >= 1024 * 1024) {
        lastReportedBytes = bytesRead;
        onProgress(
          SiteLibraryProgress(
            phase: '正在导入',
            statements: statements,
            bytesRead: bytesRead,
            totalBytes: totalBytes,
          ),
        );
      }
    }
    final tail = splitter.flush();
    if (tail != null) {
      final head = _statementHead(tail);
      if (head != 'BEGIN' &&
          head != 'COMMIT' &&
          !_isStatisticsStatement(tail, head)) {
        if (head == 'INSERT') {
          pendingInserts.add(tail);
        } else {
          await executor.execute(tail);
          statements++;
        }
      }
    }
    await flushInserts();
    checkCancelled();
  }

  static bool _isStatisticsStatement(String statement, String head) {
    if (head == 'ANALYZE') return true;
    if (head != 'INSERT') return false;
    return RegExp(
      r'''^\s*INSERT\s+INTO\s+["'\[\`]?\s*sqlite_stat1\b''',
      caseSensitive: false,
    ).hasMatch(statement);
  }

  static String _statementHead(String statement) {
    final text = statement.trimLeft().replaceFirst(RegExp(r';\s*$'), '');
    final end = text.indexOf(RegExp(r'\s|\('));
    return (end < 0 ? text : text.substring(0, end)).toUpperCase();
  }
}
