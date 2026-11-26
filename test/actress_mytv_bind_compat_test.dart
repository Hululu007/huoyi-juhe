// 演员库安卓兼容批（2026-11-26）补测：绑定解析四条路。
// 1. 直读直写：写探针过 + 库在 → direct（42 轮原行为不回退）。
// 2. 只读直读：写探针不过但库读得到 → directReadOnly 也绑上。
// 3. 文件夹授权镜像：前两路不通 + SAF 授权在 → mirror 绑镜像。
// 4. 授权失效/什么都没有：明确未绑定 + needsPermission，不静默。
// 5. requestPermission 回设置页打没打开；grantFolderAccess 存档。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_mytv_bind.dart';
import 'package:fqapp/actress/actress_storage_access.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

/// 假 SAF 层：授权与清单由测试控制，copy 真写文件。
ActressStorageAccess _fakeStorage({
  bool grantValid = true,
  List<ActressDbDocument> docs = const [],
  Map<String, List<int>> contents = const {},
  Map<String, Object?>? pickTreeResult,
}) {
  return ActressStorageAccess(
    pickTree: () async => pickTreeResult,
    pickFile: () async => null,
    listDbFiles: (_) async => docs,
    statDocument: (_) async => null,
    copyDocument: (uri, destPath) async {
      final bytes = contents[uri] ?? const [1];
      await File(destPath).writeAsBytes(bytes, flush: true);
      return bytes.length;
    },
    hasGrant: (_) async => grantValid,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory rootDir;
  late Directory docsDir;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    rootDir = Directory.systemTemp.createTempSync('actress_bind_root');
    docsDir = Directory.systemTemp.createTempSync('actress_bind_docs');
    addTearDown(() {
      if (rootDir.existsSync()) rootDir.deleteSync(recursive: true);
      if (docsDir.existsSync()) docsDir.deleteSync(recursive: true);
    });
  });

  ActressMytvBind makeBind({
    bool writeOk = true,
    bool allFiles = false,
    bool settingsOpens = true,
    bool rootAvailable = true,
    ActressStorageAccess? storage,
  }) {
    return ActressMytvBind(
      externalRoot: () async => rootAvailable ? rootDir : null,
      documentsDir: () async => docsDir,
      hasAllFilesAccess: () async => allFiles,
      requestAllFilesAccess: () async => settingsOpens,
      writeProbe: (_, _) async => writeOk,
      storageAccess: storage ?? _fakeStorage(),
    );
  }

  File plantDb() {
    final dbDir = Directory(
      path.join(rootDir.path, 'MYTV', 'db'),
    )..createSync(recursive: true);
    final file = File(path.join(dbDir.path, '女优库.db'));
    file.writeAsBytesSync([1, 2, 3]);
    return file;
  }

  test('直读直写：探针过 + 库在 → direct（原行为）', () async {
    final dbFile = plantDb();
    final bind = makeBind(writeOk: true);
    final result = await bind.ensureBound();
    expect(result.bound, isTrue);
    expect(result.accessVia, 'direct');
    expect(result.dbPath, dbFile.path);
    expect(result.hasVideoDb, isTrue);
    expect(result.needsPermission, isFalse);
  });

  test('只读直读：探针不过但库读得到 → directReadOnly 也绑上', () async {
    final dbFile = plantDb();
    final bind = makeBind(writeOk: false);
    final result = await bind.ensureBound();
    expect(result.bound, isTrue);
    expect(result.accessVia, 'directReadOnly');
    expect(result.dbPath, dbFile.path);
    expect(result.displayPath, contains('只读'));
    // json/m3u 指回应用目录，不再指 MYTV（写不进去）。
    expect(result.jsonDir.path, contains('actress_json'));
  });

  test('什么都没有：未绑定 + needsPermission + 文案带未找到外置数据库', () async {
    final bind = makeBind(writeOk: false);
    final result = await bind.ensureBound();
    expect(result.bound, isFalse);
    expect(result.accessVia, 'none');
    expect(result.needsPermission, isTrue);
    expect(result.note, contains('未找到外置数据库'));
  });

  test('外部存储不可用且无授权：旧空态文案不变', () async {
    final bind = makeBind(rootAvailable: false);
    final result = await bind.ensureBound();
    expect(result.bound, isFalse);
    expect(result.needsPermission, isFalse);
    expect(result.note, '外部存储不可用：未找到外置数据库');
  });

  test('文件夹授权镜像：直读不通 + 授权在 → mirror 绑镜像路径', () async {
    await ActressDbGrantStore.saveTree('content://tree/MYTV');
    final storage = _fakeStorage(
      docs: const [
        ActressDbDocument(
          uri: 'u-main',
          name: '女优库.db',
          relPath: 'db/女优库.db',
          size: 3,
          lastModifiedMs: 1000,
        ),
      ],
      contents: const {
        'u-main': [7, 8, 9],
      },
    );
    final bind = makeBind(writeOk: false, storage: storage);
    final result = await bind.ensureBound();
    expect(result.bound, isTrue);
    expect(result.accessVia, 'mirror');
    expect(result.hasFolderGrant, isTrue);
    expect(result.dbPath, contains(ActressDbMirror.mirrorDirName));
    expect(File(result.dbPath).readAsBytesSync(), [7, 8, 9]);
    expect(result.displayPath, contains('文件夹授权'));
  });

  test('授权已失效：未绑定且文案写清要重新授权', () async {
    await ActressDbGrantStore.saveTree('content://tree/MYTV');
    final bind = makeBind(
      writeOk: false,
      storage: _fakeStorage(grantValid: false),
    );
    final result = await bind.ensureBound();
    expect(result.bound, isFalse);
    expect(result.needsPermission, isTrue);
    expect(result.note, contains('文件夹授权已失效'));
  });

  test('requestPermission 回设置页打没打开', () async {
    expect(await makeBind(settingsOpens: true).requestPermission(), isTrue);
    expect(await makeBind(settingsOpens: false).requestPermission(), isFalse);
  });

  test('grantFolderAccess：选了存档、没选回 false', () async {
    final bind = makeBind(
      storage: _fakeStorage(
        pickTreeResult: {'uri': 'content://tree/MYTV', 'name': 'MYTV'},
      ),
    );
    expect(await bind.grantFolderAccess(), isTrue);
    final grant = await ActressDbGrantStore.load();
    expect(grant.treeUri, 'content://tree/MYTV');

    final cancelBind = makeBind(storage: _fakeStorage());
    expect(await cancelBind.grantFolderAccess(), isFalse);
  });
}
