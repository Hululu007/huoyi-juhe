import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 软件内远程更新（魔蚁同步批 B8）：按魔蚁设计在修仙版重写——
/// 更新源是修仙版自己的发布仓，选版跳过草稿/预发布/核发布标签
/// 取版本最大者，启动弹窗带「稍后再说只跳本版」与发布说明里的
/// 强制更新窗口，安卓框内断点续传下载 + SHA-256 校验 + 系统
/// 安装器调起；非安卓打开发布页。

/// 发布仓（修仙版自己的仓，与魔蚁的发布仓分开）。
const String kAppUpdateRepoSlug = 'hoyittvggfh45/huoyi-juhe';

/// 核发布与整包发布同仓分流：整包选版跳过此前缀的标签。
const String kCoreReleaseTagPrefix = 'core-';

String get appUpdateReleasesApiUrl =>
    'https://api.github.com/repos/$kAppUpdateRepoSlug/releases?per_page=30';

String get appUpdateReleasesPageUrl =>
    'https://github.com/$kAppUpdateRepoSlug/releases';

const String _dismissedVersionKey = 'app_update_dismissed_version';
const String _lastCheckMsKey = 'app_update_last_check_ms';
const String _latestVersionKey = 'app_update_latest_version';

/// 版本号：主.次.修订+构建。正则从任意文本里抠第一组，所以
/// `v1.0.12+37`、`1.0.12-37`、标签与发布名都能解析，缺构建号按 0。
@immutable
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, [this.build = 0]);

  final int major;
  final int minor;
  final int patch;
  final int build;

  static final RegExp _pattern = RegExp(r'(\d+)\.(\d+)\.(\d+)(?:[+-](\d+))?');

  static AppVersion? tryParse(String? text) {
    if (text == null) return null;
    final match = _pattern.firstMatch(text);
    if (match == null) return null;
    return AppVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4) ?? '0'),
    );
  }

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    return build.compareTo(other.build);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;
  bool operator <=(AppVersion other) => compareTo(other) <= 0;

  /// 只输出主.次.修订（不含构建号）：「稍后再说」的存储与比较
  /// 都用这个字符串，同主版本不同构建号视为同一版。
  @override
  String toString() => '$major.$minor.$patch';

  @override
  bool operator ==(Object other) =>
      other is AppVersion &&
      major == other.major &&
      minor == other.minor &&
      patch == other.patch &&
      build == other.build;

  @override
  int get hashCode => Object.hash(major, minor, patch, build);
}

/// 一条整包发布（从 GitHub 发布 JSON 解析）。
@immutable
class AppReleaseInfo {
  const AppReleaseInfo({
    required this.version,
    required this.tag,
    required this.name,
    required this.notes,
    required this.htmlUrl,
    this.apkUrl,
    this.apkName,
    this.apkSize,
    this.apkSha256,
  });

  final AppVersion version;
  final String tag;
  final String name;
  final String notes;
  final String htmlUrl;
  final String? apkUrl;
  final String? apkName;
  final int? apkSize;
  final String? apkSha256;

  bool get hasApk => apkUrl != null && apkName != null;
}

/// 选整包最新版：跳过草稿、预发布、`core-` 标签、版本号解析不出
/// 的，余下取版本号最大的一条（不是列表第一条）。
AppReleaseInfo? selectAppRelease(List<dynamic> releasesJson) {
  AppReleaseInfo? best;
  for (final raw in releasesJson) {
    if (raw is! Map) continue;
    if (raw['draft'] == true || raw['prerelease'] == true) continue;
    final tag = raw['tag_name']?.toString() ?? '';
    if (tag.startsWith(kCoreReleaseTagPrefix)) continue;
    final name = raw['name']?.toString() ?? '';
    final version = AppVersion.tryParse(tag) ?? AppVersion.tryParse(name);
    if (version == null) continue;
    String? apkUrl;
    String? apkName;
    int? apkSize;
    String? apkSha256;
    final assets = raw['assets'];
    if (assets is List) {
      Map? chosen;
      for (final asset in assets) {
        if (asset is! Map) continue;
        final assetName = asset['name']?.toString() ?? '';
        if (!assetName.toLowerCase().endsWith('.apk')) continue;
        // 多架构包并存时优先名字含 arm64 的（本应用只出 v8a）。
        if (chosen == null || assetName.toLowerCase().contains('arm64')) {
          chosen = asset;
          if (assetName.toLowerCase().contains('arm64')) break;
        }
      }
      if (chosen != null) {
        apkName = chosen['name']?.toString();
        apkUrl = chosen['browser_download_url']?.toString();
        final size = chosen['size'];
        apkSize = size is int ? size : null;
        final digest = chosen['digest']?.toString() ?? '';
        if (digest.toLowerCase().startsWith('sha256:')) {
          apkSha256 = digest.substring(7).toLowerCase();
        }
      }
    }
    final info = AppReleaseInfo(
      version: version,
      tag: tag,
      name: name,
      notes: raw['body']?.toString() ?? '',
      htmlUrl: raw['html_url']?.toString() ?? appUpdateReleasesPageUrl,
      apkUrl: apkUrl,
      apkName: apkName,
      apkSize: apkSize,
      apkSha256: apkSha256,
    );
    if (best == null || info.version > best.version) best = info;
  }
  return best;
}

/// 强制更新窗口：藏在发布说明正文里，行首 `FORCE_AFTER:` /
/// `FORCE_UNTIL:` 后跟日期（纯日期或完整 ISO 时间）。解析不出
/// 的界视为无此界。
({DateTime? after, DateTime? until}) parseForceWindow(String notes) {
  DateTime? after;
  DateTime? until;
  for (final rawLine in notes.split('\n')) {
    final line = rawLine.trim();
    if (line.startsWith('FORCE_AFTER:')) {
      after = _parseForceDate(line.substring(12).trim(), endOfDay: false);
    } else if (line.startsWith('FORCE_UNTIL:')) {
      until = _parseForceDate(line.substring(13).trim(), endOfDay: true);
    }
  }
  return (after: after, until: until);
}

DateTime? _parseForceDate(String text, {required bool endOfDay}) {
  if (text.isEmpty) return null;
  final parsed = DateTime.tryParse(text);
  if (parsed == null) return null;
  final pureDate = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text);
  if (pureDate && endOfDay) {
    return DateTime(parsed.year, parsed.month, parsed.day, 23, 59, 59, 999);
  }
  return parsed;
}

/// 是否处于强制更新：最新版不高于当前版、或没有窗口、或当前
/// 时刻不在窗口内，都不强制；只给一个界时只查那一侧。
bool isForceUpdate({
  required AppVersion current,
  required AppReleaseInfo latest,
  required DateTime now,
}) {
  if (latest.version <= current) return false;
  final window = parseForceWindow(latest.notes);
  if (window.after == null && window.until == null) return false;
  if (window.after != null && now.isBefore(window.after!)) return false;
  if (window.until != null && now.isAfter(window.until!)) return false;
  return true;
}

/// 安卓更新桥（通道 fqapp/appupdate，宿主 AppUpdatePlugin）：
/// appInfo 读包版本、installApk 调系统安装器、openUrl 开浏览器。
/// 非安卓/桥缺失时各方法安全降级（appInfo 回 0.0.0、install 回
/// 错误码、openUrl 回 false）。
class AppUpdateBridge {
  AppUpdateBridge([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('fqapp/appupdate');

  final MethodChannel _channel;

  static final AppUpdateBridge instance = AppUpdateBridge();

  Future<AppVersion> currentVersion() async {
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>('appInfo');
      final name = AppVersion.tryParse(info?['versionName']?.toString());
      final code = info?['versionCode'];
      final codeInt = code is int ? code : int.tryParse('${code ?? ''}') ?? 0;
      if (name != null) {
        return AppVersion(name.major, name.minor, name.patch, codeInt);
      }
      return AppVersion(0, 0, 0, codeInt);
    } catch (_) {
      return const AppVersion(0, 0, 0, 0);
    }
  }

  /// 成功回 null；失败回 (代码, 文案)。install_permission 表示已
  /// 跳去系统设置请用户授权，回来重点即可。
  Future<({String code, String message})?> installApk(String path) async {
    try {
      await _channel.invokeMethod<void>('installApk', {'path': path});
      return null;
    } on PlatformException catch (e) {
      return (code: e.code, message: e.message ?? '安装失败');
    } catch (e) {
      return (code: 'error', message: '安装失败：$e');
    }
  }

  Future<bool> openUrl(String url) async {
    try {
      final ok = await _channel.invokeMethod<bool>('openUrl', {'url': url});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// 断点续传的决策（纯函数，供测试锁住）：已有字节数与响应状态
/// 决定从 0 重下、续写、还是删掉重来。
enum ResumeAction { restart, append, discardAndFail }

ResumeAction resumeDecision({
  required int existingBytes,
  required int statusCode,
}) {
  if (statusCode == 416) return ResumeAction.discardAndFail;
  if (statusCode == 206 && existingBytes > 0) return ResumeAction.append;
  return ResumeAction.restart;
}

/// 断点续传下载器：先下到 `<目标>.part`，已有 .part 时带 Range
/// 续；200 从 0 重下、206 续写、416 删 .part 报错。最多 4 次
/// 尝试，间隔 1+attempt 秒；可 cancel。
class ResumableDownloader {
  ResumableDownloader({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;
  bool _cancelled = false;

  void cancel() => _cancelled = true;

  Future<File> download(
    Uri url,
    File target, {
    void Function(int received, int total)? onProgress,
  }) async {
    final part = File('${target.path}.part');
    await part.parent.create(recursive: true);
    Object? lastError;
    for (var attempt = 0; attempt < 4; attempt++) {
      if (_cancelled) throw StateError('下载已取消');
      try {
        await _attemptOnce(url, part, onProgress);
        await part.rename(target.path);
        return target;
      } catch (e) {
        lastError = e;
        if (_cancelled) throw StateError('下载已取消');
        if (attempt < 3) {
          await Future<void>.delayed(Duration(seconds: 1 + attempt));
        }
      }
    }
    throw StateError('下载失败：$lastError');
  }

  Future<void> _attemptOnce(
    Uri url,
    File part,
    void Function(int received, int total)? onProgress,
  ) async {
    final existing = await part.exists() ? await part.length() : 0;
    final client = _clientFactory();
    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      request.headers.set(HttpHeaders.userAgentHeader, 'xiuxian-app-update');
      if (existing > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
      }
      final response = await request.close();
      final action = resumeDecision(
        existingBytes: existing,
        statusCode: response.statusCode,
      );
      if (action == ResumeAction.discardAndFail) {
        await response.drain<void>();
        if (await part.exists()) await part.delete();
        throw StateError('服务器拒绝续传（416），已清掉半截文件，请重试');
      }
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.drain<void>();
        throw StateError('下载返回 ${response.statusCode}');
      }
      var total = response.contentLength;
      final range = response.headers.value(HttpHeaders.contentRangeHeader);
      if (range != null && range.contains('/')) {
        total = int.tryParse(range.split('/').last.trim()) ?? total;
      }
      final append = action == ResumeAction.append;
      var received = append ? existing : 0;
      if (append && total < 0) total = existing + response.contentLength;
      final sink = part.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      try {
        await for (final chunk in response) {
          if (_cancelled) throw StateError('下载已取消');
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }
  }
}

/// 更新检查器：拉取、节流、「稍后再说」、下载与校验。
class AppUpdateChecker {
  AppUpdateChecker({
    AppUpdateBridge? bridge,
    HttpClient Function()? clientFactory,
    Future<SharedPreferences> Function()? prefsFactory,
    this._supportDirFactory,
  }) : _bridge = bridge ?? AppUpdateBridge.instance,
       _clientFactory = clientFactory ?? HttpClient.new,
       _prefsFactory = prefsFactory ?? SharedPreferences.getInstance;

  final AppUpdateBridge _bridge;
  final HttpClient Function() _clientFactory;
  final Future<SharedPreferences> Function() _prefsFactory;
  final Directory Function()? _supportDirFactory;

  static final AppUpdateChecker instance = AppUpdateChecker();

  /// 一次启动最多弹一次：进程内静态标志，第一次尝试即置真。
  static bool _promptAttempted = false;

  Future<AppVersion> currentVersion() => _bridge.currentVersion();

  Future<AppReleaseInfo?> fetchLatest() async {
    final client = _clientFactory();
    try {
      final request = await client.getUrl(Uri.parse(appUpdateReleasesApiUrl));
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      request.headers.set(HttpHeaders.userAgentHeader, 'xiuxian-app-update');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) {
        throw StateError('更新源返回 ${response.statusCode}');
      }
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! List) throw StateError('更新源返回格式不对');
      final latest = selectAppRelease(decoded);
      if (latest != null) {
        final prefs = await _prefsFactory();
        await prefs.setString(_latestVersionKey, latest.version.toString());
      }
      return latest;
    } finally {
      client.close(force: true);
    }
  }

  /// 「稍后再说」只跳本版：存版本字符串（主.次.修订），全等才算
  /// 跳过；更高版本字符串不等，照常再弹。无过期、无次数。
  Future<bool> isDismissed(AppVersion version) async {
    final prefs = await _prefsFactory();
    return prefs.getString(_dismissedVersionKey) == version.toString();
  }

  Future<void> dismiss(AppVersion version) async {
    final prefs = await _prefsFactory();
    await prefs.setString(_dismissedVersionKey, version.toString());
  }

  Future<String?> cachedLatestVersion() async {
    final prefs = await _prefsFactory();
    return prefs.getString(_latestVersionKey);
  }

  /// 启动弹窗用：返回 (当前版本, 最新发布) 或 null（不弹）。
  /// 缓存说有新版时仍实时拉完整信息（弹窗要说明与下载地址）；
  /// 缓存没有时走 24 小时节流（先记时刻再请求，失败不狂重试）。
  /// 全程吞异常。
  Future<({AppVersion current, AppReleaseInfo latest})?>
  pendingUpdatePrompt() async {
    if (_promptAttempted) return null;
    _promptAttempted = true;
    try {
      final current = await currentVersion();
      final cached = await cachedLatestVersion();
      final cachedVersion = AppVersion.tryParse(cached);
      if (cachedVersion != null && cachedVersion > current) {
        if (await isDismissed(cachedVersion)) return null;
        final latest = await fetchLatest();
        if (latest == null || latest.version <= current) return null;
        if (await isDismissed(latest.version)) return null;
        return (current: current, latest: latest);
      }
      final prefs = await _prefsFactory();
      final lastCheck = prefs.getInt(_lastCheckMsKey) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastCheck < const Duration(hours: 24).inMilliseconds) {
        return null;
      }
      await prefs.setInt(_lastCheckMsKey, now);
      final latest = await fetchLatest();
      if (latest == null || latest.version <= current) return null;
      if (await isDismissed(latest.version)) return null;
      return (current: current, latest: latest);
    } catch (_) {
      return null;
    }
  }

  /// 下载安装包到应用支持目录 app_update/，带断点续传与进度；
  /// 发布带了校验和时验 SHA-256，不符删文件并报错。
  Future<File> downloadApk(
    AppReleaseInfo release, {
    void Function(int received, int total)? onProgress,
    ResumableDownloader? downloader,
  }) async {
    if (!release.hasApk) throw StateError('该版本没有可下载的安装包');
    final support =
        _supportDirFactory?.call() ?? await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/app_update');
    final target = File('${dir.path}/${release.apkName}');
    final file = await (downloader ?? ResumableDownloader()).download(
      Uri.parse(release.apkUrl!),
      target,
      onProgress: onProgress,
    );
    final expected = release.apkSha256;
    if (expected != null && expected.isNotEmpty) {
      final digest = await sha256.bind(file.openRead()).first;
      if (digest.toString().toLowerCase() != expected) {
        await file.delete();
        throw StateError('安装包校验失败（SHA-256 不符），已删除');
      }
    }
    return file;
  }
}
