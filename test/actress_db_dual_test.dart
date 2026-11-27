import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_db_import.dart';
import 'package:fqapp/actress/actress_db_manage_page.dart';
import 'package:fqapp/actress/actress_db_source.dart';
import 'package:fqapp/actress/actress_library_version.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 双库＋激活批测试：来源层（选择存取兼容、激活解析、存量
/// 过渡）、.db 收编判定与版本门（注入式假校验器/假版本检查，
/// 不硬依赖真机 sqflite）、外置导入激活、管理页两卡渲染与
/// 未激活引导。sqflite 在 flutter test 里跑不起来，凡是要真
/// 开库的地方都注入假件（与 actress_sql_import_test 同款口径）。

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

/// 带完整版本字段的假版本信息（版本门通过样）。
const stampedInfo = ActressLibraryVersionInfo(
  format: 'actress_library',
  formatVersion: '1',
  coreVersion: '2026.11.27',
  libraryVersion: '20261127v5',
);

/// 版本门放行假件。
Future<({ActressLibraryVersionInfo info, String? error})> passingVersion(
  String path,
) async => (info: stampedInfo, error: null);

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

  group('ActressDbSource 选择存取（存量兼容）', () {
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

  group('ActressDbSource 激活与生效路径', () {
    test('只有外置文件：未激活、生效路径为空（外置只是导入来源）', () async {
      File(externalDb).writeAsStringSync('EXT');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      final status = await source.status();
      expect(status.activated, isFalse);
      expect(status.activation, isNull);
      expect(status.effectivePath, '');
      expect(await source.effectiveDbPath(), '');
      expect(status.external.exists, isTrue);
      expect(status.imported.exists, isFalse);
      expect(status.isEffective(ActressDbSlot.external), isFalse);
      expect(status.isEffective(ActressDbSlot.imported), isFalse);
    });

    test('存量过渡：导入库在、无激活记录 → legacy 补记并生效，重启仍在', () async {
      File(externalDb).writeAsStringSync('EXT');
      File(importedDb).writeAsStringSync('IMP');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      final status = await source.status();
      expect(status.activated, isTrue);
      expect(status.activation!.origin, 'legacy');
      expect(status.activation!.isLegacy, isTrue);
      expect(status.effectiveSlot, ActressDbSlot.imported);
      expect(status.effectivePath, importedDb);
      // 补记落盘：新实例（模拟重启）读到同一条 legacy 记录。
      final reopened = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      final again = await reopened.status();
      expect(again.activated, isTrue);
      expect(again.activation!.origin, 'legacy');
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(actressDbActivationPrefsKey),
        contains('"legacy"'),
      );
    });

    test('markActivated 落 import 记录；删导入库回未激活并清记录', () async {
      File(importedDb).writeAsStringSync('IMP');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      await source.markActivated(
        origin: 'import',
        libraryVersion: '20261127v5',
        formatVersion: '1',
        coreVersion: '2026.11.27',
      );
      var status = await source.status();
      expect(status.activated, isTrue);
      expect(status.activation!.origin, 'import');
      expect(status.activation!.libraryVersion, '20261127v5');
      expect(await source.deleteImported(), isTrue);
      status = await source.status();
      expect(status.activated, isFalse);
      expect(status.effectivePath, '');
      expect(await source.loadActivation(), isNull);
    });

    test('有激活记录但导入库文件没了：未激活', () async {
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      await source.markActivated(origin: 'import');
      final status = await source.status();
      expect(status.activated, isFalse);
      expect(status.activation, isNull);
      expect(status.effectivePath, '');
    });

    test('两个槽都不可用：生效路径为空', () async {
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      final status = await source.status();
      expect(status.activated, isFalse);
      expect(status.effectivePath, '');
      expect(await source.effectiveDbPath(), '');
    });

    test('空文件不算就绪：外置空文件不算在、导入空文件不补记存量', () async {
      File(externalDb).writeAsStringSync('');
      File(importedDb).writeAsStringSync('');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      final status = await source.status();
      expect(status.external.exists, isFalse);
      expect(status.imported.exists, isFalse);
      expect(status.activated, isFalse);
      expect(await source.loadActivation(), isNull);
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
      ActressDbValidator validator, {
      ActressDbVersionChecker? versionChecker,
    }) => ActressDbImportService(
      source: source,
      dbValidator: validator,
      dbVersionChecker: versionChecker ?? passingVersion,
    );

    test('校验＋版本都过：拷进 imported 槽、旧 imported 留 .bak、落激活记录', () async {
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
      // 激活记录落下（origin=import、带版本信息）。
      final status = await source.status();
      expect(status.activated, isTrue);
      expect(status.activation!.origin, 'import');
      expect(status.activation!.libraryVersion, '20261127v5');
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

    test('版本字段缺失被拒：连复制都不发生、imported 不动、不关库、无新激活', () async {
      File(importedDb).writeAsStringSync('OLDIMP');
      final picked = File('${tempDir.path}/old.db')
        ..writeAsStringSync('OLDDB');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      var closeCalls = 0;
      final outcome = await serviceWith(
        source,
        (_) async => const ActressDbValidation(ok: true, works: 7),
        versionChecker: (_) async => (
          info: const ActressLibraryVersionInfo(),
          error: actressLibraryVersionError(
            const ActressLibraryVersionInfo(),
          ),
        ),
      ).importLocalFile(
        localPath: picked.path,
        closeDatabase: () async => closeCalls++,
      );
      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('没有版本字段'));
      expect(outcome.needsReload, isFalse);
      expect(closeCalls, 0);
      expect(File(importedDb).readAsStringSync(), 'OLDIMP');
      expect(File('$importedDb.bak').existsSync(), isFalse);
      expect(File('$importedDb.importing-db').existsSync(), isFalse);
    });

    test('核心版本对不上被拒：imported 不动', () async {
      File(importedDb).writeAsStringSync('OLDIMP');
      final picked = File('${tempDir.path}/future.db')
        ..writeAsStringSync('FUTUREDB');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      const futureInfo = ActressLibraryVersionInfo(
        format: 'actress_library',
        formatVersion: '1',
        coreVersion: '2027.01.01',
        libraryVersion: '20270101',
      );
      final outcome = await serviceWith(
        source,
        (_) async => const ActressDbValidation(ok: true, works: 7),
        versionChecker: (_) async => (
          info: futureInfo,
          error: actressLibraryVersionError(futureInfo),
        ),
      ).importLocalFile(localPath: picked.path, closeDatabase: () async {});
      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('要求核心版本 2027.01.01'));
      expect(outcome.error, contains('2026.11.27'));
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

  group('ActressDbImportService 外置导入激活', () {
    test('外置在、校验与版本都过：拷入 imported、外置原样、已激活', () async {
      File(externalDb).writeAsStringSync('EXTDB');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      final service = ActressDbImportService(
        source: source,
        dbValidator: (_) async =>
            const ActressDbValidation(ok: true, works: 9),
        dbVersionChecker: passingVersion,
      );
      final outcome = await service.importExternalFile(
        closeDatabase: () async {},
      );
      expect(outcome.ok, isTrue, reason: outcome.error);
      expect(outcome.videos, 9);
      expect(File(importedDb).readAsStringSync(), 'EXTDB');
      // 外置文件只读：内容一字未动。
      expect(File(externalDb).readAsStringSync(), 'EXTDB');
      final status = await source.status();
      expect(status.activated, isTrue);
      expect(status.activation!.origin, 'import');
    });

    test('外置没绑定（路径为空）：中文报错', () async {
      final source = ActressDbSource(
        externalPath: () async => '',
        importedPath: () async => importedDb,
        worksCounter: (_) async => 0,
        isIOS: () => false,
      );
      final service = ActressDbImportService(
        source: source,
        dbValidator: (_) async =>
            const ActressDbValidation(ok: true, works: 1),
        dbVersionChecker: passingVersion,
      );
      final outcome = await service.importExternalFile(
        closeDatabase: () async {},
      );
      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('还没绑定'));
    });

    test('外置版本门不过：拒、imported 不落地', () async {
      File(externalDb).writeAsStringSync('EXTDB');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      final service = ActressDbImportService(
        source: source,
        dbValidator: (_) async =>
            const ActressDbValidation(ok: true, works: 9),
        dbVersionChecker: (_) async => (
          info: const ActressLibraryVersionInfo(),
          error: actressLibraryVersionError(
            const ActressLibraryVersionInfo(),
          ),
        ),
      );
      final outcome = await service.importExternalFile(
        closeDatabase: () async {},
      );
      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('没有版本字段'));
      expect(File(importedDb).existsSync(), isFalse);
    });
  });

  group('ActressDbManagePage 管理页', () {
    ActressDbImportService pageService(
      ActressDbSource source, {
      ActressDbVersionChecker? versionChecker,
      int works = 1,
    }) => ActressDbImportService(
      source: source,
      dbValidator: (_) async => ActressDbValidation(ok: true, works: works),
      dbVersionChecker: versionChecker ?? passingVersion,
    );

    Future<ActressDbSource> pumpPage(
      WidgetTester tester, {
      bool withExternal = true,
      bool withImported = true,
      ActressDbVersionChecker? versionChecker,
      int serviceWorks = 1,
    }) async {
      // 组装接缝（20261127+3）：管理页新增站点库区后整页变高，
      // 默认 800x600 视口下双库卡片落到折叠线以下、ListView 不
      // 构建，finder 找不到。把测试视口加高让整页都构建出来，
      // 断言一字不动（与站点库批给本文件补滚动同一口径的等价法）。
      tester.view.physicalSize = const Size(800, 2800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      if (withExternal) File(externalDb).writeAsStringSync('EXTDB');
      if (withImported) File(importedDb).writeAsStringSync('IMPDB');
      final source = fakeSource(
        externalPath: externalDb,
        importedPath: importedDb,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ActressDbManagePage(
            source: source,
            importService: pageService(
              source,
              versionChecker: versionChecker,
              works: serviceWorks,
            ),
            onLibraryChanged: () async {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      return source;
    }

    testWidgets('两张卡渲染：存量已激活、当前标记在导入卡、无切换钮', (tester) async {
      await pumpPage(tester);
      expect(find.byKey(const ValueKey('dual-card-external')), findsOneWidget);
      expect(find.byKey(const ValueKey('dual-card-imported')), findsOneWidget);
      expect(find.text('外置库（导入来源）'), findsOneWidget);
      expect(find.text('导入库（已激活）'), findsOneWidget);
      // 导入库在 = 存量 legacy 已激活：当前标记在导入卡上。
      expect(find.byKey(const ValueKey('dual-current-imported')), findsOneWidget);
      expect(find.byKey(const ValueKey('dual-current-external')), findsNothing);
      // 激活制下没有切换钮；外置卡有「导入激活」。
      expect(find.byKey(const ValueKey('dual-switch-imported')), findsNothing);
      expect(find.byKey(const ValueKey('dual-switch-external')), findsNothing);
      expect(find.byKey(const ValueKey('dual-import-external')), findsOneWidget);
      // 激活行在、且是已激活（存量）。
      expect(find.byKey(const ValueKey('dual-activation-line')), findsOneWidget);
      expect(find.textContaining('已激活 · 存量库'), findsOneWidget);
      // 已激活时没有未激活引导。
      expect(find.byKey(const ValueKey('activation-guide')), findsNothing);
      // 作品数由假统计给出（两槽各 42）。
      expect(find.textContaining('作品数：42'), findsNWidgets(2));
      // 删除只在导入卡有。
      expect(find.byKey(const ValueKey('dual-delete-imported')), findsOneWidget);
      expect(find.byKey(const ValueKey('dual-import-button')), findsOneWidget);
    });

    testWidgets('未激活态：引导出现、外置卡可导入、两卡都无当前标记', (tester) async {
      await pumpPage(tester, withImported: false);
      expect(find.byKey(const ValueKey('activation-guide')), findsOneWidget);
      expect(find.textContaining('演员库还没激活'), findsWidgets);
      expect(find.byKey(const ValueKey('dual-import-external')), findsOneWidget);
      expect(find.byKey(const ValueKey('dual-current-imported')), findsNothing);
      expect(find.byKey(const ValueKey('dual-current-external')), findsNothing);
      expect(find.textContaining('激活：未激活'), findsOneWidget);
      // 导入库不存在：没有删除钮。
      expect(find.byKey(const ValueKey('dual-delete-imported')), findsNothing);
    });

    testWidgets('点导入激活（外置）：成功提示出现、引导消失', (tester) async {
      final source = await pumpPage(
        tester,
        withImported: false,
        serviceWorks: 7,
      );
      // 成功路要真拷文件：dart:io 异步在假时钟里不返回，整条
      // 点击链放进 runAsync 真时间里跑（AGENTS.md 2026-11-18 课）。
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('dual-import-external')));
        for (var i = 0; i < 30; i++) {
          await Future.delayed(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 50));
          if (find
              .text('外置库导入成功，已激活：7 部作品')
              .evaluate()
              .isNotEmpty) {
            break;
          }
        }
      });
      expect(find.text('外置库导入成功，已激活：7 部作品'), findsOneWidget);
      expect(find.byKey(const ValueKey('activation-guide')), findsNothing);
      expect(find.byKey(const ValueKey('dual-current-imported')), findsOneWidget);
      final status = await source.status();
      expect(status.activated, isTrue);
      expect(status.activation!.origin, 'import');
    });

    testWidgets('点导入激活被版本门拒：中文原因上屏、仍未激活', (tester) async {
      await pumpPage(
        tester,
        withImported: false,
        versionChecker: (_) async => (
          info: const ActressLibraryVersionInfo(),
          error: actressLibraryVersionError(
            const ActressLibraryVersionInfo(),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('dual-import-external')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      expect(find.byKey(const ValueKey('dual-error')), findsOneWidget);
      expect(find.textContaining('没有版本字段'), findsWidgets);
      expect(find.byKey(const ValueKey('activation-guide')), findsOneWidget);
      expect(find.byKey(const ValueKey('dual-current-imported')), findsNothing);
    });
  });
}
