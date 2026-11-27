/// 详情页「打开即自动离线」判定单元（2026-11-27 用户改令：
/// 不要点按触发——详情页拿到下载链接后，115 已登入就自动
/// 提交，全程不用用户点）。
///
/// 只做判定、优选与流程编排，不碰界面：登录判据、开关、
/// 指纹存取、任务/网盘查重与提交函数都由调用方注入（生产
/// 走引擎 + CloudDriveSettings + SharedPreferences 指纹表，
/// 测试注入假件）。页面拿到结果后只负责在下载区摆一行状态
/// 小字，不弹窗、不挡播放。
///
/// 防重复三道闸（自动化不浪费配额的关键）：
/// 1. 一次打开只跑一轮（页面侧 [_autoOfflineTried] 守卫），
///    本单元 run 本身也只提交一条；
/// 2. 同一部片只交**一条最优链接**：下载区那几行多是同一
///    部片的不同形态（直链/磁力/.torrent 名），优选规则见
///    [pickBestOfflineLink]；
/// 3. 提交前先查：本地指纹表交过 → 跳过；115 离线任务里
///    已有（infohash 或任务名番号命中）→ 跳过；网盘里已按
///    番号找到成品文件 → 跳过。
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_115_offline.dart';
import 'magnet_offline.dart';

/// 下载链接形态：按 URL 本身判（不是按显示名）。
enum OfflineLinkKind {
  /// http(s) 直链（非 .torrent 结尾）。
  direct,

  /// magnet: 磁力。
  magnet,

  /// ed2k:// 电驴。
  ed2k,

  /// http(s) 种子文件地址（路径以 .torrent 结尾）。
  torrent,

  /// 其余认不出的形态。
  other,
}

/// 链接形态判定：115 离线 add_task_url 收磁力/ed2k/http
/// （见 cloud_115_offline 的 ssp 通道）；.torrent 文件地址
/// 交上去只会把种子文件本身当普通文件下下来，不是下片，
/// 故单列一档、不提交（见 [offlineLinkSubmittable]）。
OfflineLinkKind offlineLinkKindOf(String url) {
  final lower = url.trim().toLowerCase();
  if (lower.startsWith('magnet:')) return OfflineLinkKind.magnet;
  if (lower.startsWith('ed2k://')) return OfflineLinkKind.ed2k;
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    final path = Uri.tryParse(url.trim())?.path.toLowerCase() ?? lower;
    if (path.endsWith('.torrent')) return OfflineLinkKind.torrent;
    return OfflineLinkKind.direct;
  }
  return OfflineLinkKind.other;
}

/// 该形态能不能走 115 离线提交：直链/磁力/电驴能；.torrent
/// 文件地址与认不出的形态不能（不许假提交）。
bool offlineLinkSubmittable(OfflineLinkKind kind) =>
    kind == OfflineLinkKind.direct ||
    kind == OfflineLinkKind.magnet ||
    kind == OfflineLinkKind.ed2k;

/// 下载链接候选（详情页 JavdbMagnet 的 name/url 映射过来）。
typedef OfflineLinkCandidate = ({String name, String url});

int _offlineKindRank(OfflineLinkKind kind) => switch (kind) {
  OfflineLinkKind.direct => 0,
  OfflineLinkKind.magnet => 1,
  OfflineLinkKind.ed2k => 2,
  _ => 9,
};

/// 显示名像不像正片视频文件（同形态内优选用）：.torrent
/// 命名的磁力行多是种子包形态，排在正片文件形态之后。
bool offlineNameLooksLikeVideo(String name) {
  final lower = name.trim().toLowerCase();
  for (final ext in const [
    '.mp4',
    '.mkv',
    '.avi',
    '.mov',
    '.wmv',
    '.m4v',
    '.ts',
    '.webm',
  ]) {
    if (lower.endsWith(ext)) return true;
  }
  return false;
}

/// 优选一条（同一部片只交一条）：先按形态——能直链优先
/// 直链、其次磁力、再次电驴；同形态里名字像正片视频文件
/// 的优先；再同则先到先得（保持接口原序）。没有一条可
/// 提交时回 null。
OfflineLinkCandidate? pickBestOfflineLink(
  List<OfflineLinkCandidate> links,
) {
  OfflineLinkCandidate? best;
  var bestRank = 99;
  var bestVideo = false;
  for (final link in links) {
    final kind = offlineLinkKindOf(link.url);
    if (!offlineLinkSubmittable(kind)) continue;
    final rank = _offlineKindRank(kind);
    final video = offlineNameLooksLikeVideo(link.name);
    if (best == null ||
        rank < bestRank ||
        (rank == bestRank && video && !bestVideo)) {
      best = link;
      bestRank = rank;
      bestVideo = video;
    }
  }
  return best;
}

/// 已提交链接指纹：磁力认 infohash（同一片换个磁力写法也
/// 认得出），其余认归一后的完整 URL。
String offlineLinkFingerprint(String url) {
  final hash = pan115InfoHashOf(url);
  if (hash.isNotEmpty) return 'bt:$hash';
  return 'url:${url.trim().toLowerCase()}';
}

/// 一次自动离线的结局分类。
enum AutoOfflineOutcome {
  /// 已自动提交成功。
  submitted,

  /// 本地指纹表里有：以前交过，不重复交。
  alreadySubmitted,

  /// 115 离线任务里已有这部片。
  alreadyInTasks,

  /// 115 网盘里已有成品文件。
  alreadyInDrive,

  /// 未登入 115：静默跳过（页面只留一行小字，不弹窗）。
  notLoggedIn,

  /// 开关关着：不自动交（点按提交仍是手动兜底）。
  disabled,

  /// 链接形态都不可提交（如只有 .torrent 文件地址）。
  unsupported,

  /// 提交失败（结果带可直接上屏的中文原因文案）。
  failed,

  /// 没有下载链接：什么都不发生。
  noLinks,
}

/// 自动离线结果：分类 + 状态小字文案（disabled/noLinks
/// 时为空）+ 实际选中的链接（页面据此给对应行打已提交标）。
class AutoOfflineResult {
  const AutoOfflineResult(
    this.outcome, {
    this.message = '',
    this.chosenUrl = '',
  });

  final AutoOfflineOutcome outcome;
  final String message;
  final String chosenUrl;
}

/// 自动离线编排器：判定与查重顺序都在这里，页面只管在下
/// 载链接落地后调一次 [run]、按结果摆一行小字。
class ActressAutoOffline {
  ActressAutoOffline({
    required this.isEnabled,
    required this.isLoggedIn,
    required this.wasSubmitted,
    required this.markSubmitted,
    required this.taskExists,
    required this.driveHasFile,
    required this.submit,
    this.checkTimeout = const Duration(seconds: 10),
  });

  /// 「详情页自动离线」开关（网盘页 115 区，默认开）。
  final Future<bool> Function() isEnabled;

  /// 115 是否已登入（与引擎 pan115LoggedIn 同口径）。
  final Future<bool> Function() isLoggedIn;

  /// 本地指纹表里有没有这条链接。
  final Future<bool> Function(String fingerprint) wasSubmitted;

  /// 把指纹记进本地表（提交成功/任务已有/盘里已有都记，
  /// 下次打开先命中本地闸、省一轮网络查重）。
  final Future<void> Function(String fingerprint) markSubmitted;

  /// 115 离线任务里有没有这部片：按 infohash 或任务名提码
  /// 与番号比对（生产实现见详情页接线）。
  final Future<bool> Function(String code, String infoHash) taskExists;

  /// 115 网盘里有没有按番号找得到的成品文件。
  final Future<bool> Function(String code) driveHasFile;

  /// 提交一条链接到 115 离线下载。
  final Future<Pan115SubmitResult> Function(String url) submit;

  /// 查重（任务/网盘）单项超时：查不动当没有，继续走提交
  /// （115 侧对同 hash 任务本身也会拦重复）；绝不因查重
  /// 卡住页面。
  final Duration checkTimeout;

  static const submittedMessage = '已自动提交到 115 离线下载';
  static const alreadySubmittedMessage = '已提交过离线下载';
  static const alreadyInTasksMessage = '115 离线任务里已有这部片';
  static const alreadyInDriveMessage = '115 网盘里已有这部片';
  static const notLoggedInMessage = '未登录 115 网盘，自动离线已跳过';
  static const unsupportedMessage = '这类下载链接暂不支持自动离线';

  Future<AutoOfflineResult> run({
    required String code,
    required List<OfflineLinkCandidate> links,
  }) async {
    if (links.isEmpty) {
      return const AutoOfflineResult(AutoOfflineOutcome.noLinks);
    }
    bool enabled;
    try {
      enabled = await isEnabled();
    } catch (_) {
      // 开关读不出来按关处理：宁可不自动交，不许乱交。
      enabled = false;
    }
    if (!enabled) {
      return const AutoOfflineResult(AutoOfflineOutcome.disabled);
    }
    final best = pickBestOfflineLink(links);
    if (best == null) {
      return const AutoOfflineResult(
        AutoOfflineOutcome.unsupported,
        message: unsupportedMessage,
      );
    }
    bool loggedIn;
    try {
      loggedIn = await isLoggedIn();
    } catch (_) {
      loggedIn = false;
    }
    if (!loggedIn) {
      return AutoOfflineResult(
        AutoOfflineOutcome.notLoggedIn,
        message: notLoggedInMessage,
        chosenUrl: best.url,
      );
    }
    final fingerprint = offlineLinkFingerprint(best.url);
    if (await _check(() => wasSubmitted(fingerprint))) {
      return AutoOfflineResult(
        AutoOfflineOutcome.alreadySubmitted,
        message: alreadySubmittedMessage,
        chosenUrl: best.url,
      );
    }
    final infoHash = pan115InfoHashOf(best.url);
    if (await _check(() => taskExists(code, infoHash))) {
      await _mark(fingerprint);
      return AutoOfflineResult(
        AutoOfflineOutcome.alreadyInTasks,
        message: alreadyInTasksMessage,
        chosenUrl: best.url,
      );
    }
    if (code.isNotEmpty && await _check(() => driveHasFile(code))) {
      await _mark(fingerprint);
      return AutoOfflineResult(
        AutoOfflineOutcome.alreadyInDrive,
        message: alreadyInDriveMessage,
        chosenUrl: best.url,
      );
    }
    try {
      final result = await submit(best.url);
      if (result.ok) {
        await _mark(fingerprint);
        return AutoOfflineResult(
          AutoOfflineOutcome.submitted,
          message: submittedMessage,
          chosenUrl: best.url,
        );
      }
      // 接口明确回失败又没给原因：通用兜底文案，不静默。
      return AutoOfflineResult(
        AutoOfflineOutcome.failed,
        message: MagnetOfflineSubmitter.genericFailureMessage,
        chosenUrl: best.url,
      );
    } catch (e) {
      return AutoOfflineResult(
        AutoOfflineOutcome.failed,
        message: MagnetOfflineSubmitter.failureMessageOf(e),
        chosenUrl: best.url,
      );
    }
  }

  /// 查重护栏：超时/异常一律当「没有」，不挡提交、不崩。
  Future<bool> _check(Future<bool> Function() check) async {
    try {
      return await check().timeout(checkTimeout);
    } catch (_) {
      return false;
    }
  }

  Future<void> _mark(String fingerprint) async {
    try {
      await markSubmitted(fingerprint);
    } catch (_) {
      // 记不上指纹只是下次多查一轮，不算失败。
    }
  }
}

/// 已提交链接指纹的本地存取（SharedPreferences 字符串表，
/// 上限 2000 条、超了丢最旧的）：重复打开同一详情页靠它
/// 在本地就拦下，不再走网络查重。
class SubmittedOfflineLinks {
  SubmittedOfflineLinks._();

  static const prefsKey = 'actress_auto_offline_submitted_links';
  static const _cap = 2000;

  static Future<bool> contains(String fingerprint) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(prefsKey) ?? const <String>[]).contains(
      fingerprint,
    );
  }

  static Future<void> add(String fingerprint) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getStringList(prefsKey) ?? <String>[];
    if (current.contains(fingerprint)) return;
    final next = [...current, fingerprint];
    if (next.length > _cap) next.removeRange(0, next.length - _cap);
    await prefs.setStringList(prefsKey, next);
  }
}
