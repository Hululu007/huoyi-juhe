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
  DramaSite('yaguo', '芽果'),
  DramaSite('maoguo', '猫果'),
  DramaSite('fanguo', '饭果'),
  DramaSite('guanguo', '观果'),
  DramaSite('heguo', '河果'),
  DramaSite('xingguo', '星果'),
  DramaSite('huaguo', '花果'),
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
