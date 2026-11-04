import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/m3u_export_db.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory globalDir;

  setUpAll(() async {
    globalDir = await Directory.systemTemp.createTemp('huiju_global_');
    Hive.init(globalDir.path);
  });

  tearDownAll(() async {
    if (globalDir.existsSync()) globalDir.deleteSync(recursive: true);
  });

  tearDown(() async {
    for (final name in ['m3u_export_v1_pub', 'm3u_export_v1']) {
      try {
        if (EncryptedHive.isBoxOpen(Hive, name)) {
          await EncryptedHive.box<dynamic>(Hive, name).close();
        }
      } catch (_) {}
    }
  });

  M3uExportCategoryInfo category({
    String categoryId = '1',
    String parentId = '',
  }) {
    return M3uExportCategoryInfo(
      siteId: 'py_site',
      siteName: 'py 站',
      categoryId: categoryId,
      categoryName: '电影',
      categoryPath: '电影',
      parentId: parentId,
      updatedAt: 1,
    );
  }

  M3uExportVideoRecord video() {
    return const M3uExportVideoRecord(
      siteId: 'py_site',
      siteName: 'py 站',
      categoryId: '1',
      categoryName: '电影',
      videoId: 'v1',
      title: '片一',
      url: 'https://cdn.example.com/v1.m3u8',
      cover: '',
      synopsis: '',
      updatedAt: 1,
    );
  }

  test('公开目录箱：文件夹不存在自动建，箱文件落在该目录', () async {
    final temp = await Directory.systemTemp.createTemp('huiju_pub_');
    try {
      final publicDir = Directory('${temp.path}/火蚁聚合');
      expect(publicDir.existsSync(), isFalse);
      final db = HiveM3uExportDb(
        directoryResolver: () async => publicDir,
      );
      await db.saveExport(
        siteId: 'py_site',
        siteName: 'py 站',
        categories: [category()],
        videos: [video()],
      );
      expect(publicDir.existsSync(), isTrue);
      final hiveFiles = publicDir
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.hive'))
          .toList();
      expect(hiveFiles, isNotEmpty);
      expect(hiveFiles.first.path, contains('m3u_export_v1_pub'));
      final rows = await db.listVideos(gateOpen: true);
      expect(rows.map((row) => row.videoId).toList(), ['v1']);
      final cats = await db.listCategories(gateOpen: true);
      expect(cats.first.parentId, isEmpty);
    } finally {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    }
  });

  test('旧箱迁移：公开箱为空时旧箱数据全量拷过去，旧箱保留', () async {
    final legacy = await EncryptedHive.openBox<dynamic>(Hive, 'm3u_export_v1');
    await legacy.putAll({
      category(categoryId: '9').key: category(categoryId: '9').toMap(),
      video().key: video().toMap(),
    });
    final temp = await Directory.systemTemp.createTemp('huiju_pub2_');
    try {
      final db = HiveM3uExportDb(
        directoryResolver: () async => Directory('${temp.path}/火蚁聚合'),
      );
      final rows = await db.listVideos(gateOpen: true);
      expect(rows.map((row) => row.videoId).toList(), ['v1']);
      final cats = await db.listCategories(gateOpen: true);
      expect(cats.map((cat) => cat.categoryId).toList(), ['9']);
      expect(legacy.isNotEmpty, isTrue);
    } finally {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    }
  });

  test('层级字段：父分类 id 往返保留，缺省为空', () {
    final withParent = category(categoryId: '2', parentId: '1');
    expect(withParent.parentId, '1');
    final restored =
        M3uExportCategoryInfo.fromMap(withParent.toMap())!;
    expect(restored.parentId, '1');
    expect(restored.categoryPath, '电影');
    final oldShape = Map<String, dynamic>.from(withParent.toMap())
      ..remove('parentId');
    expect(M3uExportCategoryInfo.fromMap(oldShape)!.parentId, isEmpty);
  });
}
