import 'dart:async';

import 'actress_database.dart';
import 'actress_models.dart';
import 'actress_roster_sources.dart';
import 'actress_adapter_repository.dart';
import 'actress_crosssite_probe.dart';
import 'actress_adapter_store.dart';
import 'actress_adapter_models.dart';

/// 全站搜索用的站源 id：可见视频站（与跨站探活同一口径，去网盘站）。
List<String> actressSearchSiteIds(LocalStore store) => [
  for (final site in store.visibleSources)
    if (site.isVideoSection &&
        !site.id.startsWith('cloud:') &&
        store.siteVisible(site.id))
      site.id,
];

/// 双键合流补全：人物页打开时后台跑，把站源搜索结果叠加进本地作品。
///
/// - 名字路：按显示名（+ 首个别名）搜全部可见站，用流式搜索
///   `searchAcrossProgressive`，每站结果一到就附封面并通知刷新，
///   不等整轮搜完；命中按番号对上本地作品后附封面；番号不在本地
///   的命中新增为跨站发现作品（只限带番号的命中，无番号命中只附
///   到标题相同的已有行，不新增）；
/// - whos 路（默认关闭）：名字路一无所获时，用 whos `?name=` 追加
///   找人、拉该人作品清单与简介；封面只在 XOR 开关打开时才有，
///   简介经硬线过滤后写库；源级开关与本处开关须同时打开才跑；
/// - 番号路：对仍无封面的作品按番号逐个搜（每轮上限 120 个、并发 6，
///   每轮墙钟上限 60 秒：超时不再起跑新作品，已贴上的保留、下一轮
///   续跑），只补已有行，不新增；
/// - 补全写库按（站，归一化番号）去重（无番号按站+标题键），同番号
///   两站各留一条；搜索结果展示仍一部一卡（显示层去重，不动）；
/// - 零作品的人也照常跑名字路：按名搜全站，带番号的命中新增进库，
///   搜不到保持为空、不造假数据；该轮开始时作品为空且结束时仍为空
///   的返回 false（不算完成，调用方不记 enrichedAt）；
/// - 搜过的结果写进库；已记 enrichedAt 且全部作品已有封面时下次
///   打开不再跑（[ActressPerson.enrichedAt] 非空且无无封面作品才跳
///   过——只看 enrichedAt 会把同步窗口期打开过的人永久锁死在无封
///   面状态）；失败的站静默跳过，不弹错、不挡列表；
/// - 来源信息只写进库内字段供封面解析用，界面绝不显示。
class ActressEnrichment {
  ActressEnrichment({
    required this.repository,
    required this.store,
    required this.db,
    this.concurrency = 6,
    this.codeSearchCap = 120,
    this.nameHitsCap = 100,
    this.codeRoundBudget = const Duration(seconds: 60),
  });

  final AppRepository repository;
  final LocalStore store;
  final ActressDatabase db;
  final int concurrency;
  final int codeSearchCap;
  final int nameHitsCap;

  /// 番号路每轮墙钟上限：超时不再起跑新作品（已贴上的保留），
  /// 本轮返回未完成、下次打开续跑。
  final Duration codeRoundBudget;

  /// 跑一轮补全。返回 true 表示本轮已把能查的都查完（调用方记
  /// enrichedAt，下次打开符合跳过条件时不再跑）；返回 false 表示
  /// 本轮没查完（番号路触到上限或中途取消），下次打开继续。
  /// 零作品的人也照常跑名字路（2026-11-20 用户令：没有也要爬取
  /// 新增），搜到就新增进库；开始时零作品、结束时仍零作品的返回
  /// false：返回 true 会让调用方记 enrichedAt，作品随后进来也再
  /// 也不补（中毒标记，见 actress_cover_fix_test）。
  ///
  /// whos 追加输入默认关闭：[whosDetailEnabled] 为 false（默认）或
  /// 未传 [whosSource]/[whosFetch] 时，行为与此前一字不差。
  ///
  /// [prioritizeWorkIds]：当前页正在看的作品 id——番号路先补这批，
  /// 再补其余无封面作品（cap 120 按 id ASC 取，翻页看到的新作品
  /// 本来永远排不到 cap 里，UMSO-660 这类新同步行就是这么一直
  /// 没封面的）。不传时行为与此前一字不差。
  Future<bool> enrichPerson(
    ActressPerson person, {
    bool Function()? isCancelled,
    void Function()? onChanged,
    WhosRosterSource? whosSource,
    ActressHttpFetch? whosFetch,
    bool whosDetailEnabled = false,
    List<int> prioritizeWorkIds = const [],
  }) async {
    final works = await _allWorks(person.localId);
    final startedEmpty = works.isEmpty;
    // 已补过且全部作品已有封面：跳过。跳过条件不能只看
    // enrichedAt：同步窗口期打开过的人会被记上 enrichedAt，作品
    // 进来后仍有无封面作品时必须重新补。零作品时“全部已有封面”
    // 在空集上恒真，不能凭它跳过——零作品的人必须跑名字路搜。
    if (!startedEmpty &&
        person.enrichedAt != null &&
        !works.any((work) => !work.hasCover)) {
      return true;
    }
    if (isCancelled?.call() == true) return false;

    final siteIds = actressSearchSiteIds(store);
    if (siteIds.isEmpty) return false;
    var changedAt = DateTime.fromMillisecondsSinceEpoch(0);
    void notifyChanged() {
      final now = DateTime.now();
      if (now.difference(changedAt).inMilliseconds < 500) return;
      changedAt = now;
      onChanged?.call();
    }

    final attachedByName = await _enrichByName(
      person,
      siteIds,
      isCancelled,
      notifyChanged,
    );
    if (isCancelled?.call() == true) return false;

    if (whosDetailEnabled &&
        whosSource != null &&
        whosFetch != null &&
        attachedByName == 0) {
      await _enrichByWhos(person, whosSource, whosFetch, isCancelled);
      if (isCancelled?.call() == true) return false;
    }

    final refreshed = await _allWorks(person.localId);
    // 开始时零作品、名字路也没新增：本轮不算完成，调用方不得记
    // enrichedAt；下次打开/下轮叠加继续搜。
    if (startedEmpty && refreshed.isEmpty) return false;
    final uncovered = refreshed
        .where((work) => !work.hasCover && work.codeKey.isNotEmpty)
        .toList();
    if (prioritizeWorkIds.isNotEmpty) {
      final priority = prioritizeWorkIds.toSet();
      uncovered.sort((a, b) {
        final ap = priority.contains(a.id) ? 0 : 1;
        final bp = priority.contains(b.id) ? 0 : 1;
        return ap - bp;
      });
    }
    final capped = uncovered.length > codeSearchCap;
    final targets = capped ? uncovered.take(codeSearchCap).toList() : uncovered;
    final codeDone = await _enrichByCode(
      person,
      targets,
      siteIds,
      isCancelled,
      notifyChanged,
    );
    if (isCancelled?.call() == true) return false;
    onChanged?.call();
    return !capped && codeDone;
  }

  Future<List<ActressWork>> _allWorks(int personId) async {
    const pageSize = 500;
    final out = <ActressWork>[];
    var offset = 0;
    while (true) {
      final page = await db.worksForPerson(
        personId,
        offset: offset,
        limit: pageSize,
      );
      if (page.isEmpty) break;
      out.addAll(page);
      if (page.length < pageSize) break;
      offset += page.length;
    }
    return out;
  }

  /// 名字路：流式搜索，每站结果一到就附封面并通知刷新，不等整轮
  /// 搜完才贴第一张封面。返回带封面的有效命中数（whos 路是否
  /// 追加以此为准）。每站命中各取前 [nameHitsCap] 条（与旧整轮
  /// 上限同一数值，逐站计）；对库的附着口径与旧整轮一字不差。
  Future<int> _enrichByName(
    ActressPerson person,
    List<String> siteIds,
    bool Function()? isCancelled,
    void Function() notifyChanged,
  ) async {
    var useful = 0;
    final queries = <String>[person.displayName];
    if (person.aliases.isNotEmpty) queries.add(person.aliases.first);
    for (final query in queries) {
      if (isCancelled?.call() == true) return useful;
      if (query.trim().isEmpty) continue;
      // 在途的贴附任务：onSite 是同步回调，贴附本身是异步的，
      // 先收进 pending、整轮结束前等它们全部落库，useful 计数
      // 才准；贴附一跑起来就调 notifyChanged，不等整轮。
      final pending = <Future<int>>[];
      try {
        await repository.searchAcrossProgressive(
          siteIds,
          query,
          onSite: (source, hits) {
            pending.add(
              _attachNameHits(person, hits, isCancelled, notifyChanged),
            );
          },
          shouldStop: isCancelled,
        );
      } catch (_) {
        continue;
      }
      for (final delta in await Future.wait(pending)) {
        useful += delta;
      }
      notifyChanged();
    }
    return useful;
  }

  /// 名字路一批站源命中：按番号/标题对上本地作品后附封面，
  /// 返回其中带封面的有效命中数。
  Future<int> _attachNameHits(
    ActressPerson person,
    List<Drama> hits,
    bool Function()? isCancelled,
    void Function() notifyChanged,
  ) async {
    var useful = 0;
    var attached = 0;
    for (final hit in hits.take(nameHitsCap)) {
      if (isCancelled?.call() == true) break;
      if (actressTextBlocked(hit.title)) continue;
      final code = extractAvId(
        title: hit.title,
        id: hit.id,
        sourceId: hit.sourceId,
      );
      final codeKey = code == null ? '' : normalizeAvCode(code);
      await db.attachCover(
        personId: person.localId,
        codeKey: codeKey,
        titleKey: actressTitleKey(hit.title),
        codeDisplay: code ?? '',
        title: hit.title,
        coverSource: hit.source,
        coverDramaId: hit.id,
        coverUrl: hit.cover,
        site: hit.source,
        // 无番号的命中只附已有行，不新增（防名字搜索的杂标题淹没列表）。
        insertIfMissing: codeKey.isNotEmpty,
      );
      attached++;
      if (hit.cover.isNotEmpty) useful++;
      if (attached % 10 == 0) notifyChanged();
    }
    notifyChanged();
    return useful;
  }

  /// whos 路：已有 whos 身份直接用，否则 `?name=` 搜人按名字键匹配；
  /// 拉作品清单（缺行补行、有封面的给已有行补封面）与简介写库。
  /// 任一步失败静默跳过，不拖番号路。
  Future<void> _enrichByWhos(
    ActressPerson person,
    WhosRosterSource whosSource,
    ActressHttpFetch whosFetch,
    bool Function()? isCancelled,
  ) async {
    try {
      var slug = person.whosSlug;
      if (slug.isEmpty) {
        final queries = <String>[person.displayName];
        if (person.aliases.isNotEmpty) queries.add(person.aliases.first);
        final wanted = <String>{
          actressNameKey(person.displayName),
          for (final alias in person.aliases) actressNameKey(alias),
        };
        for (final query in queries) {
          if (isCancelled?.call() == true) return;
          if (query.trim().isEmpty) continue;
          final page = await whosSource.fetchSearchByName(
            query,
            fetch: whosFetch,
          );
          for (final candidate in page.persons) {
            final keys = <String>{
              for (final variant in actressNameVariants(candidate.name))
                actressNameKey(variant),
            };
            if (keys.any(wanted.contains)) {
              slug = candidate.sourceId;
              break;
            }
          }
          if (slug.isNotEmpty) break;
        }
      }
      if (slug.isEmpty || isCancelled?.call() == true) return;
      try {
        final about = await whosSource.fetchPersonAbout(slug, fetch: whosFetch);
        if (about.isNotEmpty) await db.setPersonAbout(person.localId, about);
      } catch (_) {}
      if (isCancelled?.call() == true) return;
      final films = await whosSource.fetchFilms(slug, fetch: whosFetch);
      if (films.isEmpty) return;
      await db.upsertWorks(
        person.localId,
        films,
        coverSource: actressRosterCoverSource(ActressRosterSourceId.whos),
        site: 'whos',
      );
      for (final film in films) {
        if (film.coverUrl.isEmpty) continue;
        await db.attachCover(
          personId: person.localId,
          codeKey: film.codeKey,
          titleKey: film.titleKey,
          coverSource: 'whos',
          coverDramaId: film.detailUrl,
          coverUrl: film.coverUrl,
          site: 'whos',
          insertIfMissing: false,
        );
      }
    } catch (_) {}
  }

  /// 番号路：先查兜底 MJV 系（[actressFallbackSiteIds] 里可见的站），
  /// 有带封面的匹配命中就附上、不再查全站；取不到再走全站搜索。
  /// 去重与附着口径不变（归一化番号 + codeKey）。
  /// 返回 true 表示本轮目标全部起跑过（调用方可记完成），false
  /// 表示墙钟上限到了、还有目标没起跑（下次打开续跑）。
  Future<bool> _enrichByCode(
    ActressPerson person,
    List<ActressWork> targets,
    List<String> siteIds,
    bool Function()? isCancelled,
    void Function() notifyChanged,
  ) async {
    final fallbackIds = [
      for (final id in actressFallbackSiteIds)
        if (siteIds.contains(id)) id,
    ];
    var next = 0;
    var attached = 0;
    var stoppedEarly = false;
    final startedAt = DateTime.now();

    /// 在 [hits] 里找第一个带封面且番号匹配的命中，附到 [work] 上。
    Future<bool> attachFirstCover(ActressWork work, List<Drama> hits) async {
      final query = work.codeDisplay.isNotEmpty
          ? work.codeDisplay
          : work.codeKey;
      for (final hit in hits) {
        if (actressTextBlocked(hit.title)) continue;
        if (hit.cover.isEmpty) continue;
        if (!crossSiteHitMatches(title: hit.title, id: hit.id, avId: query)) {
          continue;
        }
        await db.attachCover(
          personId: person.localId,
          codeKey: work.codeKey,
          titleKey: work.titleKey,
          coverSource: hit.source,
          coverDramaId: hit.id,
          coverUrl: hit.cover,
          site: hit.source,
          insertIfMissing: false,
        );
        attached++;
        if (attached % 10 == 0) notifyChanged();
        return true;
      }
      return false;
    }

    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() == true) return;
        if (next >= targets.length) return;
        // 每轮墙钟上限：超时不再起跑新作品，已贴上的保留、
        // 下次打开续跑；在途的搜索跑完，结果照收。
        if (DateTime.now().difference(startedAt) > codeRoundBudget) {
          stoppedEarly = true;
          return;
        }
        final work = targets[next++];
        final query = work.codeDisplay.isNotEmpty
            ? work.codeDisplay
            : work.codeKey;
        if (query.isEmpty) continue;
        if (fallbackIds.isNotEmpty) {
          try {
            final page = await repository.searchAcross(fallbackIds, query);
            if (await attachFirstCover(work, page.items)) continue;
          } catch (_) {
            // 兜底站查失败，回落全站搜索，不丢这部作品。
          }
          if (isCancelled?.call() == true) return;
        }
        List<Drama> hits;
        try {
          final page = await repository.searchAcross(siteIds, query);
          hits = page.items;
        } catch (_) {
          continue;
        }
        await attachFirstCover(work, hits);
      }
    }

    final workers = concurrency < targets.length ? concurrency : targets.length;
    if (workers <= 0) return true;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return !stoppedEarly;
  }
}
