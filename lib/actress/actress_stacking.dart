import 'dart:async';

import 'actress_database.dart';
import 'actress_search.dart';

/// 全站叠加进度：只含数字，不含任何来源名（界面不显示来源）。
class ActressStackingProgress {
  const ActressStackingProgress({
    required this.done,
    required this.total,
    required this.worksAdded,
    required this.running,
    required this.finished,
  });

  /// 本轮全库已叠加人数（断点累计值）。
  final int done;

  /// 库内总人数；为 0 表示总量未知。
  final int total;

  /// 本轮新增的作品行数（跨站发现的新作品行，同番号两站各计一条）。
  final int worksAdded;
  final bool running;
  final bool finished;

  static const idle = ActressStackingProgress(
    done: 0,
    total: 0,
    worksAdded: 0,
    running: false,
    finished: false,
  );
}

/// 全站叠加结果：供列表页横幅与刷新判断用。
class ActressStackingResult {
  const ActressStackingResult({
    required this.processed,
    required this.worksAdded,
    required this.failed,
    required this.cancelled,
    required this.finished,
  });

  /// 本轮实际跑过的人数（含空作品与失败的人，均已越过断点）。
  final int processed;
  final int worksAdded;
  final int failed;
  final bool cancelled;
  final bool finished;
}

/// 全站叠加服务：把全库人物逐个跑一遍 [ActressEnrichment]，按（站，
/// 番号）把各站作品叠加进本地库（某站有某站没有的进库；同番号两站
/// 各留一条，各算一条可播线路），后台断点续跑。零作品的人也照常跑
/// 名字路搜全站，搜到就新增进库（见 [ActressEnrichment]）。
///
/// - 复用详情页同一套补全（名字路 + 番号路 + whos 路默认关闭），
///   不另写去重逻辑；失败的站静默跳过，不弹错、不挡列表；
/// - 断点：独立检查点（source/phase 均为 'stacking'，与三家名册源
///   的检查点分键），cursor 为最后跑完的人物 localId，total 为本
///   轮累计已叠加人数；每跑完一人即存点，取消/预算用尽后下次从
///   断点续，永不从头重拉；
/// - 与 enrichedAt 各记各的：叠加以自己的检查点为准，绝不看
///   enrichedAt 跳人；补全内部的 enrichedAt 跳过语义（已补过且
///   全部作品已有封面才跳过）保持原样，也不由本服务改写
///   enrichedAt（那是详情页打开时的职责）；
/// - 逐人串行跑（补全内部已有 4 路并发），不为一次跑完放宽超时
///   或并发；单人补全抛错时记失败并越过断点，不卡住整轮；
/// - 手动触发，不自动跑；跑完一轮后列表页刷新总览与列表即可看
///   到叠加后的作品数（写库刷新 works_count，displayWorks 取
///   worksCount 与 rosterWorks 的较大者，自动跟涨）。
class ActressStackingService {
  ActressStackingService({
    required this.db,
    required this.enrichment,
    this.personBudget = 20,
    this.pageSize = 50,
  });

  final ActressDatabase db;
  final ActressEnrichment enrichment;

  /// 每轮最多跑的人数（预算用尽即停点，下次断点续跑）。
  final int personBudget;

  /// 每次从库里取的人数（只作取数分页，不影响预算口径）。
  final int pageSize;

  final _progressController =
      StreamController<ActressStackingProgress>.broadcast();

  Stream<ActressStackingProgress> get progress => _progressController.stream;

  bool _running = false;
  bool _cancelled = false;
  Future<ActressStackingResult>? _currentRun;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isRunning => _running;

  void cancel() {
    _cancelled = true;
  }

  void dispose() {
    _progressController.close();
  }

  /// 当前叠加状态（列表页进页显示用）：只读检查点与总览，不启动。
  Future<ActressStackingProgress> snapshot() async {
    final checkpoint = await db.stackingCheckpoint();
    final overview = await db.overview();
    return ActressStackingProgress(
      done: checkpoint?.total ?? 0,
      total: overview.persons,
      worksAdded: 0,
      running: _running,
      finished: checkpoint?.finished ?? false,
    );
  }

  /// 跑一轮叠加。已在跑时返回同一份结果（不重复跑）；检查点已记
  /// 完成时直接返回零处理结果，不重拉。
  Future<ActressStackingResult> run() {
    final current = _currentRun;
    if (current != null) return current;
    final run = _run();
    _currentRun = run;
    return run.whenComplete(() {
      _currentRun = null;
    });
  }

  Future<ActressStackingResult> _run() async {
    _running = true;
    _cancelled = false;
    var processed = 0;
    var worksAdded = 0;
    var failed = 0;
    try {
      final checkpoint = await db.stackingCheckpoint();
      if (checkpoint != null && checkpoint.finished) {
        return const ActressStackingResult(
          processed: 0,
          worksAdded: 0,
          failed: 0,
          cancelled: false,
          finished: true,
        );
      }
      var cursor = int.tryParse(checkpoint?.cursor ?? '') ?? 0;
      var stacked = checkpoint?.total ?? 0;
      final total = (await db.overview()).persons;
      _emit(
        ActressStackingProgress(
          done: stacked,
          total: total,
          worksAdded: 0,
          running: true,
          finished: false,
        ),
        force: true,
      );
      var exhausted = false;
      while (!_cancelled && processed < personBudget) {
        final batch = await db.personsAfterId(
          afterId: cursor,
          limit: pageSize,
        );
        if (batch.isEmpty) {
          exhausted = true;
          break;
        }
        var batchConsumed = true;
        for (final person in batch) {
          if (_cancelled || processed >= personBudget) {
            // 预算用尽/取消时跳出：本批没吃完，不能记跑完。
            batchConsumed = false;
            break;
          }
          final before = await db.countWorks(person.localId);
          try {
            await enrichment.enrichPerson(
              person,
              isCancelled: () => _cancelled,
            );
          } catch (_) {
            failed++;
          }
          if (_cancelled) break;
          final after = await db.countWorks(person.localId);
          if (after > before) worksAdded += after - before;
          processed++;
          stacked++;
          cursor = person.localId;
          await db.saveStackingCheckpoint(
            ActressSyncCheckpoint(
              source: actressStackingCheckpointSource,
              phase: actressStackingCheckpointPhase,
              cursor: '$cursor',
              total: stacked,
              finished: false,
            ),
          );
          _emit(
            ActressStackingProgress(
              done: stacked,
              total: total,
              worksAdded: worksAdded,
              running: true,
              finished: false,
            ),
          );
        }
        if (batchConsumed && batch.length < pageSize) {
          exhausted = true;
          break;
        }
      }
      final finished = exhausted && !_cancelled;
      if (finished) {
        await db.saveStackingCheckpoint(
          ActressSyncCheckpoint(
            source: actressStackingCheckpointSource,
            phase: actressStackingCheckpointPhase,
            cursor: '$cursor',
            total: stacked,
            finished: true,
          ),
        );
      }
      final result = ActressStackingResult(
        processed: processed,
        worksAdded: worksAdded,
        failed: failed,
        cancelled: _cancelled,
        finished: finished,
      );
      _emit(
        ActressStackingProgress(
          done: stacked,
          total: total,
          worksAdded: worksAdded,
          running: false,
          finished: finished,
        ),
        force: true,
      );
      return result;
    } finally {
      _running = false;
    }
  }

  void _emit(ActressStackingProgress progress, {bool force = false}) {
    if (_progressController.isClosed) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastEmit).inMilliseconds < 300) return;
    _lastEmit = now;
    _progressController.add(progress);
  }
}
