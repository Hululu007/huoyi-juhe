import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'actress_json_fallback.dart';
import 'actress_models.dart';

/// whos m3u 分片索引读取器：用户 2026-11-19 发来的 9 个女优合集 m3u
///（310,028 条，约 100MB raw）转成的紧凑索引。
///
/// 存储形态（不直接随包带 raw 100MB）：按 md5(女优名) % 32 分 32 个
/// shard，每 shard `{"a": {女优名: [[hash, code, title], ...]}}` 再 gzip；
/// 另附 manifest（女优→分片、归一化番号→分片、总数）。gzip 合计
/// 约 24MB（24,213,597 字节）。2026-11-21 内置分片已从包里删掉
///（库里按番号基本都能取到，内置那份纯属白占安装包），下面
/// manifest/分片读不到时直接返回空表，不再抛异常。
///
/// 查询只解需要的分片：按女优名查只解该女优所在分片（一般 1 个），
/// 按番号查只解 manifest 指出的分片；分片缓存最多留 4 个，超了
/// 丢最旧的。manifest 只解一次。整库 224,456 部去重后作品绝不
/// 一次全读进内存。
///
/// 行转条目：播 `https://v.hersav.me/<hash>/<hash>.m3u8`、
/// 图 `https://v.hersav.me/images/av/<hash>.jpg`，与 whos.json
/// 同一套 hash 编址；vod_play_url 仍是 `正片$地址`，parse=0 直链播。
///
/// 2026-11-20 MYTV 绑定：m3u 兜底先读用户自己放进 MYTV/m3u 的
/// m3u 文件（女优合集1.m3u～9.m3u 这种），读不到再回退上面这套
/// 内置分片——内置分片 2026-11-21 已从包里删掉，读不到时返回空表，
/// 只走库/用户自己的 MYTV/m3u。用户用文件管理器往 MYTV/m3u 里
/// 丢新 m3u 就能用，不用重编；用户文件里的行与内置分片里的同一
/// 播放地址，调用方按播放地址去重（json 行优先、m3u 行只补缺）。

/// 读 asset 字节用：默认走 rootBundle；测试可注入假字节。
typedef WhosM3uBytesReader = Future<Uint8List> Function(String assetPath);

Future<Uint8List> _defaultM3uReader(String assetPath) async {
  final data = await rootBundle.load(assetPath);
  return data.buffer.asUint8List();
}

class WhosM3uIndex {
  WhosM3uIndex({WhosM3uBytesReader? bytesReader, Directory? userM3uDir})
    : _bytesReader = bytesReader ?? _defaultM3uReader,
      _userM3uDir = userM3uDir;

  /// 2026-11-20 MYTV 绑定：绑定解析出来后调，用户 m3u 目录改走
  /// MYTV/m3u；传 null 时不读用户目录，只剩（已删的）内置分片，
  /// 读不到返回空表。目录换了就清掉用户 m3u 缓存（下次查按文件
  /// 指纹重读）。
  void bindUserM3uDir(Directory? dir) {
    if (dir?.path == _userM3uDir?.path) return;
    _userM3uDir = dir;
    _userFingerprint = null;
    _userCache = null;
  }

  static const manifestAsset =
      'assets/actress_json/whos_m3u/whos_m3u_manifest.json.gz';

  /// 分片数（与转换脚本 build_m3u_index.py 的 SHARDS=32 一致）。
  static const shardCount = 32;

  /// 内存里最多留几个解开的分片。
  static const maxCachedShards = 4;

  final WhosM3uBytesReader _bytesReader;
  Future<Map<String, dynamic>>? _manifestFuture;
  final _shardCache = <int, Map<String, dynamic>>{};
  final _shardOrder = <int>[];

  static String shardAsset(int idx) =>
      'assets/actress_json/whos_m3u/shard_${idx.toString().padLeft(2, '0')}.json.gz';

  Future<Map<String, dynamic>> _manifest() {
    return _manifestFuture ??= _loadManifest();
  }

  Future<Map<String, dynamic>> _loadManifest() async {
    // 2026-11-21：内置分片已从包里删掉（22.4 万条地址实测 224,454/224,456
    // 都能在用户库里按番号取到，库里还多 9.8 万条，内置那份纯属白占
    // 24MB 安装包）。这里缺资源就当没有，返回空表：查不到就走库/用户
    // 自己的 MYTV/m3u，不再抛异常拖慢每次点播。
    try {
      final bytes = await _bytesReader(manifestAsset);
      final doc = jsonDecode(utf8.decode(gzip.decode(bytes)));
      if (doc is! Map<String, dynamic>) return const {};
      return doc;
    } catch (_) {
      return const {};
    }
  }

  Future<Map<String, dynamic>> _shard(int idx) async {
    final cached = _shardCache[idx];
    if (cached != null) return cached;
    Map<String, dynamic> doc;
    try {
      final bytes = await _bytesReader(shardAsset(idx));
      final parsed = jsonDecode(utf8.decode(gzip.decode(bytes)));
      doc = parsed is Map<String, dynamic> ? parsed : const {};
    } catch (_) {
      // 分片不在包里（已删）/资源读失败：当这个分片没有数据。
      doc = const {};
    }
    _shardCache[idx] = doc;
    _shardOrder.add(idx);
    while (_shardOrder.length > maxCachedShards) {
      _shardCache.remove(_shardOrder.removeAt(0));
    }
    return doc;
  }

  /// 行 [hash, code, title] → ActressJsonEntry（站 whos）。
  ActressJsonEntry _rowToEntry(String actress, List row) {
    final hash = row[0].toString();
    final code = row.length > 1 ? row[1].toString() : '';
    final title = row.length > 2 ? row[2].toString() : '';
    final pic = 'https://v.hersav.me/images/av/$hash.jpg';
    return ActressJsonEntry(
      site: 'whos',
      vodId: hash,
      vodName: title,
      vodPic: pic,
      vodActor: actress,
      vodDirector: '',
      vodRemarks: '高清',
      vodPubdate: '',
      vodArea: '',
      vodYear: '',
      vodContent: '',
      vodPlayFrom: 'whos',
      vodPlayUrl: '正片\$https://v.hersav.me/$hash/$hash.m3u8',
      typeName: '日本AV',
      vodCode: code,
      vodActressPic: pic,
    );
  }

  /// manifest 里分片号的两种写法都认：女优值是单个 int（每女优
  /// 只落一个分片），番号值是 int 数组（同一番号可跨多分片）。
  static List<int> _shardIdxs(dynamic value) {
    if (value is int) return [value];
    if (value is List) {
      return [for (final e in value) if (e is int) e];
    }
    return const [];
  }

  /// 用户 m3u 目录（MYTV/m3u）；没绑定时为 null，只读内置分片。
  Directory? _userM3uDir;

  /// 用户 m3u 缓存：按目录文件指纹（文件名+大小+修改时间）失效，
  /// 用户换了文件下次查自动重读，不用重启。
  String? _userFingerprint;
  _UserM3uCache? _userCache;

  /// 读用户 m3u 目录：每个 .m3u 文件按 #EXTINF 行解析
  /// （group-title 作女优名，逗号后作标题，下一行作播放地址），
  /// 按归一化女优名与归一化番号建索引。文件坏了只跳过它。
  Future<_UserM3uCache> _userEntries() async {
    final dir = _userM3uDir;
    if (dir == null) return _UserM3uCache.empty;
    try {
      if (!dir.existsSync()) return _UserM3uCache.empty;
      final files =
          dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.m3u'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      final fingerprint = files
          .map((f) {
            final s = f.statSync();
            return '${f.path}|${s.size}|${s.modified.millisecondsSinceEpoch}';
          })
          .join(';');
      if (_userFingerprint == fingerprint && _userCache != null) {
        return _userCache!;
      }
      final byActress = <String, List<ActressJsonEntry>>{};
      final byCode = <String, List<ActressJsonEntry>>{};
      final names = <String>{};
      for (final file in files) {
        for (final entry in _parseUserM3uFile(file)) {
          final nameKey = normalizeActressJsonName(entry.vodActor);
          if (nameKey.isNotEmpty) {
            (byActress[nameKey] ??= []).add(entry);
            names.add(entry.vodActor);
          }
          final codeKey = normalizeAvCode(entry.vodCode);
          if (codeKey.isNotEmpty) {
            (byCode[codeKey] ??= []).add(entry);
          }
        }
      }
      final cache = _UserM3uCache(
        byActress: byActress,
        byCode: byCode,
        names: names,
      );
      _userFingerprint = fingerprint;
      _userCache = cache;
      return cache;
    } catch (_) {
      return _userCache ?? _UserM3uCache.empty;
    }
  }

  /// 解析一个用户 m3u 文件：#EXTINF 行取 group-title 与标题，
  /// 下一行 http 地址取播放链接。地址是 v.hersav.me 的按 hash
  /// 编址（与内置分片同一套）；不是的用地址本身当 vodId，
  /// 照样能播（parse=0 直链）。
  List<ActressJsonEntry> _parseUserM3uFile(File file) {
    final out = <ActressJsonEntry>[];
    String? actress;
    String? title;
    try {
      final lines = file.readAsStringSync().split('\n');
      for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        if (line.startsWith('#EXTINF')) {
          final group = RegExp(
            r'group-title="([^"]*)"',
          ).firstMatch(line);
          actress = group?.group(1)?.trim();
          final comma = line.lastIndexOf(',');
          title = comma >= 0 ? line.substring(comma + 1).trim() : '';
          continue;
        }
        if (line.startsWith('#')) continue;
        if (!line.startsWith('http')) continue;
        if ((actress == null || actress.isEmpty) &&
            (title == null || title.isEmpty)) {
          continue;
        }
        out.add(_userRowToEntry(actress ?? '', title ?? '', line));
        actress = null;
        title = null;
      }
    } catch (_) {
      // 单个文件坏了只跳过它，不掀翻整个用户目录。
    }
    return out;
  }

  /// 用户 m3u 行 → ActressJsonEntry（站 whos，与内置分片同形）。
  /// 标题里第一个像番号的词作 vodCode（走 actressCodeQueryKey，
  /// 与全站叠加的番号口径一致）。
  ActressJsonEntry _userRowToEntry(
    String actress,
    String title,
    String url,
  ) {
    final hash =
        RegExp(r'v\.hersav\.me/([0-9a-fA-F]+)/').firstMatch(url)?.group(1) ??
        '';
    final pic =
        hash.isEmpty
            ? ''
            : 'https://v.hersav.me/images/av/$hash.jpg';
    var code = '';
    for (final token in title.split(RegExp(r'[\s,、/]+'))) {
      if (actressCodeQueryKey(token) != null) {
        code = normalizeAvCode(token);
        break;
      }
    }
    return ActressJsonEntry(
      site: 'whos',
      vodId: hash.isEmpty ? url : hash,
      vodName: title,
      vodPic: pic,
      vodActor: actress,
      vodDirector: '',
      vodRemarks: '高清',
      vodPubdate: '',
      vodArea: '',
      vodYear: '',
      vodContent: '',
      vodPlayFrom: 'whos',
      vodPlayUrl: '正片\$$url',
      typeName: '日本AV',
      vodCode: code,
      vodActressPic: pic,
    );
  }

  /// 按女优名取 m3u 条目：先取用户 MYTV/m3u 里的行，再取包里
  /// 内置分片里的行（manifest 里女优→分片，先精确名，再按
  /// 归一化名扫一遍键）。内置分片读失败时只回用户文件里的行。
  Future<List<ActressJsonEntry>> entriesForActress(String name) async {
    if (name.isEmpty) return const [];
    final out = <ActressJsonEntry>[];
    final user = await _userEntries();
    out.addAll(user.byActress[normalizeActressJsonName(name)] ?? const []);
    try {
      final manifest = await _manifest();
      final actressMap = manifest['actress'];
      if (actressMap is! Map) return out;
      List<int>? shardIdxs;
      var key = name;
      if (actressMap.containsKey(name)) {
        shardIdxs = _shardIdxs(actressMap[name]);
      } else {
        final want = normalizeActressJsonName(name);
        for (final k in actressMap.keys) {
          if (normalizeActressJsonName(k.toString()) == want) {
            shardIdxs = _shardIdxs(actressMap[k]);
            key = k.toString();
            break;
          }
        }
      }
      if (shardIdxs == null) return out;
      for (final idx in shardIdxs) {
        final shard = await _shard(idx);
        final a = shard['a'];
        if (a is! Map) continue;
        final rows = a[key];
        if (rows is List) {
          for (final row in rows) {
            if (row is List && row.isNotEmpty) {
              out.add(_rowToEntry(key, row));
            }
          }
        }
      }
    } catch (_) {
      // 内置分片坏了只回用户文件里的行。
    }
    return out;
  }

  /// 按归一化番号取 m3u 条目：先取用户 MYTV/m3u 里的行，再取
  /// 包里内置分片里的行（只解 manifest 指出的分片，再在分片里
  /// 扫出番号相同的行；同一部片在多女优名下各留一条，与全站
  /// 叠加“按（站，番号）去重”的口径一致，调用方按站|mergeKey
  /// 去重）。内置分片读失败时只回用户文件里的行。
  Future<List<ActressJsonEntry>> entriesForCode(String codeKey) async {
    final key = normalizeAvCode(codeKey);
    if (key.isEmpty) return const [];
    final out = <ActressJsonEntry>[];
    final user = await _userEntries();
    out.addAll(user.byCode[key] ?? const []);
    try {
      final manifest = await _manifest();
      final codeMap = manifest['code'];
      if (codeMap is! Map || !codeMap.containsKey(key)) return out;
      final shardIdxs = _shardIdxs(codeMap[key]);
      for (final idx in shardIdxs) {
        final shard = await _shard(idx);
        final a = shard['a'];
        if (a is! Map) continue;
        for (final kv in a.entries) {
          final actress = kv.key.toString();
          final rows = kv.value;
          if (rows is! List) continue;
          for (final row in rows) {
            if (row is List &&
                row.length > 1 &&
                normalizeAvCode(row[1].toString()) == key) {
              out.add(_rowToEntry(actress, row));
            }
          }
        }
      }
    } catch (_) {
      // 内置分片坏了只回用户文件里的行。
    }
    return out;
  }

  /// 某人（名字 + 本地作品番号集合）在 m3u 里有没有条目：
  /// 先看用户 MYTV/m3u，再看内置 manifest（只查 manifest，
  /// 不解分片）。
  Future<bool> hasEntriesForPerson({
    required List<String> names,
    required Set<String> codeKeys,
  }) async {
    final user = await _userEntries();
    for (final name in names) {
      if (user.byActress.containsKey(normalizeActressJsonName(name))) {
        return true;
      }
    }
    for (final codeKey in codeKeys) {
      if (user.byCode.containsKey(normalizeAvCode(codeKey))) return true;
    }
    try {
      final manifest = await _manifest();
      final actressMap = manifest['actress'];
      if (actressMap is Map) {
        for (final name in names) {
          if (actressMap.containsKey(name)) return true;
          final want = normalizeActressJsonName(name);
          for (final k in actressMap.keys) {
            if (normalizeActressJsonName(k.toString()) == want) return true;
          }
        }
      }
      final codeMap = manifest['code'];
      if (codeMap is Map) {
        for (final codeKey in codeKeys) {
          if (codeMap.containsKey(normalizeAvCode(codeKey))) return true;
        }
      }
    } catch (_) {
      // 内置分片坏了只认用户文件里的。
    }
    return false;
  }

  /// 索引总数（与转换脚本输出一致：videos 224,456、
  /// appearances 309,716、actresses 3,183、codes 86,720）。
  Future<
      ({
        int videos,
        int appearances,
        int actresses,
        int codes,
        int entries,
      })> stats() async {
    final manifest = await _manifest();
    int n(String k) =>
        manifest[k] is num ? (manifest[k] as num).toInt() : 0;
    return (
      videos: n('videos'),
      appearances: n('appearances'),
      actresses: n('actresses'),
      codes: n('codes'),
      entries: n('entries'),
    );
  }
}

/// 用户 m3u 目录的解析缓存：按归一化女优名与归一化番号索引，
/// 只在目录文件指纹变了时重读。
class _UserM3uCache {
  const _UserM3uCache({
    required this.byActress,
    required this.byCode,
    required this.names,
  });

  static const empty = _UserM3uCache(byActress: {}, byCode: {}, names: {});

  final Map<String, List<ActressJsonEntry>> byActress;
  final Map<String, List<ActressJsonEntry>> byCode;
  final Set<String> names;
}
