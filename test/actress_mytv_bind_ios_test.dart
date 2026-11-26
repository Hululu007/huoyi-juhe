// iOS 演员库平台门（2026-11-26 用户令）：iOS 走 .sql 导入制。
// 断言四件：
// 1. 未导入时：未绑定、空库、accessVia=iosImport、文案指去导入；
//    外部根目录/写探针/权限检查一行都不许被调（安卓阶梯不执行）。
// 2. 私有目录里有导入落成的库时：绑它，dbPath 就是那份私有库。
// 3. requestPermission / grantFolderAccess / grantFileAccess 在
//    iOS 上恒 false 且不碰 SAF（安卓概念不许漏到 iOS）。
// 4. iosDbPath 与绑定解析的落点一致（导入器换库的目标路径）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_mytv_bind.dart';
import 'package:fqapp/actress/actress_storage_access.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;
  var externalRootCalls = 0;
  var writeProbeCalls = 0;
  var permissionCheckCalls = 0;
  var pickTreeCalls = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    docsDir = Directory.systemTemp.createTempSync('actress_bind_ios');
    externalRootCalls = 0;
    writeProbeCalls = 0;
    permissionCheckCalls = 0;
    pickTreeCalls = 0;
    addTearDown(() {
      if (docsDir.existsSync()) docsDir.deleteSync(recursive: true);
    });
  });

  ActressMytvBind makeIosBind() {
    return ActressMytvBind(
      isIOS: () => true,
      documentsDir: () async => docsDir,
      externalRoot: () async {
        externalRootCalls++;
        return Directory.systemTemp;
      },
      writeProbe: (_, _) async {
        writeProbeCalls++;
        return true;
      },
      hasAllFilesAccess: () async {
        permissionCheckCalls++;
        return true;
      },
      requestAllFilesAccess: () async => true,
      storageAccess: ActressStorageAccess(
        pickTree: () async {
          pickTreeCalls++;
          return {'uri': 'content://fake'};
        },
        pickFile: () async => null,
        listDbFiles: (_) async => const [],
        statDocument: (_) async => null,
        copyDocument: (_, _) async => 0,
        hasGrant: (_) async => true,
      ),
    );
  }

  void expectAndroidLadderUntouched() {
    expect(externalRootCalls, 0, reason: 'iOS 不许解析外部根目录');
    expect(writeProbeCalls, 0, reason: 'iOS 不许跑写探针');
    expect(permissionCheckCalls, 0, reason: 'iOS 不许查文件权限');
  }

  test('未导入：空态 + 导入文案，安卓阶梯一行不跑', () async {
    final bind = makeIosBind();
    final result = await bind.ensureBound();
    expect(result.bound, isFalse);
    expect(result.hasVideoDb, isFalse);
    expect(result.dbPath, isEmpty);
    expect(result.needsPermission, isFalse);
    expect(result.accessVia, 'iosImport');
    expect(result.externalRoot, isNull);
    expect(result.note, contains('导入'));
    expectAndroidLadderUntouched();
  });

  test('已导入：绑私有目录里那份库', () async {
    final dir = Directory(path.join(docsDir.path, 'actress'))
      ..createSync(recursive: true);
    final dbFile = File(path.join(dir.path, '女优库.db'))
      ..writeAsBytesSync([1, 2, 3]);
    final bind = makeIosBind();
    final result = await bind.ensureBound();
    expect(result.bound, isTrue);
    expect(result.hasVideoDb, isTrue);
    expect(result.dbPath, dbFile.path);
    expect(result.note, isNull);
    expectAndroidLadderUntouched();
    // 导入器换库目标与绑定落点一致。
    expect(await bind.iosDbPath(), dbFile.path);
  });

  test('权限与 SAF 入口在 iOS 上恒关死', () async {
    final bind = makeIosBind();
    expect(await bind.requestPermission(), isFalse);
    expect(await bind.grantFolderAccess(), isFalse);
    expect(await bind.grantFileAccess(), isFalse);
    expect(pickTreeCalls, 0, reason: 'iOS 不许弹 SAF 选择器');
    expectAndroidLadderUntouched();
  });
}
