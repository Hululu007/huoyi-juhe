import 'actress_adapter_http.dart'
    show FeedProbeFetch, feedProbePlayable, probeStreamHead;
import 'actress_adapter_models.dart'
    show AppFailure, Drama, PlaybackPlan;
import 'actress_adapter_repository.dart' show AppRepository;
import 'actress_online_parse.dart';
import 'actress_online_sources.dart';
import 'actress_work_detail_page.dart' show ActressPlayTarget;

/// py 桥：演员库经仓储既有 py 客户端机件（SourceRegistry →
/// PySiteContentClient → PyBridge）调 seed_missav /
/// seed_chaoliu 种子蜘蛛，只做「按番号搜 + 取流」与浏览取卡。
/// 桥本身是仓储层现成机件的薄封装，不重造引擎通道
/// （2026-11-27 盘点路径 A）。
///
/// 取流纪律（与 Dart 直连线同尺）：
/// - 只收 parse=0 直链：仓储 resolve 对 parse=1 的 py 回包
///   直接抛错，这里一律按无结果处理，绝不递给播放器；
/// - 潮流索引线递送前轻验（探针验活）：验死自动落 MJV
///   现拉线，不把死地址递出去（蜘蛛本体只在索引未命中时
///   落现拉、命中但死不落——这一层在桥上补齐）；
/// - 失败只内部回 null，不向界面抛英文原文。
class ActressPyBridge {
  ActressPyBridge(this.repository, {FeedProbeFetch? verifyFetch})
    : verifyFetch = verifyFetch ?? probeStreamHead;

  final AppRepository repository;

  /// 索引线递送前轻验探针（默认走壳级同款 probeStreamHead）。
  final FeedProbeFetch verifyFetch;

  static const missavSiteId = 'seed_missav';
  static const chaoliuSiteId = 'seed_chaoliu';

  /// 一部作品走 detail → resolve 的通用取流：集优先选标题
  /// 带 [preferMark] 的（如 MJV 的 720P），没有就第一集。
  Future<ActressPlayTarget?> playDrama(
    Drama drama, {
    String preferMark = '',
  }) async {
    try {
      final detail = await repository.detail(drama);
      if (detail.episodes.isEmpty) return null;
      var episode = detail.episodes.first;
      if (preferMark.isNotEmpty) {
        for (final row in detail.episodes) {
          if (row.title.contains(preferMark)) {
            episode = row;
            break;
          }
        }
      }
      final PlaybackPlan plan = await repository.resolve(
        detail.drama,
        episode,
      );
      if (plan.needsParse) return null;
      final url = plan.url.trim();
      final uri = Uri.tryParse(url);
      if (uri == null || uri.host.isEmpty) return null;
      if (uri.scheme != 'http' && uri.scheme != 'https') return null;
      return ActressPlayTarget(url, plan.headers);
    } catch (_) {
      return null;
    }
  }

  /// MissAV 线：按番号搜 seed_missav，命中（标题/编号含
  /// 目标番号）后取流。只接搜 + 取流，不做浏览面解析。
  Future<ActressPlayTarget?> playMissavByCode(String code) async {
    final hits = await _search(missavSiteId, code);
    final target = actressCodeKey(code);
    for (final hit in hits) {
      final inTitle = actressCodeKey(hit.title).contains(target);
      final inId = actressCodeKey(hit.id).contains(target);
      if (target.isNotEmpty && (inTitle || inId)) {
        final play = await playDrama(hit);
        if (play != null) return play;
      }
    }
    return null;
  }

  /// 潮流索引线：seed_chaoliu 的 code_<番号> 详情直达
  /// jpcode:<番号>（蜘蛛 _resolve_code 先查索引 buckets）。
  /// 拿到地址先轻验：验活才递送；验死/取不到 → 落 MJV
  /// 现拉线（[playChaoliuLive]），不递死地址。
  Future<ActressPlayTarget?> playChaoliuIndex(String code) async {
    final drama = Drama(
      id: 'code_$code',
      source: chaoliuSiteId,
      title: code,
    );
    final target = await playDrama(drama);
    if (target != null && await _verify(target)) return target;
    return playChaoliuLive(code);
  }

  /// MJV 现拉线：seed_chaoliu 站内搜索的本体卡
  /// （ctype#num#slug）→ 详情解密 → play.php 取 720P。
  /// 整链约 45 秒（盘点实测），调用方须给独立超时预算、
  /// 不进主竞速总闸（详情页作后补线，见
  /// actress_work_detail_page.dart）。
  Future<ActressPlayTarget?> playChaoliuLive(String code) async {
    final hits = await _search(chaoliuSiteId, code);
    final target = actressCodeKey(code);
    for (final hit in hits) {
      if (!hit.id.contains('#')) continue;
      final ctype = hit.id.split('#').first;
      if (const {'novel', 'cg', 'cwp', '18H', 'doujin'}.contains(ctype)) {
        continue;
      }
      final inTitle = actressCodeKey(hit.title).contains(target);
      final inSlug = actressCodeKey(hit.id).contains(target);
      if (target.isNotEmpty && !inTitle && !inSlug) continue;
      final play = await playDrama(hit, preferMark: '720');
      if (play != null) return play;
    }
    return null;
  }

  /// 浏览取卡（MissAV / 潮流页签用）：query 非空走搜索，
  /// 否则走分类目录。卡的 pageUrl 暂存种子内的作品 id，
  /// resolvePlay 时凭它回仓储取详情。
  Future<List<OnlineVideoCard>> browseCards({
    required String siteId,
    required String category,
    required String query,
    required int page,
  }) async {
    try {
      final result = await repository.catalog(
        siteId,
        page: page,
        query: query,
        category: query.trim().isNotEmpty ? '' : category,
      );
      return [
        for (final drama in result.items)
          OnlineVideoCard(
            pageUrl: drama.id,
            title: drama.title,
            cover: drama.cover,
            duration: drama.description,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 浏览卡点播：凭卡里暂存的作品 id 回仓储 detail+resolve。
  Future<ActressPlayTarget?> playFromCard(
    String siteId,
    OnlineVideoCard card,
  ) => playDrama(
    Drama(
      id: card.pageUrl,
      source: siteId,
      title: card.title,
      cover: card.cover,
    ),
    preferMark: siteId == chaoliuSiteId ? '720' : '',
  );

  Future<List<Drama>> _search(String siteId, String query) async {
    try {
      final page = await repository.searchAcross([siteId], query);
      return page.items;
    } catch (_) {
      return const [];
    }
  }

  Future<bool> _verify(ActressPlayTarget target) async {
    try {
      final uri = Uri.tryParse(target.url);
      if (uri == null || uri.host.isEmpty) return false;
      final response = await verifyFetch(
        target.url,
        target.headers,
        const Duration(seconds: 8),
      );
      return feedProbePlayable(uri, response);
    } catch (_) {
      return false;
    }
  }
}

/// MissAV 页签源（py 桥）：py 蜘蛛有首页/分类/搜索，浏览
/// 走仓储 catalog，点播走仓储 detail+resolve。[fetch] 不用
/// （py 桥不走 HTTP 取数函数），签名与 Dart 直连源一致。
class MissavPySource extends ActressOnlineSource {
  MissavPySource(this.bridge);

  final ActressPyBridge bridge;

  @override
  String get id => 'missav';

  @override
  String get label => 'MissAV';

  @override
  String get site => 'https://www.missav123.nl';

  /// 页签 = missav.py 分类的视频子集（女优一览/类型/发行商
  /// 是索引下钻页、不作一级页签）。
  @override
  List<OnlineTabOption> get primaryTabs => const [
    OnlineTabOption(id: 'release', name: '新作上市', value: 'release'),
    OnlineTabOption(id: 'new', name: '最近更新', value: 'new'),
    OnlineTabOption(
      id: 'chinese-subtitle',
      name: '中文字幕',
      value: 'chinese-subtitle',
    ),
    OnlineTabOption(
      id: 'uncensored-leak',
      name: '无码流出',
      value: 'uncensored-leak',
    ),
    OnlineTabOption(id: 'today-hot', name: '今日热门', value: 'today-hot'),
    OnlineTabOption(id: 'fc2', name: 'FC2', value: 'fc2'),
  ];

  @override
  List<OnlineTabOption> get secondaryTabs => const [];

  @override
  String get defaultPrimaryId => 'release';

  @override
  String get defaultSecondaryId => '';

  @override
  Future<List<OnlineVideoCard>> fetchCards({
    required String primaryId,
    required String secondaryId,
    required String query,
    required int page,
    required ActressOnlineFetch fetch,
  }) => bridge.browseCards(
    siteId: ActressPyBridge.missavSiteId,
    category: actressPickTab(primaryTabs, primaryId).value,
    query: query,
    page: page,
  );

  @override
  Future<ActressOnlinePlay> resolvePlay(
    OnlineVideoCard card, {
    required ActressOnlineFetch fetch,
  }) async {
    final target = await bridge.playFromCard(
      ActressPyBridge.missavSiteId,
      card,
    );
    if (target == null) {
      throw AppFailure('这个视频暂时取不到播放地址');
    }
    return ActressOnlinePlay(
      streamUrl: target.url,
      headers: target.headers,
      detail: OnlineDetailInfo(title: card.title, poster: card.cover),
    );
  }

  @override
  Future<OnlineDetailInfo?> fetchInfo(
    OnlineVideoCard card, {
    required ActressOnlineFetch fetch,
  }) async => OnlineDetailInfo(title: card.title, poster: card.cover);
}

/// 潮流页签源（py 桥）：chaoliu.py 的浏览面就是 MJV 本体
/// 分类/搜索（索引 buckets 只出番号直查、不出浏览卡），
/// 页签 = MJV 视频分类子集。MJV 本体不单设页签（与潮流
/// 共用同一种子、浏览面重复），只进详情页竞速后补线。
class ChaoliuPySource extends ActressOnlineSource {
  ChaoliuPySource(this.bridge);

  final ActressPyBridge bridge;

  @override
  String get id => 'chaoliu';

  @override
  String get label => '潮流';

  @override
  String get site => 'https://mjv011.com';

  @override
  List<OnlineTabOption> get primaryTabs => const [
    OnlineTabOption(
      id: 'chinese',
      name: '中文字幕',
      value: 'chinese_random/all',
    ),
    OnlineTabOption(id: 'censored', name: '有码', value: 'censored_random/all'),
    OnlineTabOption(
      id: 'uncensored',
      name: '无码',
      value: 'uncensored_random/all',
    ),
    OnlineTabOption(
      id: 'amateurjav',
      name: '素人',
      value: 'amateurjav_random/all',
    ),
    OnlineTabOption(
      id: 'reducing-mosaic',
      name: '无码破解',
      value: 'reducing-mosaic_random/all',
    ),
  ];

  @override
  List<OnlineTabOption> get secondaryTabs => const [];

  @override
  String get defaultPrimaryId => 'chinese';

  @override
  String get defaultSecondaryId => '';

  @override
  Future<List<OnlineVideoCard>> fetchCards({
    required String primaryId,
    required String secondaryId,
    required String query,
    required int page,
    required ActressOnlineFetch fetch,
  }) async {
    final cards = await bridge.browseCards(
      siteId: ActressPyBridge.chaoliuSiteId,
      category: actressPickTab(primaryTabs, primaryId).value,
      query: query,
      page: page,
    );
    // 图库卡（tk_ 前缀）是图片集、不是视频，不进视频页签。
    return [
      for (final card in cards)
        if (!card.pageUrl.startsWith('tk_')) card,
    ];
  }

  @override
  Future<ActressOnlinePlay> resolvePlay(
    OnlineVideoCard card, {
    required ActressOnlineFetch fetch,
  }) async {
    final target = await bridge.playFromCard(
      ActressPyBridge.chaoliuSiteId,
      card,
    );
    if (target == null) {
      throw AppFailure('这个视频暂时取不到播放地址');
    }
    return ActressOnlinePlay(
      streamUrl: target.url,
      headers: target.headers,
      detail: OnlineDetailInfo(title: card.title, poster: card.cover),
    );
  }

  @override
  Future<OnlineDetailInfo?> fetchInfo(
    OnlineVideoCard card, {
    required ActressOnlineFetch fetch,
  }) async => OnlineDetailInfo(title: card.title, poster: card.cover);
}

/// py 桥可浏览源（原生页源条页签用）：MissAV + 潮流。
/// MJV 本体与潮流共种子、浏览面重复，不单设页签。
List<ActressOnlineSource> actressPyBrowsableSources(ActressPyBridge bridge) =>
    [MissavPySource(bridge), ChaoliuPySource(bridge)];
