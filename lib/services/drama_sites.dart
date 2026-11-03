import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DramaSite {
  final String id;
  final String name;

  const DramaSite(this.id, this.name);
}

const dramaSites = [
  DramaSite('original', '原始短剧'),
  DramaSite('hongguo', '红果'),
  DramaSite('hgtv', 'HGTV'),
  DramaSite('hgtvmirror', '红果镜像'),
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
