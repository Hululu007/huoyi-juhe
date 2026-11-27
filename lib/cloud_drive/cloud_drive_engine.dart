/// 网盘引擎：把五家网盘的客户端结果归一成魔蚁的目录/详情/播放模型。
///
/// 网盘作为一个“站”进站点列表（id `cloud:<网盘>`），文件夹作分类下钻，
/// 视频文件作卡片，走现有的浏览与播放链路，不做文件管理器式素列表。
///
/// 文件夹浏览：根目录列顶层文件夹卡 + 本夹视频卡；点文件夹卡以
/// `folderId` 为 category 再次请求目录，逐级下钻、层级不限（复用
/// Drama kind=folder 的现有下钻链路）；根目录首张卡是虚拟文件夹
/// “全部”，点进去是跨文件夹聚合视图（遍历上限见 [_AggregateCaps]）。
/// 夹内搜索：有站方搜索接口的用接口，没有的取当前夹列表按名过滤。
///
/// 剧集分组（飞牛式媒体库组织）：同一目录里文件名解析出同一剧名
/// + 不同集号的视频归成一个“剧集”条目，进详情选集；单集、无集号、
/// 集号重复的文件保持单卡，不硬归。光盘结构：VIDEO_TS/BDMV 文件夹
/// 归成一个光盘条目，VOB 分段归成一个“正片”条目；光盘只走 mpv。
///
/// 封面：①网盘缩略图 ②同夹同名图片的缩略图 ③占位；来源记在缓存里，
/// 详情页 tags 如实标注。直链播放：视频/音频取直链进自有播放器，
/// 不嵌网盘官方网页播放器；图片走 pics:// 浏览；字幕与其他类型只
/// 展示、不可播。疑似广告视频默认隐藏（设置里可显示），只过滤显示，
/// 绝不删文件。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'cloud_drive_models.dart';
import 'cloud_115_offline.dart';
import 'cloud_credential_store.dart';
import 'cloud_drive_types.dart';
import 'cloud_filename.dart';
import 'cloud_providers.dart';

/// “全部”聚合视图的遍历上限（与 TVBox_Web 的 maxDepth 3 口径一致，
/// 再加文件夹数与条数上限，避免大网盘一次遍历拖垮界面）。
class _AggregateCaps {
  /// 最多遍历多少个文件夹。
  static const maxFolders = 24;

  /// 最多汇总多少条视频。
  static const maxVideos = 300;

  /// 最多下钻几层（根目录为第 1 层）。
  static const maxDepth = 3;

  /// 每个文件夹最多取几页（聚合时只取前 2 页，避免单夹巨量拖慢）。
  static const maxPagesPerFolder = 2;
}

/// “全部”聚合视图的虚拟分类 id（文件夹卡的 folderId）。
const cloudDriveAllCategory = '__all__';

/// 目录页内存缓存条目：一个文件夹一页的原始文件列表。
class _FolderPageEntry {
  const _FolderPageEntry(this.files, this.hasMore);
  final List<CloudDriveFile> files;
  final bool hasMore;
}

/// 目录里一条卡片的缓存条目（详情/播放时取回文件信息与封面来源）。
class _CachedEntry {
  const _CachedEntry({required this.file, required this.coverSource});

  final CloudDriveFile file;
  final CloudCoverSource coverSource;
}

/// 剧集分组条目：成员文件按集号排序，详情时展开为选集。
class _GroupedEntry {
  const _GroupedEntry({
    required this.members,
    required this.episodeTitles,
    required this.episodeNumbers,
    required this.coverSource,
    this.forceMpv = false,
  });

  /// 成员文件（已按集号升序；VOB 组只有最大的一个 VOB）。
  final List<CloudDriveFile> members;

  /// 与 [members] 一一对应的选集标题（“第X集”或“正片”）。
  final List<String> episodeTitles;

  /// 与 [members] 一一对应的集号（选集排序与续播定位用）。
  final List<int> episodeNumbers;
  final CloudCoverSource coverSource;

  /// VOB 正片组强制走 mpv（DVD 内容）；普通剧集组为假。
  final bool forceMpv;
}

/// 光盘条目：详情时现取文件夹内容找正片文件。
class _DiscEntry {
  const _DiscEntry({
    required this.providerId,
    required this.folderId,
    required this.discType,
    this.encrypted = false,
  });

  final String providerId;
  final String folderId;

  /// 'dvd'（VIDEO_TS）或 'bd'（BDMV）。
  final String discType;

  /// 是否检出 AACS 加密（BDMV 里有 AACS 文件夹时为真，播不了）。
  final bool encrypted;
}

/// FNV-1a 32 位哈希（十六进制）：分组 id 须跨进程稳定，String.hashCode
/// 不保证跨次运行一致，不能用。
String _fnv1aHex(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

class CloudDriveEngine {
  CloudDriveEngine({
    required CloudCredentialStore credentialStore,
    required http.Client httpClient,
    required bool Function() showSuspectedAds,
    Map<String, CloudDriveProvider>? providers,
    Future<Directory> Function()? catalogCacheDir,
  }) : _credentialStore = credentialStore,
       _httpClient = httpClient,
       _showSuspectedAds = showSuspectedAds,
       _catalogCacheDir = catalogCacheDir,
       _providers = providers ??
           {for (final p in createCloudDriveProviders()) p.id: p} {
    for (final provider in _providers.values) {
      provider.onCredentialsRefreshed = (providerId, credentials) {
        _credentialStore.save(providerId, credentials);
        _clearCatalogCaches();
      };
      provider.onSessionExpired = (providerId, expiredCookie) {
        // 只清「存着的正是那份过期凭证」的情况：在途旧请求的过期
        // 报错不许清掉刚重新登录的新凭证。
        final stored = _credentialStore.load(providerId);
        if (stored != null &&
            (stored.fields['cookie'] ?? '') == expiredCookie) {
          _credentialStore.clear(providerId);
          _clearCatalogCaches();
        }
      };
    }
  }

  final CloudCredentialStore _credentialStore;
  final http.Client _httpClient;
  final bool Function() _showSuspectedAds;
  final Map<String, CloudDriveProvider> _providers;

  /// 卡片缓存（详情/播放时取回文件信息），简单 FIFO，上限 500 条。
  final Map<String, _CachedEntry> _cache = {};
  static const _cacheCap = 500;

  /// 剧集分组缓存（卡片 id → 分组成员），与 [_cache] 同口径 FIFO。
  final Map<String, _GroupedEntry> _groups = {};

  /// 光盘条目缓存（卡片 id → 光盘文件夹信息），与 [_cache] 同口径 FIFO。
  final Map<String, _DiscEntry> _discs = {};

  /// 目录页缓存（2026-11-27 问题 6「文件夹秒开」）：片库站入口
  /// 与网盘页都经本引擎取目录，此前零缓存、每次点文件夹都现拉
  /// 网络，弱网下点完长时间没动静。两级缓存：
  /// - 内存层存原始文件页（键 '<盘>|<文件夹>|<页>'），命中后
  ///   照常走 _toCatalogPage 转换（文件条目/分组/光盘缓存一并
  ///   重建），同时后台静默刷新，数据变了下一开就是新的；
  /// - 落盘层存转换后的条目页精简字段（Drama 的 JSON：标题/
  ///   封面/类型/文件夹 id 等展示字段，不含凭证与取链私有字
  ///   段），重启软件后第一开也能先出画、再后台刷新回填。
  /// 凭证刷新/会话过期即整表清掉，不给换账号后看旧账号目录
  /// 的机会。落盘目录由构造方注入（测试不注入即禁用落盘）。
  final Map<String, _FolderPageEntry> _folderPages = {};
  static const _folderPageCap = 96;
  final Set<String> _refreshingPages = {};
  final Map<String, CatalogPage> _diskPages = {};
  static const _diskPageCap = 128;
  Future<void>? _diskLoadFuture;
  Timer? _diskWriteTimer;
  final Future<Directory> Function()? _catalogCacheDir;

  /// STRM 内容读取上限（指针文件只有几行，8KB 足够；超了也只取前 8KB）。
  static const _strmMaxBytes = 8192;

  /// STRM 内容读取超时。
  static const _strmTimeout = Duration(seconds: 15);

  /// 站点 id `cloud:<网盘>` → 网盘 id；不是网盘站返回 ''。
  static String providerIdOf(String sourceId) {
    if (!sourceId.startsWith('cloud:')) return '';
    return sourceId.substring('cloud:'.length);
  }

  /// 站点 id 是否网盘站。
  static bool isCloudSource(String sourceId) => sourceId.startsWith('cloud:');

  /// 卡片 id：`<网盘>:<文件 id>`（跨网盘不重，目录合并去重不串台）。
  static String dramaId(String providerId, String fileId) => '$providerId:$fileId';

  /// 从卡片 id 还原文件 id（去掉 `<网盘>:` 前缀）。
  static String fileIdOf(String dramaIdValue) {
    final idx = dramaIdValue.indexOf(':');
    return idx < 0 ? dramaIdValue : dramaIdValue.substring(idx + 1);
  }

  CloudDriveProvider? _provider(String providerId) => _providers[providerId];

  CloudCredentials _credentials(String providerId) {
    final creds = _credentialStore.load(providerId);
    if (creds == null) {
      throw AppFailure('该网盘未登录，请先在设置 → 网盘登录里扫码登录');
    }
    return creds;
  }

  // -------------------------------------------------------------------------
  // 115 离线接入（演员库详情页，见 cloud_115_offline.dart）
  // -------------------------------------------------------------------------

  /// 115 是否已登录（存有 cookie 凭证）。
  bool get pan115LoggedIn {
    final creds = _credentialStore.load('pan115');
    return (creds?.fields['cookie'] ?? '').isNotEmpty;
  }

  /// 115 离线客户端：未登录返回 null（复用既有 qandroid
  /// 会话 cookie，不另起登录）。
  Pan115OfflineClient? pan115OfflineClient() {
    final creds = _credentialStore.load('pan115');
    final cookie = creds?.fields['cookie'] ?? '';
    if (cookie.isEmpty) return null;
    return Pan115OfflineClient(client: _httpClient, cookie: cookie);
  }

  /// 115 按关键词搜文件（根目录搜索即全盘范围）。
  Future<List<CloudDriveFile>> searchPan115Files(String keyword) async {
    final provider = _provider('pan115');
    if (provider == null) return const [];
    final credentials = _credentials('pan115');
    return provider.search(
      _httpClient,
      credentials,
      keyword,
      provider.rootFolderId,
    );
  }

  /// 115 账号信息（昵称/VIP 到期等）：未登录、provider 不
  /// 在或接口读不到一律回 null、不抛错——会员状态只是如
  /// 实展示用（见 pan115IsVip），读不到就降级不显，绝不
  /// 挡播放。
  Future<Pan115AccountInfo?> pan115AccountInfo() async {
    final provider = _provider('pan115');
    if (provider is! Pan115Provider) return null;
    if (!pan115LoggedIn) return null;
    try {
      return await provider.accountInfo(_httpClient, _credentials('pan115'));
    } catch (_) {
      return null;
    }
  }

  /// 115 文件取直链（复用 Pan115Provider.directLink 既有链，
  /// 返回的 headers 已按取链口径组装好）。
  Future<CloudDirectLink> pan115DirectLink(CloudDriveFile file) async {
    final provider = _provider('pan115');
    if (provider == null) throw AppFailure('115 网盘不可用');
    final credentials = _credentials('pan115');
    return provider.directLink(_httpClient, credentials, file);
  }

  void _remember(String key, CloudDriveFile file, CloudCoverSource coverSource) {
    if (_cache.length >= _cacheCap) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = _CachedEntry(file: file, coverSource: coverSource);
  }

  void _rememberGroup(String key, _GroupedEntry entry) {
    if (_groups.length >= _cacheCap) {
      _groups.remove(_groups.keys.first);
    }
    _groups[key] = entry;
  }

  void _rememberDisc(String key, _DiscEntry entry) {
    if (_discs.length >= _cacheCap) {
      _discs.remove(_discs.keys.first);
    }
    _discs[key] = entry;
  }

  // -------------------------------------------------------------------------
  // 目录页缓存（问题 6）
  // -------------------------------------------------------------------------

  /// 缓存键里的账号段（开源目录缓存的通行口径：键＝账号＋cid）：
  /// 凭证内容的 FNV 哈希，不落明文。换账号后键自然不同，旧账号
  /// 的缓存页不会被新账号读到（整表清理是第二道防线）。
  String _accountSeed(CloudCredentials credentials) {
    final keys = credentials.fields.keys.toList()..sort();
    return _fnv1aHex([for (final k in keys) '$k=${credentials.fields[k]}'].join('&'));
  }

  String _pageKey(
    String providerId,
    String accountSeed,
    String folderId,
    int page,
  ) => '$providerId|$accountSeed|$folderId|$page';

  /// 后台列表请求限频闸（问题 6）：刷新/预取这类不挡界面的请求
  /// 彼此至少间隔 300ms，避免一波预取把 115 的 405 限频打出来；
  /// 前台请求（用户正等着的）不走闸、不受影响。
  int _lastBackgroundListMs = 0;

  Future<void> _backgroundGate() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final wait = _lastBackgroundListMs + 300 - now;
    if (wait > 0) {
      await Future<void>.delayed(Duration(milliseconds: wait));
    }
    _lastBackgroundListMs = DateTime.now().millisecondsSinceEpoch;
  }

  void _rememberFolderPage(String key, _FolderPageEntry entry) {
    _folderPages.remove(key);
    _folderPages[key] = entry;
    while (_folderPages.length > _folderPageCap) {
      _folderPages.remove(_folderPages.keys.first);
    }
  }

  void _clearCatalogCaches() {
    _folderPages.clear();
    _diskPages.clear();
    _scheduleDiskWrite();
  }

  Future<File?> _diskCacheFile() async {
    final dirFn = _catalogCacheDir;
    if (dirFn == null) return null;
    try {
      final dir = await dirFn();
      return File('${dir.path}/cloud_catalog_pages.json');
    } catch (_) {
      return null;
    }
  }

  Future<void> _ensureDiskLoaded() {
    return _diskLoadFuture ??= () async {
      final file = await _diskCacheFile();
      if (file == null) return;
      try {
        if (!await file.exists()) return;
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map) return;
        for (final entry in decoded.entries) {
          final value = entry.value;
          if (value is! Map) continue;
          _diskPages[entry.key as String] = CatalogPage(
            [
              for (final row in value['items'] as List? ?? const [])
                Drama.fromJson(Map<String, dynamic>.from(row as Map)),
            ],
            hasMore: value['hasMore'] == true,
            warning: value['warning'] as String? ?? '',
            page: (value['page'] as num?)?.toInt() ?? 1,
          );
        }
      } catch (_) {
        // 缓存文件损坏就当没有，网络现拉为准。
      }
    }();
  }

  void _rememberDiskPage(String key, CatalogPage page) {
    if (_catalogCacheDir == null) return;
    _diskPages.remove(key);
    _diskPages[key] = page;
    while (_diskPages.length > _diskPageCap) {
      _diskPages.remove(_diskPages.keys.first);
    }
    _scheduleDiskWrite();
  }

  void _scheduleDiskWrite() {
    if (_catalogCacheDir == null) return;
    _diskWriteTimer?.cancel();
    _diskWriteTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_writeDiskPages());
    });
  }

  Future<void> _writeDiskPages() async {
    final file = await _diskCacheFile();
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      final data = <String, dynamic>{
        for (final entry in _diskPages.entries)
          entry.key: {
            'items': [for (final drama in entry.value.items) drama.toJson()],
            'hasMore': entry.value.hasMore,
            'warning': entry.value.warning,
            'page': entry.value.page,
          },
      };
      await file.writeAsString(jsonEncode(data), flush: true);
    } catch (_) {
      // 落盘失败不影响内存缓存继续顶。
    }
  }

  /// 后台静默刷新一页目录：成功就换掉内存/落盘两级缓存，
  /// 失败静默（旧缓存继续顶着，下次打开再试）。
  void _refreshFolderPage(
    CloudDriveProvider provider,
    CloudCredentials credentials,
    String folderId,
    int page,
    String key,
    bool isRoot,
  ) {
    if (!_refreshingPages.add(key)) return;
    unawaited(() async {
      try {
        await _backgroundGate();
        final result = await provider.listFolder(
          _httpClient,
          credentials,
          folderId,
          page,
        );
        // 空结果不进缓存、也不覆盖已有缓存（开源目录缓存口径：
        // 空页多半是临时抽风，钉住会把真文件夹显示成空的）。
        if (result.files.isEmpty) return;
        _rememberFolderPage(
          key,
          _FolderPageEntry(result.files, result.hasMore),
        );
        _rememberDiskPage(
          key,
          _toCatalogPage(
            providerId: provider.id,
            files: result.files,
            hasMore: result.hasMore,
            page: page,
            isRoot: isRoot,
          ),
        );
      } catch (_) {
        // 静默：刷新失败不打扰正在看的旧页。
      } finally {
        _refreshingPages.remove(key);
      }
    }());
  }

  /// 子文件夹预取：当前页出来后，把每个子文件夹的第一页悄悄
  /// 拉进内存缓存（并发 2、最多 6 个、失败静默、不级联），
  /// 用户点哪个子夹都是热开。
  void _prefetchChildren(
    CloudDriveProvider provider,
    CloudCredentials credentials,
    String accountSeed,
    List<CloudDriveFile> files,
  ) {
    final targets = <String>[
      for (final file in files)
        if (file.isFolder) file.id,
    ];
    if (targets.isEmpty) return;
    final limited = targets.length > 6 ? targets.sublist(0, 6) : targets;
    var index = 0;
    Future<void> worker() async {
      while (index < limited.length) {
        final folderId = limited[index++];
        final key = _pageKey(provider.id, accountSeed, folderId, 1);
        if (_folderPages.containsKey(key)) continue;
        if (!_refreshingPages.add(key)) continue;
        try {
          await _backgroundGate();
          final result = await provider.listFolder(
            _httpClient,
            credentials,
            folderId,
            1,
          );
          if (result.files.isNotEmpty) {
            _rememberFolderPage(
              key,
              _FolderPageEntry(result.files, result.hasMore),
            );
          }
        } catch (_) {
          // 预取失败静默，用户点进去时照常现拉。
        } finally {
          _refreshingPages.remove(key);
        }
      }
    }

    unawaited(Future.wait([worker(), worker()]));
  }

  // -------------------------------------------------------------------------
  // 目录
  // -------------------------------------------------------------------------

  Future<CatalogPage> catalog({
    required String source,
    required int page,
    required String query,
    required String category,
    bool force = false,
  }) async {
    final providerId = providerIdOf(source);
    final provider = _provider(providerId);
    if (provider == null) throw AppFailure('未知的网盘：$providerId');
    final credentials = _credentials(providerId);
    try {
      if (query.trim().isNotEmpty) {
        return await _search(provider, credentials, query.trim(), category, page);
      }
      await _ensureDiskLoaded();
      final accountSeed = _accountSeed(credentials);
      if (category == cloudDriveAllCategory) {
        return await _aggregateCatalog(provider, credentials, accountSeed, force);
      }
      final folderId = category.isEmpty ? provider.rootFolderId : category;
      final key = _pageKey(providerId, accountSeed, folderId, page);
      final isRoot = folderId == provider.rootFolderId && page == 1;
      final memory = force ? null : _folderPages[key];
      if (memory != null) {
        // 热开：内存有这一页，先出画，后台静默刷新换新数据。
        _refreshFolderPage(provider, credentials, folderId, page, key, isRoot);
        _prefetchChildren(provider, credentials, accountSeed, memory.files);
        return _toCatalogPage(
          providerId: providerId,
          files: memory.files,
          hasMore: memory.hasMore,
          page: page,
          isRoot: isRoot,
        );
      }
      final disk = force ? null : _diskPages[key];
      if (disk != null) {
        // 重启后第一开：落盘页先出画，后台刷新回填内存层。
        _refreshFolderPage(provider, credentials, folderId, page, key, isRoot);
        return disk;
      }
      final result = await provider.listFolder(
        _httpClient,
        credentials,
        folderId,
        page,
      );
      final catalogPage = _toCatalogPage(
        providerId: providerId,
        files: result.files,
        hasMore: result.hasMore,
        page: page,
        isRoot: isRoot,
      );
      if (result.files.isNotEmpty) {
        _rememberFolderPage(
          key,
          _FolderPageEntry(result.files, result.hasMore),
        );
        _rememberDiskPage(key, catalogPage);
      }
      _prefetchChildren(provider, credentials, accountSeed, result.files);
      return catalogPage;
    } on CloudDriveException catch (e) {
      throw AppFailure(e.message);
    }
  }

  /// 站内搜索：有接口的用接口；没有的取当前夹列表按名过滤（兜底注明）。
  Future<CatalogPage> _search(
    CloudDriveProvider provider,
    CloudCredentials credentials,
    String keyword,
    String category,
    int page,
  ) async {
    final folderId = category.isEmpty || category == cloudDriveAllCategory
        ? provider.rootFolderId
        : category;
    List<CloudDriveFile> files;
    var fallbackNote = '';
    try {
      files = await provider.search(_httpClient, credentials, keyword, folderId);
    } on UnsupportedError {
      final result = await provider.listFolder(
        _httpClient,
        credentials,
        folderId,
        1,
      );
      final lower = keyword.toLowerCase();
      files = result.files
          .where((f) => f.name.toLowerCase().contains(lower))
          .toList();
      fallbackNote = '（该网盘没有站方搜索接口，只在当前文件夹的第一页里按名过滤）';
    }
    final catalogPage = _toCatalogPage(
      providerId: provider.id,
      files: files,
      hasMore: false,
      page: page,
      isRoot: false,
    );
    if (fallbackNote.isNotEmpty) {
      return CatalogPage(
        catalogPage.items,
        hasMore: catalogPage.hasMore,
        warning: '${catalogPage.warning} $fallbackNote'.trim(),
        page: catalogPage.page,
      );
    }
    return catalogPage;
  }

  /// “全部”聚合目录：与其他目录页同一套两级缓存（问题 6）——
  /// 命中先出画、后台静默刷新；未命中才真遍历。
  Future<CatalogPage> _aggregateCatalog(
    CloudDriveProvider provider,
    CloudCredentials credentials,
    String accountSeed,
    bool force,
  ) async {
    final key = _pageKey(provider.id, accountSeed, cloudDriveAllCategory, 1);
    final memory = force ? null : _folderPages[key];
    if (memory != null) {
      _refreshAggregate(provider, credentials, key);
      // 聚合键的条目里 hasMore 槽存的是“是否触顶”（见
      // _fetchAggregate 返回值），不是分页语义。
      return _aggregatePage(provider.id, memory.files, memory.hasMore);
    }
    final disk = force ? null : _diskPages[key];
    if (disk != null) {
      _refreshAggregate(provider, credentials, key);
      return disk;
    }
    final (videos, hitCap) = await _fetchAggregate(provider, credentials);
    final page = _aggregatePage(provider.id, videos, hitCap);
    if (videos.isNotEmpty) {
      _rememberFolderPage(key, _FolderPageEntry(videos, hitCap));
      _rememberDiskPage(key, page);
    }
    return page;
  }

  void _refreshAggregate(
    CloudDriveProvider provider,
    CloudCredentials credentials,
    String key,
  ) {
    if (!_refreshingPages.add(key)) return;
    unawaited(() async {
      try {
        await _backgroundGate();
        final (videos, hitCap) = await _fetchAggregate(provider, credentials);
        if (videos.isEmpty) return;
        _rememberFolderPage(key, _FolderPageEntry(videos, hitCap));
        _rememberDiskPage(key, _aggregatePage(provider.id, videos, hitCap));
      } catch (_) {
        // 静默：刷新失败不打扰正在看的旧页。
      } finally {
        _refreshingPages.remove(key);
      }
    }());
  }

  CatalogPage _aggregatePage(
    String providerId,
    List<CloudDriveFile> videos,
    bool hitCap,
  ) {
    final catalogPage = _toCatalogPage(
      providerId: providerId,
      files: videos,
      hasMore: false,
      page: 1,
      isRoot: false,
    );
    final notes = <String>[
      if (catalogPage.warning.isNotEmpty) catalogPage.warning,
      if (hitCap)
        '聚合视图有上限（最多 ${_AggregateCaps.maxFolders} 个文件夹、'
            '${_AggregateCaps.maxVideos} 条视频、${_AggregateCaps.maxDepth} 层），'
            '超出部分请进文件夹逐个查看',
    ];
    return CatalogPage(catalogPage.items, warning: notes.join(' '), page: 1);
  }

  /// “全部”聚合的真遍历：广度优先汇总视频（上限见
  /// [_AggregateCaps]）。原来逐个文件夹串行拉满才出画，弱网下
  /// 长时间没动静；改成一波 3 个文件夹并行（同一文件夹的分页
  /// 仍按页串行），返回值第二项是“是否触顶”。
  Future<(List<CloudDriveFile>, bool)> _fetchAggregate(
    CloudDriveProvider provider,
    CloudCredentials credentials,
  ) async {
    final videos = <CloudDriveFile>[];
    final queue = <({String folderId, int depth})>[
      (folderId: provider.rootFolderId, depth: 1),
    ];
    var visitedFolders = 0;
    var hitCap = false;
    while (queue.isNotEmpty && videos.length < _AggregateCaps.maxVideos) {
      final wave = <({String folderId, int depth})>[];
      while (queue.isNotEmpty && wave.length < 3) {
        if (visitedFolders + wave.length >= _AggregateCaps.maxFolders) {
          hitCap = true;
          break;
        }
        wave.add(queue.removeAt(0));
      }
      if (wave.isEmpty) break;
      visitedFolders += wave.length;
      final results = await Future.wait([
        for (final current in wave)
          _listFolderAllPages(provider, credentials, current.folderId),
      ]);
      for (var i = 0; i < wave.length; i++) {
        final current = wave[i];
        for (final file in results[i]) {
          if (file.isFolder) {
            if (current.depth < _AggregateCaps.maxDepth) {
              queue.add((folderId: file.id, depth: current.depth + 1));
            }
          } else if (file.kind == CloudFileKind.video) {
            if (videos.length < _AggregateCaps.maxVideos) videos.add(file);
          }
        }
      }
    }
    if (queue.isNotEmpty) hitCap = true;
    return (videos, hitCap);
  }

  /// 聚合遍历里单个文件夹的全部页（按页串行，页数上限见
  /// [_AggregateCaps.maxPagesPerFolder]）。
  Future<List<CloudDriveFile>> _listFolderAllPages(
    CloudDriveProvider provider,
    CloudCredentials credentials,
    String folderId,
  ) async {
    final files = <CloudDriveFile>[];
    for (var page = 1; page <= _AggregateCaps.maxPagesPerFolder; page++) {
      final result = await provider.listFolder(
        _httpClient,
        credentials,
        folderId,
        page,
      );
      files.addAll(result.files);
      if (!result.hasMore) break;
    }
    return files;
  }

  /// 文件列表 → 目录页：文件夹卡在前、视频卡在后；封面三级兜底；
  /// 非视频文件（推广 html/chm 等）不进列表；疑似广告视频默认隐藏并计数。
  CatalogPage _toCatalogPage({
    required String providerId,
    required List<CloudDriveFile> files,
    required bool hasMore,
    required int page,
    required bool isRoot,
  }) {
    // 同夹图片索引：base 名 → 缩略图（视频封面第二级兜底用）。
    final imageThumbs = <String, String>{};
    for (final file in files) {
      if (file.kind == CloudFileKind.image && file.thumbnailUrl.isNotEmpty) {
        imageThumbs[_baseName(file.name)] = file.thumbnailUrl;
        if (_isPosterName(file.name)) {
          imageThumbs[''] = file.thumbnailUrl;
        }
      }
    }
    final items = <Drama>[];
    var hiddenAds = 0;
    if (isRoot) {
      // 虚拟文件夹卡“全部”：点进去是跨文件夹聚合视图。
      items.add(
        Drama(
          id: dramaId(providerId, cloudDriveAllCategory),
          source: 'cloud:$providerId',
          title: '全部',
          description: '跨文件夹汇总全部视频',
          kind: 'folder',
          folderId: cloudDriveAllCategory,
        ),
      );
    }
    final folders = files.where((f) => f.isFolder).toList();
    final rest = files.where((f) => !f.isFolder).toList();
    for (final folder in folders) {
      final discType = discTypeOfFolder(folder.name);
      if (discType != null) {
        // 光盘文件夹归成一个光盘条目，不再是可下钻的文件夹卡；
        // 详情时现取夹内内容找正片文件。
        final key = dramaId(providerId, 'disc:${folder.id}');
        _rememberDisc(
          key,
          _DiscEntry(
            providerId: providerId,
            folderId: folder.id,
            discType: discType,
          ),
        );
        items.add(
          Drama(
            id: key,
            source: 'cloud:$providerId',
            title: discType == 'dvd' ? 'DVD 光盘' : '蓝光光盘',
            description: discType == 'dvd'
                ? 'DVD 光盘（VIDEO_TS）· 点进详情播放正片'
                : '蓝光光盘（BDMV）· 点进详情播放正片',
            kind: 'video',
            tags: ['光盘', discType == 'dvd' ? 'DVD' : '蓝光'],
          ),
        );
        continue;
      }
      final key = dramaId(providerId, folder.id);
      _remember(key, folder, CloudCoverSource.placeholder);
      items.add(
        Drama(
          id: key,
          source: 'cloud:$providerId',
          title: folder.name,
          description: '文件夹',
          kind: 'folder',
          folderId: folder.id,
        ),
      );
    }
    // 推广文件（html/chm/url/txt 等）不进列表（文件夹已在上面单列）；
    // 其余文件一律成卡；疑似广告过滤只对真视频文件生效。
    final visible = <CloudDriveFile>[];
    for (final file in rest) {
      if (!isListableDriveFile(file)) continue;
      if (isSuspectedAdVideo(file) && !_showSuspectedAds()) {
        hiddenAds++;
        continue;
      }
      visible.add(file);
    }
    // VOB 分段：同一目录里只要有 VOB，就归成一个“DVD 正片”条目，
    // IFO/BUP 元数据文件不再单独成卡；没有 VOB 时 IFO/BUP 保持原样。
    final vobs = visible.where((f) => isVobFile(f.name)).toList();
    final singles = <CloudDriveFile>[];
    final groupables = <CloudDriveFile>[];
    for (final file in visible) {
      if (isVobFile(file.name)) continue;
      if (vobs.isNotEmpty && isDiscMetadataFile(file.name)) continue;
      // ISO 不进剧集分组（一个 ISO 就是一张盘）；其它可分组视频
      // （含 STRM）按文件名解析结果进分组候选。
      if (file.kind == CloudFileKind.video &&
          !isIsoFile(file.name) &&
          parseCloudFileName(file.name).groupable) {
        groupables.add(file);
      } else {
        singles.add(file);
      }
    }
    if (vobs.isNotEmpty) {
      items.add(_vobGroupDrama(providerId, vobs, imageThumbs));
    }
    items.addAll(
      _seriesGroupDramas(providerId, groupables, imageThumbs, singles),
    );
    for (final file in singles) {
      final cover = _coverFor(file, imageThumbs);
      final key = dramaId(providerId, file.id);
      _remember(key, file, cover.source);
      items.add(
        Drama(
          id: key,
          source: 'cloud:$providerId',
          title: file.name,
          description: _fileDescription(file),
          cover: cover.url,
          kind: 'video',
          tags: [
            if (isSuspectedAdVideo(file)) '疑似广告',
            _kindLabel(file.kind),
            if (isStrmFile(file.name)) 'STRM',
            if (isIsoFile(file.name)) 'ISO 光盘',
          ],
        ),
      );
    }
    return CatalogPage(
      items,
      hasMore: hasMore,
      warning: hiddenAds > 0
          ? '已隐藏 $hiddenAds 个疑似广告视频（设置 → 网盘登录里可显示）'
          : '',
      page: page,
    );
  }

  /// VOB 分段归成一个“DVD 正片”条目：主视频取最大的 VOB（DVD 正片
  /// 通常是最大的 VOB 文件），详情只有一集“正片”，播放强制走 mpv。
  Drama _vobGroupDrama(
    String providerId,
    List<CloudDriveFile> vobs,
    Map<String, String> imageThumbs,
  ) {
    final sorted = [...vobs]
      ..sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
    final main = sorted.first;
    final cover = _coverFor(main, imageThumbs);
    final sortedIds = vobs.map((f) => f.id).toList()..sort();
    final key = dramaId(
      providerId,
      'vobgroup:${_fnv1aHex(sortedIds.join('|'))}',
    );
    _remember(dramaId(providerId, main.id), main, cover.source);
    _rememberGroup(
      key,
      _GroupedEntry(
        members: [main],
        episodeTitles: const ['正片'],
        episodeNumbers: const [1],
        coverSource: cover.source,
        forceMpv: true,
      ),
    );
    return Drama(
      id: key,
      source: 'cloud:$providerId',
      title: 'DVD 正片',
      description: 'DVD 光盘正片（${vobs.length} 个 VOB 分段，已合并）',
      cover: cover.url,
      kind: 'video',
      tags: const ['光盘', 'DVD'],
    );
  }

  /// 剧集分组：同一剧名（归一键 + 季号）且集号互不相同的视频归成
  /// 一个剧集条目；集号重复、只有一部的，退回 [leftovers] 各自成单卡。
  /// 分组 id 由成员 id 排序后哈希，跨进程稳定。
  List<Drama> _seriesGroupDramas(
    String providerId,
    List<CloudDriveFile> groupables,
    Map<String, String> imageThumbs,
    List<CloudDriveFile> leftovers,
  ) {
    final buckets = <String, List<(CloudDriveFile, ParsedCloudFileName)>>{};
    final order = <String>[];
    for (final file in groupables) {
      final parsed = parseCloudFileName(file.name);
      final key = '${parsed.normalizedKey}|${parsed.season ?? ''}';
      if (!buckets.containsKey(key)) {
        buckets[key] = [];
        order.add(key);
      }
      buckets[key]!.add((file, parsed));
    }
    final groups = <Drama>[];
    for (final key in order) {
      final members = buckets[key]!;
      final episodes = members.map((m) => m.$2.episode!).toSet();
      if (members.length < 2 || episodes.length != members.length) {
        leftovers.addAll(members.map((m) => m.$1));
        continue;
      }
      members.sort((a, b) => a.$2.episode!.compareTo(b.$2.episode!));
      final first = members.first.$2;
      final title = first.season != null
          ? '${first.seriesTitle} 第${first.season}季'
          : first.seriesTitle;
      final sortedIds = members.map((m) => m.$1.id).toList()..sort();
      final groupKey = dramaId(
        providerId,
        'group:${_fnv1aHex(sortedIds.join('|'))}',
      );
      // 封面取成员里第一个非占位封面，都没有时用首个成员的。
      var cover = _coverFor(members.first.$1, imageThumbs);
      for (final member in members) {
        final candidate = _coverFor(member.$1, imageThumbs);
        if (candidate.source != CloudCoverSource.placeholder) {
          cover = candidate;
          break;
        }
      }
      for (final member in members) {
        _remember(
          dramaId(providerId, member.$1.id),
          member.$1,
          _coverFor(member.$1, imageThumbs).source,
        );
      }
      _rememberGroup(
        groupKey,
        _GroupedEntry(
          members: members.map((m) => m.$1).toList(),
          episodeTitles: members
              .map((m) => '第${m.$2.episode}集')
              .toList(),
          episodeNumbers: members.map((m) => m.$2.episode!).toList(),
          coverSource: cover.source,
        ),
      );
      groups.add(
        Drama(
          id: groupKey,
          source: 'cloud:$providerId',
          title: title,
          description: '共 ${members.length} 集',
          cover: cover.url,
          episodes: members.length,
          kind: 'video',
          tags: [
            '剧集',
            '共${members.length}集',
            if (members.any((m) => isSuspectedAdVideo(m.$1))) '疑似广告',
          ],
        ),
      );
    }
    return groups;
  }

  /// 封面三级兜底：网盘缩略图 → 同名图片 → 占位（空 cover 走现有占位）。
  ({String url, CloudCoverSource source}) _coverFor(
    CloudDriveFile file,
    Map<String, String> imageThumbs,
  ) {
    if (file.thumbnailUrl.isNotEmpty) {
      return (url: file.thumbnailUrl, source: CloudCoverSource.providerThumbnail);
    }
    final sameName = imageThumbs[_baseName(file.name)];
    if (sameName != null && sameName.isNotEmpty) {
      return (url: sameName, source: CloudCoverSource.sameNameImage);
    }
    final poster = imageThumbs[''];
    if (poster != null && poster.isNotEmpty && file.kind == CloudFileKind.video) {
      return (url: poster, source: CloudCoverSource.sameNameImage);
    }
    return (url: '', source: CloudCoverSource.placeholder);
  }

  String _baseName(String name) {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    return base.toLowerCase();
  }

  bool _isPosterName(String name) {
    final base = _baseName(name);
    return base == 'poster' || base == 'cover' || base == '海报' || base == '封面';
  }

  String _kindLabel(CloudFileKind kind) {
    switch (kind) {
      case CloudFileKind.folder:
        return '文件夹';
      case CloudFileKind.video:
        return '视频';
      case CloudFileKind.audio:
        return '音频';
      case CloudFileKind.image:
        return '图片';
      case CloudFileKind.subtitle:
        return '字幕';
      case CloudFileKind.other:
        return '文件';
    }
  }

  String _fileDescription(CloudDriveFile file) {
    final parts = <String>[_kindLabel(file.kind)];
    if (file.sizeBytes > 0) parts.add(_sizeLabel(file.sizeBytes));
    final duration = file.durationSeconds;
    if (duration != null && duration > 0) {
      parts.add(_durationLabel(duration));
    }
    return parts.join(' · ');
  }

  String _sizeLabel(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  String _durationLabel(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }

  // -------------------------------------------------------------------------
  // 详情
  // -------------------------------------------------------------------------

  Future<DramaDetail> detail(Drama drama) async {
    final disc = _discs[drama.id];
    if (disc != null) return _discDetail(drama, disc);
    final group = _groups[drama.id];
    if (group != null) {
      return DramaDetail(
        drama,
        [
          for (var i = 0; i < group.members.length; i++)
            Episode({
              'id': group.members[i].id,
              'title': group.episodeTitles[i],
              'currentEpisode': group.episodeNumbers[i],
            }, group.episodeNumbers[i]),
        ],
        warning: group.forceMpv ? 'DVD 菜单无法导航，已直接播放正片' : '',
        backdrop: drama.cover,
        tags: [
          const DetailTag(id: 'kind', name: '视频'),
          const DetailTag(id: 'group', name: '剧集'),
          DetailTag(id: 'cover', name: '封面：${group.coverSource.label}'),
        ],
      );
    }
    final entry = _cache[drama.id];
    if (entry == null) {
      // 缓存未命中（进程重启后直接打开旧详情）：只剩卡片自带信息，
      // 如实提示返回列表刷新，不编文件信息。
      return DramaDetail(
        drama,
        const [],
        warning: '文件信息已过期，请返回列表重新打开',
      );
    }
    final file = entry.file;
    if (file.isFolder) {
      return DramaDetail(drama, const [], warning: '文件夹请点卡片下钻浏览');
    }
    final tags = <DetailTag>[
      DetailTag(id: 'kind', name: _kindLabel(file.kind)),
      DetailTag(id: 'cover', name: '封面：${entry.coverSource.label}'),
      if (isSuspectedAdVideo(file))
        const DetailTag(id: 'ad', name: '疑似广告视频'),
    ];
    switch (file.kind) {
      case CloudFileKind.video:
      case CloudFileKind.audio:
      case CloudFileKind.image:
        return DramaDetail(
          drama,
          [Episode({'id': file.id, 'title': file.name}, 1)],
          backdrop: drama.cover,
          tags: tags,
        );
      case CloudFileKind.subtitle:
      case CloudFileKind.folder:
      case CloudFileKind.other:
        return DramaDetail(
          drama,
          const [],
          warning: '该文件类型不可播放，仅展示文件信息',
          backdrop: drama.cover,
          tags: tags,
        );
    }
  }

  /// 光盘详情：现取光盘文件夹内容找正片文件。
  ///
  /// DVD（VIDEO_TS）：取最大的 VOB 作“正片”一集，菜单无法导航如实
  /// 提示；夹里没有 VOB 时零集 + 提示，不编选集。
  /// 蓝光（BDMV）：先看有没有 AACS 文件夹，有则零集 + 加密提示
  /// （正版加密蓝光播不了，不假播）；没有则进 STREAM 文件夹取
  /// 最大的 .m2ts 作“正片”。列表读取失败时零集 + 失败原因。
  Future<DramaDetail> _discDetail(Drama drama, _DiscEntry disc) async {
    final provider = _provider(disc.providerId);
    if (provider == null) throw AppFailure('未知的网盘：${disc.providerId}');
    final credentials = _credentials(disc.providerId);
    final tags = <DetailTag>[
      DetailTag(id: 'kind', name: disc.discType == 'dvd' ? 'DVD 光盘' : '蓝光光盘'),
      const DetailTag(id: 'player', name: 'mpv 播放'),
    ];
    DramaDetail noEpisodes(String warning) => DramaDetail(
      drama,
      const [],
      warning: warning,
      backdrop: drama.cover,
      tags: tags,
    );
    DramaDetail mainFeature(CloudDriveFile file, String warning) {
      _remember(dramaId(disc.providerId, file.id), file, CloudCoverSource.placeholder);
      return DramaDetail(
        drama,
        [
          Episode({'id': file.id, 'title': '正片', 'currentEpisode': 1}, 1),
        ],
        warning: warning,
        backdrop: drama.cover,
        tags: tags,
      );
    }

    try {
      final listing = await provider.listFolder(
        _httpClient,
        credentials,
        disc.folderId,
        1,
      );
      if (disc.discType == 'dvd') {
        final vobs = listing.files.where((f) => isVobFile(f.name)).toList()
          ..sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
        if (vobs.isEmpty) {
          return noEpisodes('该 DVD 文件夹里没有找到 VOB 视频文件');
        }
        return mainFeature(vobs.first, 'DVD 菜单无法导航，已直接播放正片');
      }
      // 蓝光：AACS 文件夹存在即加密盘。
      final hasAacs = listing.files.any(
        (f) => f.isFolder && f.name.trim().toUpperCase() == 'AACS',
      );
      if (hasAacs) {
        _rememberDisc(
          drama.id,
          _DiscEntry(
            providerId: disc.providerId,
            folderId: disc.folderId,
            discType: disc.discType,
            encrypted: true,
          ),
        );
        return noEpisodes('检测到 AACS 加密，无法播放正版加密蓝光');
      }
      final stream = listing.files
          .where((f) => f.isFolder && f.name.trim().toUpperCase() == 'STREAM')
          .firstOrNull;
      if (stream == null) {
        return noEpisodes('该蓝光文件夹里没有找到 STREAM 流目录');
      }
      final streams = await provider.listFolder(
        _httpClient,
        credentials,
        stream.id,
        1,
      );
      final clips = streams.files
          .where((f) => fileExtension(f.name) == 'm2ts')
          .toList()
        ..sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
      if (clips.isEmpty) {
        return noEpisodes('STREAM 目录里没有找到 m2ts 视频文件');
      }
      return mainFeature(clips.first, '蓝光菜单无法导航，已直接播放正片');
    } on CloudDriveException catch (e) {
      return noEpisodes('光盘内容读取失败：${e.message}');
    }
  }

  // -------------------------------------------------------------------------
  // 播放
  // -------------------------------------------------------------------------

  Future<PlaybackPlan> resolve(Drama drama, Episode episode) async {
    final providerId = providerIdOf(drama.source);
    final provider = _provider(providerId);
    if (provider == null) throw AppFailure('未知的网盘：$providerId');
    // 加密蓝光纵深拦截：详情已零集，正常流程到不了这里；万一到了
    // 也诚实报错，绝不把加密盘地址交给播放器假播。
    final disc = _discs[drama.id];
    if (disc != null && disc.encrypted) {
      throw AppFailure('该蓝光盘带 AACS 加密，无法播放');
    }
    final fileId = episode.id.isNotEmpty ? episode.id : fileIdOf(drama.id);
    final key = dramaId(providerId, fileId);
    final entry = _cache[key] ?? _cache[drama.id];
    if (entry == null) {
      throw AppFailure('文件信息已过期，请返回列表重新打开');
    }
    final file = entry.file;
    if (file.kind != CloudFileKind.video &&
        file.kind != CloudFileKind.audio &&
        file.kind != CloudFileKind.image) {
      throw AppFailure('该文件类型不可播放');
    }
    final credentials = _credentials(providerId);
    try {
      final link = await _directOrTranscode(provider, credentials, file);
      if (isStrmFile(file.name)) {
        // STRM 指针文件：读内容取第一行流地址，再走正常播放链；
        // 内容无效时诚实报错。只展开一层，不递归。
        final target = await _fetchStrmTarget(link);
        if (target == null) {
          throw AppFailure('STRM 文件内容不是有效的流地址');
        }
        return PlaybackPlan(
          url: target,
          originalUrl: target,
          headers: link.headers,
        );
      }
      if (file.kind == CloudFileKind.image) {
        // 图片走 pics:// 浏览链路（与现有非视频内容协议一致）。
        // 注意：图片查看器只透传 User-Agent/Referer，不透传 Cookie，
        // 需要 Cookie 的图片直链在应用内可能打不开，
        // 已在回报里列为已知缺口。
        return PlaybackPlan(
          url: 'pics://${link.url}',
          originalUrl: link.url,
          headers: link.headers,
        );
      }
      // 光盘类强制走 mpv：ISO 文件、光盘条目、VOB 正片组。
      final forceMpv =
          isIsoFile(file.name) ||
          disc != null ||
          (_groups[drama.id]?.forceMpv ?? false);
      return PlaybackPlan(
        url: link.url,
        originalUrl: link.url,
        headers: link.headers,
        forceMpv: forceMpv,
      );
    } on CloudDriveException catch (e) {
      throw AppFailure(e.message);
    }
  }

  /// 取播放地址：一般网盘只走直链；115 的视频多一条转码兜底——
  /// 直链取不到、或直链首请求被 CDN 明确拒掉（403，多半是 f 校验
  /// 在当前环境对不上）时，回退转码 m3u8（安卓路）。两条都失败时
  /// 把两边的原因一起报，不让用户只看到一条路的错。
  Future<CloudDirectLink> _directOrTranscode(
    CloudDriveProvider provider,
    CloudCredentials credentials,
    CloudDriveFile file,
  ) async {
    final canTranscode =
        provider is Pan115Provider &&
        file.kind == CloudFileKind.video &&
        !isStrmFile(file.name);
    if (!canTranscode) {
      return provider.directLink(_httpClient, credentials, file);
    }
    CloudDriveException? directError;
    CloudDirectLink? link;
    try {
      link = await provider.directLink(_httpClient, credentials, file);
    } on CloudDriveException catch (e) {
      directError = e;
    }
    if (link != null && !await _probeForbidden(link)) return link;
    try {
      return await provider.transcodeLink(_httpClient, credentials, file);
    } on CloudDriveException catch (transError) {
      if (directError != null) {
        throw CloudDriveException(
          '115 直链取不到（${directError.message}），'
          '转码兜底也失败（${transError.message}）',
        );
      }
      throw CloudDriveException(
        '115 直链被服务器拒绝，转码兜底也失败（${transError.message}）',
      );
    }
  }

  /// 直链首请求探针：带上计划的请求头打一个 1 字节的 Range GET，
  /// 不跟重定向（302 跳 CDN 是正常形态）。只有明确回 403 才算被拒；
  /// 网络失败、超时、其它状态一律不拦——探不准就不惩罚，交给
  /// 播放器自己试。
  Future<bool> _probeForbidden(CloudDirectLink link) async {
    try {
      final request = http.Request('GET', Uri.parse(link.url));
      request.followRedirects = false;
      request.headers.addAll(link.headers);
      request.headers.putIfAbsent('Range', () => 'bytes=0-0');
      final response = await _httpClient
          .send(request)
          .timeout(const Duration(seconds: 10));
      await response.stream.listen(null).cancel().catchError((_) {});
      return response.statusCode == 403;
    } catch (_) {
      return false;
    }
  }

  /// 读 STRM 文件内容取流地址：直链 GET 只读前 8KB 就停（指针文件
  /// 只有几行）。读不到/超时/非 2xx 时抛“读取失败”；内容读到了但
  /// 第一行不是有效流地址时返回 null（调用方按“内容无效”报错）。
  /// 两者分开，报错才诚实。
  Future<String?> _fetchStrmTarget(CloudDirectLink link) async {
    final uri = Uri.tryParse(link.url);
    if (uri == null) return null;
    http.StreamedResponse streamed;
    try {
      final request = http.Request('GET', uri)..headers.addAll(link.headers);
      streamed = await _httpClient.send(request).timeout(_strmTimeout);
    } catch (_) {
      throw AppFailure('STRM 文件读取失败，请检查网络后重试');
    }
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      await streamed.stream.listen(null).cancel().catchError((_) {});
      throw AppFailure('STRM 文件读取失败（HTTP ${streamed.statusCode}）');
    }
    try {
      final bytes = <int>[];
      await for (final chunk in streamed.stream) {
        bytes.addAll(chunk);
        if (bytes.length >= _strmMaxBytes) break;
      }
      return parseStrmContent(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      throw AppFailure('STRM 文件读取失败，请检查网络后重试');
    }
  }
}
