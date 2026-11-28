import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_db_import.dart';

/// MYTV/db 直读入口的目录清单口径（2026-11-28 同病同源补修）：
/// 只列 .db/.sql/.sql.gz、带真实路径与大小、按名排序、不读
/// 内容；目录不存在回空表。与站点库 listMytvDbImportFiles
/// 同口径，只是女优库多了 .db。
void main() {
  group('ActressDbImportService.listMytvDbImportFiles', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mytv_list_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    ActressDbImportService service() => ActressDbImportService(
      publicRootProvider: () async => tempDir.path,
    );

    test('目录不存在回空表', () async {
      expect(await service().listMytvDbImportFiles(), isEmpty);
    });

    test('只列 .db/.sql/.sql.gz，按名排序，带路径与大小，子目录不算', () async {
      final dbDir = Directory('${tempDir.path}/MYTV/db')
        ..createSync(recursive: true);
      File('${dbDir.path}/b.sql').writeAsStringSync('12345');
      File('${dbDir.path}/a.db').writeAsStringSync('123');
      File('${dbDir.path}/c.sql.gz').writeAsStringSync('12');
      File('${dbDir.path}/d.txt').writeAsStringSync('nope');
      File('${dbDir.path}/e.SQL').writeAsStringSync('1');
      Directory('${dbDir.path}/sub.db').createSync();

      final files = await service().listMytvDbImportFiles();
      expect(files.map((f) => f.name).toList(), [
        'a.db',
        'b.sql',
        'c.sql.gz',
        'e.SQL',
      ]);
      expect(files.first.path, '${dbDir.path}/a.db');
      expect(files.first.sizeBytes, 3);
      expect(files[1].sizeBytes, 5);
    });
  });
}
