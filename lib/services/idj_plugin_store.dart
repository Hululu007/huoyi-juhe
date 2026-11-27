import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// iDuanJu `.idjplugin` 插件仓库（修仙版）：manifest 校验 + 包解析 /
/// 下载 / 完整性 / 试加载 / 写盘 / 索引 / 订阅 / 更新检查 + 已装索引。
///
/// 形态与校验口径对齐魔蚁现行实现（`idj_plugin_store.dart`），使魔蚁
/// 远程插件索引里的包在修仙版同样装得上；与魔蚁的差异只有三处：
/// - 错误类型用本文件的 [IdjPluginFailure]（本树没有 AppFailure）；
/// - 站点登记不在本文件：装/卸/启停后经 [IdjPluginStore.onInstalledChanged]
///   通知 `SourceRegistry.syncIdjPluginSites` 对账登记（避免循环依赖）；
/// - 试加载（probe）由 `main.dart` 接到 [IdjPluginStore.probeHandler]：
///   安卓走 QuickJS 真运行时试跑，平台没有引擎时由接线方如实报错。
///
/// 插件不预装、不预注册、不打进安装包，只通过插件区市场装进来。

/// 宿主实现的 idj1 规格水平（与魔蚁一致）：minAppVersion 只认这个
/// 规格版本比对，不用 App 版本号。
const String idjHostSpecVersion = '1.5.2';

/// 插件索引的 SharedPreferences 键：值是 JSON 对象字符串，
/// `{pluginId: {name, version, type, adult, enabled, origin, fileHash,
/// siteKey, installedAt, failures}}`。manifest 本体不进 prefs，
/// 用时读包文件；包文件是唯一事实来源。
const String idjPluginsPrefsKey = 'xiuxian_idj_plugins';

/// 订阅地址列表的 SharedPreferences 键：只存地址，订阅内容不持久化。
const String idjSubscriptionsPrefsKey = 'xiuxian_idj_subscriptions';

/// 「已卸载」记录的 SharedPreferences 键（用户 2026-11-27 更正令）：
/// 值是 JSON 对象字符串 `{pluginId: 卸载时的版本号}`，持久化、
/// 重启保留。市场渲染据此判四态：已卸载且远程版本 ≤ 记录版本
/// 的条目整个不显示；远程出了更高版本才重新出现（可安装）；
/// 重新装回即清掉该条记录。见 [IdjPluginStore.uninstall]、
/// [IdjPluginStore.readUninstalledVersions]。
const String idjUninstalledPrefsKey = 'xiuxian_idj_uninstalled';

/// 内置远程插件索引（用户 2026-11-26 令：用魔蚁现行远程索引那套，
/// 地址绑定在程序里、界面不显示）。打开插件区自动拉取，不用手动贴
/// 地址；插件本身不预装，只展示、逐个点安装。拉取失败只记 error、
/// 不拦市场。索引格式：`{"name", "plugins": [...], "cms": []}`，
/// 条目的 `manifest` 是相对索引地址的包路径。
const String idjBuiltInSubscriptionUrl =
    'https://raw.githubusercontent.com/hoyittvggfh45/moytv/plugins/index.json';

/// 内置订阅不可删：[IdjPluginStore.removeSubscription] 遇到它直接返回。
bool idjIsBuiltInSubscription(String url) =>
    url.trim() == idjBuiltInSubscriptionUrl;

/// 内置订阅在界面上的显示名（只给名、不给地址）。
const String idjBuiltInSubscriptionLabel = '官方插件源';

/// 安装器下载的 UA：`Xiuxian/<App 真实版本> plugin-installer`。
/// 版本号与 `pubspec.yaml` 的 `version` 保持一致，改版时同步改这里。
const String idjInstallerAppVersion = '1.0.1104';

/// 插件链路的失败：带一句人话原因，界面原样展示，不吞。
class IdjPluginFailure implements Exception {
  IdjPluginFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 界面错误文案口径（用户令）：插件区不许把异常原文（英文报错、
/// 「Bad state:」前缀之类）摆上界面。[IdjPluginFailure] 的 message
/// 本就是写给用户看的中文，可直接用；其它异常一律换成调用方给的
/// 中文兜底文案（说清哪一步失败＋怎么办），原文由抛出侧进日志。
String idjPluginUserErrorText(Object error, String fallback) =>
    error is IdjPluginFailure ? error.message : fallback;

/// probe 试加载的回调：把包里的脚本与 manifest 传给运行时，
/// 运行时加载入口脚本、检查 `export default` 是否齐 manifest
/// 声明的能力函数；失败抛 [IdjPluginFailure] 写明原因。
/// 生产环境由 `main.dart` 接到 QuickJS 运行时（见 idj_runtime.dart）；
/// 未接线时安装明确报错，不静默跳过 probe。
typedef IdjProbeFn =
    Future<void> Function({
      required String pluginId,
      required String script,
      required Map<String, dynamic> manifest,
    });

/// manifest 校验（与魔蚁 `IdjPluginManifest` 同口径）：解析 + 逐条
/// 问题清单。域名清单在 fromJson 先归一化（剥协议头/端口/路径、
/// 转小写）再验形态——校验、落盘登记、运行时三处用同一份清单。
class IdjPluginManifest {
  IdjPluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.entry,
    required this.type,
    required this.adult,
    required this.author,
    required this.description,
    required this.capabilities,
    required this.httpDomains,
    required this.mediaDomains,
    required this.cloudflare,
    required this.storagePermission,
    required this.loginPermission,
    required this.minAppVersion,
    required this.updateUrl,
    required this.raw,
  });

  factory IdjPluginManifest.fromJson(Map<String, dynamic> json) {
    final permissions = json['permissions'] is Map
        ? Map<String, dynamic>.from(json['permissions'] as Map)
        : const <String, dynamic>{};
    final update = json['update'] is Map
        ? Map<String, dynamic>.from(json['update'] as Map)
        : const <String, dynamic>{};
    final httpDomains = normalizeDomainList(permissions['http']);
    final mediaDomains = normalizeDomainList(permissions['media']);
    // author 在仓库形态里是对象 {name, contact}，魔蚁旧形态是字符串；
    // 两种都收，展示时取名字。
    var author = '';
    final rawAuthor = json['author'];
    if (rawAuthor is Map) {
      author = (rawAuthor['name'] as Object?)?.toString() ?? '';
    } else if (rawAuthor != null) {
      author = rawAuthor.toString();
    }
    final raw = Map<String, dynamic>.from(json);
    if (raw['permissions'] is Map) {
      final rawPermissions = Map<String, dynamic>.from(
        raw['permissions'] as Map,
      );
      if (rawPermissions.containsKey('http')) {
        rawPermissions['http'] = httpDomains;
      }
      if (rawPermissions.containsKey('media')) {
        rawPermissions['media'] = mediaDomains;
      }
      raw['permissions'] = rawPermissions;
    }
    return IdjPluginManifest(
      id: (json['id'] as Object?)?.toString() ?? '',
      name: (json['name'] as Object?)?.toString() ?? '',
      version: (json['version'] as Object?)?.toString() ?? '',
      entry: (json['entry'] as Object?)?.toString() ?? '',
      type: (json['type'] as Object?)?.toString() ?? '',
      adult: json['adult'] == true,
      author: author,
      description: (json['description'] as Object?)?.toString() ?? '',
      capabilities: [
        for (final row in json['capabilities'] as List? ?? const [])
          if (row != null && row.toString().isNotEmpty) row.toString(),
      ],
      httpDomains: httpDomains,
      mediaDomains: mediaDomains,
      cloudflare: permissions['cloudflare'] == true,
      storagePermission: permissions['storage'] == true,
      loginPermission: permissions['login'] == true,
      minAppVersion: (json['minAppVersion'] as Object?)?.toString() ?? '',
      updateUrl: (update['url'] as Object?)?.toString() ?? '',
      raw: raw,
    );
  }

  /// 域名清单归一化（只做减法，不扩大主机集合）：逐条剥协议头、
  /// 剥路径/查询/片段、剥端口、转小写。归一化后仍须过
  /// [_domainPattern] 才合法，见 [problems]。
  static String normalizeDomain(String value) {
    var v = value.trim().toLowerCase();
    final schemeEnd = v.indexOf('://');
    if (schemeEnd >= 0) v = v.substring(schemeEnd + 3);
    for (final sep in const ['/', '?', '#']) {
      final idx = v.indexOf(sep);
      if (idx >= 0) v = v.substring(0, idx);
    }
    final portStart = v.indexOf(':');
    if (portStart >= 0) v = v.substring(0, portStart);
    return v;
  }

  static List<String> normalizeDomainList(Object? rows) => [
    for (final row in rows as List? ?? const [])
      if (row != null && row.toString().isNotEmpty)
        normalizeDomain(row.toString()),
  ];

  final String id;
  final String name;
  final String version;
  final String entry;
  final String type;
  final bool adult;
  final String author;
  final String description;
  final List<String> capabilities;
  final List<String> httpDomains;
  final List<String> mediaDomains;
  final bool cloudflare;
  final bool storagePermission;
  final bool loginPermission;
  final String minAppVersion;
  final String updateUrl;

  /// manifest JSON（运行时白名单用；域名清单已归一化，其余原样）。
  final Map<String, dynamic> raw;

  /// manifest.id 的末段（`com.idj.ext.chengguo` → `chengguo`）。
  String get shortName => id.split('.').last;

  /// integrity 取值：扁平字符串形态直接取整个字符串；对象形态取
  /// `integrity.files[entry]`；都没有时回 null（不校验）。
  String? integrityValue() {
    final integrity = raw['integrity'];
    if (integrity is String) return integrity;
    if (integrity is Map) {
      final files = Map<String, dynamic>.from(integrity)['files'];
      if (files is Map) {
        final value = files[entry];
        if (value is String) return value;
      }
    }
    return null;
  }

  /// `x.y.z` 三段 semver 比对：a < b 回负数，相等回 0，a > b 回正数。
  /// 非三段写法的按 0 补齐再比（如 `1.5` 当 `1.5.0`）。
  static int compareVersions(String a, String b) {
    final pa = _versionParts(a);
    final pb = _versionParts(b);
    for (var i = 0; i < 3; i++) {
      if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
    }
    return 0;
  }

  static List<int> _versionParts(String value) {
    final parts = value.trim().split('.');
    final numbers = <int>[];
    for (var i = 0; i < 3; i++) {
      numbers.add(i < parts.length ? int.tryParse(parts[i].trim()) ?? 0 : 0);
    }
    return numbers;
  }

  static final _idPattern = RegExp(r'^[a-z0-9]+(\.[a-z0-9-]+){2,}$');
  static final _versionPattern = RegExp(r'^\d+\.\d+\.\d+$');
  static final _entryPattern = RegExp(r'^[A-Za-z0-9_-]+\.js$');
  static final _domainPattern = RegExp(r'^(\*\.)?[a-z0-9-]+(\.[a-z0-9-]+)+$');
  static final _ipv4Pattern = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

  /// 按魔蚁的 Android 宽松口径校验，失败逐条指明是哪一条。
  /// 宽松点：integrity 扁平字符串接受、多文件不拒绝、域名清单先
  /// 归一化再验；其余照 iDuanJu `problems()`。
  List<String> problems() {
    final found = <String>[];
    if (!_idPattern.hasMatch(id)) {
      found.add('插件 id 不是合法的反向域名');
    }
    if (name.trim().isEmpty) {
      found.add('插件缺少名称');
    }
    if (!_versionPattern.hasMatch(version)) {
      found.add('插件版本不是合法的三段版本号');
    }
    if (!_entryPattern.hasMatch(entry)) {
      found.add('插件入口不是合法的 .js 文件名');
    }
    const knownTypes = {'video', 'shortdrama', 'comic', 'live'};
    if (!knownTypes.contains(type)) {
      found.add('插件类型未知（只支持 video / shortdrama / comic / live）');
    } else {
      final required = switch (type) {
        'video' || 'shortdrama' => const ['detail', 'play'],
        'comic' => const ['detail', 'pages'],
        'live' => const ['play'],
        _ => const <String>[],
      };
      for (final capability in required) {
        if (!capabilities.contains(capability)) {
          found.add('缺少 $capability 能力');
        }
      }
    }
    for (final domain in [...httpDomains, ...mediaDomains]) {
      // IP 字面量不是域名形态：原正则的数字段会放行 127.0.0.1 这类
      // 值，这里显式拒掉（与播放地址拒 IP 同口径）。
      if (!_domainPattern.hasMatch(domain) || _ipv4Pattern.hasMatch(domain)) {
        found.add('域名不合法：$domain（只支持 example.com 或 *.example.com 形态）');
      }
    }
    if (updateUrl.isNotEmpty) {
      final uri = Uri.tryParse(updateUrl);
      if (uri == null || uri.scheme != 'https') {
        found.add('update.url 必须是 https 地址');
      }
    }
    if (minAppVersion.isNotEmpty &&
        compareVersions(minAppVersion, idjHostSpecVersion) > 0) {
      found.add('minAppVersion $minAppVersion 高于本机支持的 $idjHostSpecVersion');
    }
    return found;
  }
}

/// 索引里的一条插件记录（轻量登记；manifest 本体不进 prefs）。
class IdjPluginIndexEntry {
  IdjPluginIndexEntry({
    required this.pluginId,
    required this.name,
    required this.version,
    required this.type,
    required this.adult,
    required this.enabled,
    required this.origin,
    required this.fileHash,
    required this.siteKey,
    required this.installedAt,
    this.failures = 0,
  });

  factory IdjPluginIndexEntry.fromJson(
    String pluginId,
    Map<String, dynamic> json,
  ) => IdjPluginIndexEntry(
    pluginId: pluginId,
    name: (json['name'] as Object?)?.toString() ?? '',
    version: (json['version'] as Object?)?.toString() ?? '',
    type: (json['type'] as Object?)?.toString() ?? '',
    adult: json['adult'] == true,
    enabled: json['enabled'] != false,
    origin: (json['origin'] as Object?)?.toString() ?? 'import',
    fileHash: (json['fileHash'] as Object?)?.toString() ?? '',
    siteKey: (json['siteKey'] as Object?)?.toString() ?? '',
    installedAt: json['installedAt'] is num
        ? (json['installedAt'] as num).toInt()
        : 0,
    failures: json['failures'] is num ? (json['failures'] as num).toInt() : 0,
  );

  final String pluginId;
  final String name;
  final String version;
  final String type;
  final bool adult;
  final bool enabled;
  final String origin;
  final String fileHash;
  final String siteKey;
  final int installedAt;
  final int failures;

  Map<String, dynamic> toJson() => {
    'name': name,
    'version': version,
    'type': type,
    'adult': adult,
    'enabled': enabled,
    'origin': origin,
    'fileHash': fileHash,
    'siteKey': siteKey,
    'installedAt': installedAt,
    'failures': failures,
  };

  IdjPluginIndexEntry copyWith({bool? enabled, int? failures}) =>
      IdjPluginIndexEntry(
        pluginId: pluginId,
        name: name,
        version: version,
        type: type,
        adult: adult,
        enabled: enabled ?? this.enabled,
        origin: origin,
        fileHash: fileHash,
        siteKey: siteKey,
        installedAt: installedAt,
        failures: failures ?? this.failures,
      );
}

/// 解析好的一个 `.idjplugin` 包（内存形态，写盘用原文）。
class IdjPluginBundle {
  IdjPluginBundle({
    required this.manifest,
    required this.script,
    required this.fileHash,
    required this.rawText,
  });

  final IdjPluginManifest manifest;
  final String script;
  final String fileHash;
  final String rawText;

  /// 入口脚本按 UTF-8 算 SHA-256 再 base64（打包脚本同款算法）。
  static String hashScript(String script) =>
      base64Encode(sha256.convert(utf8.encode(script)).bytes);
}

/// 已安装插件的列表视图（含包文件校验结果）。
class IdjInstalledPlugin {
  IdjInstalledPlugin({
    required this.entry,
    required this.manifest,
    required this.damaged,
    this.damageReason = '',
  });

  final IdjPluginIndexEntry entry;
  final IdjPluginManifest? manifest;
  final bool damaged;
  final String damageReason;
}

/// 更新时的权限差异：装更新免确认（用户口径），差异只作装完后的
/// 提示文案来源，不拦安装。
class IdjPermissionDiff {
  IdjPermissionDiff({
    required this.addedDomains,
    required this.addedCapabilities,
    required this.cloudflareEnabled,
    required this.loginEnabled,
    required this.storageEnabled,
    required this.adultBecameTrue,
    required this.minAppVersionRaised,
    required this.newMinAppVersion,
  });

  final List<String> addedDomains;
  final List<String> addedCapabilities;
  final bool cloudflareEnabled;
  final bool loginEnabled;
  final bool storageEnabled;
  final bool adultBecameTrue;
  final bool minAppVersionRaised;
  final String newMinAppVersion;

  bool get hasExpansion =>
      addedDomains.isNotEmpty ||
      cloudflareEnabled ||
      loginEnabled ||
      storageEnabled ||
      adultBecameTrue;

  bool get isEmpty =>
      !hasExpansion && addedCapabilities.isEmpty && !minAppVersionRaised;

  /// 差异项中文列表（给装后提示展示）。
  List<String> describe() => [
    if (addedDomains.isNotEmpty)
      '新版本多申请了 ${addedDomains.length} 个域名：${addedDomains.join('、')}',
    if (cloudflareEnabled) '新版本开启了 Cloudflare 验证',
    if (loginEnabled) '新版本开启了登录',
    if (storageEnabled) '新版本开启了存储',
    if (adultBecameTrue) '成人标记由否变是',
    if (addedCapabilities.isNotEmpty) '新增能力：${addedCapabilities.join('、')}',
    if (minAppVersionRaised) '最低宿主版本提高到 $newMinAppVersion',
  ];
}

/// 订阅里的一个插件条目：`manifest` 是相对订阅地址的包路径或内联
/// manifest（内联形态没有脚本地址，装不了、明确报错）。
class IdjSubscriptionPlugin {
  IdjSubscriptionPlugin({
    required this.id,
    required this.name,
    required this.version,
    required this.type,
    required this.adult,
    required this.description,
    required this.manifestUrl,
    this.manifest,
  });

  final String id;
  final String name;
  final String version;
  final String type;
  final bool adult;
  final String description;
  final String manifestUrl;
  final Map<String, dynamic>? manifest;
}

/// 订阅里的一个 CMS 采集站条目：只展示（名 + adult 标记），不接线；
/// api 地址不在界面显示（与远程地址不显示口径一致）。
class IdjSubscriptionCms {
  IdjSubscriptionCms({required this.name, required this.api, required this.adult});

  final String name;
  final String api;
  final bool adult;
}

class IdjSubscription {
  IdjSubscription({
    required this.url,
    required this.name,
    required this.plugins,
    required this.cms,
    this.error = '',
  });

  final String url;
  final String name;
  final List<IdjSubscriptionPlugin> plugins;
  final List<IdjSubscriptionCms> cms;
  final String error;

  bool get isBuiltIn => idjIsBuiltInSubscription(url);

  /// 界面显示名：内置订阅只给固定名；用户订阅给订阅自带名，
  /// 都不露地址原文。
  String get displayName {
    if (isBuiltIn) return idjBuiltInSubscriptionLabel;
    return name.isEmpty ? '远程插件源' : name;
  }

  IdjSubscription withError(String value) => IdjSubscription(
    url: url,
    name: name,
    plugins: plugins,
    cms: cms,
    error: value,
  );
}

/// 有 update.url 且拉到新版的插件。
class IdjUpdateCandidate {
  IdjUpdateCandidate({
    required this.pluginId,
    required this.currentVersion,
    required this.latestVersion,
    required this.manifest,
  });

  final String pluginId;
  final String currentVersion;
  final String latestVersion;
  final IdjPluginManifest manifest;
}

enum IdjInterpretKind { bundle, subscription, m3u, tvbox, unsupported }

/// `interpret` 的分流结果：粘贴文本或链接统一分流后的安装动作。
class IdjInterpretResult {
  IdjInterpretResult({
    required this.kind,
    required this.message,
    this.bundleText,
    this.subscription,
  });

  final IdjInterpretKind kind;
  final String message;
  final String? bundleText;
  final IdjSubscription? subscription;
}

class IdjPluginStore {
  IdjPluginStore({
    SharedPreferences? preferences,
    Directory? rootDir,
    Directory? supportDir,
    IdjProbeFn? probe,
    HttpClient Function()? httpFactory,
    Future<void> Function(Uri uri)? uriValidator,
  }) : _preferencesOverride = preferences,
       _rootOverride = rootDir,
       _supportOverride = supportDir,
       _probeOverride = probe,
       _httpClientFactory = httpFactory,
       _downloadUriValidator = uriValidator;

  /// 生产环境的 probe 接线（`main.dart` 里接到 QuickJS 运行时探针）。
  /// 单元测试直接传构造参数的 `probe`，不走这个静态回调。
  static IdjProbeFn? probeHandler;

  /// 装 / 卸 / 启停后通知登记侧对账（`main.dart` 里接到
  /// `SourceRegistry.syncIdjPluginSites`）。未接线时只改索引与包文件，
  /// 调用方（插件区界面）自己刷新列表。
  static void Function()? onInstalledChanged;

  /// 站 key 占用判定（算 `idj_<末段>` 撞名时用）：`main.dart` 接到
  /// 登记表（自定义站 id + 短剧站 id）。未接线时只查插件索引自身。
  static bool Function(String siteKey)? siteKeyTaken;

  final SharedPreferences? _preferencesOverride;
  final Directory? _rootOverride;
  final Directory? _supportOverride;
  final IdjProbeFn? _probeOverride;
  final HttpClient Function()? _httpClientFactory;
  final Future<void> Function(Uri uri)? _downloadUriValidator;

  /// 装 / 卸串行链：同一插件的包目录与索引不许并发改——市场
  /// 区段可能因弹窗对账重挂载而跑两轮自动更新，用户手点安装
  /// 也可能与自动更新撞上；并发写包会踩同一个 staging 目录
  /// （实测 PathNotFound）。所有改包/改索引的操作排队逐个来。
  Future<void> _mutationTail = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _mutationTail.then((_) => action());
    _mutationTail = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// 订阅内容只缓存在内存里：重拉失败留旧列表、只记 error。
  final Map<String, IdjSubscription> _subscriptionCache = {};

  Future<SharedPreferences> _preferences() async =>
      _preferencesOverride ?? await SharedPreferences.getInstance();

  /// 插件包根目录：`documents/idj_plugins`。
  Future<Directory> get root async {
    final override = _rootOverride;
    if (override != null) return override;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'idj_plugins'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 运行态根目录：`support/idj/<pluginId>/storage.json`（运行时写，
  /// Dart 侧只在卸载清除 / 清数据时碰）。
  Future<Directory> get supportRoot async {
    final override = _supportOverride;
    if (override != null) return override;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'idj'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 某插件的运行态目录（storage 落点，运行时与清数据共用）。
  Future<Directory> runtimeDir(String pluginId) async {
    final base = await supportRoot;
    return Directory(p.join(base.path, _safeDirName(pluginId)));
  }

  String _safeDirName(String pluginId) =>
      pluginId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  /// 站 key = `idj_` + manifest.id 末段；末段冲突加 `_2` / `_3`。
  /// 占用判定先查插件索引自身，再查 [siteKeyTaken] 接线（登记表）。
  Future<String> siteKeyForPluginId(String pluginId) async {
    final short = pluginId.split('.').last;
    final base = 'idj_$short';
    final index = await readIndex();
    final takenByPlugins = {
      for (final entry in index.values)
        if (entry.pluginId != pluginId) entry.siteKey,
    };
    var candidate = base;
    var suffix = 2;
    while (takenByPlugins.contains(candidate) ||
        (siteKeyTaken?.call(candidate) ?? false)) {
      candidate = '${base}_$suffix';
      suffix++;
    }
    return candidate;
  }

  // ---------- 索引 ----------

  Future<Map<String, IdjPluginIndexEntry>> readIndex() async {
    final prefs = await _preferences();
    final raw = prefs.getString(idjPluginsPrefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final entries = <String, IdjPluginIndexEntry>{};
      for (final item in decoded.entries) {
        if (item.value is! Map) continue;
        entries[item.key] = IdjPluginIndexEntry.fromJson(
          item.key,
          Map<String, dynamic>.from(item.value as Map),
        );
      }
      return entries;
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeIndex(Map<String, IdjPluginIndexEntry> entries) async {
    final prefs = await _preferences();
    final encoded = jsonEncode({
      for (final entry in entries.entries) entry.key: entry.value.toJson(),
    });
    await prefs.setString(idjPluginsPrefsKey, encoded);
  }

  // ---------- 解析与校验 ----------

  /// 解析 `.idjplugin` 包文本：JSON 结构 → manifest 校验 →
  /// 入口脚本存在 → integrity 核对。失败抛中文 [IdjPluginFailure]，
  /// 逐条指明是哪一步、哪一条。
  static IdjPluginBundle parseBundleText(String text) {
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw IdjPluginFailure('不是合法的 .idjplugin（缺少 manifest 或入口脚本）');
    }
    if (decoded is! Map) {
      throw IdjPluginFailure('不是合法的 .idjplugin（缺少 manifest 或入口脚本）');
    }
    final bundleJson = Map<String, dynamic>.from(decoded);
    final manifestJson = bundleJson['manifest'];
    final filesJson = bundleJson['files'];
    if (manifestJson is! Map || filesJson is! Map) {
      throw IdjPluginFailure('不是合法的 .idjplugin（缺少 manifest 或入口脚本）');
    }
    final manifest = IdjPluginManifest.fromJson(
      Map<String, dynamic>.from(manifestJson),
    );
    final problems = manifest.problems();
    if (problems.isNotEmpty) {
      throw IdjPluginFailure('manifest 校验失败：${problems.join('；')}');
    }
    final files = Map<String, dynamic>.from(filesJson);
    final script = files[manifest.entry];
    if (script is! String || script.isEmpty) {
      throw IdjPluginFailure('不是合法的 .idjplugin（缺少 manifest 或入口脚本）');
    }
    final fileHash = IdjPluginBundle.hashScript(script);
    _verifyIntegrity(manifest, fileHash);
    return IdjPluginBundle(
      manifest: manifest,
      script: script,
      fileHash: fileHash,
      rawText: text,
    );
  }

  /// integrity 核对：两种形态都接受，去掉 `sha256-` 前缀后与算出的
  /// 值逐字节比对；不符拒装。不写 integrity 时不校验。
  /// 签名口径（与魔蚁一致）：只认包不认签名——`integrity.signature`
  /// 当它不存在，不验、不拒、不提示；带签名块的包照常安装。
  static void _verifyIntegrity(IdjPluginManifest manifest, String fileHash) {
    final expected = manifest.integrityValue();
    if (expected == null || expected.isEmpty) return;
    final stripped = expected.startsWith('sha256-')
        ? expected.substring('sha256-'.length)
        : expected;
    if (stripped != fileHash) {
      throw IdjPluginFailure(
        '完整性校验失败：文件哈希与 manifest 不一致，已拒绝安装（插件 ${manifest.id}）',
      );
    }
  }

  // ---------- probe ----------

  /// probe 试加载：运行时加载入口脚本 → 若导出 `init` 则调一次 →
  /// 检查 `export default` 是否齐 manifest.capabilities 声明的能力
  /// 函数（缺失由运行时报错、写明缺哪个）。超时 20 秒。
  /// probe 失败不装。未接线时明确报错，不静默跳过。
  Future<void> probeBundle(IdjPluginBundle bundle, {IdjProbeFn? probe}) async {
    final probeFn = probe ?? _probeOverride ?? probeHandler;
    if (probeFn == null) {
      throw IdjPluginFailure('试加载失败：插件宿主未就绪，请重启应用后再试');
    }
    try {
      await probeFn(
        pluginId: bundle.manifest.id,
        script: bundle.script,
        manifest: bundle.manifest.raw,
      ).timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw IdjPluginFailure('试加载失败：插件初始化超时（20 秒）'),
      );
    } on IdjPluginFailure {
      rethrow;
    } catch (error) {
      // 底层异常原文（多为英文）只进日志，界面给中文人话。
      debugPrint('idj probe 失败（${bundle.manifest.id}）：$error');
      throw IdjPluginFailure('试加载失败：插件初始化没能完成，请稍后重试');
    }
  }

  // ---------- 写盘与安装 ----------

  /// 安装链：解析 → 校验 → integrity → probe → 写盘 + 索引 →
  /// 通知登记侧对账。免确认口径（用户令）：点安装直接装到底，
  /// 更新时权限有扩大也不拦路要确认——差异只供界面在装完后顺带
  /// 提示一句（见 [permissionDiff]），不作安装门槛。
  /// 安装失败不留半成品：staging 删除、索引不写、站点不登记。
  Future<IdjInstalledPlugin> installBundleText(
    String text, {
    IdjProbeFn? probe,
  }) => _serialized(() => _installBundleText(text, probe: probe));

  /// 安装链兜底包装：链上任何一步（读索引、算站 key 的外部接线
  /// 回调、写索引、清已卸载记录、装后通知回调等）漏出的未包装
  /// 原始异常 / StateError 一律在这里收成中文 [IdjPluginFailure]，
  /// 原文只进日志——安装失败的口径恒为「抛中文原因」，不许把
  /// 英文异常原文甚至进程级崩溃漏给界面。既有步骤自己抛的
  /// [IdjPluginFailure] 原样透传，不改任何既有行为口径。
  Future<IdjInstalledPlugin> _installBundleText(
    String text, {
    IdjProbeFn? probe,
  }) async {
    try {
      return await _installBundleTextInner(text, probe: probe);
    } on IdjPluginFailure {
      rethrow;
    } catch (error) {
      debugPrint('idj 安装失败（未包装异常兜底）：$error');
      throw IdjPluginFailure('安装失败：插件没能装上，请稍后重试');
    }
  }

  Future<IdjInstalledPlugin> _installBundleTextInner(
    String text, {
    IdjProbeFn? probe,
  }) async {
    final bundle = parseBundleText(text);
    final manifest = bundle.manifest;
    final index = await readIndex();
    final existing = index[manifest.id];
    final siteKey =
        existing?.siteKey ?? await siteKeyForPluginId(manifest.id);
    await probeBundle(bundle, probe: probe);
    await _writeBundle(manifest.id, text);
    final entry = IdjPluginIndexEntry(
      pluginId: manifest.id,
      name: manifest.name,
      version: manifest.version,
      type: manifest.type,
      adult: manifest.adult,
      // 同 id 覆盖安装保留原 enabled 状态，新装默认启用。
      enabled: existing?.enabled ?? true,
      origin: 'import',
      fileHash: bundle.fileHash,
      siteKey: siteKey,
      installedAt:
          existing?.installedAt ?? DateTime.now().millisecondsSinceEpoch,
      failures: 0,
    );
    index[manifest.id] = entry;
    await _writeIndex(index);
    // 装回（含首次安装）清掉该插件的「已卸载」记录：四态回到
    // 「已装」，下次卸载按新版本重新记（见 uninstall）。
    await _clearUninstalledRecord(manifest.id);
    onInstalledChanged?.call();
    return IdjInstalledPlugin(entry: entry, manifest: manifest, damaged: false);
  }

  Future<IdjInstalledPlugin> installBundleBytes(
    List<int> bytes, {
    IdjProbeFn? probe,
  }) async {
    String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      throw IdjPluginFailure('不是合法的 .idjplugin（缺少 manifest 或入口脚本）');
    }
    return installBundleText(text, probe: probe);
  }

  /// 写盘：先写 `.staging-<pluginId>/bundle.idjplugin`，写完重算
  /// 哈希通过后再原子改名成目标目录；失败清掉 staging，不留半成品。
  Future<void> _writeBundle(String pluginId, String rawText) async {
    final base = await root;
    final safeId = _safeDirName(pluginId);
    final staging = Directory(p.join(base.path, '.staging-$safeId'));
    final target = Directory(p.join(base.path, safeId));
    try {
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
      await staging.create(recursive: true);
      final file = File(p.join(staging.path, 'bundle.idjplugin'));
      await file.writeAsString(rawText, flush: true);
      final written = await file.readAsString();
      final bundle = parseBundleText(written);
      if (bundle.fileHash.isEmpty) {
        throw IdjPluginFailure('安装失败：写入失败（存储空间不足？）');
      }
      if (await target.exists()) {
        await target.delete(recursive: true);
      }
      await staging.rename(target.path);
    } catch (error) {
      if (await staging.exists()) {
        try {
          await staging.delete(recursive: true);
        } catch (_) {}
      }
      if (error is IdjPluginFailure) rethrow;
      // 文件系统异常原文（多为英文）只进日志，界面给中文人话。
      debugPrint('idj 写包失败（$pluginId）：$error');
      throw IdjPluginFailure('安装失败：写入失败（存储空间不足？）');
    }
  }

  /// 读已安装插件的包文件（唯一事实来源）。缺失 / 损坏回 null。
  Future<IdjPluginBundle?> readBundle(String pluginId) async {
    final base = await root;
    final file = File(
      p.join(base.path, _safeDirName(pluginId), 'bundle.idjplugin'),
    );
    if (!await file.exists()) return null;
    try {
      final text = await file.readAsString();
      return parseBundleText(text);
    } catch (_) {
      return null;
    }
  }

  Future<IdjPluginManifest?> readInstalledManifest(String pluginId) async {
    final bundle = await readBundle(pluginId);
    return bundle?.manifest;
  }

  /// 已安装列表：读索引 + 逐个校验包文件存在且哈希未变；
  /// 包文件缺失 / 损坏的条目标记损坏，不拦启动、不拦列表。
  Future<List<IdjInstalledPlugin>> listInstalled() async {
    final index = await readIndex();
    final items = <IdjInstalledPlugin>[];
    for (final entry in index.values) {
      final base = await root;
      final file = File(
        p.join(base.path, _safeDirName(entry.pluginId), 'bundle.idjplugin'),
      );
      if (!await file.exists()) {
        items.add(
          IdjInstalledPlugin(
            entry: entry,
            manifest: null,
            damaged: true,
            damageReason: '包文件缺失',
          ),
        );
        continue;
      }
      try {
        final text = await file.readAsString();
        final bundle = parseBundleText(text);
        if (bundle.fileHash != entry.fileHash) {
          items.add(
            IdjInstalledPlugin(
              entry: entry,
              manifest: bundle.manifest,
              damaged: true,
              damageReason: '包文件已被改动（哈希不一致）',
            ),
          );
          continue;
        }
        items.add(
          IdjInstalledPlugin(
            entry: entry,
            manifest: bundle.manifest,
            damaged: false,
          ),
        );
      } catch (_) {
        items.add(
          IdjInstalledPlugin(
            entry: entry,
            manifest: null,
            damaged: true,
            damageReason: '包文件损坏',
          ),
        );
      }
    }
    items.sort((a, b) => a.entry.name.compareTo(b.entry.name));
    return items;
  }

  // ---------- 卸载 / 启用 / 停用 / 清数据 ----------

  /// 卸载：删包目录、清索引条目、通知登记侧摘站，并留一条
  /// 「已卸载」记录（pluginId + 卸载时的版本，持久化）：市场里
  /// 该条目自此隐藏，直到远程版本高于记录版本才重新出现。
  /// 运行态数据（storage.json）默认保留（重装回来状态还在），
  /// [clearData] 为真才连运行态目录一起删。
  Future<void> uninstall(String pluginId, {bool clearData = false}) =>
      _serialized(() => _uninstall(pluginId, clearData: clearData));

  Future<void> _uninstall(String pluginId, {bool clearData = false}) async {
    final index = await readIndex();
    final entry = index[pluginId];
    if (entry == null) {
      throw IdjPluginFailure('未安装该插件');
    }
    index.remove(pluginId);
    await _writeIndex(index);
    final base = await root;
    final dir = Directory(p.join(base.path, _safeDirName(pluginId)));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    if (clearData) {
      await _deleteRuntimeDir(pluginId);
    }
    await _recordUninstalled(pluginId, entry.version);
    onInstalledChanged?.call();
  }

  // ---------- 已卸载记录（市场四态） ----------

  /// 读「已卸载」记录：pluginId → 卸载时的版本号。市场渲染判
  /// 四态用（见 [marketEntryHiddenAfterUninstall]）。
  Future<Map<String, String>> readUninstalledVersions() async {
    final prefs = await _preferences();
    final raw = prefs.getString(idjUninstalledPrefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final item in decoded.entries)
          item.key: (item.value as Object?)?.toString() ?? '',
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeUninstalledVersions(Map<String, String> records) async {
    final prefs = await _preferences();
    await prefs.setString(idjUninstalledPrefsKey, jsonEncode(records));
  }

  Future<void> _recordUninstalled(String pluginId, String version) async {
    final records = await readUninstalledVersions();
    if (records[pluginId] == version) return;
    records[pluginId] = version;
    await _writeUninstalledVersions(records);
  }

  Future<void> _clearUninstalledRecord(String pluginId) async {
    final records = await readUninstalledVersions();
    if (!records.containsKey(pluginId)) return;
    records.remove(pluginId);
    await _writeUninstalledVersions(records);
  }

  /// 市场条目四态里的「已卸载隐藏」判定：有已卸载记录、且远程
  /// 版本不高于卸载时版本 → 整条不显示；远程版本更高 → 回到
  /// 可安装显示（「已卸载待更新」态）。已装条目不走本判定
  /// （装回时记录已清，见 [installBundleText]）。
  static bool marketEntryHiddenAfterUninstall({
    required String remoteVersion,
    required String? uninstalledVersion,
  }) {
    if (uninstalledVersion == null) return false;
    return IdjPluginManifest.compareVersions(remoteVersion, uninstalledVersion) <=
        0;
  }

  /// 启用 / 停用：只改索引 `enabled` + 通知登记侧，不动包文件与
  /// 运行态。启用时计数清零；停用后该站从站点列表消失，重启用
  /// 立即回来，不用重装。
  Future<IdjPluginIndexEntry> setEnabled(String pluginId, bool enabled) async {
    final index = await readIndex();
    final entry = index[pluginId];
    if (entry == null) {
      throw IdjPluginFailure('未安装该插件');
    }
    if (enabled) {
      final bundle = await readBundle(pluginId);
      if (bundle == null) {
        throw IdjPluginFailure('插件包文件已损坏，请重新安装');
      }
      final updated = entry.copyWith(enabled: true, failures: 0);
      index[pluginId] = updated;
      await _writeIndex(index);
      onInstalledChanged?.call();
      return updated;
    }
    final updated = entry.copyWith(enabled: false);
    index[pluginId] = updated;
    await _writeIndex(index);
    onInstalledChanged?.call();
    return updated;
  }

  /// 清数据：只删运行态 `storage.json`，不卸载插件。
  Future<void> clearData(String pluginId) async {
    final dir = await runtimeDir(pluginId);
    final file = File(p.join(dir.path, 'storage.json'));
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> _deleteRuntimeDir(String pluginId) async {
    final dir = await runtimeDir(pluginId);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  // ---------- 看门狗 ----------

  /// 看门狗：连续 3 次非瞬时失败自动停用。网络/环境类错误不计数
  /// （出口、站方、限流问题不是插件坏了，一次断网不许把插件悄悄
  /// 停用）；只有插件/站点本身的错误（解析、空数据、404 等）才计数。
  static const _transientFailureCodes = {
    'E_NET',
    'E_NETWORK',
    'E_TIMEOUT',
    'E_CF_REQUIRED',
    'E_DNS',
    'E_RATE_LIMIT',
    'E_BLOCKED',
    'E_AUTH',
  };

  static bool isTransientFailureCode(String code) =>
      _transientFailureCodes.contains(code);

  Future<void> recordFailure(String pluginId, {String code = ''}) async {
    if (_transientFailureCodes.contains(code)) return;
    final index = await readIndex();
    final entry = index[pluginId];
    if (entry == null) return;
    final failures = entry.failures + 1;
    index[pluginId] = entry.copyWith(failures: failures);
    await _writeIndex(index);
    if (failures >= 3 && entry.enabled) {
      index[pluginId] = entry.copyWith(enabled: false, failures: failures);
      await _writeIndex(index);
      onInstalledChanged?.call();
      debugPrint('idj 看门狗：插件 $pluginId 连续失败 $failures 次，已自动停用');
    }
  }

  Future<void> recordSuccess(String pluginId) async {
    final index = await readIndex();
    final entry = index[pluginId];
    if (entry == null || entry.failures == 0) return;
    index[pluginId] = entry.copyWith(failures: 0);
    await _writeIndex(index);
  }

  // ---------- 安装摘要与 PermissionDiff ----------

  /// 更新时算 PermissionDiff：多了域名、开了 CF / 登录 / 存储、
  /// adult 由 false 变 true——免确认口径下只作装后提示，不拦安装。
  static IdjPermissionDiff permissionDiff(
    IdjPluginManifest oldManifest,
    IdjPluginManifest newManifest,
  ) {
    final oldDomains = {
      ...oldManifest.httpDomains,
      ...oldManifest.mediaDomains,
    };
    final newDomains = {
      ...newManifest.httpDomains,
      ...newManifest.mediaDomains,
    };
    final addedDomains = newDomains.difference(oldDomains).toList()..sort();
    final addedCapabilities = newManifest.capabilities
        .where((capability) => !oldManifest.capabilities.contains(capability))
        .toList();
    return IdjPermissionDiff(
      addedDomains: addedDomains,
      addedCapabilities: addedCapabilities,
      cloudflareEnabled: !oldManifest.cloudflare && newManifest.cloudflare,
      loginEnabled: !oldManifest.loginPermission && newManifest.loginPermission,
      storageEnabled:
          !oldManifest.storagePermission && newManifest.storagePermission,
      adultBecameTrue: !oldManifest.adult && newManifest.adult,
      minAppVersionRaised:
          IdjPluginManifest.compareVersions(
            newManifest.minAppVersion,
            oldManifest.minAppVersion,
          ) >
          0,
      newMinAppVersion: newManifest.minAppVersion,
    );
  }

  // ---------- 输入解释器 interpret ----------

  /// 输入解释器：粘贴文本或链接统一分流。M3U 报“请走直播导入”
  /// 不走安装器；TVBox JSON 拒绝；含 `plugins` / `cms` 的走订阅
  /// 流程；含 `manifest` + `files` 的走安装链；含 `schema` 的单个
  /// manifest 按 entry 从同目录下载脚本拼成包再走安装链；
  /// http(s) 链接先下载正文再按内容分流。
  Future<IdjInterpretResult> interpret(String input, {Uri? baseUri}) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return IdjInterpretResult(
        kind: IdjInterpretKind.unsupported,
        message: '这个链接不是插件 manifest / .idjplugin / 订阅列表 / M3U',
      );
    }
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      final uri = Uri.tryParse(trimmed);
      if (uri == null) {
        return IdjInterpretResult(
          kind: IdjInterpretKind.unsupported,
          message: '这个链接不是插件 manifest / .idjplugin / 订阅列表 / M3U',
        );
      }
      late final String text;
      try {
        text = await downloadText(uri, maxBytes: 2 * 1024 * 1024);
      } on IdjPluginFailure catch (error) {
        return IdjInterpretResult(
          kind: IdjInterpretKind.unsupported,
          message: error.message,
        );
      }
      return interpretText(text, baseUri: uri);
    }
    return interpretText(trimmed, baseUri: baseUri);
  }

  /// 文本分流（`interpret` 的内容分支，可单独测，不联网）。
  Future<IdjInterpretResult> interpretText(String text, {Uri? baseUri}) async {
    final trimmed = text.trim();
    if (trimmed.startsWith('#EXTM3U')) {
      return IdjInterpretResult(
        kind: IdjInterpretKind.m3u,
        message: '这是 M3U 频道列表，请走直播导入',
      );
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      return IdjInterpretResult(
        kind: IdjInterpretKind.unsupported,
        message: '这个链接不是插件 manifest / .idjplugin / 订阅列表 / M3U',
      );
    }
    if (decoded is! Map) {
      return IdjInterpretResult(
        kind: IdjInterpretKind.unsupported,
        message: '这个链接不是插件 manifest / .idjplugin / 订阅列表 / M3U',
      );
    }
    final json = Map<String, dynamic>.from(decoded);
    if (json.containsKey('sites') ||
        json.containsKey('spider') ||
        json.containsKey('lives')) {
      return IdjInterpretResult(
        kind: IdjInterpretKind.tvbox,
        message: '这是 TVBox 配置，不是 idj1 插件；不支持直接运行 JAR / CatVod / Python 源',
      );
    }
    if (json.containsKey('plugins') || json.containsKey('cms')) {
      final subscription = parseSubscriptionJson(
        json,
        baseUri ?? Uri.parse('https://localhost/'),
      );
      return IdjInterpretResult(
        kind: IdjInterpretKind.subscription,
        message: '订阅：${subscription.name}',
        subscription: subscription,
      );
    }
    if (json.containsKey('manifest') && json.containsKey('files')) {
      return IdjInterpretResult(
        kind: IdjInterpretKind.bundle,
        message: '插件包',
        bundleText: trimmed,
      );
    }
    if (json.containsKey('schema')) {
      // 裸 manifest：按 entry 从同目录下载脚本，拼成包再走安装链。
      if (baseUri == null) {
        return IdjInterpretResult(
          kind: IdjInterpretKind.unsupported,
          message: '这是单个 manifest，缺少入口脚本地址，请用链接安装或直接粘贴 .idjplugin 包',
        );
      }
      final manifest = IdjPluginManifest.fromJson(json);
      if (manifest.entry.isEmpty) {
        return IdjInterpretResult(
          kind: IdjInterpretKind.unsupported,
          message: '不是合法的 .idjplugin（缺少 manifest 或入口脚本）',
        );
      }
      final scriptUri = baseUri.resolve(manifest.entry);
      late final String script;
      try {
        script = await downloadText(scriptUri, maxBytes: 2 * 1024 * 1024);
      } on IdjPluginFailure catch (error) {
        return IdjInterpretResult(
          kind: IdjInterpretKind.unsupported,
          message: error.message,
        );
      }
      final bundleText = jsonEncode({
        'manifest': json,
        'files': {manifest.entry: script},
      });
      return IdjInterpretResult(
        kind: IdjInterpretKind.bundle,
        message: '插件包',
        bundleText: bundleText,
      );
    }
    return IdjInterpretResult(
      kind: IdjInterpretKind.unsupported,
      message: '这个链接不是插件 manifest / .idjplugin / 订阅列表 / M3U',
    );
  }

  // ---------- 下载器 ----------

  /// 下载器：只接受无凭证 HTTPS 公网域名、443 端口、非 IP 字面量；
  /// 不自动跟随跳转（手动最多 6 跳，每跳重验规则）；请求 20 秒、
  /// 资源 30 秒超时；解析到本机 / 内网直接拒绝；
  /// UA 是 `Xiuxian/<App 真实版本> plugin-installer`；
  /// 单文件上限由 [maxBytes] 定（订阅 1MB、链接识别 2MB、插件包 2MB）。
  Future<String> downloadText(Uri uri, {required int maxBytes}) async {
    final bytes = await _downloadBytes(uri, maxBytes: maxBytes);
    try {
      return utf8.decode(bytes);
    } catch (_) {
      throw IdjPluginFailure('下载失败：内容不是合法文本');
    }
  }

  Future<List<int>> _downloadBytes(Uri uri, {required int maxBytes}) async {
    var current = uri;
    final client = (_httpClientFactory ?? HttpClient.new)();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      for (var hop = 0; hop <= 6; hop++) {
        await _validateDownloadUri(current);
        final request = await client.getUrl(current);
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'Xiuxian/$idjInstallerAppVersion plugin-installer',
        );
        final response = await request.close().timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw IdjPluginFailure('下载超时（20 秒）'),
        );
        final location = response.headers.value(HttpHeaders.locationHeader);
        if ((response.statusCode == 301 ||
                response.statusCode == 302 ||
                response.statusCode == 303 ||
                response.statusCode == 307 ||
                response.statusCode == 308) &&
            location != null &&
            location.isNotEmpty) {
          if (hop == 6) {
            throw IdjPluginFailure('下载失败：跳转次数过多');
          }
          current = current.resolve(location);
          await response.drain<void>();
          continue;
        }
        if (response.statusCode != 200) {
          await response.drain<void>();
          throw IdjPluginFailure('下载失败：HTTP ${response.statusCode}');
        }
        final bytes = <int>[];
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
          onTimeout: (_) => throw IdjPluginFailure('下载超时（30 秒）'),
        )) {
          bytes.addAll(chunk);
          if (bytes.length > maxBytes) {
            throw IdjPluginFailure('下载失败：文件超过上限');
          }
        }
        return bytes;
      }
      throw IdjPluginFailure('下载失败：跳转次数过多');
    } on IdjPluginFailure {
      rethrow;
    } catch (error) {
      // 底层网络异常原文（多为英文）只进日志，界面给中文人话。
      debugPrint('idj 下载失败（$current）：$error');
      throw IdjPluginFailure('下载失败：网络连接不通或对方无响应，请检查网络后重试');
    } finally {
      client.close(force: true);
    }
  }

  /// 每跳重验：https、无凭证、443 端口、非 IP 字面量、非本机 / 内网。
  /// 测试可经构造参数 `uriValidator` 整体替换（假客户端
  /// 没有真 DNS）；生产默认走这里。
  Future<void> _validateDownloadUri(Uri uri) async {
    final override = _downloadUriValidator;
    if (override != null) {
      await override(uri);
      return;
    }
    if (uri.scheme != 'https') {
      throw IdjPluginFailure('这个地址不是合法的插件下载地址（只支持 HTTPS 公网地址）');
    }
    if (uri.userInfo.isNotEmpty) {
      throw IdjPluginFailure('这个地址不是合法的插件下载地址（只支持 HTTPS 公网地址）');
    }
    if (uri.hasPort && uri.port != 443) {
      throw IdjPluginFailure('这个地址不是合法的插件下载地址（只支持 HTTPS 公网地址）');
    }
    final host = uri.host.toLowerCase();
    if (host.isEmpty ||
        host == 'localhost' ||
        host.endsWith('.local') ||
        RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host) ||
        host.contains(':')) {
      throw IdjPluginFailure('这个地址不是合法的插件下载地址（只支持 HTTPS 公网地址）');
    }
    List<InternetAddress> addresses;
    try {
      addresses = await InternetAddress.lookup(host);
    } catch (_) {
      throw IdjPluginFailure('下载失败：域名无法解析');
    }
    for (final address in addresses) {
      if (_isPrivateOrLoopback(address)) {
        throw IdjPluginFailure('这个地址不是合法的插件下载地址（只支持 HTTPS 公网地址）');
      }
    }
  }

  static bool _isPrivateOrLoopback(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal) return true;
    if (address.type == InternetAddressType.IPv4) {
      final raw = address.rawAddress;
      if (raw.length == 4) {
        if (raw[0] == 10) return true;
        if (raw[0] == 172 && raw[1] >= 16 && raw[1] <= 31) return true;
        if (raw[0] == 192 && raw[1] == 168) return true;
      }
      return false;
    }
    // IPv6：fc00::/7（唯一本地）与 fe80::/10（链路本地）拒绝。
    final raw = address.rawAddress;
    if (raw.isNotEmpty && (raw[0] & 0xfe) == 0xfc) return true;
    if (raw.length >= 2 && raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) {
      return true;
    }
    return false;
  }

  // ---------- 订阅 ----------

  /// 解析订阅 JSON：`{"name", "plugins": [...], "cms": [...]}`。
  /// `manifest` 可以是相对订阅地址的路径（Uri.resolve 解析，
  /// 失败的条目跳过记日志）；订阅里的插件不自动安装，只展示、
  /// 逐个点安装。
  static IdjSubscription parseSubscriptionJson(
    Map<String, dynamic> json,
    Uri baseUri,
  ) {
    final plugins = <IdjSubscriptionPlugin>[];
    for (final row in json['plugins'] as List? ?? const []) {
      if (row is! Map) continue;
      final parsed = Map<String, dynamic>.from(row);
      final manifestRaw = parsed['manifest'];
      String manifestUrl = '';
      Map<String, dynamic>? manifest;
      if (manifestRaw is String && manifestRaw.isNotEmpty) {
        try {
          manifestUrl = baseUri.resolve(manifestRaw).toString();
        } catch (error) {
          debugPrint('idj 订阅：插件 manifest 地址解析失败，已跳过：$error');
          continue;
        }
      } else if (manifestRaw is Map) {
        manifest = Map<String, dynamic>.from(manifestRaw);
      }
      plugins.add(
        IdjSubscriptionPlugin(
          id: (parsed['id'] as Object?)?.toString() ?? '',
          name: (parsed['name'] as Object?)?.toString() ?? '',
          version: (parsed['version'] as Object?)?.toString() ?? '',
          type: (parsed['type'] as Object?)?.toString() ?? '',
          adult: parsed['adult'] == true,
          description: (parsed['description'] as Object?)?.toString() ?? '',
          manifestUrl: manifestUrl,
          manifest: manifest,
        ),
      );
    }
    final cms = <IdjSubscriptionCms>[
      for (final row in json['cms'] as List? ?? const [])
        if (row is Map)
          IdjSubscriptionCms(
            name:
                (Map<String, dynamic>.from(row)['name'] as Object?)
                    ?.toString() ??
                '',
            api:
                (Map<String, dynamic>.from(row)['api'] as Object?)
                    ?.toString() ??
                '',
            adult: Map<String, dynamic>.from(row)['adult'] == true,
          ),
    ];
    return IdjSubscription(
      url: baseUri.toString(),
      name: (json['name'] as Object?)?.toString() ?? '',
      plugins: plugins,
      cms: cms,
    );
  }

  Future<List<String>> _subscriptionUrls() async {
    final prefs = await _preferences();
    return prefs.getStringList(idjSubscriptionsPrefsKey) ?? const [];
  }

  Future<void> _saveSubscriptionUrls(List<String> urls) async {
    final prefs = await _preferences();
    await prefs.setStringList(idjSubscriptionsPrefsKey, urls);
  }

  /// 订阅内容不持久化：每次打开插件区时重拉；失败只记 error 不丢
  /// 旧列表。内置远程索引永远排第一（用户自己又贴了同一地址也
  /// 不重复拉）。
  Future<List<IdjSubscription>> loadSubscriptions() async {
    final userUrls = await _subscriptionUrls();
    final urls = <String>[
      idjBuiltInSubscriptionUrl,
      for (final url in userUrls)
        if (url != idjBuiltInSubscriptionUrl) url,
    ];
    final result = <IdjSubscription>[];
    for (final url in urls) {
      final uri = Uri.tryParse(url);
      if (uri == null) continue;
      try {
        final text = await downloadText(uri, maxBytes: 1024 * 1024);
        final decoded = jsonDecode(text);
        if (decoded is! Map) {
          throw IdjPluginFailure('订阅内容不是合法 JSON');
        }
        final subscription = parseSubscriptionJson(
          Map<String, dynamic>.from(decoded),
          uri,
        );
        _subscriptionCache[url] = subscription;
        result.add(subscription);
      } catch (error) {
        final cached = _subscriptionCache[url];
        if (cached != null) {
          final failed = cached.withError(error.toString());
          _subscriptionCache[url] = failed;
          result.add(failed);
        } else {
          final failed = IdjSubscription(
            url: url,
            name: '',
            plugins: const [],
            cms: const [],
            error: error.toString(),
          );
          _subscriptionCache[url] = failed;
          result.add(failed);
        }
      }
    }
    return result;
  }

  /// 逐个重拉（与 [loadSubscriptions] 同款：失败留旧列表记 error）。
  Future<List<IdjSubscription>> refreshSubscriptions() => loadSubscriptions();

  /// 添加订阅先拉取一次成功才保存（失败不保存地址）。
  Future<IdjSubscription> addSubscription(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) {
      throw IdjPluginFailure('这个地址不是合法的插件下载地址（只支持 HTTPS 公网地址）');
    }
    final text = await downloadText(uri, maxBytes: 1024 * 1024);
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw IdjPluginFailure('订阅内容不是合法 JSON');
    }
    if (decoded is! Map) {
      throw IdjPluginFailure('订阅内容不是合法 JSON');
    }
    final subscription = parseSubscriptionJson(
      Map<String, dynamic>.from(decoded),
      uri,
    );
    final urls = await _subscriptionUrls();
    if (!urls.contains(url.trim())) {
      await _saveSubscriptionUrls([...urls, url.trim()]);
    }
    _subscriptionCache[url.trim()] = subscription;
    return subscription;
  }

  /// 删除订阅只删地址，不卸载已装插件（已装插件独立存在）。
  /// 内置远程索引不可删：删它直接返回，下次照样拉它。
  Future<void> removeSubscription(String url) async {
    if (idjIsBuiltInSubscription(url)) return;
    final urls = await _subscriptionUrls();
    await _saveSubscriptionUrls(urls.where((item) => item != url).toList());
    _subscriptionCache.remove(url);
  }

  /// 从订阅安装一个插件：按 `manifestUrl` 下载正文再分流
  /// （包 JSON 直接装；裸 manifest 从同目录下载脚本拼包再装）。
  /// 订阅安装兜底包装：与 [_installBundleText] 同口径——下载与
  /// interpret 分流里漏出的未包装原始异常一律收成中文
  /// [IdjPluginFailure]，原文只进日志；已有的中文失败原样透传。
  Future<IdjInstalledPlugin> installFromSubscriptionPlugin(
    IdjSubscriptionPlugin plugin, {
    IdjProbeFn? probe,
  }) async {
    try {
      return await _installFromSubscriptionPluginInner(plugin, probe: probe);
    } on IdjPluginFailure {
      rethrow;
    } catch (error) {
      debugPrint('idj 订阅安装失败（未包装异常兜底）：$error');
      throw IdjPluginFailure('安装失败：插件没能装上，请稍后重试');
    }
  }

  Future<IdjInstalledPlugin> _installFromSubscriptionPluginInner(
    IdjSubscriptionPlugin plugin, {
    IdjProbeFn? probe,
  }) async {
    if (plugin.manifest != null) {
      // 内联 manifest：没有脚本地址，无法拼包，明确报错。
      throw IdjPluginFailure('该订阅条目只有 manifest、没有插件包地址，无法安装');
    }
    if (plugin.manifestUrl.isEmpty) {
      throw IdjPluginFailure('该订阅条目没有插件地址，无法安装');
    }
    final uri = Uri.tryParse(plugin.manifestUrl);
    if (uri == null) {
      throw IdjPluginFailure('该订阅条目没有合法的插件地址，无法安装');
    }
    final text = await downloadText(uri, maxBytes: 2 * 1024 * 1024);
    final interpreted = await interpretText(text, baseUri: uri);
    if (interpreted.kind != IdjInterpretKind.bundle ||
        interpreted.bundleText == null) {
      throw IdjPluginFailure(interpreted.message);
    }
    return installBundleText(interpreted.bundleText!, probe: probe);
  }

  // ---------- 自动更新（订阅索引路线） ----------

  /// 自动更新（用户 2026-11-27 令）：插件第一次由用户手动装上后，
  /// 之后每次市场加载完由界面在后台调本方法——把各订阅索引里
  /// version 高于已装 version 的条目静默装上，全程无确认、无提示、
  /// 无角标。只更新**已经装过**的插件：订阅里没装过的条目绝不
  /// 自动安装（首装永远是用户手动点）。
  ///
  /// 口径：
  /// - 同一插件在多个订阅里出现时取版本最高的那条；
  /// - 安装走 [installFromSubscriptionPlugin] 完整安装链（下载
  ///   地址校验、manifest 校验、integrity、域名清单、probe 一样
  ///   不少），自动更新不绕过任何既有校验；
  /// - 单个插件失败（网络 / 校验 / probe 不过）只记日志、保留旧版
  ///   照常可用，不抛、不打断其余插件；
  /// - 包文件缺失 / 损坏的已装条目跳过（那是「重装」的事，手动
  ///   入口在市场卡上），不拿自动更新冒充修复；
  /// - 装完复核索引版本确实前进才记入返回值，防止索引版本号与
  ///   包内 manifest 版本不一致时反复重装。
  ///
  /// 返回真正更新成功的 pluginId 列表（界面据此静默刷新列表，
  /// 不向用户展示任何更新字样）。
  Future<List<String>> autoUpdateFromSubscriptions(
    List<IdjSubscription> subscriptions,
  ) async {
    final index = await readIndex();
    if (index.isEmpty) return const [];
    final bestById = <String, IdjSubscriptionPlugin>{};
    for (final subscription in subscriptions) {
      for (final plugin in subscription.plugins) {
        if (!index.containsKey(plugin.id)) continue;
        final current = bestById[plugin.id];
        if (current == null ||
            IdjPluginManifest.compareVersions(
                  plugin.version,
                  current.version,
                ) >
                0) {
          bestById[plugin.id] = plugin;
        }
      }
    }
    final updated = <String>[];
    for (final entry in index.values) {
      final candidate = bestById[entry.pluginId];
      if (candidate == null) continue;
      if (IdjPluginManifest.compareVersions(
            candidate.version,
            entry.version,
          ) <=
          0) {
        continue;
      }
      // 循环内复读索引：本方法可能被并发调用两轮（市场区段重
      // 挂载），先到的一轮装完后，后到的一轮在这里看到新版本
      // 直接跳过，不重复下载。装/卸本身有仓库串行链兜底。
      final fresh = (await readIndex())[entry.pluginId];
      if (fresh == null) continue;
      if (IdjPluginManifest.compareVersions(
            candidate.version,
            fresh.version,
          ) <=
          0) {
        continue;
      }
      // 包已损坏 / 缺失的跳过：自动更新不碰，留给手动重装。
      if (await readInstalledManifest(entry.pluginId) == null) {
        debugPrint('idj 自动更新：${entry.pluginId} 包文件不可用，跳过');
        continue;
      }
      try {
        final installed = await installFromSubscriptionPlugin(candidate);
        if (IdjPluginManifest.compareVersions(
              installed.entry.version,
              entry.version,
            ) >
            0) {
          updated.add(entry.pluginId);
          debugPrint(
            'idj 自动更新：${entry.pluginId} ${entry.version} → '
            '${installed.entry.version}',
          );
        } else {
          debugPrint(
            'idj 自动更新：${entry.pluginId} 索引版本 ${candidate.version} '
            '与包内版本 ${installed.entry.version} 不一致，未记更新',
          );
        }
      } catch (error) {
        // 失败保旧版：安装链失败不写索引、不动旧包，插件照常用。
        debugPrint('idj 自动更新：${entry.pluginId} 失败，保留旧版：$error');
      }
    }
    return updated;
  }

  // ---------- 更新检查 ----------

  /// 更新检查：只对 manifest 写了 `update.url` 的插件拉新 manifest
  /// 比 semver；手动触发，无定时自动刷新。订阅里的更新走
  /// [autoUpdateFromSubscriptions] 静默自动装，不再靠界面摆
  /// 「更新」按钮（用户 2026-11-27 令）。
  Future<List<IdjUpdateCandidate>> checkUpdates() async {
    final index = await readIndex();
    final candidates = <IdjUpdateCandidate>[];
    for (final entry in index.values) {
      final manifest = await readInstalledManifest(entry.pluginId);
      if (manifest == null || manifest.updateUrl.isEmpty) continue;
      final uri = Uri.tryParse(manifest.updateUrl);
      if (uri == null) continue;
      try {
        final text = await downloadText(uri, maxBytes: 1024 * 1024);
        final decoded = jsonDecode(text);
        if (decoded is! Map) continue;
        final latest = IdjPluginManifest.fromJson(
          Map<String, dynamic>.from(decoded),
        );
        if (IdjPluginManifest.compareVersions(latest.version, entry.version) >
            0) {
          candidates.add(
            IdjUpdateCandidate(
              pluginId: entry.pluginId,
              currentVersion: entry.version,
              latestVersion: latest.version,
              manifest: latest,
            ),
          );
        }
      } catch (error) {
        debugPrint('idj 更新检查：${entry.pluginId} 拉取失败：$error');
        continue;
      }
    }
    return candidates;
  }
}
