import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/unified_import.dart';

// 统一导入口认库嗅探单测（2026-11-28）：五种真实文件形态各
// 一份＋认不出一份，样本按真文件版式缩样构造（合并文件清单
// 在最前、站点库独有表名、女优/磁力同结构靠播放地址区分）。
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('unified_sniff');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<String> writeFile(String name, String content) async {
    final file = File('${dir.path}/$name');
    await file.writeAsString(content);
    return file.path;
  }

  Future<String> writeGz(String name, String content) async {
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(gzip.encode(content.codeUnits));
    return file.path;
  }

  const actressHead = '''
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE videos(
                vod_id TEXT PRIMARY KEY,
                title TEXT,
                pic_url TEXT,
                m3u8_url TEXT);
''';

  test('合并三段文件：bundle_manifest 在最前 → bundle', () async {
    final path = await writeFile('bundle.sql', '''
CREATE TABLE bundle_manifest(
  id INTEGER PRIMARY KEY CHECK(id=1),
  bundle_format TEXT NOT NULL);
INSERT INTO bundle_manifest VALUES(1,'fanren_bundle');
CREATE TABLE seg_site_schema_meta(key TEXT PRIMARY KEY, value TEXT);
INSERT INTO videos VALUES('a-001','标题','', 'https://v.example/1.m3u8');
''');
    expect(await UnifiedImportSniffer.sniff(path), UnifiedImportKind.bundle);
  });

  test('合并文件 .sql.gz → bundle', () async {
    final path = await writeGz(
      'bundle.sql.gz',
      "CREATE TABLE bundle_manifest(id INTEGER);\n"
          "INSERT INTO seg_actress_videos VALUES('a-001');\n",
    );
    expect(await UnifiedImportSniffer.sniff(path), UnifiedImportKind.bundle);
  });

  test('站点库单段：独有表名 → siteLibrary', () async {
    final path = await writeFile('site.sql', '''
CREATE TABLE schema_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO schema_meta VALUES('format','site_library');
CREATE TABLE station_code(site_id TEXT PRIMARY KEY, code_text TEXT);
INSERT INTO stations VALUES('demo','演示站');
''');
    expect(
      await UnifiedImportSniffer.sniff(path),
      UnifiedImportKind.siteLibrary,
    );
  });

  test('女优库 .sql：播放地址是 http 直链 → actressSql', () async {
    final path = await writeFile('actress.sql', '''
$actressHead
INSERT INTO videos VALUES('aaa-001','标题','https://img.example/a.jpg','https://v.example/aaa-001.m3u8');
INSERT INTO video_play_urls VALUES('aaa-001','https://v.example/aaa-001.m3u8','whos');
INSERT INTO video_play_urls VALUES('aaa-002','https://v.example/aaa-002.m3u8','whos');
''');
    expect(
      await UnifiedImportSniffer.sniff(path),
      UnifiedImportKind.actressSql,
    );
  });

  test('女优库 .sql.gz → actressSql', () async {
    final path = await writeGz('actress.sql.gz', '''
$actressHead
INSERT INTO videos VALUES('aaa-001','标题','','https://v.example/aaa-001.m3u8');
INSERT INTO video_play_urls VALUES('aaa-001','https://v.example/aaa-001.m3u8','whos');
''');
    expect(
      await UnifiedImportSniffer.sniff(path),
      UnifiedImportKind.actressSql,
    );
  });

  test('女优库 .db：SQLite 文件头 → actressDb', () async {
    final file = File('${dir.path}/nvku.db');
    await file.writeAsBytes([
      ...'SQLite format 3'.codeUnits,
      0,
      ...List.filled(1024, 0),
    ]);
    expect(
      await UnifiedImportSniffer.sniff(file.path),
      UnifiedImportKind.actressDb,
    );
  });

  test('磁力库 .sql：磁力地址成片出现 → magnetSql', () async {
    final rows = StringBuffer(actressHead);
    for (var i = 0; i < 30; i++) {
      rows.writeln(
        "INSERT INTO videos VALUES('m-$i','标题','','',"
        "'magnet:?xt=urn:btih:HASH$i');",
      );
    }
    final path = await writeFile('magnet.sql', rows.toString());
    expect(await UnifiedImportSniffer.sniff(path), UnifiedImportKind.magnetSql);
  });

  test('磁力库小文件：靠 video_play_urls 样本定 → magnetSql', () async {
    final path = await writeFile('magnet_small.sql', '''
$actressHead
INSERT INTO videos VALUES('m-1','标题','','');
INSERT INTO video_play_urls VALUES('m-1','magnet:?xt=urn:btih:ONLY1','magnet');
''');
    expect(await UnifiedImportSniffer.sniff(path), UnifiedImportKind.magnetSql);
  });

  test('女优库夹零星磁力值：样本是 http → actressSql', () async {
    final path = await writeFile('actress_mixed.sql', '''
$actressHead
INSERT INTO videos VALUES('aaa-001','标题','','https://v.example/aaa-001.m3u8');
INSERT INTO video_play_urls VALUES('aaa-001','https://v.example/aaa-001.m3u8','whos');
INSERT INTO video_play_urls VALUES('aaa-002','magnet:?xt=urn:btih:FEW1','magnet');
INSERT INTO video_play_urls VALUES('aaa-003','magnet:?xt=urn:btih:FEW2','magnet');
''');
    expect(
      await UnifiedImportSniffer.sniff(path),
      UnifiedImportKind.actressSql,
    );
  });

  test('认不出：无关文本 → unknown', () async {
    final path = await writeFile(
      'random.sql',
      'CREATE TABLE something_else(id INTEGER);\nINSERT INTO something_else VALUES(1);\n',
    );
    expect(await UnifiedImportSniffer.sniff(path), UnifiedImportKind.unknown);
  });

  test('认不出：空文件与不存在的文件 → unknown', () async {
    final empty = await writeFile('empty.sql', '');
    expect(await UnifiedImportSniffer.sniff(empty), UnifiedImportKind.unknown);
    expect(
      await UnifiedImportSniffer.sniff('${dir.path}/nope.sql'),
      UnifiedImportKind.unknown,
    );
  });

  test('认不出：坏 gzip → unknown', () async {
    final file = File('${dir.path}/broken.sql.gz');
    await file.writeAsBytes([0x1f, 0x8b, 1, 2, 3, 4, 5, 6, 7, 8]);
    expect(
      await UnifiedImportSniffer.sniff(file.path),
      UnifiedImportKind.unknown,
    );
  });
}
