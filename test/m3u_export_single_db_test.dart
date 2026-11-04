import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/m3u_export_db.dart';
import 'package:hive_ce/hive.dart';

M3uExportCategoryInfo category({
  required String siteId,
  required String siteName,
  String categoryId = '1',
  String categoryName = '电影',
}) {
  return M3uExportCategoryInfo(
    siteId: siteId,
    siteName: siteName,
    categoryId: categoryId,
    categoryName: categoryName,
    categoryPath: categoryName,
    updatedAt: 1,
  );
}

M3uExportVideoRecord video({
  required String siteId,
  required String siteName,
  required String videoId,
  String localPath = '',
}) {
  return M3uExportVideoRecord(
    siteId: siteId,
    siteName: siteName,
    categoryId: '1',
    categoryName: '电影',
    categoryPath: '电影',
    videoId: videoId,
    title: '片$videoId',
    url: 'https://cdn.example.com/$videoId.m3u8',
    localPath: localPath,
    cover: '',
    synopsis: '',
    updatedAt: 1,
  );
}

void main() {
  group('单库', () {
    test('多站多源同箱：内存箱只有一张分类表、一张视频表', () async {
      final db = MemoryM3uExportDb();
      await db.saveExport(
        siteId: 'hongguo',
        siteName: '红果',
        categories: [category(siteId: 'hongguo', siteName: '红果')],
        videos: [
          video(siteId: 'hongguo', siteName: '红果', videoId: 'h1'),
        ],
      );
      await db.saveExport(
        siteId: 'py_x',
        siteName: 'py 站',
        categories: [category(siteId: 'py_x', siteName: 'py 站')],
        videos: [
          video(
            siteId: 'py_x',
            siteName: 'py 站',
            videoId: 'p1',
            localPath: '/tmp/p1.m3u8',
          ),
        ],
      );
      await db.saveExport(
        siteId: 'host:zywest263.com',
        siteName: '花果采集',
        categories: [
          category(siteId: 'host:zywest263.com', siteName: '花果采集'),
        ],
        videos: [
          video(
            siteId: 'host:zywest263.com',
            siteName: '花果采集',
            videoId: 'z1',
          ),
        ],
      );
      expect(db.categories.length, 3);
      expect(db.videos.length, 3);
      final all = await db.listVideos(gateOpen: true);
      expect(all.map((row) => row.videoId).toSet(), {'h1', 'p1', 'z1'});
      final py = await db.listVideos(gateOpen: true, siteId: 'py_x');
      expect(py.map((row) => row.videoId).toList(), ['p1']);
      expect(py.first.url, 'https://cdn.example.com/p1.m3u8');
      expect(py.first.localPath, '/tmp/p1.m3u8');
    });

    test('实箱单文件：多站多源写进公开目录后只有一个 .hive 文件', () async {
      final globalDir =
          await Directory.systemTemp.createTemp('huiju_single_global_');
      final temp = await Directory.systemTemp.createTemp('huiju_single_pub_');
      Hive.init(globalDir.path);
      try {
        final publicDir = Directory('${temp.path}/火蚁聚合');
        final db = HiveM3uExportDb(
          directoryResolver: () async => publicDir,
        );
        await db.saveExport(
          siteId: 'hongguo',
          siteName: '红果',
          categories: [category(siteId: 'hongguo', siteName: '红果')],
          videos: [video(siteId: 'hongguo', siteName: '红果', videoId: 'h1')],
        );
        await db.saveExport(
          siteId: 'py_x',
          siteName: 'py 站',
          categories: [category(siteId: 'py_x', siteName: 'py 站')],
          videos: [video(siteId: 'py_x', siteName: 'py 站', videoId: 'p1')],
        );
        final hiveFiles = publicDir
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.hive'))
            .toList();
        expect(hiveFiles.length, 1);
        expect(hiveFiles.first.path, contains('m3u_export_v1_pub'));
        final all = await db.listVideos(gateOpen: true);
        expect(all.map((row) => row.videoId).toSet(), {'h1', 'p1'});
      } finally {
        try {
          if (EncryptedHive.isBoxOpen(Hive, 'm3u_export_v1_pub')) {
            await EncryptedHive.box<dynamic>(Hive, 'm3u_export_v1_pub')
                .close();
          }
        } catch (_) {}
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        if (globalDir.existsSync()) globalDir.deleteSync(recursive: true);
      }
    });
  });
}
