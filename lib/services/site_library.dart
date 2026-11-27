import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'live_sources.dart';
import 'site_library_bundle.dart';

/// 站点库服务层（2026-11-27 站点库批）：独立第三库，物理文件落在
/// 应用支持目录 `site_library/site_library.db`，与女优库双槽完全
/// 隔离（不占槽、没有切换语义，只有导入/重导/删除三动作）。
/// 绝不使用 `MYTV/db/站点库.db`——那个名字已被播放记录库占用。
///
/// 导入链照女优库 .sql 导入的「流式执行＋先验后换」骨架，但校验器
/// 独立且更严：站点库是代码分发（一份 .sql ＝一份任意代码执行
/// 授权），必须验整库内容哈希（payload_sha256）与 HMAC 签名，
/// 还要逐行验 code_sha256 与 code_text 实算一致；任一项不过整库
/// 拒、旧库一字不动。
///
/// 本文件自带拆分器/执行器抽象（不跨域 import 女优库的类），
/// 测试可注入假执行器。

/// 站点库签名密钥（与生成器钉死）：HMAC-SHA256 的 key。
const siteLibrarySignKey = 'xiuxian-site-library-v1';

/// 本软件支持的站点库格式版本（manifest.format_version 必须等于它）。
const siteLibrarySupportedFormatVersion = '1';

/// 本软件的核心版本（manifest.core_version 必须等于它）。
/// 可由 SiteLibraryService 构造注入覆盖（测试/将来升版用）。
const siteLibraryDefaultCoreVersion = '2026.11.27';

/// ext 直带上限：超过这个长度的 ext 落盘成文件，条目里只留路径。
const siteLibraryExtInlineLimit = 4096;

/// 计算整库内容哈希（与生成器口径钉死）：
/// parts ＝ 每站 `S|{site_id}|{kind}|{name}` ＋ 每代码行
/// `C|{site_id}|{code_sha256}` ＋ 每资产 `A|{asset_id}|{md5}`
/// ＋ 清单行 `M|{format_version}|{core_version}|{library_version}`；
/// 全 parts 按 UTF-8 字节序排序、'\n' 连接、UTF-8 取 sha256 hex。
/// 版本三字段在签名范围内：篡改任一版本字段，payload 都对不上。
String computeSiteLibraryPayloadSha256({
  required Iterable<({String siteId, String kind, String name})> stations,
  required Iterable<({String siteId, String codeSha256})> codes,
  required Iterable<({String assetId, String md5})> assets,
  required ({
    String formatVersion,
    String coreVersion,
    String libraryVersion,
  })
  manifest,
}) {
  final parts = <String>[
    for (final s in stations) 'S|${s.siteId}|${s.kind}|${s.name}',
    for (final c in codes) 'C|${c.siteId}|${c.codeSha256}',
    for (final a in assets) 'A|${a.assetId}|${a.md5}',
    'M|${manifest.formatVersion}|${manifest.coreVersion}'
        '|${manifest.libraryVersion}',
  ];
  parts.sort(_compareUtf8Bytes);
  return sha256.convert(utf8.encode(parts.join('\n'))).toString();
}

/// 对 payload_sha256 的 HMAC-SHA256 签名（hex）。
String computeSiteLibrarySignature(String payloadSha256) {
  return Hmac(
    sha256,
    utf8.encode(siteLibrarySignKey),
  ).convert(utf8.encode(payloadSha256)).toString();
}

/// UTF-8 字节序比较（不能用 Dart 默认的字符串序：默认按 UTF-16
/// 码元排，与生成器的字节序在非 ASCII 站名上会分叉）。
int _compareUtf8Bytes(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  final n = x.length < y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    if (x[i] != y[i]) return x[i] - y[i];
  }
  return x.length - y.length;
}

/// 导入进度：阶段 + 已执行语句数 + 已读字节 + 文件总字节。
/// 与女优库同款形态。
class SiteLibraryProgress {
  const SiteLibraryProgress({
    required this.phase,
    required this.statements,
    required this.bytesRead,
    required this.totalBytes,
  });

  final String phase;
  final int statements;
  final int bytesRead;
  final int totalBytes;

  double get fraction =>
      totalBytes <= 0 ? 0 : (bytesRead / totalBytes).clamp(0, 1);
}

/// 合并文件里一段的落位结果（分段导入器产出）：[segment] 是
/// site/actress/magnet，[ok] 为该段是否落位成功，失败时 [error]
/// 是中文拒因（只拒该段、别段照常）；[detail] 是成功时的人话
/// 计数（如「639 个站」「作品 449,339」），供管理页逐段回报。
class SiteLibrarySegmentResult {
  const SiteLibrarySegmentResult({
    required this.segment,
    required this.ok,
    this.error,
    this.detail,
  });

  final String segment;
  final bool ok;
  final String? error;
  final String? detail;

  /// 段的人话名（界面用）。
  String get segmentLabel => switch (segment) {
    'site' => '站点库',
    'actress' => '演员库',
    'magnet' => '磁力库',
    _ => segment,
  };
}

/// 导入结果：失败时 [error] 为中文原因、旧库不动。
/// 合并文件导入时 [segmentResults] 逐段带结果（整文件签名不过
/// 时为空、只有一条全拒原因）；单段文件导入时为空。
class SiteLibraryImportOutcome {
  const SiteLibraryImportOutcome({
    required this.ok,
    this.error,
    this.stationCount = 0,
    this.libraryVersion,
    this.segmentResults = const [],
  });

  final bool ok;
  final String? error;
  final int stationCount;
  final String? libraryVersion;
  final List<SiteLibrarySegmentResult> segmentResults;
}

/// 站点库里的一站（stations 主表＋station_code 分表合并后的视图）。
class SiteLibraryStation {
  const SiteLibraryStation({
    required this.siteId,
    required this.canonId,
    required this.name,
    required this.kind,
    required this.zone,
    required this.contentType,
    required this.isAdult,
    required this.sortOrder,
    this.verifyNote,
    this.fileName,
    this.codeSha256,
    this.className,
    this.jarAssetId,
    this.ext,
    this.codeFilePath,
    this.extFilePath,
  });

  /// 库内稳定 id（stations.site_id）。
  final String siteId;

  /// 归一后的裸 id（canon_id 列；缺列/为空时回落 siteId）。
  final String canonId;

  final String name;

  /// pyImport/legadoImport/jarImport/nativeGate/liveM3u/livePlatform。
  final String kind;

  /// 分区：video/drama/novel/comic/audio/live。
  final String zone;

  final String? contentType;
  final bool isAdult;
  final int sortOrder;
  final String? verifyNote;

  /// station_code 侧字段（jar 站可只有 className/jarAssetId）。
  final String? fileName;
  final String? codeSha256;
  final String? className;
  final String? jarAssetId;

  /// 小 ext 直带；大 ext 落盘后为 null，看 [extFilePath]。
  final String? ext;

  /// code_text 按哈希落盘后的本地路径（无代码行为 null）。
  final String? codeFilePath;

  /// 大 ext 落盘路径（ext 直带时为 null）。
  final String? extFilePath;
}

/// 随包名单（roster.json）一行：只有名/分区/成人/排序/kind，
/// 不含任何代码。
class SiteLibraryRosterEntry {
  const SiteLibraryRosterEntry({
    required this.id,
    required this.name,
    required this.zone,
    required this.adult,
    required this.sort,
    required this.kind,
  });

  /// 归一后的裸 id（canon）。
  final String id;
  final String name;
  final String zone;
  final bool adult;
  final int sort;
  final String kind;
}

/// 解析名单文本：顶层可以是数组，也可以是带 stations/roster
/// 数组的对象。坏行跳过，不整份失败。
List<SiteLibraryRosterEntry> parseSiteLibraryRoster(String text) {
  final decoded = jsonDecode(text);
  final List<dynamic> rows;
  if (decoded is List) {
    rows = decoded;
  } else if (decoded is Map) {
    final inner = decoded['stations'] ?? decoded['roster'];
    rows = inner is List ? inner : const [];
  } else {
    rows = const [];
  }
  final out = <SiteLibraryRosterEntry>[];
  for (final raw in rows) {
    if (raw is! Map) continue;
    final id = '${raw['id'] ?? raw['canon_id'] ?? raw['canonId'] ?? ''}'
        .trim();
    if (id.isEmpty) continue;
    final adultRaw = raw['adult'] ?? raw['is_adult'] ?? raw['isAdult'];
    out.add(
      SiteLibraryRosterEntry(
        id: id,
        name: '${raw['name'] ?? id}',
        zone: '${raw['zone'] ?? 'video'}',
        adult: adultRaw == true || adultRaw == 1 || adultRaw == '1',
        sort: (raw['sort'] as num?)?.toInt() ??
            (raw['sort_order'] as num?)?.toInt() ??
            (raw['sortOrder'] as num?)?.toInt() ??
            0,
        kind: '${raw['kind'] ?? ''}',
      ),
    );
  }
  return out;
}

/// SQL 语句切分器（本站点库自带一份，逻辑与女优库导入同款：
/// 只认单引号字符串里的分号、`''` 是转义、跨行字符串认、
/// `--` 只在字符串外才是行注释）。
class SiteLibrarySqlSplitter {
  final _buffer = StringBuffer();
  var _inString = false;

  List<String> addLine(String line) {
    final out = <String>[];
    var i = 0;
    while (i < line.length) {
      final c = line[i];
      if (_inString) {
        if (c == "'") {
          if (i + 1 < line.length && line[i + 1] == "'") {
            _buffer.write("''");
            i += 2;
            continue;
          }
          _inString = false;
        }
        _buffer.write(c);
        i++;
        continue;
      }
      if (c == '-' && i + 1 < line.length && line[i + 1] == '-') {
        break;
      }
      if (c == "'") {
        _inString = true;
        _buffer.write(c);
        i++;
        continue;
      }
      if (c == ';') {
        _buffer.write(c);
        final statement = _buffer.toString().trim();
        _buffer.clear();
        if (statement.isNotEmpty) out.add(statement);
        i++;
        continue;
      }
      _buffer.write(c);
      i++;
    }
    if (_inString) _buffer.write('\n');
    return out;
  }

  String? flush() {
    final rest = _buffer.toString().trim();
    _buffer.clear();
    _inString = false;
    return rest.isEmpty ? null : rest;
  }
}

/// 站点库 SQL 执行器抽象：生产用 sqflite，测试用假实现。
abstract class SiteLibrarySqlExecutor {
  Future<void> execute(String sql);
  Future<void> executeBatch(List<String> statements);
  Future<List<Map<String, Object?>>> query(String sql);
  Future<void> close();
}

/// sqflite 实现：批处理走 Batch，一次通道调用交一整批。
class SqfliteSiteLibraryExecutor implements SiteLibrarySqlExecutor {
  SqfliteSiteLibraryExecutor(this._db);

  final Database _db;

  @override
  Future<void> execute(String sql) => _db.execute(sql);

  @override
  Future<void> executeBatch(List<String> statements) async {
    final batch = _db.batch();
    for (final statement in statements) {
      batch.execute(statement);
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql) => _db.rawQuery(sql);

  @override
  Future<void> close() => _db.close();
}

/// 取消导入时抛这个，调用方按“已取消，数据库未改动”收尾。
class SiteLibraryImportCancelled implements Exception {}

/// 站点库 .sql 导入器：流式执行到临时库（分批事务）→ 打开临时库
/// 全量校验 → 旧库改 .bak → 临时库就位。失败/取消：临时文件删、
/// 旧库一字不动。
class SiteLibraryImporter {
  SiteLibraryImporter({
    this.batchSize = 1000,
    this.currentCoreVersion = siteLibraryDefaultCoreVersion,
    this.supportedFormatVersion = siteLibrarySupportedFormatVersion,
    Future<SiteLibrarySqlExecutor> Function(String tempPath)?
    executorFactory,
  }) : _executorFactory =
           executorFactory ??
           ((tempPath) async {
             final db = await openDatabase(
               tempPath,
               singleInstance: false,
             );
             return SqfliteSiteLibraryExecutor(db);
           });

  final int batchSize;

  /// 版本门：manifest.core_version 必须等于它（当前软件核心版本）。
  final String currentCoreVersion;

  /// 版本门：manifest.format_version 必须等于它。
  final String supportedFormatVersion;

  final Future<SiteLibrarySqlExecutor> Function(String tempPath)
  _executorFactory;

  /// 把 .sql / .sql.gz 流式执行进临时库并校验，成功才顶替
  /// [dbPath]。本方法不关任何已有连接：调用方（服务层）的读连接
  /// 是短开短关的，换名时没有连接占着目标文件。
  Future<SiteLibraryImportOutcome> importFile({
    required String sqlPath,
    required String dbPath,
    required void Function(SiteLibraryProgress) onProgress,
    bool Function()? isCancelled,
  }) async {
    final sqlFile = File(sqlPath);
    if (dbPath.isEmpty) {
      return const SiteLibraryImportOutcome(
        ok: false,
        error: '没有可替换的数据库路径',
      );
    }
    if (!await sqlFile.exists() || await sqlFile.length() == 0) {
      return const SiteLibraryImportOutcome(
        ok: false,
        error: '选中的文件不存在或为空',
      );
    }
    final lower = sqlPath.toLowerCase();
    final isGz = lower.endsWith('.gz');
    if (!lower.endsWith('.sql') && !isGz) {
      return const SiteLibraryImportOutcome(
        ok: false,
        error: '只认 .sql 或 .sql.gz 文件',
      );
    }
    final totalBytes = await sqlFile.length();
    final tempPath = '$dbPath.importing';
    final tempFile = File(tempPath);
    try {
      if (await tempFile.exists()) await tempFile.delete();
    } catch (_) {
      return const SiteLibraryImportOutcome(
        ok: false,
        error: '临时库文件删不掉，请先确认没有别的导入在跑',
      );
    }

    SiteLibrarySqlExecutor? executor;
    try {
      executor = await _executorFactory(tempPath);
      await executor.execute('PRAGMA foreign_keys=OFF');
      var statements = 0;
      var bytesRead = 0;
      var lastReportedBytes = 0;
      final splitter = SiteLibrarySqlSplitter();
      final pendingInserts = <String>[];

      Future<void> flushInserts() async {
        if (pendingInserts.isEmpty) return;
        final batch = List<String>.of(pendingInserts);
        pendingInserts.clear();
        await executor!.executeBatch(batch);
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
      if (isGz) byteStream = byteStream.transform(gzip.decoder);
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

      onProgress(
        SiteLibraryProgress(
          phase: '正在校验',
          statements: statements,
          bytesRead: bytesRead,
          totalBytes: totalBytes,
        ),
      );
      final validated = await _validate(executor);
      checkCancelled();
      await executor.close();
      executor = null;

      // 换库：备份现库为 .bak → 临时库改名顶替。
      final liveFile = File(dbPath);
      final bakPath = '$dbPath.bak';
      final liveExists = await liveFile.exists();
      if (liveExists) {
        await liveFile.copy(bakPath);
      }
      try {
        await tempFile.rename(dbPath);
      } catch (e) {
        if (!await liveFile.exists() && liveExists) {
          try {
            await File(bakPath).copy(dbPath);
          } catch (_) {}
        }
        return SiteLibraryImportOutcome(
          ok: false,
          error: '换库失败：$e（已恢复原库）',
        );
      }
      return SiteLibraryImportOutcome(
        ok: true,
        stationCount: validated.count,
        libraryVersion: validated.version,
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
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
    }
  }

  /// 全量校验（还在临时库上，不合格抛中文错、旧库不动）：
  /// format/版本对 → station_count 与 manifest 一致 → 每行
  /// code_sha256 与 code_text 实算一致 → payload 重算一致 →
  /// HMAC 验签（缺失/不符整库拒）。
  Future<({String version, int count})> _validate(
    SiteLibrarySqlExecutor executor,
  ) async {
    Map<String, String> meta;
    try {
      final metaRows = await executor.query(
        'SELECT key, value FROM schema_meta',
      );
      meta = {
        for (final row in metaRows) '${row['key']}': '${row['value']}',
      };
    } catch (_) {
      throw StateError('站点库结构不完整：读不到 schema_meta，不是站点库');
    }
    if (meta['format'] != 'site_library') {
      throw StateError('不是站点库（format 不对）');
    }
    if (meta['schema_version'] != '1') {
      throw StateError('站点库版本不受支持：${meta['schema_version'] ?? '未知'}');
    }
    List<Map<String, Object?>> manifestRows;
    List<Map<String, Object?>> stationRows;
    List<Map<String, Object?>> codeRows;
    List<Map<String, Object?>> assetRows;
    try {
      manifestRows = await executor.query(
        'SELECT library_version, station_count, payload_sha256, '
        'signature, format_version, core_version '
        'FROM manifest WHERE id=1',
      );
      stationRows = await executor.query(
        'SELECT site_id, kind, name FROM stations',
      );
      codeRows = await executor.query(
        'SELECT site_id, code_sha256, code_text FROM station_code',
      );
      assetRows = await executor.query(
        'SELECT asset_id, md5 FROM station_assets',
      );
    } catch (_) {
      throw StateError('站点库结构不完整：缺表或缺列，不是完整的站点库');
    }
    if (manifestRows.isEmpty) {
      throw StateError('站点库缺清单行（manifest），已拒绝');
    }
    final manifest = manifestRows.first;
    final version = '${manifest['library_version'] ?? ''}';
    final declaredCount =
        (manifest['station_count'] as num?)?.toInt() ?? -1;
    if (declaredCount != stationRows.length) {
      throw StateError(
        '站数对不上：清单写 $declaredCount、实际 ${stationRows.length}，已拒绝',
      );
    }
    final metaCount = int.tryParse(meta['station_count'] ?? '');
    if (metaCount != null && metaCount != stationRows.length) {
      throw StateError('站数对不上：库信息与实际不一致，已拒绝');
    }
    for (final row in codeRows) {
      final codeText = row['code_text'];
      if (codeText == null) continue;
      final actual = sha256.convert(utf8.encode('$codeText')).toString();
      if (actual != '${row['code_sha256']}') {
        throw StateError('代码哈希对不上：${row['site_id']}，已拒绝整库');
      }
    }
    final formatVersion = manifest['format_version'];
    final coreVersion = manifest['core_version'];
    final payload = computeSiteLibraryPayloadSha256(
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
        formatVersion: '${formatVersion ?? ''}',
        coreVersion: '${coreVersion ?? ''}',
        libraryVersion: version,
      ),
    );
    if (payload != '${manifest['payload_sha256']}') {
      throw StateError('整库内容哈希对不上，已拒绝（文件可能被改过）');
    }
    final signature = manifest['signature'];
    if (signature == null || '$signature'.isEmpty) {
      throw StateError('站点库没有签名，已拒绝');
    }
    if ('$signature' != computeSiteLibrarySignature(payload)) {
      throw StateError('站点库签名不对，已拒绝');
    }
    // 版本门（与哈希/验签同层）：签名验过说明版本字段是生成器
    // 原样写下的，此时版本对不上就是库与软件不配套，整库拒、
    // 原因写明两边版本。放在验签之后，篡改版本字段会先死在
    // payload 对不上那一步。
    if ('${formatVersion ?? ''}' != supportedFormatVersion) {
      throw StateError(
        '站点库格式版本 ${formatVersion ?? '未知'} 与当前软件支持的 '
        '$supportedFormatVersion 不符，已拒绝',
      );
    }
    if ('${coreVersion ?? ''}' != currentCoreVersion) {
      throw StateError(
        '站点库要求核心版本 ${coreVersion ?? '未知'}，'
        '当前软件版本是 $currentCoreVersion，不匹配，已拒绝',
      );
    }
    return (version: version, count: stationRows.length);
  }

  /// 查询优化器统计语句整类过滤（与女优库同口径）：ANALYZE 与
  /// 往 sqlite_stat1 的 INSERT 不执行、不计数。
  static bool _isStatisticsStatement(String statement, String head) {
    if (head == 'ANALYZE') return true;
    if (head != 'INSERT') return false;
    return RegExp(
      r'''^\s*INSERT\s+INTO\s+["'\[\`]?\s*sqlite_stat1\b''',
      caseSensitive: false,
    ).hasMatch(statement);
  }

  /// 语句头一个词（先去尾部分号，理由同女优库导入器注释）。
  static String _statementHead(String statement) {
    final text = statement.trimLeft().replaceFirst(RegExp(r';\s*$'), '');
    final end = text.indexOf(RegExp(r'\s|\('));
    return (end < 0 ? text : text.substring(0, end)).toUpperCase();
  }
}

/// 站点库服务：读盘加载、名单、导入、删除的状态机。
/// 注册链（SourceRegistry.syncSqlSites）按本类 API 取数。
class SiteLibraryService {
  SiteLibraryService({
    Future<Directory> Function()? supportDirectoryProvider,
    SiteLibraryImporter? importer,
    this._bundleImporter,
    Future<SiteLibrarySqlExecutor> Function(String path)? readExecutorFactory,
    Future<String> Function(String assetPath)? assetLoader,
    this.currentCoreVersion = siteLibraryDefaultCoreVersion,
    this.supportedFormatVersion = siteLibrarySupportedFormatVersion,
  }) : _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory,
       _importer =
           importer ??
           SiteLibraryImporter(
             currentCoreVersion: currentCoreVersion,
             supportedFormatVersion: supportedFormatVersion,
           ),
       _readExecutorFactory =
           readExecutorFactory ??
           ((path) async {
             final db = await openDatabase(
               path,
               readOnly: true,
               singleInstance: false,
             );
             return SqfliteSiteLibraryExecutor(db);
           }),
       _assetLoader = assetLoader ?? rootBundle.loadString;

  static SiteLibraryService get instance => _shared;
  static final SiteLibraryService _shared = SiteLibraryService();

  /// 当前软件核心版本（可注入）：库的 core_version 必须等于它。
  final String currentCoreVersion;

  /// 支持的站点库格式版本：库的 format_version 必须等于它。
  final String supportedFormatVersion;

  final Future<Directory> Function() _supportDirectoryProvider;
  final SiteLibraryImporter _importer;

  /// 合并文件分段导入器（可注入；缺省按需现建，版本口径随服务）。
  final SiteLibraryBundleImporter? _bundleImporter;
  final Future<SiteLibrarySqlExecutor> Function(String path)
  _readExecutorFactory;
  final Future<String> Function(String assetPath) _assetLoader;

  var _imported = false;
  String? _libraryVersion;
  var _stations = <SiteLibraryStation>[];
  var _libraryFileSizeBytes = 0;
  String? _loadRejectionReason;

  /// 文件戳缓存：mtime+size 未变且已加载过，load() 跳过全量读。
  String? _stamp;

  List<SiteLibraryRosterEntry>? _rosterCache;

  bool get imported => _imported;

  String? get libraryVersion => _libraryVersion;

  /// 已落盘库未被激活的原因（中文）：版本不符时 load() 写这里，
  /// 文件保留不删、供排查与管理页状态卡显示；正常/未导入时为 null。
  String? get loadRejectionReason => _loadRejectionReason;

  List<SiteLibraryStation> get stations =>
      List.unmodifiable(_stations);

  /// 当前库文件大小（字节；未导入为 0），load() 时刷新。
  int get libraryFileSizeBytes => _libraryFileSizeBytes;

  Future<Directory> _libraryDir() async {
    final support = await _supportDirectoryProvider();
    return Directory('${support.path}/site_library');
  }

  /// 管理页收件文件：选中的文件先拷到这里再导（选择器给的路径
  /// 是临时作用域路径，导入是长任务，先落地，与女优库同款）。
  Future<File> inboxFileFor(String pickedName) async {
    final dir = await _libraryDir();
    await dir.create(recursive: true);
    final safe = pickedName.replaceAll(RegExp(r'[^\w.\-]'), '_');
    return File('${dir.path}/inbox_$safe');
  }

  /// 读盘加载：库文件在 `<appSupport>/site_library/site_library.db`。
  /// 存在则打开验 schema_meta/manifest（带文件戳缓存）、读
  /// stations、把 code_text 按哈希落盘、组装 LiveSources.sqlSources；
  /// 不存在则 imported=false、sqlSources 清空（名单态）。
  Future<void> load({bool force = false}) async {
    final dir = await _libraryDir();
    final dbFile = File('${dir.path}/site_library.db');
    if (!await dbFile.exists()) {
      _resetState();
      LiveSources.sqlSources = [];
      return;
    }
    final stat = await dbFile.stat();
    final stamp =
        '${stat.modified.millisecondsSinceEpoch}:${stat.size}';
    if (!force && _imported && _stamp == stamp) return;
    SiteLibrarySqlExecutor? executor;
    try {
      executor = await _readExecutorFactory(dbFile.path);
      final metaRows = await executor.query(
        'SELECT key, value FROM schema_meta',
      );
      final meta = {
        for (final row in metaRows) '${row['key']}': '${row['value']}',
      };
      if (meta['format'] != 'site_library') {
        _resetState();
        LiveSources.sqlSources = [];
        return;
      }
      final manifestRows = await executor.query(
        'SELECT library_version, format_version, core_version '
        'FROM manifest WHERE id=1',
      );
      final version = manifestRows.isEmpty
          ? null
          : '${manifestRows.first['library_version']}';
      // 版本门：已落盘库版本不符就不激活（文件保留不删，供排查），
      // 原因写进 loadRejectionReason 给管理页状态卡显示。
      final rejection = manifestRows.isEmpty
          ? '站点库缺清单行（manifest）'
          : _versionRejection(
              formatVersion: manifestRows.first['format_version'],
              coreVersion: manifestRows.first['core_version'],
            );
      if (rejection != null) {
        _resetState();
        _loadRejectionReason = rejection;
        LiveSources.sqlSources = [];
        return;
      }
      final stationRows = await executor.query(
        'SELECT site_id, canon_id, name, kind, zone, content_type, '
        'is_adult, sort_order, verify_note FROM stations '
        'ORDER BY sort_order, name',
      );
      final codeRows = await executor.query(
        'SELECT site_id, file_name, code_text, code_sha256, ext, '
        'class_name, jar_asset_id FROM station_code',
      );
      final codeBySite = {
        for (final row in codeRows) '${row['site_id']}': row,
      };
      final stations = <SiteLibraryStation>[];
      for (final row in stationRows) {
        stations.add(
          await _materializeStation(dir, row, codeBySite['${row['site_id']}']),
        );
      }
      _stations = stations;
      _imported = true;
      _loadRejectionReason = null;
      _libraryVersion = version;
      _libraryFileSizeBytes = stat.size;
      _stamp = stamp;
      await _assembleLiveSources();
    } catch (_) {
      // 库打不开/结构不对：回名单态，不让坏库拖死启动。
      _resetState();
      LiveSources.sqlSources = [];
    } finally {
      try {
        await executor?.close();
      } catch (_) {}
    }
    // 名单缓存顺带预热（gatedNativeIds 依赖它），失败不挡加载。
    try {
      await roster();
    } catch (_) {}
  }

  /// 一站落盘：code_text 写到 `code/<code_sha256>/<file_name>`
  /// （已存在跳过）；ext 超长写 `code/<code_sha256>.ext` 文件。
  Future<SiteLibraryStation> _materializeStation(
    Directory dir,
    Map<String, Object?> row,
    Map<String, Object?>? codeRow,
  ) async {
    final siteId = '${row['site_id']}';
    final canonRaw = row['canon_id'];
    final canonId = canonRaw == null || '$canonRaw'.isEmpty
        ? siteId
        : '$canonRaw';
    String? fileName;
    String? codeSha256;
    String? className;
    String? jarAssetId;
    String? ext;
    String? codeFilePath;
    String? extFilePath;
    if (codeRow != null) {
      fileName = _nullableText(codeRow['file_name']);
      codeSha256 = _nullableText(codeRow['code_sha256']);
      className = _nullableText(codeRow['class_name']);
      jarAssetId = _nullableText(codeRow['jar_asset_id']);
      ext = _nullableText(codeRow['ext']);
      final codeText = _nullableText(codeRow['code_text']);
      final hashKey = (codeSha256 != null && codeSha256.isNotEmpty)
          ? codeSha256
          : siteId;
      if (codeText != null) {
        final codeDir = Directory('${dir.path}/code/$hashKey');
        final target = File(
          '${codeDir.path}/${fileName ?? 'code.txt'}',
        );
        if (!await target.exists()) {
          await codeDir.create(recursive: true);
          await target.writeAsString(codeText);
        }
        codeFilePath = target.path;
      }
      if (ext != null && ext.length > siteLibraryExtInlineLimit) {
        final extTarget = File('${dir.path}/code/$hashKey.ext');
        if (!await extTarget.exists()) {
          await Directory('${dir.path}/code').create(recursive: true);
          await extTarget.writeAsString(ext);
        }
        extFilePath = extTarget.path;
        ext = null;
      }
    }
    return SiteLibraryStation(
      siteId: siteId,
      canonId: canonId,
      name: '${row['name'] ?? siteId}',
      kind: '${row['kind'] ?? ''}',
      zone: '${row['zone'] ?? 'video'}',
      contentType: _nullableText(row['content_type']),
      isAdult: row['is_adult'] == 1 || row['is_adult'] == true,
      sortOrder: (row['sort_order'] as num?)?.toInt() ?? 0,
      verifyNote: _nullableText(row['verify_note']),
      fileName: fileName,
      codeSha256: codeSha256,
      className: className,
      jarAssetId: jarAssetId,
      ext: ext,
      codeFilePath: codeFilePath,
      extFilePath: extFilePath,
    );
  }

  /// 组装直播 SQL 源：liveM3u 的端点＝落盘文件路径；livePlatform
  /// 按 ext JSON 还原 LiveSource（ext 落盘时先读文件）。
  Future<void> _assembleLiveSources() async {
    final sources = <LiveSource>[];
    for (final station in _stations) {
      if (station.kind == 'liveM3u') {
        final path = station.codeFilePath;
        if (path == null) continue;
        sources.add(
          LiveSource(
            id: station.siteId,
            name: station.name,
            description: station.verifyNote ?? '站点库直播清单 · 点开即播',
            protocol: LiveProtocol.list,
            endpoints: [path],
            group: station.name,
            adult: station.isAdult,
          ),
        );
      } else if (station.kind == 'livePlatform') {
        var extText = station.ext;
        if (extText == null && station.extFilePath != null) {
          try {
            extText = await File(station.extFilePath!).readAsString();
          } catch (_) {
            extText = null;
          }
        }
        if (extText == null) continue;
        final restored = liveSourceFromExtJson(
          siteId: station.siteId,
          fallbackName: station.name,
          fallbackAdult: station.isAdult,
          extJson: extText,
        );
        if (restored != null) sources.add(restored);
      }
    }
    LiveSources.sqlSources = sources;
  }

  /// 读随包名单 assets/site_library/roster.json（解析后缓存）。
  Future<List<SiteLibraryRosterEntry>> roster() async {
    final cached = _rosterCache;
    if (cached != null) return cached;
    List<SiteLibraryRosterEntry> parsed;
    try {
      final text = await _assetLoader('assets/site_library/roster.json');
      parsed = parseSiteLibraryRoster(text);
    } catch (_) {
      parsed = const [];
    }
    _rosterCache = parsed;
    return parsed;
  }

  /// 预加载名单（gatedNativeIds 是同步 getter，靠这份缓存）。
  Future<void> loadRoster() async {
    await roster();
  }

  /// 名单里 kind=='nativeGate' 的 canon 集（原生门禁站名单）。
  /// 名单还没加载完时返回空集——先调 load()/roster() 预热；
  /// load() 结束时已顺带预热名单。
  Set<String> get gatedNativeIds {
    final cached = _rosterCache;
    if (cached == null) {
      unawaited(roster());
      return const {};
    }
    return {
      for (final entry in cached)
        if (entry.kind == 'nativeGate') entry.id,
    };
  }

  bool isGatedNative(String id) => gatedNativeIds.contains(id);

  /// 导入本地 .sql/.sql.gz：流式执行到临时库→全量校验（含验签）
  /// →先验后换→load() 刷新。失败/取消旧库一字不动。
  /// 文件是合并文件（三段）时先粗扫分流到分段导入器：站点段
  /// 落本站点库、演员段喂女优库导入槽、磁力段并存合并；粗扫
  /// 误报（查无 bundle_manifest 表）时分段导入器回 null，照旧
  /// 走单段路，单段文件行为一字不变。
  Future<SiteLibraryImportOutcome> importLocalFile({
    required String localPath,
    void Function(SiteLibraryProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final dir = await _libraryDir();
    await dir.create(recursive: true);
    var maybeBundle = false;
    try {
      maybeBundle = await SiteLibraryBundleImporter.mightBeBundle(localPath);
    } catch (_) {
      maybeBundle = false;
    }
    if (maybeBundle) {
      final bundleImporter =
          _bundleImporter ??
          SiteLibraryBundleImporter(
            currentCoreVersion: currentCoreVersion,
            supportedFormatVersion: supportedFormatVersion,
          );
      final bundleOutcome = await bundleImporter.importBundle(
        sqlPath: localPath,
        siteDbPath: '${dir.path}/site_library.db',
        workDir: dir.path,
        onProgress: onProgress ?? (_) {},
        isCancelled: isCancelled,
      );
      if (bundleOutcome != null) {
        final siteLanded = bundleOutcome.segmentResults.any(
          (r) => r.segment == 'site' && r.ok,
        );
        if (siteLanded) {
          _stamp = null;
          await load(force: true);
        }
        return bundleOutcome;
      }
      // 粗扫误报：不是合并文件，落回单段路。
    }
    final outcome = await _importer.importFile(
      sqlPath: localPath,
      dbPath: '${dir.path}/site_library.db',
      onProgress: onProgress ?? (_) {},
      isCancelled: isCancelled,
    );
    if (outcome.ok) {
      _stamp = null;
      await load(force: true);
    }
    return outcome;
  }

  /// 删除站点库：删库文件与落盘代码目录，回名单态。
  /// 只动 site_library 目录，女优库任何文件不碰。
  Future<void> deleteLibrary() async {
    final dir = await _libraryDir();
    for (final name in [
      'site_library.db',
      'site_library.db.bak',
      'site_library.db.importing',
    ]) {
      try {
        final file = File('${dir.path}/$name');
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    try {
      final codeDir = Directory('${dir.path}/code');
      if (await codeDir.exists()) {
        await codeDir.delete(recursive: true);
      }
    } catch (_) {}
    _resetState();
    LiveSources.sqlSources = [];
  }

  void _resetState() {
    _imported = false;
    _libraryVersion = null;
    _stations = [];
    _libraryFileSizeBytes = 0;
    _stamp = null;
    _loadRejectionReason = null;
  }

  /// 版本门判定：两边版本都写进中文原因；都对返回 null。
  String? _versionRejection({
    required Object? formatVersion,
    required Object? coreVersion,
  }) {
    if ('${formatVersion ?? ''}' != supportedFormatVersion) {
      return '站点库格式版本 ${formatVersion ?? '未知'} 与当前软件支持的 '
          '$supportedFormatVersion 不符';
    }
    if ('${coreVersion ?? ''}' != currentCoreVersion) {
      return '站点库要求核心版本 ${coreVersion ?? '未知'}，'
          '当前软件版本是 $currentCoreVersion，不匹配';
    }
    return null;
  }

  static String? _nullableText(Object? value) {
    if (value == null) return null;
    final text = '$value';
    return text.isEmpty ? null : text;
  }
}

/// 按 ext JSON 还原平台型直播源。JSON 字段与 LiveSource 对位：
/// name/description/protocol(pingtai|list|api)/endpoints/script/
/// headers/epg/proxies/group/adult。解析不出端点时返回 null。
LiveSource? liveSourceFromExtJson({
  required String siteId,
  required String fallbackName,
  required bool fallbackAdult,
  required String extJson,
}) {
  Object? decoded;
  try {
    decoded = jsonDecode(extJson);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final endpoints = (decoded['endpoints'] as List?)
      ?.whereType<String>()
      .where((e) => e.isNotEmpty)
      .toList();
  if (endpoints == null || endpoints.isEmpty) return null;
  final protocolName = '${decoded['protocol'] ?? 'pingtai'}';
  final protocol = LiveProtocol.values.firstWhere(
    (p) => p.name == protocolName,
    orElse: () => LiveProtocol.pingtai,
  );
  final headersRaw = decoded['headers'];
  return LiveSource(
    id: siteId,
    name: '${decoded['name'] ?? fallbackName}',
    description: '${decoded['description'] ?? ''}',
    protocol: protocol,
    endpoints: endpoints,
    script: '${decoded['script'] ?? ''}',
    headers: headersRaw is Map
        ? headersRaw.map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          )
        : const {},
    epg: '${decoded['epg'] ?? ''}',
    proxies: (decoded['proxies'] as List?)
            ?.whereType<String>()
            .toList() ??
        const [],
    group: '${decoded['group'] ?? ''}',
    adult: decoded['adult'] == true || fallbackAdult,
  );
}
