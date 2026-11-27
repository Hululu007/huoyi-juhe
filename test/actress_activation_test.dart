import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_db_source.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_library_native_page.dart';
import 'package:fqapp/actress/actress_library_version.dart';
import 'package:fqapp/actress/actress_sql_import.dart';
import 'package:fqapp/services/idj_plugin_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 演员库数据库激活批测试（2026-11-27）：
/// - 版本门判定与 schema_meta 读取；
/// -.sql 导入走真默认门：无版本字段拒收、原库不动；
/// - 没导演员库时：页签进得去只有中文
/// 引导、读库层静默回失败、全局搜索接缝不出段、不牵连
/// 远程（插件）存值、界面不露英文异常；
/// - 边界：存量已导入（含磁力并入改过文件）不受版本门回头
/// 拦；激活后 source→路径→读库层的链闭环。
/// sqflite 在 flutter test 里跑不起来处一律注入假件。

ActressDbSource fakeSource({
required String externalPath,
required String importedPath,
int works = 42,
}) {
return ActressDbSource(
externalPath: () async => externalPath,
importedPath: () async => importedPath,
worksCounter: (_) async => works,
isIOS: () => false,
);
}

/// 记账假执行器（照 actress_sql_import_test 的 _RecordingExecutor
/// 精简）：CREATE 记表名、INSERT 按表计数、COUNT 查询按计数答；
/// 额外支持 schema_meta 的键值查询（版本门读取走它）。
class _MetaExecutor implements SqlImportExecutor {
final tables = <String>{};
final counts = <String, int>{};
List<Map<String, Object?>> metaRows = const [];

static final _createRe = RegExp(
r'CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?["`\[]?(\w+)',
caseSensitive: false,
);
static final _insertRe = RegExp(
r'INSERT\s+(?:OR\s+\w+\s+)?INTO\s+["`\[]?(\w+)',
caseSensitive: false,
);

@override
Future<void> execute(String sql) async {
final create = _createRe.firstMatch(sql);
if (create!= null) tables.add(create.group(1)!);
final insert = _insertRe.firstMatch(sql);
if (insert!= null) {
final table = insert.group(1)!;
counts[table] = (counts[table]?? 0) + 1;
}
}

@override
Future<void> executeBatch(List<String> statements) async {
for (final sql in statements) {
await execute(sql);
}
}

@override
Future<List<Map<String, Object?>>> query(
String sql, [
List<Object?>? args,
]) async {
if (sql.contains('sqlite_master')) {
return [for (final t in tables) {'name': t}];
}
if (sql.contains('FROM schema_meta') && sql.contains('key')) {
return metaRows;
}
final count = RegExp(
r'FROM\s+["`\[]?(\w+)',
caseSensitive: false,
).firstMatch(sql);
if (count!= null && sql.toUpperCase().contains('COUNT')) {
return [
{'COUNT(*)': counts[count.group(1)!]?? 0},
];
}
return [];
}

@override
Future<void> close() async {}
}

const _sampleSql = '''
CREATE TABLE videos (id INTEGER PRIMARY KEY, title TEXT, pic TEXT);
CREATE TABLE actresses (id INTEGER PRIMARY KEY, name TEXT, avatar TEXT);
CREATE TABLE video_actress (video_id INTEGER, actress_id INTEGER);
CREATE TABLE video_play_urls (id INTEGER PRIMARY KEY, video_id INTEGER, url TEXT);
INSERT INTO videos (id, title, pic) VALUES (1, '示例作品', 'http://x/p.jpg');
INSERT INTO actresses (id, name, avatar) VALUES (1, '演员甲', 'http://x/a.jpg');
INSERT INTO video_actress (video_id, actress_id) VALUES (1, 1);
INSERT INTO video_play_urls (id, video_id, url) VALUES (1, 1, 'http://x/v.m3u8');
''';

const _stampedSql = '''
CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT);
INSERT INTO schema_meta (key, value) VALUES ('format', 'actress_library');
INSERT INTO schema_meta (key, value) VALUES ('format_version', '1');
INSERT INTO schema_meta (key, value) VALUES ('core_version', '2026.11.27');
INSERT INTO schema_meta (key, value) VALUES ('library_version', '20261127v5');
''';

class _Repo extends AppRepository {
@override
Future<List<CatalogCategory>> categories(
String source, {
bool force = false,
}) async => const [CatalogCategory('all', '全部')];

@override
Future<CatalogPage> catalog(
String source, {
int page = 1,
String query = '',
String category = '',
bool force = false,
Map<String, String> filters = const {},
}) async => CatalogPage(const [], page: page);

@override
Future<CatalogPage> searchAcross(List<String> sources, String query) async =>
CatalogPage(const []);

@override
Future<void> searchAcrossProgressive(
List<String> sources,
String query, {
required void Function(String source, List<Drama> items) onSite,
bool Function()? shouldStop,
}) async {}

@override
Future<String> cover(Drama drama, {bool force = false}) async => drama.cover;

@override
Future<DramaDetail> detail(Drama drama) async => DramaDetail(drama, const []);

@override
Future<PlaybackPlan> resolve(
Drama drama,
Episode episode, {
int quality = 0,
int route = 0,
bool adBlock = true,
}) async => const PlaybackPlan(url: 'https://example.test/a.m3u8');
}

void main() {
TestWidgetsFlutterBinding.ensureInitialized();

late Directory tempDir;
late String externalDb;
late String importedDb;

setUp(() {
SharedPreferences.setMockInitialValues({});
tempDir = Directory.systemTemp.createTempSync('activation_test_');
externalDb = '${tempDir.path}/external.db';
importedDb = '${tempDir.path}/actress/imported.db';
Directory('${tempDir.path}/actress').createSync(recursive: true);
});

tearDown(() {
if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
});

group('版本门判定 actressLibraryVersionError', () {
test('全空（无 schema_meta）：缺字段中文原因', () {
final error = actressLibraryVersionError(
const ActressLibraryVersionInfo(),
);
expect(error, contains('没有版本字段'));
expect(error, contains('旧版库'));
});

test('format 不是 actress_library：同样按缺字段', () {
final error = actressLibraryVersionError(
const ActressLibraryVersionInfo(
format: 'site_library',
formatVersion: '1',
coreVersion: '2026.11.27',
),
);
expect(error, contains('没有版本字段'));
});

test('格式版本对不上：写明库的格式与当前只认的格式', () {
final error = actressLibraryVersionError(
const ActressLibraryVersionInfo(
format: 'actress_library',
formatVersion: '2',
coreVersion: '2026.11.27',
),
);
expect(error, contains('格式版本 2'));
expect(error, contains('格式版本 1 不一致'));
});

test('核心版本对不上：写明要求与现状', () {
final error = actressLibraryVersionError(
const ActressLibraryVersionInfo(
format: 'actress_library',
formatVersion: '1',
coreVersion: '2027.01.01',
),
);
expect(error, contains('要求核心版本 2027.01.01'));
expect(error, contains('当前软件核心版本是 2026.11.27'));
});

test('全对：放行（返回 null）', () {
expect(
actressLibraryVersionError(
const ActressLibraryVersionInfo(
format: 'actress_library',
formatVersion: '1',
coreVersion: '2026.11.27',
libraryVersion: '20261127v5',
),
),
isNull,
);
});

test('注入覆盖：当前只认格式 2 时格式 1 被拒', () {
final error = actressLibraryVersionError(
const ActressLibraryVersionInfo(
format: 'actress_library',
formatVersion: '1',
coreVersion: '2026.11.27',
),
supportedFormatVersion: '2',
);
expect(error, contains('格式版本 2 不一致'));
});
});

group('readActressLibraryVersion 读取', () {
test('没有 schema_meta 表：全空、hasVersionFields 为假', () async {
final info = await readActressLibraryVersion((sql, [args]) async {
if (sql.contains('sqlite_master')) {
return [
{'name': 'videos'},
];
}
return [];
});
expect(info.hasVersionFields, isFalse);
expect(info.format, '');
});

test('有表有行：四字段解析出来', () async {
final info = await readActressLibraryVersion((sql, [args]) async {
if (sql.contains('sqlite_master')) {
return [
{'name': 'schema_meta'},
];
}
if (sql.contains('FROM schema_meta')) {
return [
{'key': 'format', 'value': 'actress_library'},
{'key': 'format_version', 'value': '1'},
{'key': 'core_version', 'value': '2026.11.27'},
{'key': 'library_version', 'value': '20261127v5'},
];
}
return [];
});
expect(info.hasVersionFields, isTrue);
expect(info.format, 'actress_library');
expect(info.formatVersion, '1');
expect(info.coreVersion, '2026.11.27');
expect(info.libraryVersion, '20261127v5');
});

test('查询抛错：吞掉回全空，不把异常抛给导入链', () async {
final info = await readActressLibraryVersion(
(sql, [args]) async => throw StateError('boom'),
);
expect(info.hasVersionFields, isFalse);
});
});

group('.sql 导入版本门（真默认门）', () {
Future<SqlImportExecutor> Function(String) factoryFor(
_MetaExecutor executor,
) {
return (tempPath) async {
await File(tempPath).writeAsString('NEWDB');
return executor;
};
}

test('无版本字段的.sql 被拒：原库不动、不关库、临时文件清掉', () async {
final sqlFile = File('${tempDir.path}/old.sql')
..writeAsStringSync(_sampleSql);
final livePath = '${tempDir.path}/女优库.db';
await File(livePath).writeAsString('OLDDB');
var closeCalls = 0;
final importer = ActressSqlImporter(
executorFactory: factoryFor(_MetaExecutor()),
);
final result = await importer.importFile(
sqlPath: sqlFile.path,
dbPath: livePath,
closeDatabase: () async => closeCalls++,
onProgress: (_) {},
);
expect(result.ok, isFalse);
// 拒收原因是门自己的中文原因，不套「导入失败：」前缀。
expect(result.error, contains('没有版本字段'));
expect(result.error, isNot(startsWith('导入失败')));
expect(result.needsReload, isFalse);
expect(closeCalls, 0);
expect(await File(livePath).readAsString(), 'OLDDB');
expect(await File('$livePath.bak').exists(), isFalse);
expect(await File('$livePath.importing').exists(), isFalse);
});

test('带版本字段且对得上的.sql 放行：换库成功', () async {
final executor = _MetaExecutor()
..metaRows = const [
{'key': 'format', 'value': 'actress_library'},
{'key': 'format_version', 'value': '1'},
{'key': 'core_version', 'value': '2026.11.27'},
{'key': 'library_version', 'value': '20261127v5'},
];
final sqlFile = File('${tempDir.path}/v5.sql')
..writeAsStringSync('$_sampleSql\n$_stampedSql');
final livePath = '${tempDir.path}/女优库.db';
await File(livePath).writeAsString('OLDDB');
final importer = ActressSqlImporter(
executorFactory: factoryFor(executor),
);
final result = await importer.importFile(
sqlPath: sqlFile.path,
dbPath: livePath,
closeDatabase: () async {},
onProgress: (_) {},
);
expect(result.ok, isTrue, reason: result.error);
expect(result.videos, 1);
expect(await File(livePath).readAsString(), 'NEWDB');
expect(await File('$livePath.bak').readAsString(), 'OLDDB');
});
});

group('未激活态（硬门组）', () {
test('读库层静默：各 op 都回 ok:false＋中文激活引导、无英文异常', () async {
File(externalDb).writeAsStringSync('EXTDB');
final source = fakeSource(
externalPath: externalDb,
importedPath: importedDb,
);
final fallback = ActressLibraryDbFallback(
pathResolver: source.effectiveDbPath,
);
for (final op in ['list', 'search', 'actresses']) {
final result = await fallback.handle({'op': op});
expect(result['ok'], isFalse, reason: op);
final error = '${result['error']}';
expect(error, contains('还没激活'), reason: op);
expect(error, isNot(contains('Exception')), reason: op);
expect(error, isNot(contains('Bad state')), reason: op);
}
});

test('全局搜索接缝：未激活时 globalSearch 在分发前回 ok:false', () async {
// 全局搜索批（global-search-20261127）经
// ActressLibraryDbFallback.shared → effectiveDbPath() 取数，
// 就绪检查在 op 分发之前：未激活回 ok:false，上层静默
// 不出演员/作品两段、不报错。本机 op 表尚无 globalSearch
// 不影响接缝判定（失败发生在分发前）。
File(externalDb).writeAsStringSync('EXTDB');
final source = fakeSource(
externalPath: externalDb,
importedPath: importedDb,
);
final fallback = ActressLibraryDbFallback(
pathResolver: source.effectiveDbPath,
);
final result = await fallback.handle({'op': 'globalSearch', 'q': 'SSIS-001'});
expect(result['ok'], isFalse);
expect('${result['error']}', contains('还没激活'));
});

test('来源层全 API 未激活不抛错', () async {
final source = fakeSource(
externalPath: externalDb,
importedPath: importedDb,
);
final status = await source.status();
expect(status.activated, isFalse);
expect(await source.effectiveDbPath(), '');
expect(await source.loadActivation(), isNull);
expect(await source.deleteImported(), isFalse);
expect(await source.status().then((s) => s.activated), isFalse);
});

test('未激活不牵连远程：插件存值在激活全流程后原样', () async {
// 远程（插件站等）不走演员库激活：激活流程只碰自己
// 的 prefs 键，插件三键（清单/订阅/已卸载记录）预置后
// 跑满状态查询、标记激活、删除导入库，值必须一字不变。
final prefs = await SharedPreferences.getInstance();
await prefs.setString(idjPluginsPrefsKey, '[{"id":"missav"}]');
await prefs.setStringList(
idjSubscriptionsPrefsKey,
const ['https://example.test/index.json'],
);
await prefs.setString(idjUninstalledPrefsKey, '{"18av":"1.0.0"}');
File(importedDb).writeAsStringSync('IMPDB');
final source = fakeSource(
externalPath: externalDb,
importedPath: importedDb,
);
await source.status(); // 存量补记
await source.markActivated(origin: 'import');
await source.deleteImported();
expect(prefs.getString(idjPluginsPrefsKey), '[{"id":"missav"}]');
expect(
prefs.getStringList(idjSubscriptionsPrefsKey),
const ['https://example.test/index.json'],
);
expect(prefs.getString(idjUninstalledPrefsKey), '{"18av":"1.0.0"}');
});

testWidgets('演员库页签未激活：进得去、只有中文引导、无作品卡、无英文异常', (
tester,
) async {
final store = LocalStore();
addTearDown(store.dispose);
File(externalDb).writeAsStringSync('EXTDB');
final source = fakeSource(
externalPath: externalDb,
importedPath: importedDb,
);
await tester.pumpWidget(
MaterialApp(
home: ActressLibraryNativePage(
repository: _Repo(),
store: store,
fallback: ActressLibraryDbFallback(
pathResolver: source.effectiveDbPath,
),
onlineFetch: (_, __) async => '',
),
),
);
for (var i = 0; i < 30; i++) {
await tester.pump(const Duration(milliseconds: 50));
}
// 页签本体在（进得去）。
expect(find.text('演员库'), findsOneWidget);
// 只有中文激活引导＋去管理入口。
expect(find.textContaining('还没激活'), findsWidgets);
expect(find.text('去授权 / 打开管理'), findsOneWidget);
// 不出演员不出作品。
expect(find.byKey(const ValueKey('native-work-ssis-001')), findsNothing);
// 界面不露英文异常原文。
expect(find.textContaining('Exception'), findsNothing);
expect(find.textContaining('Bad state'), findsNothing);
});
});

group('边界：存量与已并入不受版本门回头拦', () {
test('存量 legacy 激活后导入库被改（磁力并入）仍激活', () async {
// 磁力库合并落导入库槽、会改动已激活库文件；激活是
// 槽位级的，文件内容变化不掉激活——「导入进来了的
// 不受影响」（用户 2026-11-27 21:31 口径）。
File(importedDb).writeAsStringSync('IMPDB');
final source = fakeSource(
externalPath: externalDb,
importedPath: importedDb,
);
var status = await source.status();
expect(status.activation!.isLegacy, isTrue);
// 模拟磁力合并往库里追加了数据。
File(importedDb).writeAsStringSync('IMPDB+MAGNET', mode: FileMode.append);
status = await source.status();
expect(status.activated, isTrue);
expect(status.effectivePath, importedDb);
});

test('激活后全链闭环：source 给路径、读库层回 ok:true', () async {
File(importedDb).writeAsStringSync('IMPDB');
final source = fakeSource(
externalPath: externalDb,
importedPath: importedDb,
);
await source.markActivated(
origin: 'import',
libraryVersion: '20261127v5',
);
expect(await source.effectiveDbPath(), importedDb);
final fallback = ActressLibraryDbFallback(
pathResolver: source.effectiveDbPath,
opener: (path) async => (sql, [args]) async {
if (sql.contains('sqlite_master')) {
return [
{'name': 'videos'},
{'name': 'video_play_urls'},
{'name': 'video_actress'},
{'name': 'actresses'},
{'name': 'index_categories'},
];
}
return [
{'name': '中文字幕', 'cnt': 3},
];
},
);
final result = await fallback.handle({'op': 'tags'});
expect(result['ok'], isTrue, reason: '${result['error']}');
});
});
}
