import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DramaSiteCategory {
  final String id;
  final String name;

  const DramaSiteCategory(this.id, this.name);
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
  DramaSite('niuguo', '牛果'),
  DramaSite('wangguo', '网果'),
  DramaSite('faguo', '发果'),
  DramaSite('wuguo', '伍果'),
  DramaSite('huangdou_yh', '黄豆短剧'),
];

DramaSite dramaSiteById(String id) {
  for (final site in dramaSites) {
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
