import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/live_sources.dart';
import 'package:fqapp/services/site_library.dart';

/// 按规格口径独立算 payload（不调生产函数）：parts 拼串、UTF-8
/// 字节序排序、'\n' 连接、sha256 hex。生产函数若拼串/排序口径
/// 漂移，这里对不上就会红。
String _specPayload({
  required List<List<String>> stations,
  required List<List<String>> codes,
  required List<List<String>> assets,
  required String formatVersion,
  required String coreVersion,
  required String libraryVersion,
}) {
  final parts = <String>[
    for (final s in stations) 'S|${s[0]}|${s[1]}|${s[2]}',
    for (final c in codes) 'C|${c[0]}|${c[1]}',
    for (final a in assets) 'A|${a[0]}|${a[1]}',
    'M|$formatVersion|$coreVersion|$libraryVersion',
  ];
  parts.sort((a, b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    final n = x.length < y.length ? x.length : y.length;
    for (var i = 0; i < n; i++) {
      if (x[i] != y[i]) return x[i] - y[i];
    }
    return x.length - y.length;
  });
  return sha256.convert(utf8.encode(parts.join('\n'))).toString();
}

String _specSignature(String payload) {
  return Hmac(
    sha256,
    utf8.encode('xiuxian-site-library-v1'),
  ).convert(utf8.encode(payload)).toString();
}

String _sha(String text) => sha256.convert(utf8.encode(text)).toString();

/// 一份完整站点库的假数据（2 站：py 站 + 直播清单站，1 个 jar 资产）。
/// 校验查询由假执行器按这份数据回答；导入的 .sql 文本只走流式
/// 执行通道（假执行器不真跑），与女优库导入测试同款分工。
class _LibFixture {
  _LibFixture({
    this.formatVersion = '1',
    this.coreVersion = '2026.11.27',
    this.tamperLibraryVersion,
    this.badSignature = false,
    this.badCodeHash = false,
  }) {
    final demoCode = "# demo spider\nprint('hi')\n";
    final m3uCode = '#EXTM3U\n#EXTINF:-1,台一\nhttp://x/1.m3u8\n';
    final demoHash = badCodeHash ? 'deadbeef' : _sha(demoCode);
    stationRows = [
      {
        'site_id': 'demo',
        'canon_id': 'demo',
        'name': '演示站',
        'kind': 'pyImport',
        'zone': 'video',
        'content_type': 'video',
        'is_adult': 0,
        'sort_order': 1,
        'verify_note': null,
      },
      {
        'site_id': 'livem3u1',
        'canon_id': 'livem3u1',
        'name': '直播清单一',
        'kind': 'liveM3u',
        'zone': 'live',
        'content_type': null,
        'is_adult': 1,
        'sort_order': 2,
        'verify_note': null,
      },
    ];
    codeRows = [
      {
        'site_id': 'demo',
        'file_name': 'demo.py',
        'code_text': demoCode,
        'code_sha256': demoHash,
        'ext': 'x' * 5000,
        'class_name': null,
        'jar_asset_id': null,
      },
      {
        'site_id': 'livem3u1',
        'file_name': 'livem3u1.m3u',
        'code_text': m3uCode,
        'code_sha256': _sha(m3uCode),
        'ext': null,
        'class_name': null,
        'jar_asset_id': null,
      },
    ];
    assetRows = [
      {'asset_id': 'jar:zakatv', 'md5': 'fd800a963fde845dd0a5fe797d7d7516'},
    ];
    final payload = _specPayload(
      stations: [
        for (final r in stationRows)
          ['${r['site_id']}', '${r['kind']}', '${r['name']}'],
      ],
      codes: [
        for (final r in codeRows) ['${r['site_id']}', '${r['code_sha256']}'],
      ],
      assets: [
        for (final r in assetRows) ['${r['asset_id']}', '${r['md5']}'],
      ],
      formatVersion: formatVersion,
      coreVersion: coreVersion,
      libraryVersion: libraryVersion,
    );
    manifestRow = {
      'library_version': tamperLibraryVersion ?? libraryVersion,
      'station_count': stationRows.length,
      'payload_sha256': payload,
      'signature': badSignature ? 'deadbeef' : _specSignature(payload),
      'format_version': formatVersion,
      'core_version': coreVersion,
    };
  }

  final String formatVersion;
  final String coreVersion;
  final String libraryVersion = '20261128';

  /// 清单行里的 library_version 被改掉（payload/签名仍按原值算）。
  final String? tamperLibraryVersion;
  final bool badSignature;
  final bool badCodeHash;

  late final List<Map<String, Object?>> stationRows;
  late final List<Map<String, Object?>> codeRows;
  late final List<Map<String, Object?>> assetRows;
  late final Map<String, Object?> manifestRow;

  Map<String, String> get meta => {
    'format': 'site_library',
    'schema_version': '1',
    'station_count': '${stationRows.length}',
    'library_version': libraryVersion,
  };
}

/// 假执行器：execute/executeBatch 只记录，query 按表名回假数据。
class _FakeExecutor implements SiteLibrarySqlExecutor {
  _FakeExecutor(this.fixture);

  final _LibFixture fixture;
  var closed = false;

  @override
  Future<void> execute(String sql) async {}

  @override
  Future<void> executeBatch(List<String> statements) async {}

  @override
  Future<List<Map<String, Object?>>> query(String sql) async {
    if (sql.contains('FROM schema_meta')) {
      return [
        for (final e in fixture.meta.entries)
          {'key': e.key, 'value': e.value},
      ];
    }
    if (sql.contains('FROM manifest')) return [fixture.manifestRow];
    if (sql.contains('FROM station_code')) return fixture.codeRows;
    if (sql.contains('FROM stations')) return fixture.stationRows;
    if (sql.contains('FROM station_assets')) return fixture.assetRows;
    return [];
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

Future<SiteLibrarySqlExecutor> Function(String) _factoryFor(
  _FakeExecutor executor,
) {
  return (tempPath) async {
    await File(tempPath).writeAsString('NEWDB');
    return executor;
  };
}

void main() {
  group('payload 哈希与签名（纯函数，规格口径手算比对）', () {
    test('payload 与独立实现一致（含 M 版本行）', () {
      final expected = _specPayload(
        stations: [
          ['demo', 'pyImport', '演示站'],
        ],
        codes: [
          ['demo', 'hashx'],
        ],
        assets: [
          ['jar:zakatv', 'md5x'],
        ],
        formatVersion: '1',
        coreVersion: '2026.11.27',
        libraryVersion: '20261128',
      );
      final actual = computeSiteLibraryPayloadSha256(
        stations: [(siteId: 'demo', kind: 'pyImport', name: '演示站')],
        codes: [(siteId: 'demo', codeSha256: 'hashx')],
        assets: [(assetId: 'jar:zakatv', md5: 'md5x')],
        manifest: (
          formatVersion: '1',
          coreVersion: '2026.11.27',
          libraryVersion: '20261128',
        ),
      );
      expect(actual, expected);
    });

    test('签名与独立 HMAC 一致', () {
      expect(
        computeSiteLibrarySignature('abc123'),
        _specSignature('abc123'),
      );
    });

    test('拆分器：字符串里的分号与 -- 不切', () {
      final splitter = SiteLibrarySqlSplitter();
      final out = splitter.addLine(
        "INSERT INTO stations VALUES('a;b','x--y');",
      );
      expect(out, hasLength(1));
    });
  });

  group('名单 roster 解析', () {
    test('数组与对象两种顶层都认，nativeGate 集对', () async {
      final entries = parseSiteLibraryRoster(
        jsonEncode([
          {'id': 'hongguo', 'name': '红果', 'zone': 'drama', 'kind': 'nativeGate'},
          {'id': 'demo', 'name': '演示站', 'zone': 'video', 'kind': 'pyImport', 'adult': 1},
        ]),
      );
      expect(entries, hasLength(2));
      expect(entries.first.id, 'hongguo');
      expect(entries.last.adult, isTrue);

      final root = Directory.systemTemp.createTempSync('roster_');
      addTearDown(() => root.deleteSync(recursive: true));
      final service = SiteLibraryService(
        supportDirectoryProvider: () async => root,
        assetLoader: (_) async => jsonEncode({
          'stations': [
            {'id': 'hongguo', 'name': '红果', 'kind': 'nativeGate'},
          ],
        }),
      );
      await service.roster();
      expect(service.gatedNativeIds, {'hongguo'});
      expect(service.isGatedNative('hongguo'), isTrue);
      expect(service.isGatedNative('demo'), isFalse);
    });
  });

  group('SiteLibraryImporter 校验链', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('site_lib_');
    });
    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<File> writeSql() async {
      final file = File('${tempDir.path}/站点库.sql');
      await file.writeAsString(
        'CREATE TABLE stations(site_id TEXT);\n'
        "INSERT INTO stations VALUES('demo');\n",
      );
      return file;
    }

    Future<SiteLibraryImportOutcome> runImport(_LibFixture fixture) async {
      final sql = await writeSql();
      final dbPath = '${tempDir.path}/site_library.db';
      await File(dbPath).writeAsString('OLDDB');
      final importer = SiteLibraryImporter(
        executorFactory: _factoryFor(_FakeExecutor(fixture)),
      );
      return importer.importFile(
        sqlPath: sql.path,
        dbPath: dbPath,
        onProgress: (_) {},
      );
    }

    test('版本匹配正常导入：换库成功、旧库进 .bak', () async {
      final outcome = await runImport(_LibFixture());
      expect(outcome.ok, isTrue, reason: outcome.error);
      expect(outcome.stationCount, 2);
      expect(outcome.libraryVersion, '20261128');
      final dbPath = '${tempDir.path}/site_library.db';
      expect(await File(dbPath).readAsString(), 'NEWDB');
      expect(await File('$dbPath.bak').readAsString(), 'OLDDB');
    });

    test('坏签名拒收，旧库一字不动', () async {
      final outcome = await runImport(_LibFixture(badSignature: true));
      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('签名'));
      final dbPath = '${tempDir.path}/site_library.db';
      expect(await File(dbPath).readAsString(), 'OLDDB');
      expect(await File('$dbPath.bak').exists(), isFalse);
    });

    test('行哈希不符拒收', () async {
      final outcome = await runImport(_LibFixture(badCodeHash: true));
      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('代码哈希'));
      expect(
        await File('${tempDir.path}/site_library.db').readAsString(),
        'OLDDB',
      );
    });

    test('格式版本不符拒收（签名按该版本正算，死在版本门）', () async {
      final outcome = await runImport(_LibFixture(formatVersion: '2'));
      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('格式版本 2'));
      expect(outcome.error, contains('支持的 1'));
    });

    test('核心版本不符拒收（原因写明两边版本）', () async {
      final outcome = await runImport(
        _LibFixture(coreVersion: '1999.01.01'),
      );
      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('核心版本 1999.01.01'));
      expect(outcome.error, contains('2026.11.27'));
    });

    test('版本字段被篡改：payload 对不上拒收', () async {
      final outcome = await runImport(
        _LibFixture(tamperLibraryVersion: '20000101'),
      );
      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('内容哈希'));
    });
  });

  group('SiteLibraryService 状态机（临时目录注入）', () {
    late Directory root;
    late Directory libDir;

    setUp(() {
      root = Directory.systemTemp.createTempSync('site_svc_');
      libDir = Directory('${root.path}/site_library')..createSync();
      LiveSources.sqlSources = [];
    });
    tearDown(() {
      LiveSources.sqlSources = [];
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    SiteLibraryService makeService(_LibFixture fixture) {
      return SiteLibraryService(
        supportDirectoryProvider: () async => root,
        readExecutorFactory: (_) async => _FakeExecutor(fixture),
        assetLoader: (_) async => '[]',
      );
    }

    test('未导入态：stations 空、sqlSources 空、无拒收原因', () async {
      final service = makeService(_LibFixture());
      await service.load();
      expect(service.imported, isFalse);
      expect(service.stations, isEmpty);
      expect(service.loadRejectionReason, isNull);
      expect(LiveSources.sqlSources, isEmpty);
      expect(LiveSources.builtin.map((s) => s.id), [
        whosLibSourceId,
        'bilibili',
      ]);
    });

    test('已导入：代码落盘、大 ext 落盘、直播源组装', () async {
      await File('${libDir.path}/site_library.db').writeAsString('DB');
      final service = makeService(_LibFixture());
      await service.load();
      expect(service.imported, isTrue);
      expect(service.libraryVersion, '20261128');
      expect(service.stations, hasLength(2));
      final demo = service.stations.first;
      expect(demo.canonId, 'demo');
      expect(demo.codeFilePath, isNotNull);
      expect(await File(demo.codeFilePath!).exists(), isTrue);
      // ext 5000 字超上限：直带为 null、落盘文件存在。
      expect(demo.ext, isNull);
      expect(demo.extFilePath, isNotNull);
      expect(await File(demo.extFilePath!).readAsString(), 'x' * 5000);
      // 直播清单源：端点＝落盘文件路径。
      expect(LiveSources.sqlSources, hasLength(1));
      final live = LiveSources.sqlSources.single;
      expect(live.id, 'livem3u1');
      expect(live.endpoint, service.stations.last.codeFilePath);
      expect(live.endpoint.startsWith('/'), isTrue);
      // 本地文件端点能被 loadBuiltinListChannels 读出频道。
      final channels = await LiveSources.loadBuiltinListChannels(live);
      expect(channels, hasLength(1));
      expect(channels.single.title, '台一');
    });

    test('落盘库版本不符：不激活、文件保留、原因可读', () async {
      final dbFile = File('${libDir.path}/site_library.db');
      await dbFile.writeAsString('DB');
      final service = makeService(
        _LibFixture(coreVersion: '1999.01.01'),
      );
      await service.load();
      expect(service.imported, isFalse);
      expect(service.stations, isEmpty);
      expect(LiveSources.sqlSources, isEmpty);
      expect(service.loadRejectionReason, contains('核心版本 1999.01.01'));
      expect(service.loadRejectionReason, contains('2026.11.27'));
      expect(await dbFile.exists(), isTrue);
    });

    test('删除回名单态：库文件与代码目录清掉', () async {
      await File('${libDir.path}/site_library.db').writeAsString('DB');
      final service = makeService(_LibFixture());
      await service.load();
      expect(service.imported, isTrue);
      await service.deleteLibrary();
      expect(service.imported, isFalse);
      expect(service.stations, isEmpty);
      expect(LiveSources.sqlSources, isEmpty);
      expect(await File('${libDir.path}/site_library.db').exists(), isFalse);
      expect(
        await Directory('${libDir.path}/code').exists(),
        isFalse,
      );
    });

    test('经服务导入（版本匹配）后立即激活', () async {
      final fixture = _LibFixture();
      final sql = File('${root.path}/站点库.sql');
      await sql.writeAsString(
        'CREATE TABLE stations(site_id TEXT);\n',
      );
      final service = SiteLibraryService(
        supportDirectoryProvider: () async => root,
        readExecutorFactory: (_) async => _FakeExecutor(fixture),
        assetLoader: (_) async => '[]',
        importer: SiteLibraryImporter(
          executorFactory: _factoryFor(_FakeExecutor(fixture)),
        ),
      );
      final outcome = await service.importLocalFile(localPath: sql.path);
      expect(outcome.ok, isTrue, reason: outcome.error);
      expect(service.imported, isTrue);
      expect(service.stations, hasLength(2));
      expect(LiveSources.sqlSources, hasLength(1));
    });
  });
}
