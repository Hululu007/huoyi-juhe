import 'dart:async';

import 'actress_adapter_repository.dart';
import 'actress_adapter_models.dart';

/// 跨站选线路：详情页按番号向多家站源探活，平台→版本→线路三级。
/// 规格见 ~/workspace/moyi_crosssite_probe/SPEC.md：只复用魔蚁现有源
/// 体系（searchAcross + detail），不另写解析器；只探可见站；无番号
/// 的片不显示；探活失败只标状态，绝不挡本源线路与海报播放。

/// 番号提取：只认“字母+数字”结构的番号，返回归一化形式 `前缀-数字`
/// （如 HMN-927、FC2-PPV-1234567、1PONDO-102726）。找不到返回 null。
///
/// 标题里可接受无分隔符的写法（如 SSIS123）；站源 id 里只认带分隔符
/// 的写法，避免把网址、哈希里的字母数字串误认成番号。
String? extractAvId({
  required String title,
  String id = '',
  String sourceId = '',
}) {
  for (final entry in [(title, false), (id, true), (sourceId, true)]) {
    final found = _extractAvIdFromText(entry.$1, requireSeparator: entry.$2);
    if (found != null) return found;
  }
  return null;
}

/// 标题里常见的非番号词：遇到这些前缀不认作番号。
const _avIdStopPrefixes = {
  'EP',
  'HD',
  'SD',
  'UHD',
  'FHD',
  'TV',
  'PV',
  'MV',
  'CD',
  'DVD',
  'BD',
  'AV',
  'ID',
  'URL',
  'MP',
};

String? _extractAvIdFromText(String text, {required bool requireSeparator}) {
  if (text.isEmpty) return null;
  // FC2-PPV-1234567：先认全形，避免只截到 PPV-1234567。
  final fc2 = RegExp(
    r'fc2[-\s_]?ppv[-\s_]?(\d{5,7})',
    caseSensitive: false,
  ).allMatches(text);
  for (final match in fc2) {
    if (_hasCleanBounds(text, match)) {
      return 'FC2-PPV-${match.group(1)}';
    }
  }
  // 数字开头：1PONDO-102726、259LUXU-1234、10MUSUME-123456。
  final digitLeading = RegExp(
    r'(\d{1,4}[a-z]{2,6})[-\s_]?(\d{3,7})',
    caseSensitive: false,
  ).allMatches(text);
  for (final match in digitLeading) {
    if (!_hasCleanBounds(text, match)) continue;
    final prefix = match.group(1)!.toUpperCase();
    final number = match.group(2)!;
    if (requireSeparator && !_matchHasSeparator(match)) continue;
    return '$prefix-$number';
  }
  // 标准形：SSIS-123、HMN-927、SIRO-1234。
  final standard = RegExp(
    r'([a-z]{2,7})[-\s_]?(\d{3,7})',
    caseSensitive: false,
  ).allMatches(text);
  for (final match in standard) {
    if (!_hasCleanBounds(text, match)) continue;
    final prefix = match.group(1)!.toUpperCase();
    if (_avIdStopPrefixes.contains(prefix)) continue;
    final number = match.group(2)!;
    if (requireSeparator && !_matchHasSeparator(match)) continue;
    return '$prefix-$number';
  }
  return null;
}

/// 匹配两端不能紧贴字母或数字，避免从长串里截一段误认。
bool _hasCleanBounds(String text, RegExpMatch match) {
  if (match.start > 0 && _isAlphanumeric(text.codeUnitAt(match.start - 1))) {
    return false;
  }
  if (match.end < text.length && _isAlphanumeric(text.codeUnitAt(match.end))) {
    return false;
  }
  return true;
}

bool _isAlphanumeric(int code) =>
    (code >= 0x30 && code <= 0x39) ||
    (code >= 0x41 && code <= 0x5A) ||
    (code >= 0x61 && code <= 0x7A);

bool _matchHasSeparator(RegExpMatch match) {
  final text = match.group(0)!;
  return text.contains('-') || text.contains('_') || text.contains(' ');
}

/// 搜索命中是否与番号同一部片：标题或 id 里含番号核心（去分隔符比对）。
bool crossSiteHitMatches({
  required String title,
  required String id,
  required String avId,
}) {
  final core = avId.replaceAll('-', '').toUpperCase();
  String norm(String value) =>
      value.toUpperCase().replaceAll(RegExp(r'[-_\s]'), '');
  return norm(title).contains(core) || norm(id).contains(core);
}

/// 版本名：命中标题/id 里含番号的那段代号（如 HMN-927-LADA），
/// 找不到代号时回落番号本身。
String crossSiteVersionLabel({
  required String title,
  required String id,
  required String avId,
}) {
  final core = avId.replaceAll('-', '').toUpperCase();
  for (final text in [title, id]) {
    final token = _codeTokenContaining(text, core);
    if (token != null) return token;
  }
  return avId;
}

String? _codeTokenContaining(String text, String core) {
  final tokens = RegExp(
    r'[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)+|[A-Za-z]+\d+',
  ).allMatches(text);
  for (final match in tokens) {
    final raw = match.group(0)!;
    final norm = raw.toUpperCase().replaceAll(RegExp(r'[-_]'), '');
    if (!norm.contains(core)) continue;
    return raw.toUpperCase().replaceAll('_', '-');
  }
  return null;
}

/// 跨站探活的一家平台：一行对应一个站源（[siteIds] 只有一项时
/// 取首项；无源平台 [siteIds] 为空，界面显示“未接入”）。
class CrossSiteProvider {
  const CrossSiteProvider({
    required this.id,
    required this.name,
    required this.siteIds,
    required this.lazy,
  });

  final String id;
  final String name;
  final List<String> siteIds;

  /// 懒查：慢站/盾站与超出自动探活上限的站，点一下才查。
  final bool lazy;
}

/// 探活优先序：老牌番号站先探（与旧固定 6 家同一顺序），再按
/// 🔞名、其余站的顺序探。MissAV 四个镜像 id 都在表里——新模型
/// 下它们是四个独立站源、各占一行，不再是同一行的回落链。
const crossSitePrioritySiteIds = <String>[
  'javmenu',
  'avdb',
  'memojav',
  'chaoliu',
  'jar:zakatv:zakav01',
  'jar:missav30:ZakaMissav',
  'jar:missav30:ZakaMissavOff',
  'jar:zakatv:ZakaMirror',
  'jar:missav30:missavt',
  'jar:zakatv:ZakaJable',
];

/// 演员库兜底站序（用户令）：MJV 一家优先——jar、py、Go 槽；18AV
/// 双生站（与 MJV 同系统、同一内容库）作同库替补排在 MJV 之后；
/// 其余站再后。id 口径与站源表一致：jar 站为 `jar:zakatv:<key>`，
/// MissAV 三站已挪到 `jar:missav30:<key>`（2026-11-19）。
/// MJV 在树里只有一个域名 https://mjv011.com，没有多域名表。
/// 演员库点卡探查与番号补封面都按此序先查兜底站。
const actressFallbackSiteIds = <String>[
  'jar:zakatv:ZakaMjv011',
  'chaoliu',
  'v_mjv011',
  'jar:zakatv:av18avmcg',
  'jar:zakatv:av18av',
];

/// 女优库点播先探 MissAV 主站（2026-11-21，修 UMSO-660 点播不到）：
/// MissAV 是最全的 JAV 库；兜底 MJV/18AV 没有的番号（如 PRESTIGE
/// 的 UMSO-660）多半只有它有，只探主站，不探 Off/missavt 镜像。
/// 仍留在 [crossSiteLazySiteIds] 里（跨站行显示口径不变），只在
/// 女优库点播链里提前一波探——不能直接塞进兜底波（兜底波内并行
/// 等全部在途跑完，MissAV 有盾、慢，会拖慢 MJV 命中的常见情况）。
const actressMissavFirstSiteId = 'jar:missav30:ZakaMissav';

/// 慢站/盾站：永远懒查，不占自动探活名额（旧模型同口径）。
const crossSiteLazySiteIds = <String>{
  'jar:missav30:ZakaMissav',
  'jar:missav30:ZakaMissavOff',
  'jar:zakatv:ZakaMirror',
  'jar:missav30:missavt',
  'jar:zakatv:ZakaJable',
};

/// 自动探活上限：超出名额的可见站只显示“点击查询”行，点一下才探。
const crossSiteEagerCap = 24;

/// 尚无源的平台：源没到之前行状态保持“未接入”，绝不伪造已接入。
/// （AVDB、MemoJav 的 py 源已于 2026-11-14 注册进树，两家已接通，
/// 不再列在这里；此表留给将来其他无源平台。）
const crossSiteUnconnectedProviders = <CrossSiteProvider>[];

/// 一行探活计划：[siteId] 为 null 表示该平台在魔蚁里没有对应站源
/// （显示“未接入”）；站源存在但被用户藏起来的平台不在计划里，
/// 整行不显示（只探可见站，与全局搜索、轮播混成人站同一口径）。
class CrossSiteRowPlan {
  const CrossSiteRowPlan({required this.provider, this.siteId});

  final CrossSiteProvider provider;
  final String? siteId;
}

/// 从可见站源表里排出探活计划：只取视频区站源（py、jar、Go 核站
/// 都在站源表里），去掉网盘站源（`cloud:` 前缀，见
/// CloudDriveEngine.isCloudSource 的同一约定）与当前正在看的站
/// （跨站线路只取“其他站点”），再按优先序/🔞名/其余站排序；
/// 慢站与超出 [eagerCap] 名额的站标懒查；无源平台行（如有）附在末尾。
List<CrossSiteRowPlan> planCrossSiteRows({
  required List<SourceSite> sites,
  required bool Function(String siteId) siteVisible,
  String currentSourceId = '',
  int eagerCap = crossSiteEagerCap,
}) {
  final candidates = <SourceSite>[];
  for (final site in sites) {
    if (!site.isVideoSection) continue;
    if (site.id.startsWith('cloud:')) continue;
    if (site.id == currentSourceId) continue;
    if (!siteVisible(site.id)) continue;
    candidates.add(site);
  }
  final priority = <String, int>{
    for (var i = 0; i < crossSitePrioritySiteIds.length; i++)
      crossSitePrioritySiteIds[i]: i,
  };
  int tier(SourceSite site) {
    if (priority.containsKey(site.id)) return 0;
    if (site.name.contains('🔞')) return 1;
    return 2;
  }

  final indexed = [
    for (var i = 0; i < candidates.length; i++) (i, candidates[i]),
  ];
  indexed.sort((a, b) {
    final tierA = tier(a.$2);
    final tierB = tier(b.$2);
    if (tierA != tierB) return tierA - tierB;
    if (tierA == 0) {
      return priority[a.$2.id]! - priority[b.$2.id]!;
    }
    return a.$1 - b.$1;
  });
  final ordered = [for (final entry in indexed) entry.$2];
  final plans = <CrossSiteRowPlan>[];
  var eagerUsed = 0;
  for (final site in ordered) {
    final lazy =
        crossSiteLazySiteIds.contains(site.id) || eagerUsed >= eagerCap;
    if (!lazy) eagerUsed++;
    plans.add(
      CrossSiteRowPlan(
        provider: CrossSiteProvider(
          id: site.id,
          name: site.name,
          siteIds: [site.id],
          lazy: lazy,
        ),
        siteId: site.id,
      ),
    );
  }
  for (final provider in crossSiteUnconnectedProviders) {
    plans.add(CrossSiteRowPlan(provider: provider));
  }
  return plans;
}

/// 展示排序：探到线路的行置顶、按探活耗时从快到慢（排第一的即
/// “推荐”）；其余行保持计划顺序。只推荐不自动播。
List<CrossSiteRowPlan> sortCrossSitePlansForDisplay(
  List<CrossSiteRowPlan> plans,
  Map<String, CrossSiteProbeResult> results,
) {
  final found = <CrossSiteRowPlan>[];
  final rest = <CrossSiteRowPlan>[];
  for (final plan in plans) {
    final result = results[plan.provider.id];
    if (result?.status == CrossSiteProbeStatus.found) {
      found.add(plan);
    } else {
      rest.add(plan);
    }
  }
  found.sort(
    (a, b) => results[a.provider.id]!.latency.compareTo(
      results[b.provider.id]!.latency,
    ),
  );
  return [...found, ...rest];
}

/// 一条可播线路：某版本详情里同一线路名（flag）下的首集。
class CrossSiteLine {
  const CrossSiteLine({required this.label, required this.episodeIndex});

  final String label;
  final int episodeIndex;
}

/// 一个版本：一次搜索命中取详情后的全部线路。
class CrossSiteVersion {
  const CrossSiteVersion({
    required this.label,
    required this.detail,
    required this.lines,
  });

  final String label;
  final DramaDetail detail;
  final List<CrossSiteLine> lines;
}

enum CrossSiteProbeStatus {
  /// 懒查平台尚未点按。
  lazy,

  /// 正在探活。
  probing,

  /// 探到可播线路。
  found,

  /// 已探活，无此片的线路（标 ×）。
  empty,

  /// 探活失败/超时（标 ×，点按重试；不弹错、不挡主链）。
  failed,

  /// 魔蚁里没有该平台的对应站源（显示“未接入”）。
  unavailable,
}

class CrossSiteProbeResult {
  const CrossSiteProbeResult({
    required this.provider,
    required this.siteId,
    required this.status,
    this.versions = const [],
    this.latency = Duration.zero,
  });

  final CrossSiteProvider provider;
  final String siteId;
  final CrossSiteProbeStatus status;
  final List<CrossSiteVersion> versions;

  /// 本次探活耗时（搜索 + 详情）：展示排序里“响应快的在前”的依据。
  final Duration latency;
}

/// 详情集按线路名（episode raw 的 flag，jar/py 详情都带）分组，
/// 每组取首集作为该线路的起播集；无 flag 信息时整部片算一条“正片”。
List<CrossSiteLine> crossSiteLinesOf(DramaDetail detail) {
  final lines = <CrossSiteLine>[];
  final seen = <String>{};
  for (var i = 0; i < detail.episodes.length; i++) {
    final flag = (detail.episodes[i].raw['flag'] as String? ?? '').trim();
    final label = flag.isEmpty ? '正片' : flag;
    if (seen.add(label)) {
      lines.add(CrossSiteLine(label: label, episodeIndex: i));
    }
  }
  return lines;
}

/// 跨站探活服务：只走 [AppRepository] 现有接口（searchAcross +
/// detail），不另写解析器。单站超时 + 总预算双重兜底，任何失败
/// 都只落到 failed 状态，不抛错到界面；结果带耗时供排序。
class CrossSiteProbeService {
  CrossSiteProbeService({
    required this.repository,
    this.perSiteTimeout = const Duration(seconds: 20),
    this.eagerBudget = const Duration(seconds: 60),
    this.concurrency = 4,
    this.maxVersions = 3,
  });

  final AppRepository repository;
  final Duration perSiteTimeout;

  /// 自动探活波次的总预算：预算耗尽时尚未起跑的计划不再起跑，
  /// 调用方将其改走懒查（“点击查询”）；已起跑的探活跑到单站
  /// 超时为止，结果照常交付。
  final Duration eagerBudget;

  /// 探活并发上限：工作池式起跑，避免对全部可见站同时 burst。
  final int concurrency;
  final int maxVersions;

  Future<CrossSiteProbeResult> probeProvider(
    CrossSiteProvider provider,
    String siteId,
    String avId,
  ) async {
    final stopwatch = Stopwatch()..start();
    try {
      final result = await _probe(
        provider,
        siteId,
        avId,
      ).timeout(perSiteTimeout);
      return CrossSiteProbeResult(
        provider: result.provider,
        siteId: result.siteId,
        status: result.status,
        versions: result.versions,
        latency: stopwatch.elapsed,
      );
    } on TimeoutException {
      return CrossSiteProbeResult(
        provider: provider,
        siteId: siteId,
        status: CrossSiteProbeStatus.failed,
        latency: stopwatch.elapsed,
      );
    } catch (_) {
      return CrossSiteProbeResult(
        provider: provider,
        siteId: siteId,
        status: CrossSiteProbeStatus.failed,
        latency: stopwatch.elapsed,
      );
    }
  }

  /// 流式探活一批计划：工作池按 [concurrency] 起跑，每家探完立刻
  /// 调 [onResult]（界面逐行刷新、推荐随之浮现）；预算耗尽时尚未
  /// 起跑的计划直接跳过（不调 [onResult]），调用方改走懒查。
  /// 无源计划（siteId 为空）不探活。
  Future<void> probePlans(
    List<CrossSiteRowPlan> plans,
    String avId, {
    required void Function(CrossSiteProbeResult result) onResult,
  }) async {
    final targets = plans.where((plan) => plan.siteId != null).toList();
    if (targets.isEmpty) return;
    final deadline = DateTime.now().add(eagerBudget);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (next >= targets.length) return;
        if (DateTime.now().isAfter(deadline)) return;
        final plan = targets[next++];
        final result = await probeProvider(plan.provider, plan.siteId!, avId);
        onResult(result);
      }
    }

    final workers = concurrency < targets.length ? concurrency : targets.length;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
  }

  Future<CrossSiteProbeResult> _probe(
    CrossSiteProvider provider,
    String siteId,
    String avId,
  ) async {
    final page = await repository.searchAcross([siteId], avId);
    final hits = page.items
        .where(
          (drama) =>
              crossSiteHitMatches(title: drama.title, id: drama.id, avId: avId),
        )
        .take(maxVersions)
        .toList();
    final versions = <CrossSiteVersion>[];
    for (final hit in hits) {
      try {
        final detail = await repository.detail(hit);
        final lines = crossSiteLinesOf(detail);
        if (lines.isEmpty) continue;
        versions.add(
          CrossSiteVersion(
            label: crossSiteVersionLabel(
              title: hit.title,
              id: hit.id,
              avId: avId,
            ),
            detail: detail,
            lines: lines,
          ),
        );
      } catch (_) {
        // 某个命中取详情失败，换下一个命中，不拖垮整家平台。
      }
    }
    return CrossSiteProbeResult(
      provider: provider,
      siteId: siteId,
      status: versions.isEmpty
          ? CrossSiteProbeStatus.empty
          : CrossSiteProbeStatus.found,
      versions: versions,
    );
  }
}
