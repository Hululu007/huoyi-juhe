import 'actress_adapter_models.dart' show AppFailure, CatalogCategory;
import 'actress_adapter_repository.dart' show AppRepository;
import 'actress_online_parse.dart';
import 'actress_online_sources.dart';
import 'actress_py_lines.dart';

/// 片库影视站桥接（2026-11-27 用户令：把影视站点桥接过来
/// 与顶部栏平铺）：片库里能按番号搜索/出作品列表的 JAV 向
/// 影视站，经仓储既有站客户端机件（py 种子与 jar 站同一
/// 条 catalog/search/detail/resolve 通道，即 MissAV/潮流
/// 用的 ActressPyBridge）注册成演员库可浏览源，与现有六段
/// 同排平铺。桥接站在演员库里只做三件事：本段分类浏览、
/// 统一搜索按番号找片、点开进统一详情页（吃全源补全链，
/// 播放走详情页既有竞速——本源自有线 + 女优库反查 +
/// 123AV/PH/18AV/MissAV/潮流/MJV 六线）。桥接站不进详情
/// 页按番号竞速表（竞速表保持六线，防每开一页扇出上百站）。
///
/// 准入（逐站盘点，清单与理由见本批报告）：JAV 专站
/// （番号目录站）＋成人 MacCMS 资源站（标准采集接口、番
/// 号可搜）。不进：短剧/AI 短剧/漫剧、小说/漫画/听书、
/// 直播、网盘与配置类、主流影视、UGC/社区/欧美 tube
/// （无 JAV 番号体系）、同站双份（jar 与 py 同站只取
/// 一份）、who's（用户令不回演员库）、已在源条的
/// （123AV/PH/MissAV/潮流/18AV 本体与种子）。
/// 全部桥接段照例带「未验」标（手机未验前）。

/// 一个桥接站的注册项：仓储站 id + 源条显示名。
typedef ActressBridgedSite = ({String stationId, String label});

/// 桥接站注册表（顺序即源条顺序：py JAV 专站 → jar JAV
/// 专站 → py 成人资源站）。
const kActressBridgedSites = <ActressBridgedSite>[
  // ---- py JAV 专站（片库内置种子） ----
  (stationId: 'seed_abjav', label: 'ABJAV'),
  (stationId: 'seed_aijav', label: 'AiJav'),
  (stationId: 'seed_avdb', label: 'AVDB'),
  (stationId: 'seed_avhwa', label: 'AVHWA'),
  (stationId: 'seed_avtoday', label: 'AV Today'),
  (stationId: 'seed_avyanjiuyuan', label: 'AV研究院'),
  (stationId: 'seed_insav', label: 'INSAV'),
  (stationId: 'seed_jav188', label: 'AV18.Live'),
  (stationId: 'seed_javdino', label: 'JavDino'),
  (stationId: 'seed_javfun', label: 'JJavFun'),
  (stationId: 'seed_javgg', label: 'JavGG'),
  (stationId: 'seed_javhdtube', label: 'JAVHDTube'),
  (stationId: 'seed_javmenu', label: 'JAV目錄大全'),
  (stationId: 'seed_javmit', label: 'JAVMIT'),
  (stationId: 'seed_javsiri', label: 'JAVSiri'),
  (stationId: 'seed_javtiful', label: 'Javtiful'),
  (stationId: 'seed_javtsunami', label: 'JAV Tsunami'),
  (stationId: 'seed_javzw', label: 'Jav中文'),
  (stationId: 'seed_kissjav', label: 'KissJAV'),
  (stationId: 'seed_memojav', label: 'MemoJav'),
  (stationId: 'seed_mythav', label: 'MythAV'),
  (stationId: 'seed_qinav', label: 'Qinav'),
  (stationId: 'seed_ssis', label: 'ssisJAV'),
  (stationId: 'seed_taiav', label: 'TaiAV'),
  (stationId: 'seed_tinyav', label: 'TinyAV'),
  (stationId: 'seed_topjav', label: 'TopJAV'),
  (stationId: 'seed_vjav', label: 'VJAV'),
  (stationId: 'seed_xojav', label: 'XOJAV'),
  (stationId: 'seed_yiren', label: '伊人AV'),
  (stationId: 'seed_zwwm', label: '中文无码'),
  (stationId: 'seed_hmav', label: '河马AV'),
  // ---- jar JAV 专站（zakatv.jar，无 py 同站者） ----
  (stationId: 'jar:zakatv:zakajavdb', label: 'JavDB'),
  (stationId: 'jar:zakatv:zakajavverse', label: 'JAV Verse'),
  (stationId: 'jar:zakatv:zakav01', label: 'AV01'),
  (stationId: 'jar:zakatv:zakaxszav', label: 'XSZAV'),
  (stationId: 'jar:zakatv:ZakaJav380', label: 'JAV380'),
  (stationId: 'jar:zakatv:ZakaJavher', label: 'JavHer'),
  (stationId: 'jar:zakatv:zakajavmap', label: 'JAVMAP'),
  (stationId: 'jar:zakatv:ZakaAvcnn', label: 'AVCNN'),
  (stationId: 'jar:zakatv:ZakaJavwine', label: 'JAV.WINE'),
  (stationId: 'jar:zakatv:ZakaNjav', label: 'nJAV'),
  (stationId: 'jar:zakatv:ZakaJavhd', label: 'JavHD'),
  (stationId: 'jar:zakatv:ZakaJable', label: 'Jable'),
  (stationId: 'jar:zakatv:Zaka321av', label: '321AV'),
  (stationId: 'jar:zakatv:ZakaSupjav', label: 'SupJav'),
  (stationId: 'jar:zakatv:ZakaJavPlay', label: 'JavPlay'),
  (stationId: 'jar:zakatv:ZakaJavguru', label: 'JavGuru'),
  (stationId: 'jar:zakatv:ZakaJavrate', label: '鉴黄师'),
  (stationId: 'jar:zakatv:jav', label: 'J-AV'),
  (stationId: 'jar:zakatv:jav777', label: 'JAV777'),
  (stationId: 'jar:zakatv:airav', label: 'AirAV'),
  (stationId: 'jar:zakatv:goodav', label: '正妹AV'),
  (stationId: 'jar:zakatv:av6k', label: 'AV6K'),
  (stationId: 'jar:zakatv:zggjav', label: 'GGJAV'),
  (stationId: 'jar:zakatv:go2av', label: 'GO2AV'),
  (stationId: 'jar:zakatv:mmtv7', label: '7MMTV'),
  (stationId: 'jar:zakatv:netflav', label: 'Netflav'),
  (stationId: 'jar:zakatv:avbigplat', label: 'AV大平台'),
  (stationId: 'jar:zakatv:xx01', label: '无码流出'),
  // ---- py 成人 MacCMS 资源站（标准采集接口） ----
  (stationId: 'seed_aosikazy', label: '奥斯卡资源'),
  (stationId: 'seed_baofengzy', label: '暴风资源'),
  (stationId: 'seed_changzhangzy', label: '厂长资源'),
  (stationId: 'seed_ckzy', label: 'CK伦理资源'),
  (stationId: 'seed_dadizy', label: '大地资源'),
  (stationId: 'seed_danaizizy', label: '大奶子资源'),
  (stationId: 'seed_doudouzy', label: '豆豆资源'),
  (stationId: 'seed_dyttzy', label: '电影天堂资源'),
  (stationId: 'seed_fanhaozy', label: '番号资源'),
  (stationId: 'seed_feifanzy', label: '非凡资源'),
  (stationId: 'seed_guangsuzy', label: '光速资源'),
  (stationId: 'seed_haohuazy', label: '豪华资源'),
  (stationId: 'seed_heiheizy', label: '嘿嘿资源'),
  (stationId: 'seed_heiliaozy', label: '黑料资源'),
  (stationId: 'seed_honglouzy', label: '红楼资源'),
  (stationId: 'seed_hongniuzy', label: '红牛资源'),
  (stationId: 'seed_hsckzy', label: '黄色仓库'),
  (stationId: 'seed_huosuzy', label: '火速资源'),
  (stationId: 'seed_huyazy', label: '虎牙资源'),
  (stationId: 'seed_ikunzy', label: 'iKun资源'),
  (stationId: 'seed_jipinzy', label: '极品资源'),
  (stationId: 'seed_jisuzy', label: '极速资源'),
  (stationId: 'seed_jjzy', label: '吉吉资源'),
  (stationId: 'seed_jkunzy', label: 'jkun资源'),
  (stationId: 'seed_jp98zy', label: '精品98'),
  (stationId: 'seed_juliangzy', label: '巨量资源'),
  (stationId: 'seed_kuaichezy', label: '快车资源'),
  (stationId: 'seed_laosepzy', label: '老色P资源'),
  (stationId: 'seed_lebozy', label: '乐播资源'),
  (stationId: 'seed_mangguozy', label: '芒果资源'),
  (stationId: 'seed_maoyanzy', label: '猫眼资源'),
  (stationId: 'seed_moduzy', label: '魔都资源'),
  (stationId: 'seed_naixxzy', label: '奶香香资源'),
  (stationId: 'seed_niuniuzy', label: '牛牛资源'),
  (stationId: 'seed_okzy', label: 'ok资源站'),
  (stationId: 'seed_souavzy', label: '搜av资源'),
  (stationId: 'seed_subozy', label: '速播资源'),
  (stationId: 'seed_suonizy', label: '索尼资源'),
  (stationId: 'seed_taohuazy', label: '桃花资源'),
  (stationId: 'seed_tianyazy', label: '天涯资源'),
  (stationId: 'seed_wsyzy', label: '无水印资源'),
  (stationId: 'seed_wujinzy', label: '无尽资源'),
  (stationId: 'seed_xiguazy', label: '西瓜资源'),
  (stationId: 'seed_xingbazy', label: '杏吧资源'),
  (stationId: 'seed_xingyezy', label: '星夜资源站'),
  (stationId: 'seed_yayazy', label: '鸭鸭资源'),
  (stationId: 'seed_yinghuazy', label: '樱花资源'),
  (stationId: 'seed_yuanlibzy', label: '免费资源站'),
  (stationId: 'seed_yutuzy', label: '玉兔资源'),
  (stationId: 'seed_zuidazy', label: '最大资源'),
  (stationId: 'seed_zy360', label: '360资源'),
];

/// 桥接站源：分类页签开段时向仓储现取（源站真实分类，
/// 取不到就只留「全部」走站方默认列表）；取卡/取流/详情
/// 回填全走 [ActressPyBridge] 的仓储通道，与 MissAV/潮流
/// 页签源同一套机件。
class ActressBridgedSiteSource extends ActressOnlineSource {
  ActressBridgedSiteSource(this.bridge, {required this.station});

  final ActressPyBridge bridge;
  final ActressBridgedSite station;

  List<OnlineTabOption> _tabs = const [
    OnlineTabOption(id: 'all', name: '全部', value: 'all'),
  ];
  var _tabsLoaded = false;

  @override
  String get id => 'bridge-${station.stationId}';

  @override
  String get label => station.label;

  @override
  String get site => '';

  @override
  List<OnlineTabOption> get primaryTabs => _tabs;

  @override
  List<OnlineTabOption> get secondaryTabs => const [];

  @override
  String get defaultPrimaryId => 'all';

  @override
  String get defaultSecondaryId => '';

  /// 开段首拉前把源站真实分类装进页签（一次性；失败保持
  /// 「全部」一档，不挡浏览）。原生页在首拉时调用。
  Future<void> ensureTabs(AppRepository repository) async {
    if (_tabsLoaded) return;
    _tabsLoaded = true;
    try {
      final cats = await repository
          .categories(station.stationId)
          .timeout(const Duration(seconds: 15));
      if (cats.isEmpty) return;
      _tabs = [
        const OnlineTabOption(id: 'all', name: '全部', value: 'all'),
        for (final CatalogCategory cat in cats.take(30))
          if (cat.id.isNotEmpty && cat.id != 'all')
            OnlineTabOption(id: cat.id, name: cat.name, value: cat.id),
      ];
    } catch (_) {
      // 分类取不到不挡段：留「全部」走默认列表/搜索。
    }
  }

  @override
  Future<List<OnlineVideoCard>> fetchCards({
    required String primaryId,
    required String secondaryId,
    required String query,
    required int page,
    required ActressOnlineFetch fetch,
  }) => bridge.browseCards(
    siteId: station.stationId,
    category: actressPickTab(primaryTabs, primaryId).value,
    query: query,
    page: page,
  );

  @override
  Future<ActressOnlinePlay> resolvePlay(
    OnlineVideoCard card, {
    required ActressOnlineFetch fetch,
  }) async {
    final target = await bridge.playFromCard(station.stationId, card);
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

/// 全部桥接站源（原生页源条尾段，顺序同注册表）。
List<ActressOnlineSource> actressBridgedLibrarySources(
  ActressPyBridge bridge,
) => [
  for (final station in kActressBridgedSites)
    ActressBridgedSiteSource(bridge, station: station),
];
