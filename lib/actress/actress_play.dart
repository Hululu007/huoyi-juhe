import 'dart:async';

import 'actress_models.dart';
import 'actress_search.dart';
import 'actress_adapter_repository.dart';
import 'actress_crosssite_probe.dart';
import 'actress_adapter_http.dart';
import 'actress_adapter_store.dart';
import 'actress_adapter_models.dart';

/// 一条候选线路：探活取回的详情 + 起播集序号（首版本首线路）。
class ActressPlayCandidate {
  const ActressPlayCandidate({
    required this.detail,
    required this.episodeIndex,
  });

  final DramaDetail detail;
  final int episodeIndex;
}

/// 静默换线播放链：点卡后按番号把各站候选排成一条链，挨个试。
///
/// - 兜底波次先探：[actressFallbackSiteIds] 里的站（MJV 系 + 18AV
///   双生站）按表序先探一波，命中即成链、不等其余站；无果才探
///   MissAV 波次（[actressMissavFirstSiteId]，只探主站），再探
///   eager 波次与懒查波次；
/// - 候选顺序 = 跨站探活计划顺序（优先序表 → 🔞站 → 其余站），确定性
///   优先，不按延迟排；懒查计划（慢站/盾站/超名额）只在 eager 波次
///   无果或候选全部预检失败后才探；
/// - 起播前每候选都过 resolve 预检（单候选超时），首个解出的才推
///   播放器；预检失败的静默跳过，不弹错；
/// - 预检不只看“解没解出来”：直链计划还要再验活（首分片/Range
///   206，见 [feedProbePlayable]），解出死地址也算失败、换下一条，
///   绝不把死地址推进播放器开黑屏；解析型计划（needsParse）验不
///   了活，先放行，播失败时播放器再经 onPlaybackExhausted 换线；
/// - [triedSources] 记下本轮实际试过的站 id（探活波次 + 预检候选），
///   调用方链耗尽时可如实报“已试过 X 个站”；
/// - [resetForRetry] 把链恢复到建链时的状态：重试按钮调它再
///   [nextPlayable]，从头重探一遍，不原地重播同一个死地址；
/// - [preferSiteId]：作品自己记的站（如潮流）在它所属波次里排
///   到最前——存的地址死了，先探它自己的站，再探别的站。
/// - 单次 [nextPlayable] 调用有总预算（默认 45 秒）：预算耗尽时
///   尚未起跑的波次不再起跑、直接判无源，在途探活跑完、结果照收；
/// - 无番号的作品走标题模式：按标题搜全部可见站，取标题相符的命中
///   （每站首个）成链，其余流程相同；
/// - 每推一个候选前都查 [LocalStore.allowsSource] 并校验 profileEpoch
///   未变（与详情页 `_playCrossSite` 同一范式），用户切了身份立即停；
/// - 播放中途恢复耗尽时，播放器回调里继续调 [nextPlayable] 换下一个，
///   链耗尽才让播放器原错误界面留着；
/// - 来源信息只在内部流转，调用方绝不向界面暴露候选的站源身份。
class ActressPlayChain {
  ActressPlayChain({
    required this.repository,
    required this.store,
    required this.avId,
    this.titleQuery = '',
    this.candidateSites,
    CrossSiteProbeService? probeService,
    this.resolveTimeout = const Duration(seconds: 12),
    this.probeConcurrency = 6,
    this.titleHitsCap = 8,
    this.totalBudget = const Duration(seconds: 45),
    FeedProbeFetch? verifyFetch,
    this.verifyTimeout = const Duration(seconds: 8),
    this.preferSiteId,
  }) : verifyFetch = verifyFetch ?? probeStreamHead,
       _probeService =
           probeService ??
           CrossSiteProbeService(
             repository: repository,
             perSiteTimeout: const Duration(seconds: 10),
             eagerBudget: const Duration(seconds: 30),
             concurrency: 6,
             maxVersions: 1,
           ) {
    final plans = planCrossSiteRows(
      sites: candidateSites ?? store.visibleSources,
      siteVisible: store.siteVisible,
    );
    final fallbackOrder = <String, int>{
      for (var i = 0; i < actressFallbackSiteIds.length; i++)
        actressFallbackSiteIds[i]: i,
    };
    final fallbackPlans = <CrossSiteRowPlan>[];
    final missavPlans = <CrossSiteRowPlan>[];
    final eagerPlans = <CrossSiteRowPlan>[];
    final lazyPlans = <CrossSiteRowPlan>[];
    for (final plan in plans) {
      final siteId = plan.siteId;
      if (siteId == null) continue;
      // MissAV 先判（仍在懒查表里，跨站行显示口径不变）：进
      // MissAV 波，不进懒查波。
      if (siteId == actressMissavFirstSiteId) {
        missavPlans.add(plan);
      } else if (fallbackOrder.containsKey(siteId)) {
        fallbackPlans.add(plan);
      } else if (!plan.provider.lazy) {
        eagerPlans.add(plan);
      } else {
        lazyPlans.add(plan);
      }
    }
    fallbackPlans.sort(
      (a, b) => fallbackOrder[a.siteId]! - fallbackOrder[b.siteId]!,
    );
    _pendingFallback = fallbackPlans;
    _pendingMissav = missavPlans;
    _pendingEager = eagerPlans;
    _pendingLazy = lazyPlans;
    // 作品自己记的站排到它所属波次最前（不跨波次、不动 MJV 优先
    // 的波次顺序）：存的地址死了，先探它自己的站。
    final preferred = preferSiteId;
    if (preferred != null) {
      for (final pending in [
        _pendingFallback,
        _pendingMissav,
        _pendingEager,
        _pendingLazy,
      ]) {
        final index = pending.indexWhere((plan) => plan.siteId == preferred);
        if (index > 0) {
          pending.insert(0, pending.removeAt(index));
        }
      }
    }
    _initialFallback = List.of(_pendingFallback);
    _initialMissav = List.of(_pendingMissav);
    _initialEager = List.of(_pendingEager);
    _initialLazy = List.of(_pendingLazy);
  }

  final AppRepository repository;
  final LocalStore store;

  /// 探活番号：extractAvId 形态（如 SSIS-00123，保留原始前导零，
  /// 与 crossSiteHitMatches 的比对口径一致）。为空时走标题模式。
  final String avId;
  final String titleQuery;
  final List<SourceSite>? candidateSites;
  final CrossSiteProbeService _probeService;
  final Duration resolveTimeout;
  final int probeConcurrency;
  final int titleHitsCap;

  /// 单次 [nextPlayable] 调用的总预算：预算耗尽时尚未起跑的波次
  /// 不再起跑、直接判无源；在途探活跑到单站超时为止，结果照收。
  final Duration totalBudget;

  /// 直链预检的验活探针：取流地址首段字节；默认 [probeStreamHead]，
  /// 测试可注入假实现（见 actress_play_fallback_test.dart）。
  final FeedProbeFetch verifyFetch;

  /// 单条直链验活超时（resolve 超时之外另计）。
  final Duration verifyTimeout;

  /// 作品自己记的站 id（如 'chaoliu'）：在它所属波次里排最前。
  final String? preferSiteId;

  final _candidates = <ActressPlayCandidate>[];
  var _next = 0;
  late List<CrossSiteRowPlan> _pendingFallback;
  late List<CrossSiteRowPlan> _pendingMissav;
  late List<CrossSiteRowPlan> _pendingEager;
  late List<CrossSiteRowPlan> _pendingLazy;
  late List<CrossSiteRowPlan> _initialFallback;
  late List<CrossSiteRowPlan> _initialMissav;
  late List<CrossSiteRowPlan> _initialEager;
  late List<CrossSiteRowPlan> _initialLazy;
  var _titleWaveDone = false;

  /// 本轮实际试过的站 id（探活波次起跑过的站 + 预检过的候选站）：
  /// 链耗尽时调用方按它报“已试过 X 个站”。
  final _triedSources = <String>{};

  Set<String> get triedSources => Set.unmodifiable(_triedSources);

  /// 重试重探：把待探波次、候选队列与已试记录恢复到建链时的状态，
  /// 下一次 [nextPlayable] 从头再探一遍（重试按钮用；不复用上次
  /// 的死地址，也不复用上次已判死的候选）。
  void resetForRetry() {
    _pendingFallback = List.of(_initialFallback);
    _pendingMissav = List.of(_initialMissav);
    _pendingEager = List.of(_initialEager);
    _pendingLazy = List.of(_initialLazy);
    _candidates.clear();
    _next = 0;
    _titleWaveDone = false;
    _triedSources.clear();
  }

  bool get hasMore =>
      _next < _candidates.length ||
      _pendingFallback.isNotEmpty ||
      _pendingMissav.isNotEmpty ||
      _pendingEager.isNotEmpty ||
      _pendingLazy.isNotEmpty ||
      (!_titleWaveDone && avId.isEmpty && titleQuery.isNotEmpty);

  /// 取下一个可播候选：按链序预检，首个解出的返回；链耗尽返回 null。
  /// 已试过的候选不再试；[shouldStop] 为真时立即停（界面已取消）。
  /// 总预算 [totalBudget] 耗尽时尚未起跑的波次不再起跑，直接返回 null。
  Future<ActressPlayCandidate?> nextPlayable({
    required int profileEpoch,
    bool Function()? shouldStop,
  }) async {
    if (avId.isEmpty && titleQuery.isEmpty) return null;
    final stopwatch = Stopwatch()..start();
    bool overBudget() => stopwatch.elapsed >= totalBudget;
    bool stopRequested() => shouldStop?.call() == true || overBudget();
    while (true) {
      if (shouldStop?.call() == true) return null;
      if (store.profileEpoch != profileEpoch) return null;
      if (_next < _candidates.length) {
        final candidate = _candidates[_next++];
        if (!store.allowsSource(candidate.detail.drama.source)) continue;
        if (await _resolves(candidate, profileEpoch)) return candidate;
        continue;
      }
      if (overBudget()) return null;
      if (avId.isNotEmpty) {
        if (_pendingFallback.isNotEmpty) {
          final found = await _probeWave(_pendingFallback, stopRequested);
          _candidates.addAll(found);
          if (found.isNotEmpty) continue;
        }
        if (overBudget()) return null;
        // MissAV 波：兜底波无果后、eager 波之前。UMSO-660 这类
        // 兜底站没有的番号只有 MissAV 有，eager 波 24 站会吃
        // 光预算，不提前就永远探不到。
        if (_pendingMissav.isNotEmpty) {
          final found = await _probeWave(_pendingMissav, stopRequested);
          _candidates.addAll(found);
          if (found.isNotEmpty) continue;
        }
        if (overBudget()) return null;
        if (_pendingEager.isNotEmpty) {
          final found = await _probeWave(_pendingEager, stopRequested);
          _candidates.addAll(found);
          if (found.isNotEmpty) continue;
        }
        if (overBudget()) return null;
        if (_pendingLazy.isNotEmpty) {
          final found = await _probeWave(_pendingLazy, stopRequested);
          _candidates.addAll(found);
          if (found.isNotEmpty) continue;
        }
        return null;
      }
      if (!_titleWaveDone) {
        _titleWaveDone = true;
        final found = await _probeTitleWave(stopRequested);
        _candidates.addAll(found);
        if (found.isNotEmpty) continue;
      }
      return null;
    }
  }

  Future<bool> _resolves(
    ActressPlayCandidate candidate,
    int profileEpoch,
  ) async {
    final episodes = candidate.detail.episodes;
    if (candidate.episodeIndex < 0 ||
        candidate.episodeIndex >= episodes.length) {
      return false;
    }
    _triedSources.add(candidate.detail.drama.source);
    try {
      final plan = await repository
          .resolve(candidate.detail.drama, episodes[candidate.episodeIndex])
          .timeout(resolveTimeout);
      if (store.profileEpoch != profileEpoch) return false;
      // 解析型计划（壳解析/嗅探）验不了活：先放行，播失败时播放器
      // 再经 onPlaybackExhausted 换下一条，不把解析型候选判死。
      if (plan.needsParse) return true;
      final url = plan.url.trim();
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !(uri.scheme == 'http' || uri.scheme == 'https') ||
          uri.host.isEmpty) {
        return false;
      }
      // 直链必须验活（首分片/Range 206）才进播放器：解出死地址
      // 也算失败，静默换下一条，不开黑屏播放器。验活带取流回的
      // 头（Referer/UA 与播放器实际用的同一份）。
      final response = await verifyFetch(url, plan.headers, verifyTimeout);
      if (store.profileEpoch != profileEpoch) return false;
      return feedProbePlayable(uri, response);
    } catch (_) {
      return false;
    }
  }

  /// 探一波计划：工作池并发 [probeConcurrency]；一旦已有命中且排在
  /// 它前面的计划都已出结果，就不再起跑新计划（在途的跑完，结果照收），
  /// 命中按计划顺序成链。起跑过的计划从 [pending] 里挪走。
  Future<List<ActressPlayCandidate>> _probeWave(
    List<CrossSiteRowPlan> pending,
    bool Function()? shouldStop,
  ) async {
    if (pending.isEmpty) return const [];
    final plans = List.of(pending);
    pending.clear();
    final results = <String, CrossSiteProbeResult>{};
    final resolved = <String>{};
    final order = <String, int>{
      for (var i = 0; i < plans.length; i++) plans[i].provider.id: i,
    };
    var next = 0;
    var stopStarting = false;

    bool exitCondition() {
      var bestFound = 1 << 30;
      for (final entry in results.entries) {
        if (entry.value.status == CrossSiteProbeStatus.found) {
          final index = order[entry.key] ?? 1 << 30;
          if (index < bestFound) bestFound = index;
        }
      }
      if (bestFound == 1 << 30) return false;
      for (var i = 0; i < bestFound; i++) {
        if (!resolved.contains(plans[i].provider.id)) return false;
      }
      return true;
    }

    Future<void> worker() async {
      while (!stopStarting) {
        if (shouldStop?.call() == true) return;
        if (next >= plans.length) return;
        final plan = plans[next++];
        final siteId = plan.siteId;
        if (siteId == null) {
          resolved.add(plan.provider.id);
          continue;
        }
        _triedSources.add(siteId);
        final result = await _probeService.probeProvider(
          plan.provider,
          siteId,
          avId,
        );
        results[plan.provider.id] = result;
        resolved.add(plan.provider.id);
        if (exitCondition()) stopStarting = true;
      }
    }

    final workers = probeConcurrency < plans.length
        ? probeConcurrency
        : plans.length;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    // 没起跑的计划放回待探列，下次 nextPlayable 接着探。
    for (var i = next; i < plans.length; i++) {
      pending.add(plans[i]);
    }
    final out = <ActressPlayCandidate>[];
    for (final plan in plans) {
      final result = results[plan.provider.id];
      if (result == null || result.status != CrossSiteProbeStatus.found) {
        continue;
      }
      if (result.versions.isEmpty) continue;
      final version = result.versions.first;
      if (version.lines.isEmpty) continue;
      out.add(
        ActressPlayCandidate(
          detail: version.detail,
          episodeIndex: version.lines.first.episodeIndex,
        ),
      );
    }
    return out;
  }

  /// 标题模式一波：按标题搜全部可见站，标题相符的命中每站取首个，
  /// 取详情成链。
  Future<List<ActressPlayCandidate>> _probeTitleWave(
    bool Function()? shouldStop,
  ) async {
    final siteIds = actressSearchSiteIds(store);
    if (siteIds.isEmpty) return const [];
    List<Drama> hits;
    try {
      final page = await repository.searchAcross(siteIds, titleQuery);
      hits = page.items;
    } catch (_) {
      return const [];
    }
    final queryKey = actressTitleKey(titleQuery);
    if (queryKey.length < 2) return const [];
    final seenSources = <String>{};
    final picked = <Drama>[];
    for (final hit in hits) {
      if (picked.length >= titleHitsCap) break;
      if (actressTextBlocked(hit.title)) continue;
      if (!actressTitleKey(hit.title).contains(queryKey)) continue;
      if (!seenSources.add(hit.source)) continue;
      picked.add(hit);
    }
    for (final hit in picked) {
      _triedSources.add(hit.source);
    }
    final out = <ActressPlayCandidate>[];
    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (shouldStop?.call() == true) return;
        if (next >= picked.length) return;
        final hit = picked[next++];
        try {
          final detail = await repository.detail(hit);
          final lines = crossSiteLinesOf(detail);
          if (lines.isEmpty) continue;
          out.add(
            ActressPlayCandidate(
              detail: detail,
              episodeIndex: lines.first.episodeIndex,
            ),
          );
        } catch (_) {
          // 某命中取详情失败，换下一个，不拖垮整链。
        }
      }
    }

    final workers = probeConcurrency < picked.length
        ? probeConcurrency
        : picked.length;
    if (workers <= 0) return const [];
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return out;
  }
}

/// 作品起播用的番号：优先从显示番号里现取 extractAvId 形态（保留
/// 原始前导零，与探活比对口径一致），取不到用显示番号原文，
/// 再取不到从标题里现取，都没有返回 ''（走标题模式）。
String actressPlayAvId(ActressWork work) {
  final fromCode = work.codeDisplay.isNotEmpty
      ? extractAvId(title: work.codeDisplay)
      : null;
  if (fromCode != null) return fromCode;
  if (work.codeDisplay.isNotEmpty) return work.codeDisplay;
  return extractAvId(title: work.title) ?? '';
}
