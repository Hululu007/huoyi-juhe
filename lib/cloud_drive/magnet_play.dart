/// 磁力播放等待状态机（2026-11-27 用户令：详情页内嵌播放
/// 器新增「磁力播放」——用本片磁力经 115 离线落盘后，页
/// 内直接播网盘那一份）。
///
/// 只做流程编排，不碰界面：登录判据、网盘找片、指纹查重、
/// 提交、任务列表都由调用方注入（生产走引擎 + 既有
/// [DriveCodePlayFinder]，测试注入假件）。页面只管把
/// [MagnetPlayProgress] 的文案摆出来、就绪时拿 hit 起播、
/// 点「取消等待」调 [cancel]。
///
/// 流程：先按番号在网盘里找现成文件（自动离线交过的片
/// 多半已在盘里）→ 命中直接播；没有才提交（本地指纹/任
/// 务列表两道闸认出交过的就不重交，与自动离线同一套闸）
/// → 轮询任务列表：首轮轮询即完成 = 秒下（会员号常见），
/// 失败（状态 -1）立刻收尾不干等，总等待有上限、到点给
/// 超时结局；任务完成后再按番号定位文件取直链。取消随
/// 时可退，退了页面回原样、照常走三池竞速。
library;

import 'auto_offline.dart';
import 'cloud_115_offline.dart';
import 'drive_code_play.dart';
import 'magnet_offline.dart';

/// 等待阶段（终局：ready/failed/timedOut/cancelled/
/// notLoggedIn；过程：looking/submitting/waiting）。
enum MagnetPlayPhase {
  /// 正在网盘里按番号找现成文件。
  looking,

  /// 正在提交到 115 离线下载。
  submitting,

  /// 已提交/任务在跑，等它下完（带进度）。
  waiting,

  /// 文件就绪，可起播（结果带 hit）。
  ready,

  /// 失败（结果带中文原因）。
  failed,

  /// 等待总时长到点。
  timedOut,

  /// 用户取消等待。
  cancelled,

  /// 未登录 115。
  notLoggedIn,
}

/// 一帧等待进度/最终结果：文案已是可直接上屏的中文。
class MagnetPlayProgress {
  const MagnetPlayProgress(
    this.phase, {
    this.message = '',
    this.percent,
    this.hit,
    this.instant = false,
  });

  final MagnetPlayPhase phase;

  /// 上屏文案（状态实显：秒下/离线中 x%/排队等待/失败原因）。
  final String message;

  /// 离线进度 0..1；未知（排队/任务还没出现）为 null。
  final double? percent;

  /// 就绪时的网盘直链（phase == ready 才有）。
  final DrivePlayHit? hit;

  /// 是否「秒」成：盘里本来就有，或提交后首轮轮询即完成
  /// （115 按 hash 秒下，会员号常见）。
  final bool instant;

  /// 是否还在等（页面据此显等待态/禁用重复入口）。
  bool get isWaiting =>
      phase == MagnetPlayPhase.looking ||
      phase == MagnetPlayPhase.submitting ||
      phase == MagnetPlayPhase.waiting;
}

/// 磁力播放主入口的优选：只在磁力形态里挑最优一条（与
/// 自动离线同一套 [pickBestOfflineLink] 优选——同形态里
/// 名字像正片文件的优先）；一条磁力都没有时退回全体优
/// 选（直链也能离线落盘后播），再没有回 null。
OfflineLinkCandidate? pickBestMagnetPlayLink(
  List<OfflineLinkCandidate> links,
) {
  final magnets = [
    for (final link in links)
      if (offlineLinkKindOf(link.url) == OfflineLinkKind.magnet) link,
  ];
  return pickBestOfflineLink(magnets.isNotEmpty ? magnets : links);
}

/// 磁力播放等待器（单实例可复用：每次 [run] 先清取消标；
/// [cancel] 只置标，run 在每个等待点检查后收尾）。
class MagnetPlayWaiter {
  MagnetPlayWaiter({
    required this.isLoggedIn,
    required this.findInDrive,
    required this.wasSubmitted,
    required this.markSubmitted,
    required this.taskExists,
    required this.submit,
    required this.listTasks,
    this.pollInterval = const Duration(seconds: 4),
    this.maxWait = const Duration(seconds: 180),
    Future<void> Function(Duration)? delay,
  }) : _delay = delay ?? Future.delayed;

  /// 115 是否已登入（与引擎 pan115LoggedIn 同口径）。
  final Future<bool> Function() isLoggedIn;

  /// 按番号在网盘里找成品并取直链（生产走
  /// [DriveCodePlayFinder.find]，自带搜索超时、找不到回
  /// null）。
  final Future<DrivePlayHit?> Function(String code) findInDrive;

  /// 本地指纹表里有没有这条链接（与自动离线共用
  /// [SubmittedOfflineLinks]）。
  final Future<bool> Function(String fingerprint) wasSubmitted;

  /// 把指纹记进本地表（提交成功后记，下次不重交）。
  final Future<void> Function(String fingerprint) markSubmitted;

  /// 115 离线任务里有没有这部片（infohash 或任务名番号
  /// 命中，与自动离线的查重实现同口径）。
  final Future<bool> Function(String code, String infoHash) taskExists;

  /// 提交一条链接到 115 离线下载。
  final Future<Pan115SubmitResult> Function(String url) submit;

  /// 当前离线任务列表。
  final Future<List<Pan115OfflineTask>> Function() listTasks;

  /// 轮询间隔：4 秒一轮——115 任务状态刷新没必要更密，
  /// 更密只招限频。
  final Duration pollInterval;

  /// 等待总上限：3 分钟。会员秒下是秒级、普通离线多数在
  /// 分钟内；到点给超时结局，用户可改走竞速或稍后从网
  /// 盘打开，不无限转圈。
  final Duration maxWait;

  final Future<void> Function(Duration) _delay;

  var _cancelled = false;

  /// 取消等待：run 在下一个检查点以 cancelled 收尾。
  void cancel() => _cancelled = true;

  static const _cancelledProgress = MagnetPlayProgress(
    MagnetPlayPhase.cancelled,
    message: '已取消等待',
  );

  /// 跑一轮磁力播放：过程帧经 [onProgress] 推给页面，最
  /// 终结果由返回值带回（ready 带 hit）。
  Future<MagnetPlayProgress> run({
    required String code,
    required String url,
    void Function(MagnetPlayProgress progress)? onProgress,
  }) async {
    _cancelled = false;
    void emit(MagnetPlayProgress progress) => onProgress?.call(progress);

    bool loggedIn;
    try {
      loggedIn = await isLoggedIn();
    } catch (_) {
      loggedIn = false;
    }
    if (!loggedIn) {
      return const MagnetPlayProgress(
        MagnetPlayPhase.notLoggedIn,
        message: '未登录 115 网盘，登录后可用磁力播放',
      );
    }
    if (_cancelled) return _cancelledProgress;

    // 先找现成：自动离线交过/盘里本来就有的片直接播，
    // 不重复提交、不等待。
    emit(
      const MagnetPlayProgress(
        MagnetPlayPhase.looking,
        message: '正在查找 115 网盘里的这部片…',
      ),
    );
    final existing = await _guarded(() => findInDrive(code));
    if (_cancelled) return _cancelledProgress;
    if (existing != null) {
      return MagnetPlayProgress(
        MagnetPlayPhase.ready,
        message: '115 网盘里已有这部片，直接播放',
        hit: existing,
        instant: true,
      );
    }

    // 查重闸：指纹表/任务列表任一认出交过，就跳过提交
    // 直接进轮询（自动离线交的那条走的正是这条路）。
    final fingerprint = offlineLinkFingerprint(url);
    var infoHash = pan115InfoHashOf(url);
    final submittedBefore =
        await _guardedBool(() => wasSubmitted(fingerprint)) ||
        await _guardedBool(() => taskExists(code, infoHash));
    if (_cancelled) return _cancelledProgress;
    if (!submittedBefore) {
      emit(
        const MagnetPlayProgress(
          MagnetPlayPhase.submitting,
          message: '正在提交到 115 离线下载…',
        ),
      );
      try {
        final result = await submit(url);
        if (!result.ok) {
          return const MagnetPlayProgress(
            MagnetPlayPhase.failed,
            message: MagnetOfflineSubmitter.genericFailureMessage,
          );
        }
        if (result.infoHash.isNotEmpty) infoHash = result.infoHash;
        await _guarded(() => markSubmitted(fingerprint));
      } catch (e) {
        return MagnetPlayProgress(
          MagnetPlayPhase.failed,
          message: MagnetOfflineSubmitter.failureMessageOf(e),
        );
      }
    }
    if (_cancelled) return _cancelledProgress;

    // 轮询任务：首轮即完成 = 秒下；任务完成但文件还没被
    // 搜索索引到时继续轮（仍受总上限约束）。
    final deadline = DateTime.now().add(maxWait);
    var polls = 0;
    while (true) {
      if (_cancelled) return _cancelledProgress;
      List<Pan115OfflineTask> tasks;
      try {
        tasks = await listTasks();
      } catch (_) {
        tasks = const [];
      }
      if (_cancelled) return _cancelledProgress;
      final task = _matchTask(tasks, code, infoHash);
      if (task != null && task.failed) {
        return const MagnetPlayProgress(
          MagnetPlayPhase.failed,
          message: '115 离线下载失败，可换一个磁力再试',
        );
      }
      if (task != null && task.done) {
        emit(
          const MagnetPlayProgress(
            MagnetPlayPhase.waiting,
            message: '离线完成，正在网盘里定位文件…',
          ),
        );
        final hit = await _guarded(() => findInDrive(code));
        if (_cancelled) return _cancelledProgress;
        if (hit != null) {
          return MagnetPlayProgress(
            MagnetPlayPhase.ready,
            message: polls == 0 ? '秒下完成，开始播放' : '离线完成，开始播放',
            hit: hit,
            instant: polls == 0,
          );
        }
        // 下完了但搜索还没索引到：继续等下一轮。
      } else if (task != null) {
        final percent = task.percent;
        emit(
          MagnetPlayProgress(
            MagnetPlayPhase.waiting,
            percent: percent,
            message: percent > 0
                ? '离线中 ${(percent * 100).round()}%'
                : '排队等待 115 离线下载…',
          ),
        );
      } else {
        emit(
          const MagnetPlayProgress(
            MagnetPlayPhase.waiting,
            message: '排队等待 115 离线下载…',
          ),
        );
      }
      polls++;
      if (DateTime.now().isAfter(deadline)) {
        return const MagnetPlayProgress(
          MagnetPlayPhase.timedOut,
          message: '等待离线完成超时，片子下好后点播放键即可观看',
        );
      }
      await _delay(pollInterval);
    }
  }

  /// 任务匹配：infohash 优先（提交响应给的/磁力自带的）；
  /// 没有再按任务名提码与番号比对（与查重闸同口径）。
  Pan115OfflineTask? _matchTask(
    List<Pan115OfflineTask> tasks,
    String code,
    String infoHash,
  ) {
    if (infoHash.isNotEmpty) {
      for (final task in tasks) {
        if (task.infoHash == infoHash) return task;
      }
    }
    final key = pan115CodeKeyOf(code);
    if (key.isNotEmpty) {
      for (final task in tasks) {
        final extracted = pan115ExtractCode(task.name);
        if (extracted != null && pan115CodeKeyOf(extracted) == key) {
          return task;
        }
      }
    }
    return null;
  }

  /// 护栏：查重/找片这类辅助调用失败当没查到，不挡主流程。
  Future<T?> _guarded<T>(Future<T?> Function() call) async {
    try {
      return await call();
    } catch (_) {
      return null;
    }
  }

  Future<bool> _guardedBool(Future<bool> Function() call) async {
    try {
      return await call();
    } catch (_) {
      return false;
    }
  }
}
