import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/site_library.dart';
import 'package:fqapp/services/site_library_bundle.dart';

/// 合并文件分段导入测试（站点库续办批）：假执行器按夹具数据
/// 回答查询（与 site_library_test 同款分工——流式执行通道只
/// 记录、校验查询走夹具），物化器/落位链全用假件记录调用。
/// T 行 payload 的规范口径另有 Python 独立实现算出的锚点常量
/// 对账（见第一组），不是生产函数自证。

String _sha(String text) => sha256.convert(utf8.encode(text)).toString();

String _sign(String payload) => computeSiteLibrarySignature(payload);

/// 夹具：三段齐全的小合并文件。
/// - site 段：1 站（demo py）＋1 代码行＋0 资产，payload 走现行
///   站点库口径（生产函数拼，site_library_test 已有独立实现
///   对账过）。
/// - actress 段：1 张表 videos（3 行），payload 用锚点常量
///   （Python 按 SEGMENT_SPEC §4 独立算出）。
/// - magnet 段：1 张表 videos（1 行 magnet: 地址），payload
///   在夹具里按同口径现算（表哈希走生产函数——锚点组已证明
///   生产函数与 Python 口径一致）。
class _BundleFixture {
  _BundleFixture({
    this.actressCoreVersion = '2026.11.27',
    this.tamperBundleSignature = false,
    this.tamperMagnetDeclaredPayload = false,
  }) {
    final demoCode = "print('hi')\n";
    siteStationRows = [
      {
        'site_id': 'demo',
        'kind': 'pyImport',
        'name': '演示站',
        'canon_id': 'demo',
        'content_type': 'video',
        'zone': 'video',
        'is_adult': 0,
        'sort_order': 0,
        'verify_note': null,
      },
    ];
    siteCodeRows = [
      {
        'site_id': 'demo',
        'code_sha256': _sha(demoCode),
        'code_text': demoCode,
        'file_name': 'demo.py',
        'ext': null,
        'class_name': null,
        'jar_asset_id': null,
      },
    ];
    sitePayload = computeSiteLibraryPayloadSha256(
      stations: [(siteId: 'demo', kind: 'pyImport', name: '演示站')],
      codes: [(siteId: 'demo', codeSha256: _sha(demoCode))],
      assets: const [],
      manifest: (
        formatVersion: '1',
        coreVersion: '2026.11.27',
        libraryVersion: '20261127',
      ),
    );
  }

  final String actressCoreVersion;
  final bool tamperBundleSignature;
  final bool tamperMagnetDeclaredPayload;

  late final List<Map<String, Object?>> siteStationRows;
  late final List<Map<String, Object?>> siteCodeRows;
  late final String sitePayload;

  /// actress 段锚点（Python 独立实现，见文件头）：
  /// seg_actress_videos(vod_id,title) 三行
  /// ('a1','标题一') ('a2',NULL) ('b1','x;y')。
  static const actressPayload =
      '103a0cf95f53a93281de1720fc86c03ab0e043e3a466a1e938f4c611952a6604';
  static const actressSignature =
      '8d31faae1ef7078bc45eb07f3692d992a9535965821cfb65f91d9f17222d3713';

  static final actressVideoRows = <Map<String, Object?>>[
    {'vod_id': 'a1', 'title': '标题一'},
    {'vod_id': 'a2', 'title': null},
    {'vod_id': 'b1', 'title': 'x;y'},
  ];

  static final magnetVideoRows = <Map<String, Object?>>[
    {'vod_id': 'm1', 'title': '磁力一'},
  ];

  Map<String, Object?> get siteManifest => {
    'segment': 'site',
    'format_version': '1',
    'core_version': '2026.11.27',
    'library_version': '20261127',
    // schema_meta(9) + stations(1) + code(1) + assets(0) = 11
    'row_count': 11,
    'payload_sha256': sitePayload,
    'signature': _sign(sitePayload),
  };

  Map<String, Object?> get actressManifest => {
    'segment': 'actress',
    'format_version': '1',
    'core_version': actressCoreVersion,
    'library_version': '20261127v5',
    'row_count': 3,
    'payload_sha256': actressPayload,
    'signature': actressSignature,
  };

  /// magnet 段 payload 在测试运行时按锚点已证的口径现算
  /// （见 setUpMagnetPayload）。
  String magnetPayload = '';
  String get magnetDeclaredPayload =>
      tamperMagnetDeclaredPayload ? 'deadbeef' * 8 : magnetPayload;

  Map<String, Object?> get magnetManifest => {
    'segment': 'magnet',
    'format_version': '1',
    'core_version': '2026.11.27',
    'library_version': '20261127',
    'row_count': 1,
    'payload_sha256': magnetDeclaredPayload,
    'signature': _sign(magnetDeclaredPayload),
  };

  Map<String, Object?> get bundleRow {
    final payload = computeBundlePayloadSha256({
      'site': sitePayload,
      'actress': actressPayload,
      'magnet': magnetDeclaredPayload,
    });
    return {
      'bundle_format': 'fanren_bundle',
      'format_version': '1',
      'core_version': '2026.11.27',
      'bundle_version': '20261127',
      'segments': 'site,actress,magnet',
      'payload_sha256': payload,
      'signature': tamperBundleSignature ? 'deadbeef' : _sign(payload),
    };
  }
}

/// 假执行器：按 SQL 形态回夹具数据。staging 与物化后的站点库
/// 临时文件共用一个工厂时按路径分流（临时文件走空执行器）。
class _BundleFakeExecutor implements SiteLibrarySqlExecutor {
  _BundleFakeExecutor(this.fixture);

  final _BundleFixture fixture;
  var closed = false;

  @override
  Future<void> execute(String sql) async {}

  @override
  Future<void> executeBatch(List<String> statements) async {}

  @override
  Future<List<Map<String, Object?>>> query(String sql) async {
    if (sql.contains("name='bundle_manifest'")) {
      return [
        {'name': 'bundle_manifest'},
      ];
    }
    final nameEq = RegExp(r"name='([A-Za-z0-9_]+)'").firstMatch(sql);
    if (nameEq != null && sql.contains('sqlite_master')) {
      // 段 manifest 存在性查询：夹具里三段清单都在。
      return [
        {'name': nameEq.group(1)},
      ];
    }
    if (sql.contains("name LIKE 'seg_site_%'")) {
      return [
        {'name': 'seg_site_schema_meta'},
        {'name': 'seg_site_stations'},
        {'name': 'seg_site_station_code'},
        {'name': 'seg_site_station_assets'},
        {'name': 'seg_site_manifest'},
      ];
    }
    if (sql.contains("name LIKE 'seg_actress_%'")) {
      return [
        {'name': 'seg_actress_videos'},
        {'name': 'seg_actress_manifest'},
      ];
    }
    if (sql.contains("name LIKE 'seg_magnet_%'")) {
      return [
        {'name': 'seg_magnet_videos'},
        {'name': 'seg_magnet_manifest'},
      ];
    }
    if (sql.contains('FROM bundle_manifest')) return [fixture.bundleRow];
    if (sql.contains('FROM seg_site_manifest')) return [fixture.siteManifest];
    if (sql.contains('FROM seg_actress_manifest')) {
      return [fixture.actressManifest];
    }
    if (sql.contains('FROM seg_magnet_manifest')) {
      return [fixture.magnetManifest];
    }
    if (sql.contains('FROM seg_site_stations')) {
      if (sql.contains('COUNT(*)')) {
        return [
          {'c': fixture.siteStationRows.length},
        ];
      }
      return fixture.siteStationRows;
    }
    if (sql.contains('FROM seg_site_station_code')) {
      return fixture.siteCodeRows;
    }
    if (sql.contains('FROM seg_site_station_assets')) {
      return const [];
    }
    if (sql.contains('PRAGMA table_info("seg_actress_videos")')) {
      return [
        {'name': 'vod_id'},
        {'name': 'title'},
      ];
    }
    if (sql.contains('PRAGMA table_info("seg_magnet_videos")')) {
      return [
        {'name': 'vod_id'},
        {'name': 'title'},
      ];
    }
    if (sql.contains('FROM "seg_actress_videos"')) {
      if (sql.contains('COUNT(*)')) {
        return [
          {'c': _BundleFixture.actressVideoRows.length},
        ];
      }
      return _BundleFixture.actressVideoRows;
    }
    if (sql.contains('FROM "seg_magnet_videos"')) {
      if (sql.contains('COUNT(*)')) {
        return [
          {'c': _BundleFixture.magnetVideoRows.length},
        ];
      }
      return _BundleFixture.magnetVideoRows;
    }
    if (sql.contains('FROM "seg_site_schema_meta"')) {
      return [
        {'c': 9},
      ];
    }
    if (sql.contains('FROM "seg_site_stations"')) {
      return [
        {'c': 1},
      ];
    }
    if (sql.contains('FROM "seg_site_station_code"')) {
      return [
        {'c': 1},
      ];
    }
    if (sql.contains('FROM "seg_site_station_assets"')) {
      return [
        {'c': 0},
      ];
    }
    return [];
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// 空执行器（物化后的站点库临时文件补 manifest 时用）。
class _EmptyExecutor implements SiteLibrarySqlExecutor {
  final executed = <String>[];

  @override
  Future<void> execute(String sql) async {
    executed.add(sql);
  }

  @override
  Future<void> executeBatch(List<String> statements) async {}

  @override
  Future<List<Map<String, Object?>>> query(String sql) async => [];

  @override
  Future<void> close() async {}
}

/// 无合并清单的假执行器：sqlite_master 查 bundle_manifest
/// 回空（模拟单段文件 staging 后的真实形态）。
class _NoBundleExecutor implements SiteLibrarySqlExecutor {
  @override
  Future<void> execute(String sql) async {}

  @override
  Future<void> executeBatch(List<String> statements) async {}

  @override
  Future<List<Map<String, Object?>>> query(String sql) async => [];

  @override
  Future<void> close() async {}
}

/// 假物化器：记录调用、往目标路径写占位内容。
class _FakeMaterializer implements SiteLibrarySegmentMaterializer {
  final calls = <String>[];

  @override
  Future<void> materialize({
    required String stagingPath,
    required String segment,
    required String targetPath,
  }) async {
    calls.add(segment);
    final file = File(targetPath);
    await file.parent.create(recursive: true);
    await file.writeAsString('SEGDB-$segment');
  }
}

void main() {
  group('规范哈希锚点（Python 独立实现对账）', () {
    test('表哈希与 T 行 payload 与 SEGMENT_SPEC §4 口径一致', () async {
      final executor = _BundleFakeExecutor(_BundleFixture());
      final tableHash = await computeSegmentTableSha256(
        executor,
        'seg_actress_videos',
      );
      expect(
        tableHash,
        '21126603406552f28b32b426327f9dd61cfdee40a282b70d792f650df9c1162f',
      );
      final payload = await computeBundleSegmentPayload(
        executor,
        segment: 'actress',
        prefixedTables: ['seg_actress_videos'],
      );
      expect(payload, _BundleFixture.actressPayload);
      expect(
        computeSiteLibrarySignature(payload),
        _BundleFixture.actressSignature,
      );
    });
  });

  group('SiteLibraryBundleImporter 分段导入', () {
    late Directory tempDir;
    late _BundleFixture fixture;
    late _FakeMaterializer materializer;
    late List<String> actressLanded;
    late List<String> magnetLanded;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('bundle_');
      fixture = _BundleFixture();
      materializer = _FakeMaterializer();
      actressLanded = [];
      magnetLanded = [];
      // magnet 段 payload：用锚点组已证口径的假执行器现算。
      final probe = _BundleFakeExecutor(fixture);
      fixture.magnetPayload = await computeBundleSegmentPayload(
        probe,
        segment: 'magnet',
        prefixedTables: ['seg_magnet_videos'],
      );
    });
    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<File> writeBundleSql() async {
      final file = File('${tempDir.path}/凡人修仙站点.sql');
      await file.writeAsString(
        'CREATE TABLE bundle_manifest(id INTEGER);\n'
        "INSERT INTO bundle_manifest VALUES(1);\n",
      );
      return file;
    }

    SiteLibraryBundleImporter makeImporter({_BundleFixture? useFixture}) {
      final f = useFixture ?? fixture;
      return SiteLibraryBundleImporter(
        executorFactory: (path) async {
          if (path.contains('bundle_staging')) {
            await File(path).writeAsString('STAGING');
            return _BundleFakeExecutor(f);
          }
          return _EmptyExecutor();
        },
        materializer: materializer,
        actressLander: (path) async {
          actressLanded.add(path);
          return (ok: true, error: null, detail: '作品 3 部');
        },
        magnetLander: (path) async {
          magnetLanded.add(path);
          return (ok: true, error: null, detail: '新增作品 1 部');
        },
        segmentDbPostProcess: (segment, path) async {},
      );
    }

    Future<SiteLibraryImportOutcome?> runImport({
      _BundleFixture? useFixture,
    }) async {
      final f = useFixture ?? fixture;
      if (f.magnetPayload.isEmpty) {
        final probe = _BundleFakeExecutor(f);
        f.magnetPayload = await computeBundleSegmentPayload(
          probe,
          segment: 'magnet',
          prefixedTables: ['seg_magnet_videos'],
        );
      }
      final sql = await writeBundleSql();
      final siteDbPath = '${tempDir.path}/site_library/site_library.db';
      await Directory('${tempDir.path}/site_library').create();
      await File(siteDbPath).writeAsString('OLDDB');
      final outcome = await makeImporter(useFixture: useFixture).importBundle(
        sqlPath: sql.path,
        siteDbPath: siteDbPath,
        workDir: '${tempDir.path}/site_library',
        onProgress: (_) {},
      );
      return outcome;
    }

    test('三段全过：逐段落位、站数与逐段结果齐', () async {
      final outcome = await runImport();
      expect(outcome, isNotNull);
      expect(outcome!.ok, isTrue, reason: outcome.error);
      expect(outcome.stationCount, 1);
      expect(outcome.segmentResults, hasLength(3));
      expect(outcome.segmentResults.every((r) => r.ok), isTrue);
      expect(materializer.calls, ['site', 'actress', 'magnet']);
      expect(actressLanded, hasLength(1));
      expect(magnetLanded, hasLength(1));
      // 站点库已换新、旧库进 .bak。
      final siteDbPath = '${tempDir.path}/site_library/site_library.db';
      expect(await File(siteDbPath).readAsString(), 'SEGDB-site');
      expect(await File('$siteDbPath.bak').readAsString(), 'OLDDB');
      // staging 与段临时文件清干净。
      expect(
        await File(
          '${tempDir.path}/site_library/bundle_staging.db',
        ).exists(),
        isFalse,
      );
      expect(
        await File(
          '${tempDir.path}/site_library/segment_actress.db',
        ).exists(),
        isFalse,
      );
    });

    test('一段版本门拒：actress 核心版本不符，只拒该段、别段照常落位', () async {
      final outcome = await runImport(
        useFixture: _BundleFixture(actressCoreVersion: '1999.01.01'),
      );
      expect(outcome, isNotNull);
      expect(outcome!.ok, isTrue, reason: outcome.error);
      final bySegment = {
        for (final r in outcome.segmentResults) r.segment: r,
      };
      expect(bySegment['site']!.ok, isTrue);
      expect(bySegment['magnet']!.ok, isTrue);
      expect(bySegment['actress']!.ok, isFalse);
      expect(bySegment['actress']!.error, contains('1999.01.01'));
      expect(bySegment['actress']!.error, contains('2026.11.27'));
      expect(bySegment['actress']!.error, contains('演员库'));
      expect(actressLanded, isEmpty);
      expect(magnetLanded, hasLength(1));
    });

    test('一段 payload 被篡改：magnet 只拒该段', () async {
      final tampered = _BundleFixture(tamperMagnetDeclaredPayload: true);
      // 夹具的 magnet 清单 payload/签名按篡改值自洽（整文件层
      // 按声明值算也自洽），段内重算对不上才拒——与真篡改同型。
      final probe = _BundleFakeExecutor(tampered);
      tampered.magnetPayload = await computeBundleSegmentPayload(
        probe,
        segment: 'magnet',
        prefixedTables: ['seg_magnet_videos'],
      );
      final outcome = await runImport(useFixture: tampered);
      expect(outcome, isNotNull);
      expect(outcome!.ok, isTrue, reason: outcome.error);
      final bySegment = {
        for (final r in outcome.segmentResults) r.segment: r,
      };
      expect(bySegment['magnet']!.ok, isFalse);
      expect(bySegment['magnet']!.error, contains('磁力库'));
      expect(bySegment['magnet']!.error, contains('哈希'));
      expect(bySegment['site']!.ok, isTrue);
      expect(bySegment['actress']!.ok, isTrue);
      expect(magnetLanded, isEmpty);
    });

    test('整文件签名不对：全拒、一段不落、旧站点库不动', () async {
      final outcome = await runImport(
        useFixture: _BundleFixture(tamperBundleSignature: true),
      );
      expect(outcome, isNotNull);
      expect(outcome!.ok, isFalse);
      expect(outcome.error, contains('整文件签名'));
      expect(outcome.segmentResults, isEmpty);
      expect(materializer.calls, isEmpty);
      expect(actressLanded, isEmpty);
      expect(magnetLanded, isEmpty);
      final siteDbPath = '${tempDir.path}/site_library/site_library.db';
      expect(await File(siteDbPath).readAsString(), 'OLDDB');
      expect(await File('$siteDbPath.bak').exists(), isFalse);
    });

    test('非合并文件：staging 后查无 bundle_manifest 表，回 null 交回单段路',
        () async {
      final plain = await writeBundleSql();
      final importer = SiteLibraryBundleImporter(
        executorFactory: (path) async {
          await File(path).writeAsString('STAGING');
          return _NoBundleExecutor();
        },
        materializer: materializer,
        actressLander: (path) async =>
            (ok: true, error: null, detail: null),
        magnetLander: (path) async =>
            (ok: true, error: null, detail: null),
        segmentDbPostProcess: (segment, path) async {},
      );
      final outcome = await importer.importBundle(
        sqlPath: plain.path,
        siteDbPath: '${tempDir.path}/site_library/site_library.db',
        workDir: '${tempDir.path}/site_library',
        onProgress: (_) {},
      );
      expect(outcome, isNull);
      expect(materializer.calls, isEmpty);
    });

    test('粗扫：含 bundle_manifest 字样才命中', () async {
      final bundle = await writeBundleSql();
      expect(
        await SiteLibraryBundleImporter.mightBeBundle(bundle.path),
        isTrue,
      );
      final plain = File('${tempDir.path}/站点库.sql');
      await plain.writeAsString(
        'CREATE TABLE stations(site_id TEXT);\n'
        "INSERT INTO stations VALUES('demo');\n",
      );
      expect(
        await SiteLibraryBundleImporter.mightBeBundle(plain.path),
        isFalse,
      );
    });
  });

  group('SiteLibraryService 路由（单段兼容＋合并分流）', () {
    late Directory root;
    late Directory libDir;

    setUp(() {
      root = Directory.systemTemp.createTempSync('bundle_svc_');
      libDir = Directory('${root.path}/site_library')..createSync();
    });
    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    /// 0 站单段库的合法 payload（空集＋清单行）。
    String emptyPayload() => computeSiteLibraryPayloadSha256(
      stations: const [],
      codes: const [],
      assets: const [],
      manifest: (
        formatVersion: '1',
        coreVersion: '2026.11.27',
        libraryVersion: '20261127',
      ),
    );

    SiteLibrarySqlExecutor legacyExecutor() {
      final payload = emptyPayload();
      return _LegacyFakeExecutor(
        meta: {
          'format': 'site_library',
          'schema_version': '1',
          'station_count': '0',
          'library_version': '20261127',
        },
        manifestRow: {
          'library_version': '20261127',
          'station_count': 0,
          'payload_sha256': payload,
          'signature': _sign(payload),
          'format_version': '1',
          'core_version': '2026.11.27',
        },
      );
    }

    test('单段文件兼容：粗扫不命中，走现行单段路导入成功', () async {
      final service = SiteLibraryService(
        supportDirectoryProvider: () async => root,
        importer: SiteLibraryImporter(
          executorFactory: (path) async {
            await File(path).writeAsString('NEWDB');
            return legacyExecutor();
          },
        ),
        readExecutorFactory: (_) async => legacyExecutor(),
        assetLoader: (_) async => '[]',
      );
      final sql = File('${root.path}/站点库.sql');
      await sql.writeAsString(
        'CREATE TABLE stations(site_id TEXT);\n'
        "INSERT INTO stations VALUES('demo');\n",
      );
      final outcome = await service.importLocalFile(localPath: sql.path);
      expect(outcome.ok, isTrue, reason: outcome.error);
      expect(outcome.segmentResults, isEmpty);
      expect(outcome.stationCount, 0);
      expect(service.imported, isTrue);
      expect(
        await File('${libDir.path}/site_library.db').readAsString(),
        'NEWDB',
      );
    });

    test('合并文件经服务层：逐段结果回来、站点段落位后服务已导入', () async {
      final fixture = _BundleFixture();
      final probe = _BundleFakeExecutor(fixture);
      fixture.magnetPayload = await computeBundleSegmentPayload(
        probe,
        segment: 'magnet',
        prefixedTables: ['seg_magnet_videos'],
      );
      final bundleImporter = SiteLibraryBundleImporter(
        executorFactory: (path) async {
          if (path.contains('bundle_staging')) {
            await File(path).writeAsString('STAGING');
            return _BundleFakeExecutor(fixture);
          }
          return _EmptyExecutor();
        },
        materializer: _FakeMaterializer(),
        actressLander: (path) async =>
            (ok: true, error: null, detail: '作品 3 部'),
        magnetLander: (path) async =>
            (ok: true, error: null, detail: '新增作品 1 部'),
        segmentDbPostProcess: (segment, path) async {},
      );
      final service = SiteLibraryService(
        supportDirectoryProvider: () async => root,
        bundleImporter: bundleImporter,
        readExecutorFactory: (_) async => legacyExecutor(),
        assetLoader: (_) async => '[]',
      );
      final sql = File('${root.path}/凡人修仙站点.sql');
      await sql.writeAsString(
        'CREATE TABLE bundle_manifest(id INTEGER);\n'
        "INSERT INTO bundle_manifest VALUES(1);\n",
      );
      final outcome = await service.importLocalFile(localPath: sql.path);
      expect(outcome.ok, isTrue, reason: outcome.error);
      expect(outcome.segmentResults, hasLength(3));
      expect(outcome.segmentResults.every((r) => r.ok), isTrue);
      // 站点段落位后服务层 load() 刷新成已导入态。
      expect(service.imported, isTrue);
      expect(
        await File('${libDir.path}/site_library.db').readAsString(),
        'SEGDB-site',
      );
    });
  });
}

/// 单段（旧格式）假执行器：schema_meta/manifest/三表按夹具回。
class _LegacyFakeExecutor implements SiteLibrarySqlExecutor {
  _LegacyFakeExecutor({required this.meta, required this.manifestRow});

  final Map<String, String> meta;
  final Map<String, Object?> manifestRow;

  @override
  Future<void> execute(String sql) async {}

  @override
  Future<void> executeBatch(List<String> statements) async {}

  @override
  Future<List<Map<String, Object?>>> query(String sql) async {
    if (sql.contains('FROM schema_meta')) {
      return [
        for (final e in meta.entries) {'key': e.key, 'value': e.value},
      ];
    }
    if (sql.contains('FROM manifest')) return [manifestRow];
    if (sql.contains('FROM stations')) return [];
    if (sql.contains('FROM station_code')) return [];
    if (sql.contains('FROM station_assets')) return [];
    return [];
  }

  @override
  Future<void> close() async {}
}
