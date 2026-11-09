import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DramaSiteCategory {
  final String id;
  final String name;

  /// 父分类 id：顶级分类为空。多级分类时指向上级分类的 id，
  /// 层级链按它走，不跨站混；各站层级按站原样保留，不压平。
  final String parentId;

  /// 从站根到本分类的完整路径（层级间用 / 连接）；单级分类
  /// 时为空或与名相同，展示时仍用名，不受影响。
  final String path;

  /// 分类级扩展字段：该站分类自带的属性（图标、描述等），
  /// 按站原样保留，不砍字段。
  final Map<String, String> extra;

  const DramaSiteCategory(
    this.id,
    this.name, {
    this.parentId = '',
    this.path = '',
    this.extra = const {},
  });

  /// 展示名：有父级时显示完整路径（电影/动作），否则显示名本身；
  /// 平铺分类的展示不受影响。
  String get displayName =>
      parentId.isNotEmpty && path.isNotEmpty ? path : name;
}

class DramaSite {
  final String id;
  final String name;
  final List<DramaSiteCategory> categories;

  const DramaSite(this.id, this.name, [this.categories = const [DramaSiteCategory('all', '全部')]]);
}

const dramaSites = [
  // 原始站是番茄系短剧流，不是红果；分类取它短剧频道的可内容项，
  // 最近与收藏是本地历史与书架，不算内容分类，故不列入。
  DramaSite('original', '番茄短剧', [
    DramaSiteCategory('all', '全部'),
    DramaSiteCategory('recommend', '推荐'),
    DramaSiteCategory('watch', '看剧'),
    DramaSiteCategory('manju', '漫剧'),
  ]),
  DramaSite('hongguo', '红果', [
    DramaSiteCategory('all', '全部'),
    DramaSiteCategory('real-drama', '真人剧'),
    DramaSiteCategory('comic-drama', '漫剧'),
    DramaSiteCategory('ai-drama', 'AI剧'),
    DramaSiteCategory('comic', '动漫'),
  ]),
  DramaSite('hgtv', 'HGTV', [
    DramaSiteCategory('home', '首页推荐'),
    DramaSiteCategory('real', '真人剧'),
    DramaSiteCategory('comic', '漫剧'),
    DramaSiteCategory('ai', 'AI剧'),
    DramaSiteCategory('latest', '最新上架'),
  ]),
  DramaSite('hgtvmirror', '红果镜像', [
    DramaSiteCategory('real-drama', '真人剧'),
    DramaSiteCategory('comic-drama', '漫剧'),
    DramaSiteCategory('ai-drama', 'AI剧'),
  ]),
  DramaSite('huangdou', '黄豆'),
  DramaSite('huangju', '剧果'),
  DramaSite('yeguo', '野果'),
  DramaSite('yaguo', '芽果', [
    DramaSiteCategory('1', '剧场'),
    DramaSiteCategory('9', '榜单'),
  ]),
  DramaSite('maoguo', '猫果', [DramaSiteCategory('0', '推荐')]),
  DramaSite('fanguo', '饭果', [
    DramaSiteCategory('都市', '都市'),
    DramaSiteCategory('甜宠', '甜宠'),
    DramaSiteCategory('逆袭', '逆袭'),
    DramaSiteCategory('战神', '战神'),
    DramaSiteCategory('古装', '古装'),
    DramaSiteCategory('穿越', '穿越'),
    DramaSiteCategory('萌宝', '萌宝'),
  ]),
  DramaSite('guanguo', '观果'),
  DramaSite('heguo', '河果', [
    DramaSiteCategory('462', '甜宠'),
    DramaSiteCategory('1102', '古装仙侠'),
    DramaSiteCategory('1145', '现代言情'),
    DramaSiteCategory('1170', '青春'),
    DramaSiteCategory('585', '豪门恩怨'),
    DramaSiteCategory('417-464', '逆袭'),
    DramaSiteCategory('439-465', '重生'),
    DramaSiteCategory('1159', '系统'),
    DramaSiteCategory('1147', '总裁'),
    DramaSiteCategory('943', '职场商战'),
  ]),
  DramaSite('xingguo', '星果', [
    DramaSiteCategory('1287', '推荐一'),
    DramaSiteCategory('1288', '推荐二'),
    DramaSiteCategory('1289', '推荐三'),
    DramaSiteCategory('1290', '推荐四'),
    DramaSiteCategory('1291', '推荐五'),
  ]),
  DramaSite('huaguo', '花果', [DramaSiteCategory('27', '短剧')]),
  DramaSite('niuguo', '牛果', [
    DramaSiteCategory('1', '短剧'),
    DramaSiteCategory('2', '电影'),
    DramaSiteCategory('3', '电视剧'),
    DramaSiteCategory('4', '动漫'),
    DramaSiteCategory('5', '综艺'),
  ]),
  DramaSite('wangguo', '网果'),
  DramaSite('faguo', '发果'),
  DramaSite('wuguo', '伍果'),
  DramaSite('huangdou_yh', '黄豆短剧'),
  // 午夜区核心视频站（146 站筛查的视频候选，批回报已验的 83 站）：
  // 只走 Rust 核心，不回退 py/Java；分类由核心现取，登记只给
  // 「全部」兜底。显示名按成人站规则带 🔞 前缀。
  DramaSite('mjv011', '🔞mjv011'),
  DramaSite('huangguo', '🔞黄果'),
  DramaSite('hl365', '🔞黑料不打烊'),
  DramaSite('sex8', '🔞Sex8'),
  DramaSite('hgdjv', '🔞黄果短剧'),
  DramaSite('km2', '🔞新快猫'),
  DramaSite('cucumber', '🔞黄瓜视频'),
  DramaSite('haijiao', '🔞海角社区'),
  DramaSite('md', '🔞麻豆'),
  DramaSite('utube', '🔞Utube'),
  DramaSite('av91', '🔞av91'),
  DramaSite('lxs', '🔞撸先生'),
  DramaSite('javrate', '🔞鉴黄师'),
  DramaSite('xszav', '🔞XSZAV'),
  DramaSite('txfans', '🔞糖心Fans'),
  DramaSite('juyin', '🔞巨婴云播'),
  DramaSite('99jj', '🔞久久热'),
  DramaSite('dayday', '🔞天天A片'),
  DramaSite('dsav', '🔞DSAV影视'),
  DramaSite('kuaihuo', '🔞快活影院'),
  DramaSite('jack20', '🔞後宮電影院'),
  DramaSite('gqck', '🔞高清仓库'),
  DramaSite('wuyetv', '🔞午夜TV'),
  DramaSite('hjw', '🔞海角网'),
  DramaSite('pigav', '🔞PIGAV'),
  DramaSite('sihucdn', '🔞四虎·免盾CDN'),
  DramaSite('sihu', '🔞四虎·4hu'),
  DramaSite('xx9', '🔞XX9'),
  DramaSite('69vj', '🔞69VJ'),
  DramaSite('avcnn', '🔞AVCNN'),
  DramaSite('javhd', '🔞JAVHD'),
  DramaSite('fq', '🔞番茄视频'),
  DramaSite('wnzs', '🔞万能蜘蛛'),
  DramaSite('tudou', '🔞土豆视频'),
  DramaSite('xjh5', '🔞香蕉视频H5'),
  DramaSite('xj2', '🔞香蕉视频免登入'),
  DramaSite('missav', '🔞MissAV官方'),
  DramaSite('hddj', '🔞黄豆短剧'),
  DramaSite('jm', '🔞JAV目錄'),
  DramaSite('getav', '🔞帝皇影视'),
  DramaSite('hsck', '🔞帝皇影视·黄色仓库②'),
  DramaSite('missavoff', '🔞MissAV官方·原生'),
  DramaSite('mirror', '🔞MissAV镜像'),
  DramaSite('123av', '🔞123AV'),
  DramaSite('dsd', '🔞懂色帝'),
  DramaSite('lissav', '🔞麻豆视频·LissAV'),
  DramaSite('xhamster', '🔞xHamster'),
  DramaSite('rou', '🔞肉视频'),
  DramaSite('pb', '🔞好色TV'),
  DramaSite('rouav', '🔞rouAV'),
  DramaSite('av18av', '🔞18AV'),
  DramaSite('dage', '🔞大哥视频'),
  DramaSite('sporn', '🔞SuperPorn'),
  DramaSite('okxxx', '🔞OKXXX'),
  DramaSite('591av', '🔞591AV'),
  DramaSite('avjoy', '🔞AVJOY'),
  DramaSite('hanime', '🔞Hanime1'),
  DramaSite('hbook', '🔞HBook'),
  DramaSite('jav188', '🔞AV18.Live'),
  DramaSite('xvideo', '🔞XVIDEOS'),
  DramaSite('ptt01', '🔞PTT01'),
  DramaSite('cporn', '🔞CartoonPorno'),
  DramaSite('xanimu', '🔞Xanimu'),
  DramaSite('xx01', '🔞XX01'),
  DramaSite('netflav', '🔞Netflav'),
  DramaSite('goodav', '🔞正妹AV'),
  DramaSite('av6k', '🔞AV6K'),
  DramaSite('jav', '🔞J-AV'),
  DramaSite('jav777', '🔞JAV777'),
  DramaSite('airav', '🔞AirAV'),
  DramaSite('go2av', '🔞GO2AV'),
  DramaSite('mmtv7', '🔞7MMTV'),
  DramaSite('zggjav', '🔞GGJAV'),
  DramaSite('avbigplat', '🔞AV大平台'),
  DramaSite('xhy11', '🔞小黄鸭'),
  DramaSite('pj5ti', '🔞蜜桃社'),
  DramaSite('thdh', '🔞探花短视频'),
  DramaSite('hjapp', '🔞海角社区App'),
  DramaSite('17rip', '🔞17rip'),
  DramaSite('javplay', '🔞JavPlay'),
  DramaSite('javguru', '🔞JavGuru'),
  DramaSite('missavt', '🔞MissAVt'),
  DramaSite('wukong', '🔞悟空传媒'),
  DramaSite('chengren91', '🔞91成人'),
  DramaSite('badyi', '🔞八度影院'),
  DramaSite('aiye', '🔞爱液视频'),
  DramaSite('av18avmcg', '🔞18AV主站'),
  DramaSite('avtoday', '🔞AV Today'),
  DramaSite('hohoj', '🔞好好J'),
  DramaSite('jptt', '🔞JPTT禁片天堂'),
  DramaSite('xojav', '🔞XOJAV'),
  DramaSite('px8x', '🔞Px8x'),
  DramaSite('tinyav', '🔞TinyAV'),
  DramaSite('pachub', '🔞PacHub'),
  DramaSite('ssis', '🔞ssisJAV'),
  DramaSite('aisxpc', '🔞Ai小视频┃短剧'),
  DramaSite('321av', '🔞321AV'),
  DramaSite('porncgw', '🔞Porn吃瓜网'),
  DramaSite('xlook', '🔞XLook中文大全'),
  DramaSite('hgdj', '🔞黄果短剧'),
  DramaSite('hgdj58', '🔞黄果短剧'),
  DramaSite('huai', '🔞欢爱'),
  DramaSite('huangguotv', '🔞黄果TV短剧'),
  DramaSite('hgtvim', '🔞黄果短剧HGTV'),
  DramaSite('javmap', '🔞JAVMAP'),
  DramaSite('madao', '🔞麻豆傳媒'),
  DramaSite('chinax', '🔞中国X站'),
  DramaSite('chinaxjx', '🔞中国X站精选'),
  DramaSite('swagr', '🔞SWAG资源合集'),
  DramaSite('tanhua91', '🔞九色'),
  DramaSite('theporny', '🔞thePorny'),
  DramaSite('aimove', '🔞新黄果短剧'),
  DramaSite('henhenlu', '🔞狠狠撸'),
  DramaSite('pandatv', '🔞PANDATV'),
  DramaSite('mianfeiai', '🔞免费AI短剧'),
  DramaSite('avyanjiuyuan', '🔞AV研究院'),
  DramaSite('xingkongfuli', '🔞星空福利视频'),
  DramaSite('ai2026', '🔞2026短剧AI'),
  DramaSite('dj91', '🔞91短剧'),
  DramaSite('toptv', '🔞TOPTV'),
  DramaSite('jin18', '🔞18禁乐园'),
  DramaSite('klxq', '🔞快乐星球'),
  DramaSite('taose', '🔞AI成人短剧1'),
  DramaSite('hongyan', '🔞红颜AI短剧'),
  DramaSite('naihenda', '🔞奶很大'),
  DramaSite('haijiao4k', '🔞海角社区4K'),
  DramaSite('uudj', '🔞UU短剧'),
  DramaSite('madou', '🔞2048成人短剧'),
  DramaSite('dj69', '🔞69短剧'),
  DramaSite('ywmm', '🔞高清开苞处女'),
  DramaSite('luoliai', '🔞萝莉AI短剧'),
  DramaSite('shaofu', '🔞少妇·短剧AV'),
  DramaSite('hgai', '🔞黄瓜AI短剧'),
  DramaSite('danai', '🔞大奶Ai短剧'),
  DramaSite('yunmeng', '🔞云梦在线'),
  DramaSite('javzw', '🔞Jav中文'),
  DramaSite('hduanju', '🔞H-短剧'),
  DramaSite('rscg91', '🔞91人兽吃瓜'),
  DramaSite('aidj', '🔞AI短剧AV'),
  DramaSite('mose365', '🔞魔色365'),
  DramaSite('yiren', '🔞伊人AV'),
  DramaSite('zwdj', '🔞中文短剧网'),
  DramaSite('hongxing', '🔞红杏'),
  DramaSite('shunvwang', '🔞熟女网'),
  DramaSite('heitaoduanju', '🔞黑桃短剧'),
  DramaSite('dingjiaseku', '🔞顶级AI色库'),
  DramaSite('aiduanju', '🔞AI短剧网'),
  DramaSite('fuchou', '🔞妇愁者联盟'),
  DramaSite('shunvqu', '🔞熟女群'),
  DramaSite('huangguazy', '🔞黄瓜资源'),
  DramaSite('zwwm', '🔞中文无码'),
  DramaSite('hgaidj', '🔞黄果AI短剧'),
  DramaSite('jiuse', '🔞九色'),
  DramaSite('xianxia', '🔞仙侠AI短剧'),
  DramaSite('ai4k', '🔞4K.AI短剧'),
  DramaSite('muzi', '🔞母子视频'),
  DramaSite('guzhuang', '🔞古装AI'),
  DramaSite('nvdi', '🔞女帝'),
  DramaSite('caoliu', '🔞草榴视频'),
  DramaSite('djwo', '🔞短剧窝'),
  DramaSite('hgkpz', '🔞黄瓜看片'),
  DramaSite('huangduanju', '🔞黄.短剧'),
  DramaSite('jiuseduanju', '🔞九色短剧'),
  DramaSite('xj', '🔞香蕉视频'),
  DramaSite('duanjuone', '🔞短剧one'),
  DramaSite('crdj', '🔞91成人短剧'),
  DramaSite('javher', '🔞JavHer'),
  DramaSite('javwine', '🔞JAV.WINE'),
  DramaSite('lissavcn', '🔞麻豆视频┃国产区'),
  DramaSite('pornhub', '🔞Pornhub'),
  DramaSite('hongluo', '🔞红裸短剧（成人）'),
  DramaSite('ddys', '低端影视'),
  DramaSite('javgg', '🔞JavGG'),
  DramaSite('javtiful', '🔞Javtiful'),
  DramaSite('jable', '🔞Jable'),
  DramaSite('vjav', '🔞VJAV'),
  DramaSite('tiktvod', '🔞TikTok成人版'),
  DramaSite('topjav', '🔞TopJAV'),
  DramaSite('avhwa', '🔞AVHWA'),
  DramaSite('javdino', '🔞JavDino'),
  DramaSite('javhdtube', '🔞JAVHDTube'),
  DramaSite('javmit', '🔞JAVMIT'),
  DramaSite('roshy', '🔞Roshy'),
  DramaSite('abjav', '🔞ABJAV'),
  DramaSite('herexxx', '🔞HereXXX'),
  DramaSite('japanwhores', '🔞Japan Whores'),
  DramaSite('javfun', '🔞JJavFun'),
  DramaSite('koreanporn', '🔞Korean Porn Movie'),
  DramaSite('mythav', '🔞MythAV'),
  DramaSite('senzuri', '🔞Senzuri Tube'),
  DramaSite('tokyomotion', '🔞TokyoMotion'),
  DramaSite('x51', '🔞51X'),
  DramaSite('taiav', '🔞TaiAV'),
  DramaSite('rouvideo', '🔞肉视频'),
  DramaSite('porna91', '🔞91porna'),
  DramaSite('asextv', '🔞A色TV'),
  DramaSite('kissjav', '🔞KissJAV'),
  DramaSite('javtsunami', '🔞JAV Tsunami'),
  DramaSite('javsiri', '🔞JAVSiri'),
  DramaSite('sexkbj', '🔞SexKbj'),
  DramaSite('wohs', '🔍whos识图┃原生'),
  DramaSite('kankux', '🔞看裤X'),
  // 2026-11-07 短剧区改造新进站：种子 py + 短剧区加载代码（见
  // SourceRegistry.clientFor 的种子/jar 兜底），不进影视区、不进分档表。
  DramaSite('aihi', '🔞AIHI短剧'),
  DramaSite('aipornx', '🔞AiPorn短剧'),
  DramaSite('aiyinhang', '🔞AI淫航'),
  DramaSite('sexaix', '🔞幻影AI'),
  // jar 独占的短剧站：种子/py 表里没有，只有 jar 内置行。裸行必须
  // 在这里占位，否则 visibleDramaSites 跳过午夜 jar 行、短剧药丸
  // 里没有它，影视区统一表又按短剧判据把它摘掉，两区都不可见
  // （2026-11-09 复核发现 qmdj/hgdjapp 正是这样丢了）。
  // 客户端走 backingEntryForDramaSite 按 jar key 归一化找
  // （zakaqmdj→qmdj、ZakaHgdjApp→hgdjapp）；不进 coreVideoSiteIds，
  // 不会漏进影视区；也不进分档表，短剧区不分档。
  DramaSite('qmdj', '🔞七猫短剧'),
  DramaSite('hgdjapp', '🔞黄果短剧App'),
  // 种子 py 独占的短剧站：与 ai2026/aihi 同款，裸行占位、种子行去重
  // （visibleDramaSites 认 seedId 去重，药丸里只出现一次裸 id）。
  // xandaskday（AI不用钱）全部分类都是 AI 短剧/漫剧；huangguomanju
  // （黄果漫剧）全部分类都是短剧/漫剧；两站此前没有裸行，药丸里
  // 只能以 seed_ 行出现、且 xandaskday 还被误判进影视区。
  DramaSite('xandaskday', '🔞AI不用钱'),
  DramaSite('huangguomanju', '🔞黄果漫剧'),
];

List<DramaSite> _extraDramaSites = const [];

/// 短剧站裸 id：`dramaSites` 表头 19 站（番茄/红果/HGTV/各果站）
/// 与名字里不带「短剧」/「漫剧」的纯短剧站（AI淫航、幻影AI、
/// AI不用钱：全部分类都是 AI 成人短剧/漫剧，见各站 py 的 classes）。
/// 短剧区与影视区的分区共用这一个判据，不各写一套。
const shortDramaSiteIds = <String>{
  'original',
  'hongguo',
  'hgtv',
  'hgtvmirror',
  'huangdou',
  'huangju',
  'yeguo',
  'yaguo',
  'maoguo',
  'fanguo',
  'guanguo',
  'heguo',
  'xingguo',
  'huaguo',
  'niuguo',
  'wangguo',
  'faguo',
  'wuguo',
  'huangdou_yh',
  'aiyinhang',
  'sexaix',
  'xandaskday',
};

/// 该站是不是短剧站：裸 id 在短剧集里，或显示名带「短剧」/「漫剧」。
/// 「漫剧」是短剧的一种形态（见 rank.dart isDrama 同款：短剧或漫剧
/// 都算剧；黄果漫剧 3 个分类是精选短剧/热播漫剧/擦边风月，全是剧）。
/// 名字判据兜底新站：以后新加的短剧站只要名字带「短剧」/「漫剧」
/// 就自动归短剧区，不用再改这张表。
/// 只含一个短剧分类的混合影视站不算：91三级（多为三级片电影）、
/// 古装AI/丁香色库类（多为视频库、仅一个 AI短剧分类）、探花短视频
/// （短视频无分集）仍归影视区，见 drama_zone_routing_test 的反例。
bool isShortDramaSite(String id, String name) =>
    shortDramaSiteIds.contains(id) ||
    name.contains('短剧') ||
    name.contains('漫剧');

List<DramaSite> get allDramaSites => [...dramaSites, ..._extraDramaSites];

void registerExtraDramaSites(List<DramaSite> sites) {
  _extraDramaSites = List.unmodifiable(sites);
}

DramaSite dramaSiteById(String id) {
  for (final site in allDramaSites) {
    if (site.id == id) return site;
  }
  return dramaSites.first;
}

class DramaSitePreferences {
  const DramaSitePreferences._();

  static const key = 'drama_site_id';

  static String selectedId = dramaSites.first.id;

  static DramaSite get selected => dramaSiteById(selectedId);

  static Future<void> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final saved = preferences.getString(key);
      if (saved != null && saved.isNotEmpty) {
        selectedId = dramaSiteById(saved).id;
      }
    } catch (_) {}
  }

  static Future<void> save(String id) async {
    selectedId = dramaSiteById(id).id;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(key, selectedId);
    } catch (_) {}
  }

  @visibleForTesting
  static void reset() {
    selectedId = dramaSites.first.id;
  }
}
