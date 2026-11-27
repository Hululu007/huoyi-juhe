import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'actress_adapter_http.dart' show ContentHttp;
import 'actress_javdb_api.dart';
import 'actress_models.dart' show actressNameKey;
import 'actress_neon.dart';

/// 演员头像加载超时（补全链第一级）：本地库头像地址 10 秒
/// 还没出图就判死、落下一级——地址死了不许无限转圈（2026-
/// 11-27 用户实报 roe-492 详情页演员头像一直转圈）。JavDB
/// 取图同用 10 秒。
const actressAvatarLoadTimeout = Duration(seconds: 10);

/// 库里「有头像」的有效口径（2026-11-27 数据工全量点数
/// 对齐，AVATAR_AUDIT.md）：以下形态一律算「没有头像」——
/// 即时补链本地判定直接跳过第一级落 JavDB（不拿占位地址
/// 发请求白等一轮超时），预热照样排队：
/// - 空串；
/// - 站根地址 https://v.hersav.me/（13,770 条，实测 404，
///   根本不是图片路径）；
/// - JavDB 通用未知人图 c0.jdbstatic.com/images/
///   actor_unknow.jpg（370 条，图活但不是本人头像）；
/// - 相对路径（1 条，无域名拼不出完整地址）。
/// 全库实数：32,276 人里真头像 12,164 人、无有效头像
/// 20,112 人（62.31%）——「很多没有」主要是没填/占位，
/// 不是图死了（真头像抽样 120 条硬死 0、防盗链 403 约
/// 5.8% 全在 jdbstatic）；第一级的超时回退保留防个案。
bool actressAvatarUrlUsable(String url) {
  final text = url.trim();
  if (text.isEmpty) return false;
  if (!text.startsWith('http://') && !text.startsWith('https://')) {
    return false;
  }
  if (text == 'https://c0.jdbstatic.com/images/actor_unknow.jpg') {
    return false;
  }
  final uri = Uri.tryParse(text);
  if (uri != null &&
      uri.host == 'v.hersav.me' &&
      (uri.path.isEmpty || uri.path == '/') &&
      !uri.hasQuery) {
    return false;
  }
  return true;
}

/// 头像缓存键：演员归一化名（actressNameKey：去空白、小写）
/// ＋演员 id 双保险——同名不同人靠 id 分开，没 id 时退回纯
/// 名字键（本地库演员行没有 id，JavDB 演员有 id，取到后两
/// 个键都写、读时先 id 键后名字键）。
String actressAvatarCacheKey(String name, String id) {
  final raw = '${actressNameKey(name)}|${id.trim()}';
  return md5.convert(utf8.encode(raw)).toString();
}

/// 头像缓存更新通知（notifyListeners 是受保护成员，包一层）。
class ActressAvatarCacheNotifier extends ChangeNotifier {
  void bump() => notifyListeners();
}

/// 头像磁盘缓存：App 缓存目录 actress_avatars/，只进缓存、
/// **绝不回写女优库 .db**（库文件只读口径）。与剧照截帧缓
/// 存同法（缓存目录＋归一化 key、同步文件 IO）。上限 500
/// 个文件，超了按修改时间删最旧的。
class ActressAvatarCache {
  ActressAvatarCache({Future<Directory> Function()? directoryOf})
    : _directoryOf = directoryOf ?? _defaultDirectory;

  final Future<Directory> Function() _directoryOf;

  /// 任一头像落盘后 bump：还停在占位的 ActressAvatar 听见
  /// 后回头查缓存（预热补到时页面自动出图）。
  static final ActressAvatarCacheNotifier updates =
      ActressAvatarCacheNotifier();

  static const maxFiles = 500;

  static Future<Directory> _defaultDirectory() async {
    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/actress_avatars');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 读缓存：先 id 键、后纯名字键；命中回文件，没命中回 null。
  Future<File?> read(String name, {String id = ''}) async {
    try {
      final dir = await _directoryOf();
      if (id.trim().isNotEmpty) {
        final byId = File(
          '${dir.path}/${actressAvatarCacheKey(name, id)}.jpg',
        );
        if (byId.existsSync()) return byId;
      }
      final byName = File(
        '${dir.path}/${actressAvatarCacheKey(name, '')}.jpg',
      );
      return byName.existsSync() ? byName : null;
    } catch (_) {
      return null;
    }
  }

  /// 写缓存：id 已知时 id 键与纯名字键都写（两种读法都命中）。
  Future<void> write(
    String name, {
    String id = '',
    required Uint8List bytes,
  }) async {
    try {
      final dir = await _directoryOf();
      File(
        '${dir.path}/${actressAvatarCacheKey(name, '')}.jpg',
      ).writeAsBytesSync(bytes, flush: true);
      if (id.trim().isNotEmpty) {
        File(
          '${dir.path}/${actressAvatarCacheKey(name, id)}.jpg',
        ).writeAsBytesSync(bytes, flush: true);
      }
      _trim(dir);
      updates.bump();
    } catch (_) {
      // 落盘失败不挡显示（调用方手里还有字节可直接显示）。
    }
  }

  void _trim(Directory dir) {
    try {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.jpg'))
          .toList();
      if (files.length <= maxFiles) return;
      files.sort(
        (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
      );
      for (final file in files.take(files.length - maxFiles)) {
        file.deleteSync();
      }
    } catch (_) {}
  }
}

/// 头像字节取数（可注入，测试用假实现）：按演员名回图片字
/// 节与 JavDB 演员 id；取不到回 null。
typedef ActressAvatarBytesFetcher =
    Future<({Uint8List bytes, String actorId})?> Function(String name);

/// 远程取图覆盖（可注入，测试用假实现）：按地址回图片字
/// 节，取不到/失败回 null。不传时走生产路（ContentHttp 字
/// 节路＋图床解密，见 _ActressAvatarState._loadRemote）。
typedef ActressAvatarRemoteLoader = Future<Uint8List?> Function(String url);

/// 生产取数：JavDB 按名查演员（jar 路线客户端）→ 取头像图
/// （图床带 Referer、XOR 加密字节解密，与 B1 图片口径同）。
/// 查不到人/没头像/图拉不到都回 null，不抛错。
ActressAvatarBytesFetcher javdbAvatarBytesFetcher(
  JavdbApiClient client, {
  ContentHttp? http,
}) {
  final sharedHttp = http ?? ContentHttp();
  return (String name) async {
    try {
      final actor = await client
          .actorByName(name)
          .timeout(const Duration(seconds: 20));
      if (actor == null || actor.avatarUrl.isEmpty) return null;
      final raw = await sharedHttp.getRaw(
        actor.avatarUrl,
        headers: const {'Referer': 'https://javdb.com/'},
        timeout: actressAvatarLoadTimeout,
      );
      if (raw.statusCode < 200 || raw.statusCode >= 300) return null;
      final bytes = javdbIsImageUrl(actor.avatarUrl)
          ? javdbDecryptImageBytes(raw.bodyBytes)
          : raw.bodyBytes;
      if (bytes.isEmpty) return null;
      return (bytes: bytes, actorId: actor.id);
    } catch (_) {
      return null;
    }
  };
}

/// 演员头像（补全链组件，详情页演员区与演员库三列网格共用）：
/// 1. 本地缓存（预热/此前补过的）命中直接出；
/// 2. 本地库头像地址（本行）：取字节带 10 秒超时，超时/失败
///    判死落下一级——不许无限转圈（加载中只出静态首字占位，
///    不出转圈）；取到顺手落缓存；
/// 3. 同番号互补（只有详情页传）：本行没头像/占位/死址时，
///    用同番号其他行里同名演员的头像地址（详情页按归一化番
///    号查回），取到落缓存再出；
/// 4. JavDB 按演员名取头像（取数见 javdbAvatarBytesFetcher），
///    取到落缓存再出；
/// 5. 都没有：名字首字静态占位收尾，不转圈、不留空白块。
class ActressAvatar extends StatefulWidget {
  const ActressAvatar({
    super.key,
    required this.name,
    this.avatarUrl = '',
    this.sameCodeAvatarUrl = '',
    this.actorId = '',
    this.javdbClient,
    this.avatarFetcher,
    this.remoteLoader,
    this.cache,
    this.fit = BoxFit.cover,
  });

  final String name;

  /// 本地库里存的头像地址（第二级的外源，本行）。
  final String avatarUrl;

  /// 同番号互补头像地址（第三级的外源）：详情页按番号从本
  /// 地库其他同番号行查回的、同名演员的头像地址；网格等无
  /// 番号语境不传（默认空 = 这一级跳过）。
  final String sameCodeAvatarUrl;

  /// 演员 id（有就带，缓存键双保险用；本地库行没有可空）。
  final String actorId;
  final JavdbApiClient? javdbClient;

  /// 取数覆盖（测试注入）；不传时按 javdbClient 现造。
  final ActressAvatarBytesFetcher? avatarFetcher;

  /// 远程取图覆盖（测试注入）；不传时走生产 ContentHttp 路。
  final ActressAvatarRemoteLoader? remoteLoader;
  final ActressAvatarCache? cache;
  final BoxFit fit;

  @override
  State<ActressAvatar> createState() => _ActressAvatarState();
}

class _ActressAvatarState extends State<ActressAvatar> {
  static ContentHttp? _http;

  ActressAvatarCache get _cache => widget.cache ?? ActressAvatarCache();

  Uint8List? _bytes;
  File? _file;
  var _generation = 0;
  var _resolving = false;

  /// 同番号地址在主链解析中途才到：先记下，主链收尾仍无图
  /// 时单独补跑同番号一级（见 _resolve 的 finally）。
  var _pendingSameCode = false;
  var _sameCodeResolving = false;

  @override
  void initState() {
    super.initState();
    ActressAvatarCache.updates.addListener(_onCacheUpdate);
    unawaited(_resolve());
  }

  @override
  void didUpdateWidget(ActressAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name != widget.name ||
        oldWidget.avatarUrl != widget.avatarUrl) {
      _bytes = null;
      _file = null;
      unawaited(_resolve());
      return;
    }
    // 同番号互补地址迟到（详情页后台查回晚于开页）：已出图
    // 的不降级替换；主链还在跑的记一笔、收尾补跑；已停在
    // 占位的单独补跑这一级。
    if (oldWidget.sameCodeAvatarUrl != widget.sameCodeAvatarUrl &&
        widget.sameCodeAvatarUrl.trim().isNotEmpty &&
        _bytes == null &&
        _file == null) {
      if (_resolving) {
        _pendingSameCode = true;
      } else {
        unawaited(_resolveSameCodeOnly());
      }
    }
  }

  @override
  void dispose() {
    ActressAvatarCache.updates.removeListener(_onCacheUpdate);
    _generation++;
    super.dispose();
  }

  void _onCacheUpdate() {
    // 预热/别处刚把我这张头像补进缓存、而我还停在占位：
    // 回头查一次缓存直接出图。
    if (_bytes == null && _file == null && !_resolving) {
      unawaited(_resolveFromCacheOnly());
    }
  }

  Future<void> _resolveFromCacheOnly() async {
    final file = await _cache.read(widget.name, id: widget.actorId);
    if (!mounted || file == null) return;
    setState(() => _file = file);
  }

  Future<void> _resolve() async {
    if (_resolving) return;
    _resolving = true;
    final generation = ++_generation;
    try {
      // 1) 本地缓存。
      final cached = await _cache.read(widget.name, id: widget.actorId);
      if (!mounted || generation != _generation) return;
      if (cached != null) {
        setState(() => _file = cached);
        return;
      }
      // 2) 本地库头像地址（本行）：先过有效口径（占位形态本
      // 地判定直接跳过、不发请求），有效的才取字节（10 秒
      // 超时，死地址落下一级）。
      final url = widget.avatarUrl.trim();
      if (actressAvatarUrlUsable(url)) {
        final bytes = await _loadRemote(url);
        if (!mounted || generation != _generation) return;
        if (bytes != null) {
          setState(() => _bytes = bytes);
          unawaited(
            _cache.write(widget.name, id: widget.actorId, bytes: bytes),
          );
          return;
        }
      }
      // 3) 同番号互补：本行没头像/占位/死址才轮到——同番号
      // 其他行里同名演员的头像地址（详情页查回传入）。
      if (await _loadSameCode(generation)) return;
      if (!mounted || generation != _generation) return;
      // 4) JavDB 按名取头像。
      final fetcher =
          widget.avatarFetcher ??
          javdbAvatarBytesFetcher(widget.javdbClient ?? JavdbApiClient());
      final found = await fetcher(widget.name);
      if (!mounted || generation != _generation) return;
      if (found != null) {
        setState(() => _bytes = found.bytes);
        unawaited(
          _cache.write(
            widget.name,
            id: found.actorId.isNotEmpty ? found.actorId : widget.actorId,
            bytes: found.bytes,
          ),
        );
        return;
      }
      // 5) 首字占位（build 里 _bytes/_file 都空即占位）。
    } catch (_) {
      // 任一级出错都收尾到占位，不把异常带上屏。
    } finally {
      _resolving = false;
      // 同番号地址在解析中途到的：主链没出图就补跑这一级。
      if (_pendingSameCode) {
        _pendingSameCode = false;
        if (mounted && _bytes == null && _file == null) {
          unawaited(_resolveSameCodeOnly());
        }
      }
    }
  }

  /// 同番号互补一级：地址先过有效口径（占位形态直接跳过、
  /// 不发请求），取到图落缓存再出、算命中；其余一律不命中。
  Future<bool> _loadSameCode(int generation) async {
    final url = widget.sameCodeAvatarUrl.trim();
    if (!actressAvatarUrlUsable(url)) return false;
    final bytes = await _loadRemote(url);
    if (!mounted || generation != _generation) return false;
    if (bytes == null) return false;
    setState(() => _bytes = bytes);
    unawaited(_cache.write(widget.name, id: widget.actorId, bytes: bytes));
    return true;
  }

  /// 同番号一级单独补跑（地址迟到、主链已收尾停在占位时）。
  Future<void> _resolveSameCodeOnly() async {
    if (_sameCodeResolving || _resolving) return;
    _sameCodeResolving = true;
    final generation = ++_generation;
    try {
      await _loadSameCode(generation);
    } catch (_) {
      // 补跑失败就停在占位，不把异常带上屏。
    } finally {
      _sameCodeResolving = false;
    }
  }

  /// 远程取图：统一走字节路（10 秒超时是硬线），JavDB 图床
  /// 字节解密。失败/超时/非 2xx 回 null。测试注入
  /// [ActressAvatar.remoteLoader] 时走注入路（同样回 null 表
  /// 失败）。
  Future<Uint8List?> _loadRemote(String url) async {
    final loader = widget.remoteLoader;
    if (loader != null) {
      try {
        return await loader(url);
      } catch (_) {
        return null;
      }
    }
    try {
      final http = _http ??= ContentHttp();
      final raw = await http.getRaw(
        url,
        headers: const {'Referer': 'https://javdb.com/'},
        timeout: actressAvatarLoadTimeout,
      );
      if (raw.statusCode < 200 || raw.statusCode >= 300) return null;
      if (raw.bodyBytes.isEmpty) return null;
      return javdbIsImageUrl(url)
          ? javdbDecryptImageBytes(raw.bodyBytes)
          : raw.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: widget.fit,
        errorBuilder: (context, error, stack) => _placeholder(),
      );
    }
    final file = _file;
    if (file != null) {
      return Image.file(
        file,
        fit: widget.fit,
        errorBuilder: (context, error, stack) => _placeholder(),
      );
    }
    return _placeholder();
  }

  /// 静态首字占位：不转圈、不留空白（加载中与最终无图同形）。
  Widget _placeholder() {
    return Container(
      color: Neon.surfaceHigh,
      alignment: Alignment.center,
      child: Text(
        widget.name.isEmpty ? '?' : widget.name.characters.first,
        style: const TextStyle(color: Neon.text, fontSize: 22),
      ),
    );
  }
}

/// 预热取消句柄：页面退出时 cancel()——正在等的间隔定时器
/// 立即取消、队列收手，不阻塞页面切换、不留悬挂定时器。
class ActressAvatarPreheatHandle {
  bool _cancelled = false;
  Timer? _timer;
  Completer<void>? _waiter;

  bool get cancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    _timer?.cancel();
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  Future<void> _delay(Duration duration) {
    if (_cancelled) return Future.value();
    final waiter = Completer<void>();
    _waiter = waiter;
    _timer = Timer(duration, () {
      if (!waiter.isCompleted) waiter.complete();
    });
    return waiter.future;
  }
}

/// 头像后台预热（第二层）：演员库打开、演员列表加载后调
/// 一次。策略（定版，回报同口径）：
/// - 排序：按作品数从高到低（热门先补），同名归一去重；
/// - 范围：只补「无有效头像」的演员（空/占位地址都算无，
///   见 actressAvatarUrlUsable；个别真地址死了走即时链的
///   超时回退，不在预热里逐个验死——成本太高）；
/// - 每轮上限 [perRound] 人（默认 20）：一次打开演员库最多
///   补 20 个，其余下次打开继续（缓存命中自动跳过，进度不
///   丢）；请求间隔 [interval]（默认 800 毫秒）节流，串行
///   低优先级，不抢界面请求；
/// - 缓存命中直接跳过、不外取；补到落 ActressAvatarCache
///   （与即时链同一份缓存、同一套 key），页面上的占位会经
///   缓存更新通知自动换图；
/// - 页面退出 cancel() 即停：不阻塞切换、不留悬挂定时器。
Future<void> actressAvatarPreheat({
  required List<({String name, int count})> candidates,
  required ActressAvatarBytesFetcher fetcher,
  ActressAvatarCache? cache,
  int perRound = 20,
  Duration interval = const Duration(milliseconds: 800),
  ActressAvatarPreheatHandle? handle,
}) async {
  final sharedCache = cache ?? ActressAvatarCache();
  final seen = <String>{};
  final queue = [
    for (final row in candidates)
      if (row.name.trim().isNotEmpty && seen.add(actressNameKey(row.name)))
        row,
  ]..sort((a, b) => b.count.compareTo(a.count));
  var done = 0;
  for (final row in queue) {
    if (handle?.cancelled ?? false) return;
    if (done >= perRound) return;
    // 缓存已有（此前补过/即时链落过）不外取、不占额度。
    if (await sharedCache.read(row.name) != null) continue;
    if (handle?.cancelled ?? false) return;
    try {
      final found = await fetcher(row.name);
      if (found != null) {
        await sharedCache.write(
          row.name,
          id: found.actorId,
          bytes: found.bytes,
        );
      }
    } catch (_) {
      // 单个失败跳过，不拖垮整轮。
    }
    done++;
    if (done < perRound && !(handle?.cancelled ?? false)) {
      if (handle != null) {
        await handle._delay(interval);
      } else {
        await Future.delayed(interval);
      }
    }
  }
}
