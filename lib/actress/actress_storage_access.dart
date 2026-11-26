import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

/// 演员库存储授权（SAF）：全部文件访问权限之外的第二条授权路。
///
/// 背景（2026-11-26 安卓兼容批）：本包 targetSdk 36，分区存储在
/// 安卓 10–16 全版本强制；直读共享目录里的 .db 只有两条路——
/// 全部文件访问权限（用户去设置页开），或系统选择器（SAF）授予
/// 的持久读授权。这层就是 SAF 路：
/// - 用户选一次目录（如 MYTV）或单个 .db 文件，原生侧拿持久读
///   授权（通道 `fqapp/actress_storage`，见 ActressStoragePlugin）；
/// - 授权 URI 存 SharedPreferences，下次先验授权还在不在，在就
///   直接用，不重复打扰用户；
/// - .db 镜像进应用私有目录再开：源文件只读不写，且私有目录
///   可写，绕开 WAL 模式库在只读目录建不出 -shm 打不开的坑。
/// - 镜像同步按大小+修改时间戳只拷变化的；拷贝走原生临时文件
///   落定，半截不算数，断了重进按戳记续上未完的。

/// SAF 授权拿到的一个 .db 文档。
class ActressDbDocument {
  const ActressDbDocument({
    required this.uri,
    required this.name,
    required this.relPath,
    required this.size,
    required this.lastModifiedMs,
  });

  final String uri;
  final String name;

  /// 相对授权根的路径（如 `db/女优库.db`）；单文件授权时就是文件名。
  final String relPath;

  /// 字节数；提供方没给时为 -1（未知）。
  final int size;

  /// 修改时间（毫秒）；没给时为 0。
  final int lastModifiedMs;

  static ActressDbDocument? fromNative(Object? raw) {
    if (raw is! Map) return null;
    final uri = raw['uri']?.toString() ?? '';
    if (uri.isEmpty) return null;
    final name = raw['name']?.toString() ?? '';
    return ActressDbDocument(
      uri: uri,
      name: name,
      relPath: raw['relPath']?.toString() ?? name,
      size: (raw['size'] as num?)?.toInt() ?? -1,
      lastModifiedMs: (raw['lastModified'] as num?)?.toInt() ?? 0,
    );
  }
}

typedef ActressPickFn = Future<Map<String, Object?>?> Function();
typedef ActressListDbFilesFn =
    Future<List<ActressDbDocument>> Function(String treeUri);
typedef ActressStatFn = Future<Map<String, Object?>?> Function(String uri);
typedef ActressCopyFn = Future<int> Function(String uri, String destPath);
typedef ActressHasGrantFn = Future<bool> Function(String uri);

/// 通道门面：方法可注入假实现做测试；默认走真平台通道，任何一步
/// 失败都收敛成「没选/没授权/空列表」，绝不把平台异常抛进绑定链。
class ActressStorageAccess {
  ActressStorageAccess({
    ActressPickFn? pickTree,
    ActressPickFn? pickFile,
    ActressListDbFilesFn? listDbFiles,
    ActressStatFn? statDocument,
    ActressCopyFn? copyDocument,
    ActressHasGrantFn? hasGrant,
  }) : _pickTree = pickTree ?? _channelPickTree,
       _pickFile = pickFile ?? _channelPickFile,
       _listDbFiles = listDbFiles ?? _channelListDbFiles,
       _statDocument = statDocument ?? _channelStatDocument,
       _copyDocument = copyDocument ?? _channelCopyDocument,
       _hasGrant = hasGrant ?? _channelHasGrant;

  ActressStorageAccess._()
    : _pickTree = _channelPickTree,
      _pickFile = _channelPickFile,
      _listDbFiles = _channelListDbFiles,
      _statDocument = _channelStatDocument,
      _copyDocument = _channelCopyDocument,
      _hasGrant = _channelHasGrant;

  static final instance = ActressStorageAccess._();

  static const _channel = MethodChannel('fqapp/actress_storage');

  final ActressPickFn _pickTree;
  final ActressPickFn _pickFile;
  final ActressListDbFilesFn _listDbFiles;
  final ActressStatFn _statDocument;
  final ActressCopyFn _copyDocument;
  final ActressHasGrantFn _hasGrant;

  /// 弹系统目录选择器；用户取消/打不开回 null。
  Future<Map<String, Object?>?> pickTree() async {
    try {
      return await _pickTree();
    } catch (_) {
      return null;
    }
  }

  /// 弹系统文件选择器选单个 .db；用户取消/打不开回 null。
  Future<Map<String, Object?>?> pickFile() async {
    try {
      return await _pickFile();
    } catch (_) {
      return null;
    }
  }

  /// 列授权目录下的 .db；失败回空列表。
  Future<List<ActressDbDocument>> listDbFiles(String treeUri) async {
    try {
      return await _listDbFiles(treeUri).timeout(
        const Duration(seconds: 30),
      );
    } catch (_) {
      return const [];
    }
  }

  /// 查单个授权文档的当前状态（换文件后戳记刷新用）；查不到回 null。
  Future<Map<String, Object?>?> statDocument(String uri) async {
    try {
      return await _statDocument(uri);
    } catch (_) {
      return null;
    }
  }

  /// 把授权文档拷到 destPath（原生侧临时文件落定）。失败抛错，
  /// 由镜像同步决定整单失败还是跳过这一本。
  Future<int> copyDocument(String uri, String destPath) {
    return _copyDocument(uri, destPath).timeout(const Duration(minutes: 5));
  }

  /// 持久授权还在不在（被系统撤销/容器重启丢授权时回 false）。
  Future<bool> hasGrant(String uri) async {
    try {
      return await _hasGrant(uri);
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, Object?>?> _channelPickTree() async {
    final raw = await _channel.invokeMethod<Object?>('pickTree');
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    return null;
  }

  static Future<Map<String, Object?>?> _channelPickFile() async {
    final raw = await _channel.invokeMethod<Object?>('pickFile');
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    return null;
  }

  static Future<List<ActressDbDocument>> _channelListDbFiles(
    String treeUri,
  ) async {
    final raw = await _channel.invokeMethod<Object?>(
      'listDbFiles',
      {'treeUri': treeUri},
    );
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        ?ActressDbDocument.fromNative(item),
    ];
  }

  static Future<Map<String, Object?>?> _channelStatDocument(
    String uri,
  ) async {
    final raw = await _channel.invokeMethod<Object?>(
      'statDocument',
      {'uri': uri},
    );
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    return null;
  }

  static Future<int> _channelCopyDocument(String uri, String destPath) async {
    final copied = await _channel.invokeMethod<Object?>(
      'copyDocument',
      {'uri': uri, 'destPath': destPath},
    );
    return (copied as num?)?.toInt() ?? 0;
  }

  static Future<bool> _channelHasGrant(String uri) async {
    return await _channel.invokeMethod<bool>('hasGrant', {'uri': uri}) ??
        false;
  }
}

/// 授权存档：目录 URI 与单文件 URI 各一份，存 SharedPreferences。
/// 原生持久授权 + 这里的 URI 双保险：URI 在但原生授权被撤时，
/// [ActressStorageAccess.hasGrant] 会查出来，绑定层重新引导授权。
class ActressDbGrantStore {
  static const keyTreeUri = 'moyi_actress_saf_tree_uri';
  static const keyFileUri = 'moyi_actress_saf_file_uri';
  static const keyFileName = 'moyi_actress_saf_file_name';

  /// 读存档；任何失败回全空（按没授权处理），不抛错。
  static Future<({String? treeUri, String? fileUri, String? fileName})>
  load() async {
    try {
      final store = await SharedPreferences.getInstance();
      final tree = store.getString(keyTreeUri);
      final file = store.getString(keyFileUri);
      final name = store.getString(keyFileName);
      return (
        treeUri: (tree == null || tree.isEmpty) ? null : tree,
        fileUri: (file == null || file.isEmpty) ? null : file,
        fileName: (name == null || name.isEmpty) ? null : name,
      );
    } catch (_) {
      return (treeUri: null, fileUri: null, fileName: null);
    }
  }

  static Future<void> saveTree(String uri) async {
    try {
      final store = await SharedPreferences.getInstance();
      await store.setString(keyTreeUri, uri);
    } catch (_) {}
  }

  static Future<void> saveFile(String uri, String name) async {
    try {
      final store = await SharedPreferences.getInstance();
      await store.setString(keyFileUri, uri);
      await store.setString(keyFileName, name);
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      final store = await SharedPreferences.getInstance();
      await store.remove(keyTreeUri);
      await store.remove(keyFileUri);
      await store.remove(keyFileName);
    } catch (_) {}
  }
}

/// 一次镜像同步的结果。
class ActressMirrorResult {
  const ActressMirrorResult({
    required this.mirrorDir,
    required this.mainDbPath,
    required this.dbPaths,
    required this.copiedCount,
    this.error,
  });

  /// 镜像目录（应用私有，`<documents>/actress_db_mirror`）。
  final Directory mirrorDir;

  /// 主库镜像路径（认 `女优库.db`；单文件授权时就是那个文件）。
  /// 没有主库时为空字符串。
  final String mainDbPath;

  /// 全部镜像好的 .db 路径（多库勾选扫这个目录用）。
  final List<String> dbPaths;

  /// 本次实际拷贝的文件数（0 = 全是旧的，没重拷）。
  final int copiedCount;

  /// 失败/缺主库的原因；正常时为空。
  final String? error;

  bool get ok => error == null && mainDbPath.isNotEmpty;
}

/// 镜像同步：把授权目录/文件里的 .db 拷进应用私有目录。
///
/// 只从源往镜像拷，绝不回写源（演员库只读定版）。戳记
/// （`.mirror_stamps.json`：镜像名 → 大小+修改时间）存镜像目录里，
/// 没变的库不重拷；不再授权的文件从镜像里清掉（只清戳记里有记
/// 录的，不碰别的）。
class ActressDbMirror {
  ActressDbMirror({required this.access});

  final ActressStorageAccess access;

  static const mirrorDirName = 'actress_db_mirror';
  static const _stampFileName = '.mirror_stamps.json';

  /// 主库文件名（与绑定层 mytvVideoDbFileName 同值，这里不引那层
  /// 常量是为了让本层可独立测试）。
  static const mainDbFileName = '女优库.db';

  /// 镜像文件名：相对路径的 `/` 换成 `__`（如 `db__女优库.db`），
  /// 扁平放一个目录、名字可逆认出来源。
  static String mirrorNameFor(String relPath) =>
      relPath.replaceAll('/', '__');

  Future<ActressMirrorResult> sync({
    required Directory documentsDir,
    String? treeUri,
    ActressDbDocument? fileDoc,
  }) async {
    final mirrorDir = Directory(
      path.join(documentsDir.path, mirrorDirName),
    );
    try {
      mirrorDir.createSync(recursive: true);
    } catch (_) {
      return ActressMirrorResult(
        mirrorDir: mirrorDir,
        mainDbPath: '',
        dbPaths: const [],
        copiedCount: 0,
        error: '镜像目录建不出来：${mirrorDir.path}',
      );
    }

    // 1）收集文档清单：目录授权现列；单文件授权用存档那份
    //（stat 刷新戳记，stat 不到就用存档值）。
    var docs = <ActressDbDocument>[];
    if (treeUri != null && treeUri.isNotEmpty) {
      docs = await access.listDbFiles(treeUri);
      if (docs.isEmpty) {
        return ActressMirrorResult(
          mirrorDir: mirrorDir,
          mainDbPath: '',
          dbPaths: const [],
          copiedCount: 0,
          error: '授权目录里没有找到 .db 文件',
        );
      }
    } else if (fileDoc != null) {
      var doc = fileDoc;
      final stat = await access.statDocument(fileDoc.uri);
      if (stat != null) {
        doc = ActressDbDocument(
          uri: fileDoc.uri,
          name: stat['name']?.toString() ?? fileDoc.name,
          relPath: fileDoc.relPath,
          size: (stat['size'] as num?)?.toInt() ?? fileDoc.size,
          lastModifiedMs:
              (stat['lastModified'] as num?)?.toInt() ??
              fileDoc.lastModifiedMs,
        );
      }
      docs = [doc];
    } else {
      return ActressMirrorResult(
        mirrorDir: mirrorDir,
        mainDbPath: '',
        dbPaths: const [],
        copiedCount: 0,
        error: '没有文件夹授权',
      );
    }

    // 2）读戳记。
    final stampFile = File(path.join(mirrorDir.path, _stampFileName));
    final stamps = _readStamps(stampFile);

    // 3）逐个拷变化的。主库拷失败整单失败；副库失败跳过这一本
    //（勾选列表里少一本，不拖垮主库）。
    final dbPaths = <String>[];
    var copied = 0;
    String? firstError;
    // 主库挑选：db/女优库.db 最优先，其次根下同名，再其次任意层级
    // 的同名文件。
    ActressDbDocument? mainDoc;
    var mainScore = -1;
    for (final doc in docs) {
      final score = _mainDocScore(doc);
      if (score > mainScore) {
        mainScore = score;
        mainDoc = doc;
      }
    }
    // 单文件授权：用户亲手选的那本就是主库，不论文件名叫什么。
    if (fileDoc != null && docs.isNotEmpty) {
      mainDoc = docs.first;
    }
    final ordered = [
      ?mainDoc,
      for (final doc in docs)
        if (!identical(doc, mainDoc)) doc,
    ];
    final keptNames = <String>{};
    for (final doc in ordered) {
      final mirrorName = mirrorNameFor(doc.relPath);
      keptNames.add(mirrorName);
      final dest = File(path.join(mirrorDir.path, mirrorName));
      final stamp = stamps[mirrorName];
      // 大小与时间戳都未知时戳记比不出变化，宁可重拷不误判没变。
      final stampComparable = doc.size >= 0 || doc.lastModifiedMs > 0;
      final unchanged = stampComparable &&
          stamp != null &&
          stamp['size'] == doc.size &&
          stamp['lastModifiedMs'] == doc.lastModifiedMs &&
          dest.existsSync() &&
          (doc.size < 0 || dest.lengthSync() == doc.size);
      if (!unchanged) {
        try {
          await access.copyDocument(doc.uri, dest.path);
          if (!dest.existsSync() || dest.lengthSync() == 0) {
            throw StateError('拷贝后文件不存在或为空');
          }
          copied++;
        } catch (e) {
          if (identical(doc, mainDoc)) {
            return ActressMirrorResult(
              mirrorDir: mirrorDir,
              mainDbPath: '',
              dbPaths: dbPaths,
              copiedCount: copied,
              error: '主库镜像失败：$e',
            );
          }
          firstError ??= '有库镜像失败：$e';
          continue;
        }
      }
      stamps[mirrorName] = {
        'size': doc.size,
        'lastModifiedMs': doc.lastModifiedMs,
      };
      dbPaths.add(dest.path);
    }

    // 4）清掉不再授权的旧镜像（只清戳记里记过的）。
    for (final oldName in stamps.keys.toList()) {
      if (keptNames.contains(oldName)) continue;
      try {
        final stale = File(path.join(mirrorDir.path, oldName));
        if (stale.existsSync()) stale.deleteSync();
      } catch (_) {}
      stamps.remove(oldName);
    }

    // 5）落戳记。
    try {
      stampFile.writeAsStringSync(jsonEncode(stamps));
    } catch (_) {}

    if (mainDoc == null) {
      return ActressMirrorResult(
        mirrorDir: mirrorDir,
        mainDbPath: '',
        dbPaths: dbPaths,
        copiedCount: copied,
        error: firstError ?? '授权目录里没有 $mainDbFileName',
      );
    }
    return ActressMirrorResult(
      mirrorDir: mirrorDir,
      mainDbPath: path.join(mirrorDir.path, mirrorNameFor(mainDoc.relPath)),
      dbPaths: dbPaths,
      copiedCount: copied,
      error: firstError,
    );
  }

  static int _mainDocScore(ActressDbDocument doc) {
    if (doc.name != mainDbFileName) return -1;
    if (doc.relPath == 'db/$mainDbFileName') return 3;
    if (!doc.relPath.contains('/')) return 2;
    return 1;
  }

  Map<String, Map<String, int>> _readStamps(File stampFile) {
    try {
      if (!stampFile.existsSync()) return {};
      final decoded = jsonDecode(stampFile.readAsStringSync());
      if (decoded is! Map) return {};
      return decoded.map((key, value) {
        final map = value is Map ? value : const {};
        return MapEntry(key.toString(), {
          'size': (map['size'] as num?)?.toInt() ?? -1,
          'lastModifiedMs': (map['lastModifiedMs'] as num?)?.toInt() ?? 0,
        });
      });
    } catch (_) {
      return {};
    }
  }
}
