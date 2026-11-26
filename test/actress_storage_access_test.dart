// 演员库安卓兼容批（2026-11-26）补测：SAF 存储授权层。
// 1. 镜像同步：首次全拷、二次零拷（戳记命中）、变更只拷一本、
//    授权里去掉的库镜像被清、主库认 db/女优库.db。
// 2. 没有主库（目录里没 女优库.db）：报清原因、副库镜像仍在。
// 3. 单文件授权：选的那本就是主库，不论文件名。
// 4. 主库拷贝失败：整单失败报清；副库失败只跳过。
// 5. 授权存档：SharedPreferences 往返与清除。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_storage_access.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

/// 假通道层：文档清单与内容由测试给，copy 真写文件（镜像逻辑
/// 要验真实落盘与戳记）。
class _FakeStorage {
  _FakeStorage(this.docs, this.contents);

  List<ActressDbDocument> docs;
  final Map<String, List<int>> contents;
  final copiedUris = <String>[];
  String? failCopyUri;

  ActressStorageAccess get access => ActressStorageAccess(
    pickTree: () async => null,
    pickFile: () async => null,
    listDbFiles: (_) async => docs,
    statDocument: (_) async => null,
    copyDocument: (uri, destPath) async {
      if (uri == failCopyUri) throw StateError('假拷贝失败');
      final bytes = contents[uri] ?? const [1];
      await File(destPath).writeAsBytes(bytes, flush: true);
      copiedUris.add(uri);
      return bytes.length;
    },
    hasGrant: (_) async => true,
  );
}

ActressDbDocument _doc(
  String relPath, {
  required String uri,
  required int size,
  int lastModifiedMs = 1000,
}) {
  return ActressDbDocument(
    uri: uri,
    name: path.basename(relPath),
    relPath: relPath,
    size: size,
    lastModifiedMs: lastModifiedMs,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;
  setUp(() {
    docsDir = Directory.systemTemp.createTempSync('actress_mirror_test');
    addTearDown(() {
      if (docsDir.existsSync()) docsDir.deleteSync(recursive: true);
    });
  });

  group('镜像同步', () {
    test('首次全拷、主库认 db/女优库.db、二次零拷、变更只拷一本', () async {
      final main = _doc('db/女优库.db', uri: 'u-main', size: 4);
      final side = _doc('db/副库.db', uri: 'u-side', size: 3);
      final fake = _FakeStorage([main, side], {
        'u-main': [1, 2, 3, 4],
        'u-side': [5, 6, 7],
      });
      final mirror = ActressDbMirror(access: fake.access);

      final first = await mirror.sync(
        documentsDir: docsDir,
        treeUri: 'content://tree/MYTV',
      );
      expect(first.ok, isTrue);
      expect(first.copiedCount, 2);
      expect(
        first.mainDbPath,
        path.join(
          docsDir.path,
          ActressDbMirror.mirrorDirName,
          'db__女优库.db',
        ),
      );
      expect(first.dbPaths.length, 2);
      expect(File(first.mainDbPath).readAsBytesSync(), [1, 2, 3, 4]);

      // 二次同步：戳记命中，一本不拷。
      fake.copiedUris.clear();
      final second = await mirror.sync(
        documentsDir: docsDir,
        treeUri: 'content://tree/MYTV',
      );
      expect(second.ok, isTrue);
      expect(second.copiedCount, 0);
      expect(fake.copiedUris, isEmpty);

      // 主库变了（时间戳变）：只重拷主库。
      fake.docs = [
        _doc('db/女优库.db', uri: 'u-main', size: 4, lastModifiedMs: 2000),
        side,
      ];
      fake.copiedUris.clear();
      final third = await mirror.sync(
        documentsDir: docsDir,
        treeUri: 'content://tree/MYTV',
      );
      expect(third.ok, isTrue);
      expect(third.copiedCount, 1);
      expect(fake.copiedUris, ['u-main']);
    });

    test('授权里去掉的库，镜像被清掉', () async {
      final main = _doc('db/女优库.db', uri: 'u-main', size: 2);
      final side = _doc('db/副库.db', uri: 'u-side', size: 2);
      final fake = _FakeStorage([main, side], {
        'u-main': [1, 2],
        'u-side': [3, 4],
      });
      final mirror = ActressDbMirror(access: fake.access);
      final first = await mirror.sync(
        documentsDir: docsDir,
        treeUri: 'content://tree/MYTV',
      );
      final sideMirror = File(
        path.join(first.mirrorDir.path, 'db__副库.db'),
      );
      expect(sideMirror.existsSync(), isTrue);

      fake.docs = [main];
      final second = await mirror.sync(
        documentsDir: docsDir,
        treeUri: 'content://tree/MYTV',
      );
      expect(second.ok, isTrue);
      expect(sideMirror.existsSync(), isFalse);
      expect(second.dbPaths.length, 1);
    });

    test('目录里没有 女优库.db：报清原因、副库镜像仍在', () async {
      final side = _doc('db/副库.db', uri: 'u-side', size: 2);
      final fake = _FakeStorage([side], {
        'u-side': [3, 4],
      });
      final mirror = ActressDbMirror(access: fake.access);
      final result = await mirror.sync(
        documentsDir: docsDir,
        treeUri: 'content://tree/MYTV',
      );
      expect(result.ok, isFalse);
      expect(result.mainDbPath, isEmpty);
      expect(result.error, contains('没有 女优库.db'));
      expect(result.dbPaths.length, 1);
    });

    test('单文件授权：选的那本就是主库，不论文件名', () async {
      final picked = _doc('AV总库.db', uri: 'u-picked', size: 3);
      final fake = _FakeStorage(const [], {
        'u-picked': [9, 9, 9],
      });
      final mirror = ActressDbMirror(access: fake.access);
      final result = await mirror.sync(
        documentsDir: docsDir,
        fileDoc: picked,
      );
      expect(result.ok, isTrue);
      expect(path.basename(result.mainDbPath), 'AV总库.db');
      expect(File(result.mainDbPath).readAsBytesSync(), [9, 9, 9]);
    });

    test('主库拷贝失败整单失败；副库失败只跳过', () async {
      final main = _doc('db/女优库.db', uri: 'u-main', size: 2);
      final side = _doc('db/副库.db', uri: 'u-side', size: 2);
      final fake = _FakeStorage([main, side], {
        'u-main': [1, 2],
        'u-side': [3, 4],
      });
      final mirror = ActressDbMirror(access: fake.access);

      fake.failCopyUri = 'u-main';
      final failed = await mirror.sync(
        documentsDir: docsDir,
        treeUri: 'content://tree/MYTV',
      );
      expect(failed.ok, isFalse);
      expect(failed.error, contains('主库镜像失败'));

      fake.failCopyUri = 'u-side';
      final partial = await mirror.sync(
        documentsDir: docsDir,
        treeUri: 'content://tree/MYTV',
      );
      expect(partial.mainDbPath, isNotEmpty);
      expect(partial.dbPaths.length, 1);
      expect(partial.error, contains('有库镜像失败'));
    });

    test('空目录：报没有 .db 文件', () async {
      final fake = _FakeStorage(const [], const {});
      final mirror = ActressDbMirror(access: fake.access);
      final result = await mirror.sync(
        documentsDir: docsDir,
        treeUri: 'content://tree/empty',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('没有找到 .db 文件'));
    });
  });

  group('授权存档', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('目录/单文件授权往返与清除', () async {
      await ActressDbGrantStore.saveTree('content://tree/MYTV');
      await ActressDbGrantStore.saveFile('content://doc/1', '总库.db');
      final loaded = await ActressDbGrantStore.load();
      expect(loaded.treeUri, 'content://tree/MYTV');
      expect(loaded.fileUri, 'content://doc/1');
      expect(loaded.fileName, '总库.db');

      await ActressDbGrantStore.clear();
      final cleared = await ActressDbGrantStore.load();
      expect(cleared.treeUri, isNull);
      expect(cleared.fileUri, isNull);
      expect(cleared.fileName, isNull);
    });
  });

  group('文档解析', () {
    test('原生 map 解析：缺字段给默认值，uri 空的丢掉', () {
      final doc = ActressDbDocument.fromNative({
        'uri': 'content://doc/9',
        'name': 'a.db',
        'relPath': 'db/a.db',
        'size': 12,
        'lastModified': 34,
      });
      expect(doc, isNotNull);
      expect(doc!.size, 12);
      expect(doc.lastModifiedMs, 34);
      expect(ActressDbDocument.fromNative({'name': 'x.db'}), isNull);
      expect(ActressDbDocument.fromNative(null), isNull);
    });
  });
}
