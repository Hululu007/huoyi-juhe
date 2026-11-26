import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../services/public_folder.dart';
import 'actress_storage_access.dart';

/// 女优库绑定手机根目录下的 MYTV 文件夹（2026-11-20 用户令）。
///
/// 落点（2026-11-22 用户令最终口径：只读外置数据库，不内置任何
/// 数据库与 JSON 种子）：
/// - `MYTV/db/女优库.db`：唯一数据库。用户发来的视频结构库
///   （videos / video_actress / actresses 表），有就用它；
///   没有就是空库，界面如实提示放入、点“重新加载数据库”再读，
///   不回落任何内置库、不悄悄造数据。
/// - 应用库 `女优库应用.db` 已删除：包里不再带它，加载链里也不再
///   回落到它；老库 `documents/actress.db` 也不再是回退落点。
///   旧版迁移（老库拷进应用库）随之作废。
/// - `MYTV/db/mjv011.json`：本地 json 影子文件（现爬写盘入口，
///   与原来 documents/actress_json/mjv011.json 同一口径）。
/// - `MYTV/m3u/`：用户自己放 m3u 文件的地方（女优合集1.m3u～
///   9.m3u 这种），m3u 兜底先读这里。
///
/// 权限与降级（targetSdk 36，分区存储在安卓 10–16 全版本强制）：
/// 读共享目录里的 .db 只有两条授权路，绑定按顺序试——
/// 1. 直读直写：有“所有文件访问权限”（MANAGE_EXTERNAL_STORAGE）
///    时 MYTV/db 直接建目录、写探针、原地只读开库；
/// 2. 只读直读：写不进去但库文件读得到（容器放行读、目录只读）
///    时也先绑上读，导出/影子文件这类要写的功能自然不可用；
/// 3. 文件夹授权镜像（SAF）：用户用系统选择器选一次 MYTV 目录
///    （或单个 .db 文件），拿持久读授权，把 .db 镜像进应用私有
///    目录再开——不需要全部文件权限，源文件一字不动，镜像在
///    私有可写目录也绕开 WAL 库只读目录建不出 -shm 的坑；
/// 4. 都没有 → 未绑定，女优库显示空态 + 双入口（“授权文件夹
///    读取”首选、“去设置授权”兜底），用户授权后点“重新绑定”
///    再试。设置页打不开（容器无承接方）时原生回明确错误，
///    界面给手动路径文案，不许静默。
///
/// 通道口径（2026-11-26 修）：根目录/权限判定/打开设置页一律走
/// 真通道 `fqapp/public_folder`（PublicFolderPlugin）。此前误用
/// 不存在的 `moyi/device` 通道：根目录只剩路径推导、权限判定
/// 恒 false、“去设置授权”点了没反应——本批一并治掉。
///
/// 鸿蒙 NEXT（卓易通容器）：外部存储实际路径可能与原生安卓不同，
/// 根目录优先走原生 Environment 真根；解析不到、建目录失败时
/// 一律优雅降级走镜像/提示态，不在本机上假装验过——手机待验
/// 清单见 REPORT.md（xiuxian_nvku_android_compat_20261126）。
///
/// 本模块只算路径、建目录，不碰界面、不直接开库：
/// 真正开库的是 [SqfliteActressDatabase._openNow]，它第一次开库
/// 前调 [ensureBound] 拿路径；列表页在 bootstrap 里先调一次，
/// 为的是提前拿到结果显示绑定行、给 json/m3u 指目录。
///
/// iOS 例外（2026-11-26 用户令）：iOS 没有共享目录直读这条路，
/// 演员库改走 .sql 导入制——[_resolve] 在 iOS 上第一步就分流到
/// [_resolveIos]，只认应用私有目录里导入落成的那份库；四路绑定
/// 阶梯（外部根目录、写探针、SAF 镜像、权限设置页）在 iOS 上
/// 一律不执行，iOS 侧不存在任何“打开/挂载外部 .db”的路径。
/// 安卓解析路径一行未动。

/// MYTV 文件夹名（手机根目录下）。
const mytvFolderName = 'MYTV';

/// MYTV 下的两个子文件夹。
const mytvDbFolderName = 'db';
const mytvM3uFolderName = 'm3u';

/// 涩库引擎（py 的 SikuEngine.DB_DIRS）同款补充扫描目录：手机根
/// 目录下这 4 个目录里的 .db 都当女优库源读（递归扫，与 py 的
/// os.walk 一致）。MYTV/db 仍是主目录（绑定落点），这 4 个是
/// 补充——2026-11-21 用户令按 py 逻辑读库、改路径。
const sikuDbScanDirs = ['纯福利/db', '女优库', '私藏视频', 'lz/db'];

/// MYTV/db 里的唯一数据库文件名（2026-11-22 用户令最终口径）：
/// `女优库.db` 是用户发来的视频结构库（videos / video_actress /
/// actresses 表），女优库只读它。应用自己的 persons / works 表
/// 库 `女优库应用.db` 已删除，不再是落点、不再回落。
const mytvVideoDbFileName = '女优库.db';

/// iOS 导入库的私有目录名（应用 documents 下）：.sql 导入落成的
/// 女优库.db 放这里，iOS 绑定只认这一份。
const iosActressDirName = 'actress';

/// 老 json 影子文件目录名（documents 下）。
const legacyJsonDirName = 'actress_json';

/// MYTV 根目录下的合并 JSON 导出落点（不碰 MYTV/db 里正在用的
/// 影子文件，导出只写这一份，用户拷走即用）。
const mytvMergedJsonFileName = 'mjv011.json';

/// 外部存储根目录解析：默认先走平台通道拿真根目录，拿不到再从
/// getExternalStorageDirectory 的应用专属目录往上推（去
/// `/Android/data/<包名>/files` 后缀）；两条路都走不通回 null，
/// 调用方按未绑定处理。
typedef MytvExternalRootResolver = Future<Directory?> Function();

/// “所有文件访问权限”是否已授予。
typedef MytvAllFilesAccessChecker = Future<bool> Function();

/// 打开系统“所有文件访问权限”设置页；回 true = 设置页打开了，
/// false = 打不开（界面据此给手动路径文案）。
typedef MytvAllFilesSettingsOpener = Future<bool> Function();

/// 写探针：建 db/m3u 目录并实写一次，成功回 true（直读直写路的
/// 门槛）。抽出来可注入是为了测试能模拟“写不进去但读得到”。
typedef MytvWriteProbeFn =
    Future<bool> Function(Directory dbDir, Directory m3uDir);

/// documents 目录解析。
typedef MytvDocumentsResolver = Future<Directory> Function();

/// 一次绑定解析的结果：列表页显示绑定行、给 json/m3u 指目录、
/// 导出合并 JSON 落点都用它。
class MytvBindResult {
  const MytvBindResult({
    required this.bound,
    required this.needsPermission,
    required this.root,
    this.externalRoot,
    required this.dbDir,
    required this.m3uDir,
    required this.jsonDir,
    required this.dbPath,
    required this.hasVideoDb,
    required this.displayPath,
    required this.mergedJsonExportPath,
    this.note,
    this.accessVia = 'direct',
    this.hasFolderGrant = false,
  });

  /// true = MYTV 可用，json 与 m3u 都走 MYTV；false = 未绑定
  /// （原因见 [note]），女优库显示空态。
  final bool bound;

  /// true = 没拿到所有文件访问权限，用户去设置授权后点
  /// “重新绑定”可再试一次。
  final bool needsPermission;

  /// MYTV 根目录（未绑定时是 documents 目录，仅作展示与
  /// 导出路径拼接用）。
  final Directory root;

  /// 外部存储根目录（/storage/emulated/0，绑定成功时才有）：
  /// 补充扫描目录（[sikuDbScanDirs]）从这里拼。未绑定时为 null，
  /// 镜像只扫主目录。
  final Directory? externalRoot;

  /// 库目录：MYTV/db 或 documents。
  final Directory dbDir;

  /// m3u 目录：MYTV/m3u 或 documents。
  final Directory m3uDir;

  /// json 影子文件目录：MYTV/db 或 documents/actress_json。
  final Directory jsonDir;

  /// 实际开库路径：MYTV/db/女优库.db；未找到外置库时为空字符串，
  /// 开库方按“没有外置数据库”处理（不回落任何内置库）。
  final String dbPath;

  /// true = MYTV/db/女优库.db 存在且非空，女优库读它；
  /// false = 没有外置库，界面显示空态提示。
  final bool hasVideoDb;

  /// 界面显示的库落点：'MYTV/db/女优库.db'，或未找到时
  /// '未找到外置数据库'。
  final String displayPath;

  /// 合并 JSON 导出落点：MYTV/mjv011.json（只在 bound 时用）。
  final String mergedJsonExportPath;

  /// 未绑定 / 未找到外置库的原因（给界面提示用）；正常时为空。
  final String? note;

  /// 这次绑定走的读取路：`direct` 直读直写 / `directReadOnly`
  /// 只读直读 / `mirror` 文件夹授权镜像 / `none` 未绑定。
  final String accessVia;

  /// true = 有一份还有效的 SAF 文件夹/文件授权（镜像路的根基）。
  final bool hasFolderGrant;
}

/// MYTV 绑定解析：路径、建目录。
///
/// 平台调用全部包在 try/catch 里：测试环境没有平台通道、
/// 鸿蒙容器路径与原生不同，任何一步拿不到都按未绑定处理，
/// 绝不抛错。
class ActressMytvBind {
  ActressMytvBind({
    MytvExternalRootResolver? externalRoot,
    MytvAllFilesAccessChecker? hasAllFilesAccess,
    MytvAllFilesSettingsOpener? requestAllFilesAccess,
    MytvDocumentsResolver? documentsDir,
    ActressStorageAccess? storageAccess,
    MytvWriteProbeFn? writeProbe,
    bool Function()? isIOS,
  }) : _externalRoot = externalRoot ?? _defaultExternalRoot,
       _hasAllFilesAccess = hasAllFilesAccess ?? _defaultHasAllFilesAccess,
       _requestAllFilesAccess =
           requestAllFilesAccess ?? _defaultRequestAllFilesAccess,
       _documentsDir = documentsDir ?? _defaultDocumentsDir,
       _storageAccess = storageAccess ?? ActressStorageAccess.instance,
       _writeProbe = writeProbe ?? _defaultWriteProbe,
       _isIOS = isIOS ?? (() => Platform.isIOS);

  ActressMytvBind._()
    : _externalRoot = _defaultExternalRoot,
      _hasAllFilesAccess = _defaultHasAllFilesAccess,
      _requestAllFilesAccess = _defaultRequestAllFilesAccess,
      _documentsDir = _defaultDocumentsDir,
      _storageAccess = ActressStorageAccess.instance,
      _writeProbe = _defaultWriteProbe,
      _isIOS = (() => Platform.isIOS);

  static final instance = ActressMytvBind._();

  final MytvExternalRootResolver _externalRoot;
  final MytvAllFilesAccessChecker _hasAllFilesAccess;
  final MytvAllFilesSettingsOpener _requestAllFilesAccess;
  final MytvDocumentsResolver _documentsDir;
  final ActressStorageAccess _storageAccess;
  final MytvWriteProbeFn _writeProbe;

  /// 平台门：true 时绑定只走 iOS 的 .sql 导入库解析，安卓的
  /// 外部目录/权限/SAF 整套不执行。默认按 [Platform.isIOS]，
  /// 测试可注入。
  final bool Function() _isIOS;

  MytvBindResult? _cached;
  Future<MytvBindResult>? _pending;

  /// 上次解析结果（首次解析前为空）。
  MytvBindResult? get current => _cached;

  /// 解析一次绑定（结果缓存，并发调用共用同一份）。
  /// [refresh] 为 true 时重新解析（授权后重新绑定、手动“重新加载
  /// 数据库”时用：新放进 MYTV/db 的女优库.db 只有重解析才看得到）。
  Future<MytvBindResult> ensureBound({bool refresh = false}) {
    if (!refresh && _cached != null) return Future.value(_cached);
    var pending = _pending;
    if (!refresh && pending != null) return pending;
    pending = _resolve();
    _pending = pending;
    return pending.then((result) {
      _cached = result;
      _pending = null;
      return result;
    });
  }

  /// 启动时自动生成 MYTV/db 与 MYTV/m3u（2026-11-24 用户令）：
  /// 以前只在进演员库时才调 ensureBound 顺带建目录，不进演员库
  /// 文件夹就一直没有；现在启动先建一次。任何失败自己吞掉，
  /// 不阻塞启动、不抛错（没权限时等用户授权后点“重新绑定”再建）。
  /// [bind] 仅供测试注入，正常调用传空、用单例。
  static Future<void> ensureFoldersAtStartup([
    ActressMytvBind? bind,
  ]) async {
    try {
      await (bind ?? instance).ensureBound();
    } catch (_) {}
  }

  /// iOS 导入库的落点：应用私有目录 actress/女优库.db。
  /// 导入器换库与绑定解析共用这一处，路径只此一份。
  Future<String> iosDbPath() async {
    final docs = await _documentsDir();
    final dir = Directory(path.join(docs.path, iosActressDirName));
    try {
      await dir.create(recursive: true);
    } catch (_) {}
    return path.join(dir.path, mytvVideoDbFileName);
  }

  /// iOS 绑定解析（.sql 导入制）：只看私有目录里导入落成的库，
  /// 在就绑它、不在就是空态 + 导入提示。不调外部根目录、不探
  /// 权限、不碰 SAF——iOS 没有任何挂载外部 .db 的路径。
  Future<MytvBindResult> _resolveIos(Directory docs) async {
    final dir = Directory(path.join(docs.path, iosActressDirName));
    try {
      await dir.create(recursive: true);
    } catch (_) {}
    final dbFile = File(path.join(dir.path, mytvVideoDbFileName));
    var hasVideoDb = false;
    try {
      hasVideoDb = dbFile.existsSync() && dbFile.lengthSync() > 0;
    } catch (_) {
      hasVideoDb = false;
    }
    return MytvBindResult(
      bound: hasVideoDb,
      needsPermission: false,
      root: dir,
      dbDir: dir,
      m3uDir: dir,
      jsonDir: dir,
      dbPath: hasVideoDb ? dbFile.path : '',
      hasVideoDb: hasVideoDb,
      displayPath: hasVideoDb ? '应用内女优库（.sql 导入）' : '尚未导入女优库',
      mergedJsonExportPath: path.join(dir.path, 'mjv011.json'),
      note: hasVideoDb
          ? null
          : 'iOS 版女优库从 .sql 文件导入：打开右上角设置，'
                '在“导入数据库”里选 .sql / .sql.gz 文件',
      accessVia: 'iosImport',
    );
  }

  /// 打开系统“所有文件访问权限”设置页（走 fqapp/public_folder
  /// 真通道）。回 true = 设置页打开了；false = 打不开（容器无
  /// 承接方等），界面据此给手动路径文案，不许静默无反应。
  /// iOS 无此概念，恒回 false 且不调任何通道。
  Future<bool> requestPermission() async {
    if (_isIOS()) return false;
    try {
      return await _requestAllFilesAccess();
    } catch (_) {
      return false;
    }
  }

  /// SAF 文件夹授权：弹系统目录选择器请用户选 MYTV 目录，选好
  /// 存档授权 URI。回 true = 已授权（调用方随后重新绑定，绑定
  /// 解析会走镜像路）；false = 没选/打不开。授权本身不触发镜像
  /// 拷贝，拷贝在下一次绑定解析里按戳记增量做。
  Future<bool> grantFolderAccess() async {
    if (_isIOS()) return false; // SAF 是安卓概念，iOS 不走这条路。
    final picked = await _storageAccess.pickTree();
    final uri = picked?['uri']?.toString() ?? '';
    if (uri.isEmpty) return false;
    await ActressDbGrantStore.saveTree(uri);
    return true;
  }

  /// SAF 单文件授权：选单个 .db 文件（不在 MYTV 目录布局里的库
  /// 也能读）。回值口径同 [grantFolderAccess]。
  Future<bool> grantFileAccess() async {
    if (_isIOS()) return false; // SAF 是安卓概念，iOS 不走这条路。
    final picked = await _storageAccess.pickFile();
    final uri = picked?['uri']?.toString() ?? '';
    if (uri.isEmpty) return false;
    await ActressDbGrantStore.saveFile(
      uri,
      picked?['name']?.toString() ?? '',
    );
    return true;
  }

  static Future<Directory> _defaultDocumentsDir() async {
    try {
      return await getApplicationDocumentsDirectory();
    } catch (_) {
      // 测试环境没有平台通道：用系统临时目录兜底，路径只作
      // 展示与拼接，不会在这里真开库（测试都注入内存库）。
      return Directory.systemTemp;
    }
  }

  static Future<Directory?> _defaultExternalRoot() async {
    // 1）原生真根目录（PublicFolderPlugin 的 publicRoot =
    // Environment.getExternalStorageDirectory）：鸿蒙卓易通容器
    // 里根路径与原生不同、可能不含 /Android/data/ 标记，原生给
    // 什么就是什么。平台调用 5 秒超时：容器里通道迟迟不回时，
    // 开库链（直播首屏、女优库）不能跟着无限等。
    try {
      final root = await PublicFolder.publicRoot().timeout(
        const Duration(seconds: 5),
        onTimeout: () => '',
      );
      if (root.isNotEmpty) {
        final dir = Directory(root);
        if (dir.existsSync()) return dir;
      }
    } catch (_) {
      // 通道没有/旧包没实现：走下面的推导。
    }
    // 2）从应用专属目录往上推：/storage/emulated/0/Android/data/
    // <包名>/files → /storage/emulated/0。容器里这条路径可能
    // 没有 /Android/data/ 标记，推导失败回 null 降级。
    try {
      final ext = await getExternalStorageDirectory().timeout(
        const Duration(seconds: 5),
      );
      if (ext == null) return null;
      const marker = '/Android/data/';
      final idx = ext.path.indexOf(marker);
      if (idx <= 0) return null;
      final dir = Directory(ext.path.substring(0, idx));
      if (dir.existsSync()) return dir;
    } catch (_) {
      return null;
    }
    return null;
  }

  static Future<bool> _defaultHasAllFilesAccess() async {
    try {
      return await PublicFolder.hasAllFilesAccess().timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _defaultRequestAllFilesAccess() {
    return PublicFolder.requestAllFilesAccess();
  }

  /// 直读直写路的写探针：建目录 + 实写一次才算数（目录建得出
  /// 来不等于写得进去）。
  static Future<bool> _defaultWriteProbe(
    Directory dbDir,
    Directory m3uDir,
  ) async {
    try {
      dbDir.createSync(recursive: true);
      m3uDir.createSync(recursive: true);
      final probe = File(path.join(dbDir.path, '.mytv_probe'));
      await probe.writeAsString('ok');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 只读探针：文件能打开读出一个字节就算读得到。
  static Future<bool> _readableProbe(File file) async {
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      await raf.readByte();
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  Future<MytvBindResult> _resolve() async {
    final docs = await _documentsDir();
    // iOS 平台门（2026-11-26 用户令）：第一步就分流，安卓的
    // 外部根目录/写探针/SAF 镜像/权限路在 iOS 上一行都不跑。
    if (_isIOS()) return _resolveIos(docs);
    Directory? externalRoot;
    try {
      externalRoot = await _externalRoot();
    } catch (_) {
      externalRoot = null;
    }
    String? mirrorError;
    var probeFailed = false;
    if (externalRoot != null) {
      final mytvRoot = Directory(
        path.join(externalRoot.path, mytvFolderName),
      );
      final dbDir = Directory(path.join(mytvRoot.path, mytvDbFolderName));
      final m3uDir = Directory(path.join(mytvRoot.path, mytvM3uFolderName));
      final videoDb = File(path.join(dbDir.path, mytvVideoDbFileName));
      var hasVideoDb = false;
      try {
        hasVideoDb = videoDb.existsSync() && videoDb.lengthSync() > 0;
      } catch (_) {
        hasVideoDb = false;
      }
      // 1）直读直写：建目录 + 写探针成功（有全部文件访问权限的
      // 常规路）。没权限时探针抛 EACCES，落到下面两条路。
      var probeOk = false;
      try {
        probeOk = await _writeProbe(dbDir, m3uDir);
      } catch (_) {
        probeOk = false;
      }
      if (probeOk) {
        // 老 json 影子文件拷进 MYTV/db（只补没有的，不覆盖已有
        // 的；拷失败不影响绑定；用户自己的现爬文件，不是内置
        // 数据）。
        try {
          final legacyJsonDir = Directory(
            path.join(docs.path, legacyJsonDirName),
          );
          if (legacyJsonDir.existsSync()) {
            for (final entity in legacyJsonDir.listSync()) {
              if (entity is! File) continue;
              if (!path.basename(entity.path).endsWith('.json')) continue;
              final target = File(
                path.join(dbDir.path, path.basename(entity.path)),
              );
              if (!target.existsSync()) {
                await entity.copy(target.path);
              }
            }
          }
        } catch (_) {
          // json 拷失败不影响绑定。
        }
        // 唯一数据库：MYTV/db/女优库.db。存在且非空就用它；
        // 没有就是空库（note 写清去哪里放、怎么重读），不回落
        // 任何内置库、不建新库、不悄悄造数据。
        try {
          hasVideoDb = videoDb.existsSync() && videoDb.lengthSync() > 0;
        } catch (_) {
          hasVideoDb = false;
        }
        return MytvBindResult(
          bound: true,
          needsPermission: false,
          root: mytvRoot,
          externalRoot: externalRoot,
          dbDir: dbDir,
          m3uDir: m3uDir,
          jsonDir: dbDir,
          dbPath: hasVideoDb ? videoDb.path : '',
          hasVideoDb: hasVideoDb,
          displayPath: hasVideoDb
              ? '$mytvFolderName/$mytvDbFolderName/$mytvVideoDbFileName'
              : '未找到外置数据库',
          mergedJsonExportPath: path.join(mytvRoot.path, mytvMergedJsonFileName),
          note: hasVideoDb
              ? null
              : '未找到外置数据库：请把 女优库.db 放进 MYTV/db/ 文件夹，'
                  '再点“重新加载数据库”',
        );
      }
      probeFailed = true;
      // 2）只读直读：写不进去但库文件读得到（容器放行读、目录
      // 只读等），先绑上读。json/m3u 指回应用目录（与未绑定时
      // 同落点），导出与影子文件这类要写 MYTV 的功能不可用，
      // 但名单/作品/播放这条主链不该被写权限拖死。
      if (hasVideoDb && await _readableProbe(videoDb)) {
        final docsJsonDir = Directory(path.join(docs.path, legacyJsonDirName));
        return MytvBindResult(
          bound: true,
          needsPermission: false,
          root: mytvRoot,
          externalRoot: externalRoot,
          dbDir: dbDir,
          m3uDir: docsJsonDir,
          jsonDir: docsJsonDir,
          dbPath: videoDb.path,
          hasVideoDb: true,
          displayPath:
              '$mytvFolderName/$mytvDbFolderName/$mytvVideoDbFileName（只读）',
          mergedJsonExportPath: path.join(docs.path, mytvMergedJsonFileName),
          accessVia: 'directReadOnly',
        );
      }
    }
    // 3）文件夹授权镜像（SAF）：有还有效的授权就同步镜像再绑。
    final mirror = await _tryMirrorBind(docs, onError: (e) => mirrorError = e);
    if (mirror != null) return mirror;
    // 4）权限提示态：分清「外部存储根本不可用」与「就差授权」。
    if (externalRoot == null && mirrorError == null) {
      return _fallbackResult(docs, '外部存储不可用：未找到外置数据库');
    }
    if (probeFailed && mirrorError == null) {
      var granted = false;
      try {
        granted = await _hasAllFilesAccess();
      } catch (_) {
        granted = false;
      }
      if (granted) {
        return _fallbackResult(docs, 'MYTV 文件夹写不进去：未找到外置数据库');
      }
    }
    return _fallbackResult(
      docs,
      mirrorError != null
          ? '未找到外置数据库：$mirrorError'
          : '没有全部文件访问权限：未找到外置数据库',
      needsPermission: true,
    );
  }

  /// SAF 镜像路：授权在 → 同步镜像 → 绑镜像路径；授权不在/同步
  /// 失败回 null 并把原因交给 [onError] 拼进提示态文案。
  Future<MytvBindResult?> _tryMirrorBind(
    Directory docs, {
    required void Function(String error) onError,
  }) async {
    try {
      final grant = await ActressDbGrantStore.load();
      final mirror = ActressDbMirror(access: _storageAccess);
      ActressMirrorResult? result;
      String? displayName;
      if (grant.treeUri != null &&
          await _storageAccess.hasGrant(grant.treeUri!)) {
        result = await mirror.sync(documentsDir: docs, treeUri: grant.treeUri);
      } else if (grant.fileUri != null &&
          await _storageAccess.hasGrant(grant.fileUri!)) {
        final name = grant.fileName ?? 'picked.db';
        result = await mirror.sync(
          documentsDir: docs,
          fileDoc: ActressDbDocument(
            uri: grant.fileUri!,
            name: name,
            relPath: name,
            size: -1,
            lastModifiedMs: 0,
          ),
        );
        displayName = name;
      } else if (grant.treeUri != null || grant.fileUri != null) {
        onError('文件夹授权已失效，请重新授权');
        return null;
      } else {
        return null;
      }
      if (!result.ok) {
        onError(result.error ?? '镜像同步失败');
        return null;
      }
      final docsJsonDir = Directory(path.join(docs.path, legacyJsonDirName));
      return MytvBindResult(
        bound: true,
        needsPermission: false,
        root: docs,
        dbDir: result.mirrorDir,
        m3uDir: docsJsonDir,
        jsonDir: docsJsonDir,
        dbPath: result.mainDbPath,
        hasVideoDb: true,
        displayPath: displayName != null
            ? '$displayName（文件夹授权）'
            : '$mytvFolderName/$mytvDbFolderName/$mytvVideoDbFileName（文件夹授权）',
        mergedJsonExportPath: path.join(docs.path, mytvMergedJsonFileName),
        accessVia: 'mirror',
        hasFolderGrant: true,
      );
    } catch (e) {
      onError('文件夹授权读取失败：$e');
      return null;
    }
  }

  /// 未绑定结果：没有外置数据库可读（dbPath 为空），女优库显示空态。
  MytvBindResult _fallbackResult(
    Directory docs,
    String? note, {
    bool needsPermission = false,
  }) {
    return MytvBindResult(
      bound: false,
      needsPermission: needsPermission,
      root: docs,
      dbDir: docs,
      m3uDir: Directory(path.join(docs.path, legacyJsonDirName)),
      jsonDir: Directory(path.join(docs.path, legacyJsonDirName)),
      dbPath: '',
      hasVideoDb: false,
      displayPath: '未找到外置数据库',
      mergedJsonExportPath: path.join(docs.path, mytvMergedJsonFileName),
      note: note,
      accessVia: 'none',
    );
  }
}

/// 共用站点库文件名（MYTV/db/站点库.db）：只记播过的片，是播放
/// 记录库，不当女优库源扫（见 [collectDbMirrorTargets] 的排除），
/// 多库勾选里单独补回、默认不勾。原定义在已删的 actress_site_db
///（写库死代码，2026-11-26 删），常量随读侧扫描一起搬来这里。
const siteDbFileName = '站点库.db';

/// 收集可合并/可勾选的外来 .db 文件（只读扫描，不写任何文件）：
/// 主目录 MYTV/db 只扫一层 + 补充目录递归扫；排除主库本身、
/// 应用库与站点库（播放记录库绝不当女优库源）。原定义在已删的
/// actress_db_mirror（镜像写库，2026-11-26 删），扫描逻辑是读侧
/// 的，多库合并与多库勾选共用，搬来绑定层。
List<File> collectDbMirrorTargets({
  required Directory dbDir,
  required String libraryPath,
  List<Directory> extraDirs = const [],
}) {
  final seen = <String>{};
  final targets = <File>[];
  void add(File file) {
    final normalized = path.normalize(file.path);
    if (!file.path.toLowerCase().endsWith('.db')) return;
    if (path.equals(normalized, path.normalize(libraryPath))) return;
    final baseName = path.basename(file.path);
    if (baseName == '女优库应用.db' || baseName == 'actress.db') return;
    // 共用站点库（MYTV/db/站点库.db）只记播过的片，绝不当女优库
    // 源扫进来——勾选页单独把它补回（默认不勾）。
    if (baseName == siteDbFileName) return;
    if (!seen.add(normalized)) return;
    targets.add(file);
  }

  try {
    for (final entity in dbDir.listSync()) {
      if (entity is File) add(entity);
    }
  } catch (_) {
    // 主目录扫失败：返回已收集到的（可能为空），不抛错。
  }
  for (final dir in extraDirs) {
    try {
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) add(entity);
      }
    } catch (_) {
      // 该目录不存在/扫失败：跳过，不影响其他目录。
    }
  }
  return targets;
}
