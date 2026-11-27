import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_db_import.dart';
import 'package:fqapp/actress/actress_db_manage_page.dart';
import 'package:fqapp/actress/actress_db_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 双库批测试：来源层（选择存取/生效解析/回落）、.db 收编判定
/// （注入式假校验器，不硬依赖真机 sqflite）、管理页两卡渲染与
/// 切换按钮。sqflite 在 flutter test 里跑不起来，凡是要真开库
/// 的地方都注入假件（与 actress_sql_import_test 同款口径）。

ActressDbSource fakeSource({
  required String externalPath,
  required String importedPath,
  bool isIOS = false,
  int works = 42,
}) {
  return ActressDbSource(
    externalPath: () async => externalPath,
    importedPath: () async => importedPath,
    worksCounter: (_) async => works,
    isIOS: () => isIOS,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String externalDb;
  late String importedDb;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('dual_db_test_');
    externalDb = '${tempDir.path}/external.db';
    importedDb = '${tempDir.path}/actress/imported.db';
    Directory('${tempDir.path}/actress').createSync(recursive: true);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('ActressDbSource 选择存取', () {
    test('安卓默认 external，存 imported 后重启仍是 imported', () async {
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      expect(await source.loadSelection(), ActressDbSlot.external);
      await source.setSelection(ActressDbSlot.imported);
      expect(await source.loadSelection(), ActressDbSlot.imported);
      // 新实例读同一存档（模拟重启）。
      final reopened = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      expect(await reopened.loadSelection(), ActressDbSlot.imported);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(actressDbSlotPrefsKey),
        'imported',
      );
    });

    test('iOS 恒 imported：存了 external 也不认', () async {
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
        isIOS: true,
      );
      await source.setSelection(ActressDbSlot.external);
      expect(await source.loadSelection(), ActressDbSlot.imported);
    });

    test('切换会 bump 变更代次', () async {
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      final before = source.revision.value;
      await source.setSelection(ActressDbSlot.imported);
      expect(source.revision.value, before + 1);
    });
  });

  group('ActressDbSource 生效路径解析', () {
    test('选 external：外置在就用外置', () async {
      File(externalDb).writeAsStringSync('EXT');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      final status = await source.status();
      expect(status.effectiveSlot, ActressDbSlot.external);
      expect(status.effectivePath, externalDb);
      expect(status.fellBack, isFalse);
      expect(status.external.exists, isTrue);
      expect(status.imported.exists, isFalse);
    });

    test('选 imported 且导入库在：用导入库', () async {
      File(externalDb).writeAsStringSync('EXT');
      File(importedDb).writeAsStringSync('IMP');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      await source.setSelection(ActressDbSlot.imported);
      final status = await source.status();
      expect(status.effectiveSlot, ActressDbSlot.imported);
      expect(status.effectivePath, importedDb);
      expect(status.fellBack, isFalse);
    });

    test('选 imported 但导入库缺失：回落外置并标明', () async {
      File(externalDb).writeAsStringSync('EXT');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      await source.setSelection(ActressDbSlot.imported);
      final status = await source.status();
      expect(status.selection, ActressDbSlot.imported);
      expect(status.effectiveSlot, ActressDbSlot.external);
      expect(status.effectivePath, externalDb);
      expect(status.fellBack, isTrue);
    });

    test('两个槽都不可用：生效路径为空', () async {
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      final status = await source.status();
      expect(status.effectivePath, '');
      expect(await source.effectiveDbPath(), '');
    });

    test('空文件不算就绪', () async {
      File(externalDb).writeAsStringSync('');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      final status = await source.status();
      expect(status.external.exists, isFalse);
      expect(status.effectivePath, '');
    });

    test('删除导入库只删 imported，外置不动', () async {
      File(externalDb).writeAsStringSync('EXT');
      File(importedDb).writeAsStringSync('IMP');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      expect(await source.deleteImported(), isTrue);
      expect(File(importedDb).existsSync(), isFalse);
      expect(File(externalDb).readAsStringSync(), 'EXT');
    });
  });

  group('ActressDbImportService .db 收编', () {
    ActressDbImportService serviceWith(
      ActressDbSource source,
      ActressDbValidator validator,
    ) => ActressDbImportService(source: source, dbValidator: validator);

    test('校验过的 .db 拷进 imported 槽，旧 imported 留 .bak', () async {
      File(importedDb).writeAsStringSync('OLDIMP');
      final picked = File('${tempDir.path}/picked.db')
        ..writeAsStringSync('NEWDB');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      var closeCalls = 0;
      final outcome = await serviceWith(
        source,
        (_) async => const ActressDbValidation(ok: true, works: 7),
      ).importLocalFile(
        localPath: picked.path,
        closeDatabase: () async => closeCalls++,
      );
      expect(outcome.ok, isTrue, reason: outcome.error);
      expect(outcome.videos, 7);
      expect(outcome.needsReload, isTrue);
      expect(File(importedDb).readAsStringSync(), 'NEWDB');
      expect(File('$importedDb.bak').readAsStringSync(), 'OLDIMP');
      expect(File('$importedDb.importing-db').existsSync(), isFalse);
      expect(closeCalls, 1);
      // 选中文件原样保留（没有被原地当库改动过）。
      expect(picked.readAsStringSync(), 'NEWDB');
    });

    test('坏文件被拒：imported 原样不动、不关库', () async {
      File(importedDb).writeAsStringSync('OLDIMP');
      final picked = File('${tempDir.path}/bad.db')
        ..writeAsStringSync('GARBAGE');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      var closeCalls = 0;
      final outcome = await serviceWith(
        source,
        (_) async => const ActressDbValidation(
          ok: false,
          error: '认不出这个数据库的结构：没有同时带标题与播放地址的作品表',
        ),
      ).importLocalFile(
        localPath: picked.path,
        closeDatabase: () async => closeCalls++,
      );
      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('认不出'));
      expect(outcome.needsReload, isFalse);
      expect(closeCalls, 0);
      expect(File(importedDb).readAsStringSync(), 'OLDIMP');
      expect(File('$importedDb.bak').existsSync(), isFalse);
    });

    test('作品数为 0 被拒：imported 不动', () async {
      File(importedDb).writeAsStringSync('OLDIMP');
      final picked = File('${tempDir.path}/empty.db')
        ..writeAsStringSync('EMPTYDB');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      final outcome = await serviceWith(
        source,
        (_) async => const ActressDbValidation(
          ok: false,
          error: '这个数据库里没有作品，已取消导入',
        ),
      ).importLocalFile(localPath: picked.path, closeDatabase: () async {});
      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('没有作品'));
      expect(File(importedDb).readAsStringSync(), 'OLDIMP');
    });

    test('不支持的后缀直接拒绝', () async {
      final picked = File('${tempDir.path}/x.txt')..writeAsStringSync('hi');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      final outcome = await serviceWith(
        source,
        (_) async => const ActressDbValidation(ok: true, works: 1),
      ).importLocalFile(localPath: picked.path, closeDatabase: () async {});
      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('.db'));
    });

    test('文件读不到：中文报错', () async {
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      final outcome = await serviceWith(
        source,
        (_) async => const ActressDbValidation(ok: true, works: 1),
      ).importLocalFile(
        localPath: '${tempDir.path}/missing.db',
        closeDatabase: () async {},
      );
      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('读不到'));
    });

    test('默认校验器挡非 SQLite 文件（文件头判定）', () async {
      final picked = File('${tempDir.path}/fake.db')
        ..writeAsStringSync('这不是数据库，只是一个文本文件改了后缀而已。');
      final validation = await validateActressDbFile(picked.path);
      expect(validation.ok, isFalse);
      expect(validation.error, contains('不是数据库文件'));
    });
  });

  group('ActressDbManagePage 管理页', () {
    Future<ActressDbSource> pumpPage(WidgetTester tester) async {
      File(externalDb).writeAsStringSync('EXTDB');
      File(importedDb).writeAsStringSync('IMPDB');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ActressDbManagePage(
            source: source,
            importService: ActressDbImportService(
              source: source,
              dbValidator: (_) async =>
                  const ActressDbValidation(ok: true, works: 1),
            ),
            onLibraryChanged: () async {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      return source;
    }

    testWidgets('两张卡渲染：状态/作品数/当前标记都在', (tester) async {
      await pumpPage(tester);
      expect(find.byKey(const ValueKey('dual-card-external')), findsOneWidget);
      expect(find.byKey(const ValueKey('dual-card-imported')), findsOneWidget);
      expect(find.text('外置库'), findsOneWidget);
      expect(find.text('导入库'), findsOneWidget);
      // 默认选择 external：外置卡带「当前使用中」，导入卡有切换钮。
      expect(find.byKey(const ValueKey('dual-current-external')), findsOneWidget);
      expect(find.byKey(const ValueKey('dual-switch-imported')), findsOneWidget);
      expect(find.byKey(const ValueKey('dual-switch-external')), findsNothing);
      // 作品数由假统计给出（两槽各 42）。
      expect(find.textContaining('作品数：42'), findsNWidgets(2));
      // 删除只在导入卡有。
      expect(find.byKey(const ValueKey('dual-delete-imported')), findsOneWidget);
      expect(find.byKey(const ValueKey('dual-import-button')), findsOneWidget);
    });

    testWidgets('点切换到导入库：选择存下、标记换位', (tester) async {
      final source = await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('dual-switch-imported')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(await source.loadSelection(), ActressDbSlot.imported);
      expect(find.byKey(const ValueKey('dual-current-imported')), findsOneWidget);
      expect(find.byKey(const ValueKey('dual-switch-external')), findsOneWidget);
      expect(find.text('已切换到导入库'), findsOneWidget);
    });

    testWidgets('导入库缺失时选 imported：回落提示出现', (tester) async {
      File(externalDb).writeAsStringSync('EXTDB');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      await source.setSelection(ActressDbSlot.imported);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressDbManagePage(
            source: source,
            onLibraryChanged: () async {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('dual-fallback-note')), findsOneWidget);
      // 回落时「当前使用中」落在外置卡上。
      expect(find.byKey(const ValueKey('dual-current-external')), findsOneWidget);
      // 导入库不存在：没有切换钮也没有删除钮。
      expect(find.byKey(const ValueKey('dual-switch-imported')), findsNothing);
      expect(find.byKey(const ValueKey('dual-delete-imported')), findsNothing);
    });
  });
}
