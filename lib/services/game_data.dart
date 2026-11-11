/// 挂机游戏数据表：玩法结构照《凡人修仙传挂机版》H5 那套来——
/// 推图（征战天南大陆）、试炼塔、乱星海狩猎、虚天殿·玄关、
/// 惊蛰十二变（渡劫）、仙法学习、法宝觉醒、妖兽培育、法器锻造、
/// 傀儡操纵、小绿瓶之谜。
///
/// 注意：H5 官网只公布了玩法系统名，没公布逐关数值表；这里的
/// 关卡顺序、奖励数额是 App 侧按 H5 那套系统名排的实现值，
/// 不是照抄 H5 服内的数值。境界门槛与职业直接复用
/// [cultivationRealms] / [cultivationProfessions]，不另起一套。
library;

import 'package:flutter/widgets.dart';

import 'cultivation.dart';

/// 战力公式（装备为主）：
/// 总战力 = 境界基础 + 装备贡献。
/// 境界基础 = 50 + 等级 ×2（满级 270 级也只有 590，小头）；
/// 装备贡献 = Σ 已穿戴件（攻击 + 防御 + 血量 ÷10）
///   × 品质倍率 ×（1 + 强化等级 ×12%）。
/// 满配七彩 + 强化满级时装备贡献约 14600，占总战力 96% 以上；
/// 只靠境界白板（590）连第 4 章（要 700）都打不过，必须靠装备。
const int gamePowerBase = 50;

/// 战力公式：境界基础每级加多少。
const int gamePowerPerLevel = 2;

/// 强化满级。
const int gameEquipRefineMax = 5;

/// 强化每级加多少属性（每级 +12%）。
const double gameEquipRefineBonusPerLevel = 0.12;

/// 合成：几件同品质同部位合成 1 件高一档。
const int gameEquipSynthesizeCount = 3;

/// 自动回收时每（品质、部位）组保留几件当合成材料：
/// 3 件才能合成，留 2 件是“差 1 件就满”的储备，下次掉 1 件
/// 就能合；超过 2 件的才是多余的，自动回收换元宝。
const int gameAutoRecycleReserveCount = 2;

/// 装备栏位。
enum GameEquipSlot {
  /// 武器。
  weapon,

  /// 法宝。
  treasure,

  /// 防具。
  armor,

  /// 饰品。
  accessory,
}

/// 栏位显示名。
String gameEquipSlotName(GameEquipSlot slot) => switch (slot) {
  GameEquipSlot.weapon => '武器',
  GameEquipSlot.treasure => '法宝',
  GameEquipSlot.armor => '防具',
  GameEquipSlot.accessory => '饰品',
};

/// 装备品质（七档，最高七彩）。
enum GameEquipQuality {
  /// 白：普通。
  white,

  /// 绿：优秀。
  green,

  /// 蓝：精良。
  blue,

  /// 紫：史诗。
  purple,

  /// 橙：传说。
  orange,

  /// 红：神话。
  red,

  /// 七彩：至尊（最高，只能合成或通关试炼塔 30 层得，不直接掉）。
  rainbow,
}

/// 品质显示名。
String gameEquipQualityName(GameEquipQuality quality) => switch (quality) {
  GameEquipQuality.white => '普通',
  GameEquipQuality.green => '优秀',
  GameEquipQuality.blue => '精良',
  GameEquipQuality.purple => '史诗',
  GameEquipQuality.orange => '传说',
  GameEquipQuality.red => '神话',
  GameEquipQuality.rainbow => '至尊',
};

/// 品质颜色（白/绿/蓝/紫/橙/红/七彩）。
Color gameEquipQualityColor(GameEquipQuality quality) => switch (quality) {
  GameEquipQuality.white => const Color(0xFFB0BEC5),
  GameEquipQuality.green => const Color(0xFF69F0AE),
  GameEquipQuality.blue => const Color(0xFF40C4FF),
  GameEquipQuality.purple => const Color(0xFFB388FF),
  GameEquipQuality.orange => const Color(0xFFFFAB40),
  GameEquipQuality.red => const Color(0xFFFF5252),
  GameEquipQuality.rainbow => const Color(0xFFFFD54F),
};

/// 品质战力倍率：白 1.0、绿 1.3、蓝 1.7、紫 2.2、橙 2.8、红 3.6、
/// 七彩 4.8。
double gameEquipQualityPowerMultiplier(GameEquipQuality quality) =>
    switch (quality) {
      GameEquipQuality.white => 1.0,
      GameEquipQuality.green => 1.3,
      GameEquipQuality.blue => 1.7,
      GameEquipQuality.purple => 2.2,
      GameEquipQuality.orange => 2.8,
      GameEquipQuality.red => 3.6,
      GameEquipQuality.rainbow => 4.8,
    };

/// 分解一件装备得多少元宝（七彩不可分解）：白 5、绿 10、蓝 20、
/// 紫 40、橙 80、红 160。强化材料不足时自动分解多余低级装备补。
int gameEquipSalvageValue(GameEquipQuality quality) => switch (quality) {
  GameEquipQuality.white => 5,
  GameEquipQuality.green => 10,
  GameEquipQuality.blue => 20,
  GameEquipQuality.purple => 40,
  GameEquipQuality.orange => 80,
  GameEquipQuality.red => 160,
  GameEquipQuality.rainbow => 0,
};

/// 合成差 1 件材料时，花元宝补 1 件要多少（分解价 ×2，买比卖贵）：
/// 白 10、绿 20、蓝 40、紫 80、橙 160、红 320；七彩没有更高档，
/// 不参与合成，补材料费为 0。
int gameEquipSynthesizeFillCost(GameEquipQuality quality) =>
    gameEquipSalvageValue(quality) * 2;

/// 某品质装备从哪来（掉落来源说明）。
String gameEquipDropSource(GameEquipQuality quality) => switch (quality) {
  GameEquipQuality.white => '推图 1–2 章 / 打怪掉落',
  GameEquipQuality.green => '推图 2–4 章 / 乱星海狩猎',
  GameEquipQuality.blue => '推图 4–6 章 / 爬塔 1–12 层',
  GameEquipQuality.purple => '推图 6–9 章 / 爬塔 13–24 层',
  GameEquipQuality.orange => '推图 9–11 章 / 爬塔 25–30 层',
  GameEquipQuality.red => '推图 11–12 章 / 爬塔 28–30 层 / 合成',
  GameEquipQuality.rainbow => '合成（3 件红同部位）/ 通关试炼塔 30 层',
};

/// 一件装备（小说原物）。
class GameEquipment {
  /// 装备 id（落盘用）。
  final String id;

  /// 装备名。
  final String name;

  /// 栏位。
  final GameEquipSlot slot;

  /// 品质。
  final GameEquipQuality quality;

  /// 攻击加成。
  final int attack;

  /// 防御加成。
  final int defense;

  /// 血量加成。
  final int hp;

  /// 穿戴要到的境界下标（见 [cultivationRealms]）。
  final int requiredRealmIndex;

  const GameEquipment({
    required this.id,
    required this.name,
    required this.slot,
    required this.quality,
    required this.attack,
    required this.defense,
    required this.hp,
    required this.requiredRealmIndex,
  });
}

/// 装备表（36 件，全是小说原物）。
/// 品质与原物强度对得上：掌天瓶、玄天斩灵剑、噬金虫王、
/// 金缕玉衣只在七彩档；太乙仙甲、五行环、阴罗幡在橙档；
/// 金雷竹剑、墨灵圣舟、万妖幡、噬金虫在红档。
/// 旧存档兼容：20 件旧装备 id 全部保留，品质按新表映射；
/// 新倍率下同强化等级每件装备的战力贡献都比旧公式高，
/// 老玩家装备不消失、不贬值（太乙仙甲由旧最高档调至橙档，
/// 是因为上面新加了玄天仙甲、金缕玉衣两档防具，绝对战力仍涨）。
const gameEquipments = <GameEquipment>[
  // 白：普通（倍率 1.0）。
  GameEquipment(
    id: 'jin_guang_jian',
    name: '金光剑',
    slot: GameEquipSlot.weapon,
    quality: GameEquipQuality.white,
    attack: 12,
    defense: 0,
    hp: 0,
    requiredRealmIndex: 0,
  ),
  GameEquipment(
    id: 'qing_jiao_qi',
    name: '青蛟旗',
    slot: GameEquipSlot.treasure,
    quality: GameEquipQuality.white,
    attack: 8,
    defense: 5,
    hp: 40,
    requiredRealmIndex: 0,
  ),
  GameEquipment(
    id: 'xuan_tie_zhong_kai',
    name: '玄铁重铠',
    slot: GameEquipSlot.armor,
    quality: GameEquipQuality.white,
    attack: 0,
    defense: 15,
    hp: 80,
    requiredRealmIndex: 0,
  ),
  GameEquipment(
    id: 'chu_wu_zhuo',
    name: '储物镯',
    slot: GameEquipSlot.accessory,
    quality: GameEquipQuality.white,
    attack: 5,
    defense: 5,
    hp: 60,
    requiredRealmIndex: 0,
  ),
  // 绿：优秀（倍率 1.3）。
  GameEquipment(
    id: 'qing_yuan_jian',
    name: '青元剑',
    slot: GameEquipSlot.weapon,
    quality: GameEquipQuality.green,
    attack: 35,
    defense: 0,
    hp: 0,
    requiredRealmIndex: 1,
  ),
  GameEquipment(
    id: 'jin_fu_zi_mu_ren',
    name: '金蚨子母刃',
    slot: GameEquipSlot.weapon,
    quality: GameEquipQuality.green,
    attack: 28,
    defense: 0,
    hp: 0,
    requiredRealmIndex: 1,
  ),
  GameEquipment(
    id: 'yin_yang_zi_mu_huan',
    name: '阴阳子母环',
    slot: GameEquipSlot.treasure,
    quality: GameEquipQuality.green,
    attack: 20,
    defense: 10,
    hp: 50,
    requiredRealmIndex: 1,
  ),
  GameEquipment(
    id: 'jin_gang_zhao',
    name: '金刚罩',
    slot: GameEquipSlot.armor,
    quality: GameEquipQuality.green,
    attack: 0,
    defense: 35,
    hp: 150,
    requiredRealmIndex: 1,
  ),
  GameEquipment(
    id: 'bai_xi_pei',
    name: '白犀佩',
    slot: GameEquipSlot.accessory,
    quality: GameEquipQuality.green,
    attack: 18,
    defense: 12,
    hp: 130,
    requiredRealmIndex: 1,
  ),
  GameEquipment(
    id: 'ling_shou_huan',
    name: '灵兽环',
    slot: GameEquipSlot.accessory,
    quality: GameEquipQuality.green,
    attack: 15,
    defense: 10,
    hp: 120,
    requiredRealmIndex: 1,
  ),
  // 蓝：精良（倍率 1.7）。
  GameEquipment(
    id: 'qing_zhu_feng_yun_jian',
    name: '青竹蜂云剑',
    slot: GameEquipSlot.weapon,
    quality: GameEquipQuality.blue,
    attack: 90,
    defense: 0,
    hp: 0,
    requiredRealmIndex: 2,
  ),
  GameEquipment(
    id: 'pi_xie_shen_lei_zhu',
    name: '辟邪神雷珠',
    slot: GameEquipSlot.treasure,
    quality: GameEquipQuality.blue,
    attack: 55,
    defense: 20,
    hp: 100,
    requiredRealmIndex: 2,
  ),
  GameEquipment(
    id: 'qing_ning_jing',
    name: '青凝镜',
    slot: GameEquipSlot.treasure,
    quality: GameEquipQuality.blue,
    attack: 45,
    defense: 25,
    hp: 120,
    requiredRealmIndex: 2,
  ),
  GameEquipment(
    id: 'feng_lei_chi',
    name: '风雷翅',
    slot: GameEquipSlot.treasure,
    quality: GameEquipQuality.blue,
    attack: 40,
    defense: 30,
    hp: 150,
    requiredRealmIndex: 3,
  ),
  GameEquipment(
    id: 'tian_can_bao_jia',
    name: '天蚕宝甲',
    slot: GameEquipSlot.armor,
    quality: GameEquipQuality.blue,
    attack: 0,
    defense: 80,
    hp: 300,
    requiredRealmIndex: 2,
  ),
  GameEquipment(
    id: 'yang_hun_mu_pei',
    name: '养魂木佩',
    slot: GameEquipSlot.accessory,
    quality: GameEquipQuality.blue,
    attack: 30,
    defense: 25,
    hp: 250,
    requiredRealmIndex: 3,
  ),
  // 紫：史诗（倍率 2.2）。
  GameEquipment(
    id: 'xue_mo_jian',
    name: '血魔剑',
    slot: GameEquipSlot.weapon,
    quality: GameEquipQuality.purple,
    attack: 170,
    defense: 0,
    hp: 0,
    requiredRealmIndex: 4,
  ),
  GameEquipment(
    id: 'mo_long_ren',
    name: '魔龙刃',
    slot: GameEquipSlot.weapon,
    quality: GameEquipQuality.purple,
    attack: 150,
    defense: 0,
    hp: 0,
    requiredRealmIndex: 4,
  ),
  GameEquipment(
    id: 'xu_tian_ding',
    name: '虚天鼎',
    slot: GameEquipSlot.treasure,
    quality: GameEquipQuality.purple,
    attack: 120,
    defense: 60,
    hp: 300,
    requiredRealmIndex: 5,
  ),
  GameEquipment(
    id: 'qian_lan_bing_yan',
    name: '乾蓝冰焰',
    slot: GameEquipSlot.treasure,
    quality: GameEquipQuality.purple,
    attack: 100,
    defense: 40,
    hp: 200,
    requiredRealmIndex: 5,
  ),
  GameEquipment(
    id: 'xue_sha_zhan_pao',
    name: '血煞战袍',
    slot: GameEquipSlot.armor,
    quality: GameEquipQuality.purple,
    attack: 10,
    defense: 150,
    hp: 500,
    requiredRealmIndex: 4,
  ),
  GameEquipment(
    id: 'xing_yue_pu_ti',
    name: '星月菩提',
    slot: GameEquipSlot.accessory,
    quality: GameEquipQuality.purple,
    attack: 60,
    defense: 50,
    hp: 400,
    requiredRealmIndex: 5,
  ),
  // 橙：传说（倍率 2.8）。
  GameEquipment(
    id: 'da_geng_jian',
    name: '大庚剑',
    slot: GameEquipSlot.weapon,
    quality: GameEquipQuality.orange,
    attack: 260,
    defense: 0,
    hp: 0,
    requiredRealmIndex: 6,
  ),
  GameEquipment(
    id: 'wu_xing_huan',
    name: '五行环',
    slot: GameEquipSlot.treasure,
    quality: GameEquipQuality.orange,
    attack: 180,
    defense: 90,
    hp: 450,
    requiredRealmIndex: 6,
  ),
  GameEquipment(
    id: 'yin_luo_fan',
    name: '阴罗幡',
    slot: GameEquipSlot.treasure,
    quality: GameEquipQuality.orange,
    attack: 160,
    defense: 80,
    hp: 400,
    requiredRealmIndex: 6,
  ),
  GameEquipment(
    id: 'tai_yi_xian_jia',
    name: '太乙仙甲',
    slot: GameEquipSlot.armor,
    quality: GameEquipQuality.orange,
    attack: 20,
    defense: 280,
    hp: 900,
    requiredRealmIndex: 8,
  ),
  GameEquipment(
    id: 'ti_hun_shou',
    name: '啼魂兽',
    slot: GameEquipSlot.accessory,
    quality: GameEquipQuality.orange,
    attack: 120,
    defense: 70,
    hp: 500,
    requiredRealmIndex: 6,
  ),
  // 红：神话（倍率 3.6）。
  GameEquipment(
    id: 'jin_lei_zhu_jian',
    name: '金雷竹剑',
    slot: GameEquipSlot.weapon,
    quality: GameEquipQuality.red,
    attack: 300,
    defense: 0,
    hp: 0,
    requiredRealmIndex: 8,
  ),
  GameEquipment(
    id: 'mo_ling_sheng_zhou',
    name: '墨灵圣舟',
    slot: GameEquipSlot.treasure,
    quality: GameEquipQuality.red,
    attack: 190,
    defense: 100,
    hp: 500,
    requiredRealmIndex: 8,
  ),
  GameEquipment(
    id: 'wan_yao_fan',
    name: '万妖幡',
    slot: GameEquipSlot.treasure,
    quality: GameEquipQuality.red,
    attack: 140,
    defense: 90,
    hp: 600,
    requiredRealmIndex: 8,
  ),
  GameEquipment(
    id: 'xuan_tian_xian_jia',
    name: '玄天仙甲',
    slot: GameEquipSlot.armor,
    quality: GameEquipQuality.red,
    attack: 30,
    defense: 320,
    hp: 1000,
    requiredRealmIndex: 10,
  ),
  GameEquipment(
    id: 'shi_jin_chong',
    name: '噬金虫',
    slot: GameEquipSlot.accessory,
    quality: GameEquipQuality.red,
    attack: 150,
    defense: 80,
    hp: 700,
    requiredRealmIndex: 8,
  ),
  // 七彩：至尊（倍率 4.8，最高档，只能合成或通关试炼塔 30 层得）。
  GameEquipment(
    id: 'xuan_tian_zhan_ling_jian',
    name: '玄天斩灵剑',
    slot: GameEquipSlot.weapon,
    quality: GameEquipQuality.rainbow,
    attack: 420,
    defense: 0,
    hp: 0,
    requiredRealmIndex: 10,
  ),
  GameEquipment(
    id: 'zhang_tian_ping',
    name: '掌天瓶',
    slot: GameEquipSlot.treasure,
    quality: GameEquipQuality.rainbow,
    attack: 260,
    defense: 140,
    hp: 800,
    requiredRealmIndex: 10,
  ),
  GameEquipment(
    id: 'jin_lv_yu_yi',
    name: '金缕玉衣',
    slot: GameEquipSlot.armor,
    quality: GameEquipQuality.rainbow,
    attack: 50,
    defense: 420,
    hp: 1400,
    requiredRealmIndex: 12,
  ),
  GameEquipment(
    id: 'shi_jin_chong_wang',
    name: '噬金虫王',
    slot: GameEquipSlot.accessory,
    quality: GameEquipQuality.rainbow,
    attack: 200,
    defense: 110,
    hp: 900,
    requiredRealmIndex: 10,
  ),
];

/// 按 id 取装备；未知 id 返回空。
GameEquipment? gameEquipmentById(String id) {
  for (final item in gameEquipments) {
    if (item.id == id) return item;
  }
  return null;
}

/// 某品质的全部装备（七彩奖励、合成目标用）。
List<GameEquipment> gameEquipmentsOfQuality(GameEquipQuality quality) => [
  for (final item in gameEquipments)
    if (item.quality == quality) item,
];

/// 某栏位某品质的全部装备（合成选目标、掉落池用）。
List<GameEquipment> gameEquipmentsOf(
  GameEquipSlot slot,
  GameEquipQuality quality,
) => [
  for (final item in gameEquipments)
    if (item.slot == slot && item.quality == quality) item,
];

/// 打怪 / 狩猎的掉落池：境界够的装备，但七彩绝不直接掉
/// （七彩只能合成或通关试炼塔 30 层得）。
List<GameEquipment> gameDropPoolForRealm(int realmIndex) => [
  for (final item in gameEquipments)
    if (item.requiredRealmIndex <= realmIndex + 1 &&
        item.quality != GameEquipQuality.rainbow)
      item,
];

/// 妖兽种类（写实 2.5D 造型按种类画）。
enum GameMonsterKind {
  /// 狼。
  wolf,

  /// 蛟。
  jiao,

  /// 蜘蛛。
  spider,

  /// 螂。
  mantis,

  /// 蚁。
  ant,

  /// 蟒。
  python,

  /// 魔物。
  demon,

  /// 鬼物。
  ghost,

  /// 蛟王。
  king,
}

/// 一只妖兽。
class GameMonster {
  /// 妖兽 id。
  final String id;

  /// 妖兽名。
  final String name;

  /// 种类（写实立绘画法）。
  final GameMonsterKind kind;

  /// 建议战力。
  final int power;

  /// 血量。
  final int hp;

  /// 击杀修为。
  final int xpReward;

  /// 击杀元宝。
  final int yuanbaoReward;

  const GameMonster({
    required this.id,
    required this.name,
    required this.kind,
    required this.power,
    required this.hp,
    required this.xpReward,
    required this.yuanbaoReward,
  });
}

/// 妖兽表（按战力升序，打怪与爬塔共用）。
/// 难度上调后：白板境界打不动了，必须靠装备。
/// 怪物战力 = 建议战力，也是它咬人多疼的依据（战场里咬一口
/// 按 战力÷20～战力÷10 算），所以战力上调 = 血量与伤害一起上调。
/// BOSS 金蛟王只加一成（战力 7200→7900、血量 12000→13200）；
/// 其余妖兽战力上调约 20%–30%、血量上调约 50%，打起来明显更费功夫。
const gameMonsters = <GameMonster>[
  GameMonster(
    id: 'ye_lang',
    name: '野狼',
    kind: GameMonsterKind.wolf,
    power: 60,
    hp: 180,
    xpReward: 8,
    yuanbaoReward: 1,
  ),
  GameMonster(
    id: 'mo_jiao',
    name: '墨蛟',
    kind: GameMonsterKind.jiao,
    power: 380,
    hp: 1100,
    xpReward: 30,
    yuanbaoReward: 2,
  ),
  GameMonster(
    id: 'xue_yu_zhi_zhu',
    name: '血玉蜘蛛',
    kind: GameMonsterKind.spider,
    power: 680,
    hp: 1700,
    xpReward: 45,
    yuanbaoReward: 3,
  ),
  GameMonster(
    id: 'jin_bei_yao_lang',
    name: '金背妖螂',
    kind: GameMonsterKind.mantis,
    power: 1100,
    hp: 2600,
    xpReward: 70,
    yuanbaoReward: 4,
  ),
  GameMonster(
    id: 'tie_huo_yi',
    name: '铁火蚁',
    kind: GameMonsterKind.ant,
    power: 1600,
    hp: 3600,
    xpReward: 100,
    yuanbaoReward: 5,
  ),
  GameMonster(
    id: 'bing_huo_mang',
    name: '冰火蟒',
    kind: GameMonsterKind.python,
    power: 2400,
    hp: 5200,
    xpReward: 140,
    yuanbaoReward: 6,
  ),
  GameMonster(
    id: 'gu_mo',
    name: '古魔',
    kind: GameMonsterKind.demon,
    power: 3500,
    hp: 7300,
    xpReward: 200,
    yuanbaoReward: 8,
  ),
  GameMonster(
    id: 'yin_yue_yao_lang',
    name: '银月妖狼',
    kind: GameMonsterKind.wolf,
    power: 4900,
    hp: 9800,
    xpReward: 280,
    yuanbaoReward: 10,
  ),
  GameMonster(
    id: 'tian_gui',
    name: '天鬼',
    kind: GameMonsterKind.ghost,
    power: 6700,
    hp: 13200,
    xpReward: 380,
    yuanbaoReward: 12,
  ),
  GameMonster(
    id: 'jin_jiao_wang',
    name: '金蛟王',
    kind: GameMonsterKind.king,
    power: 7900,
    hp: 13200,
    xpReward: 520,
    yuanbaoReward: 15,
  ),
];

/// 按战力给妖兽定境界名：头顶飘的字，照视频里
/// “筑基后期、结丹后期”那种写法。
String monsterRealmForPower(int power) => switch (power) {
  < 200 => '炼气中期',
  < 400 => '炼气后期',
  < 700 => '筑基初期',
  < 1000 => '筑基中期',
  < 1400 => '筑基后期',
  < 2000 => '结丹初期',
  < 3000 => '结丹中期',
  < 4500 => '结丹后期',
  < 6000 => '元婴初期',
  _ => '元婴中期',
};

/// 按 id 取妖兽。
GameMonster gameMonsterById(String id) {
  for (final monster in gameMonsters) {
    if (monster.id == id) return monster;
  }
  return gameMonsters.first;
}

/// 当前战力该打哪只妖兽（战力 >= 妖兽战力里最大的那只）。
GameMonster gameMonsterForPower(int power) {
  var current = gameMonsters.first;
  for (final monster in gameMonsters) {
    if (power >= monster.power) current = monster;
  }
  return current;
}

/// 主线推图一章（挂机版 H5 的推图结构：征战天南大陆，一章一关）。
class GameChapter {
  /// 章 id（落盘用）。
  final String id;

  /// 章名。
  final String title;

  /// 章副标题（玩法说明）。
  final String subtitle;

  /// 所属副本。
  final String dungeon;

  /// 建议战力。
  final int requiredPower;

  /// 要到的修为门槛。
  final int requiredRealmXp;

  /// 通关修为奖励。
  final int xpReward;

  /// 通关元宝奖励。
  final int yuanbaoReward;

  /// 通关掉落装备 id（可空）。
  final String? equipRewardId;

  const GameChapter({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.dungeon,
    required this.requiredPower,
    required this.requiredRealmXp,
    required this.xpReward,
    required this.yuanbaoReward,
    this.equipRewardId,
  });
}

/// 主线推图 12 章：顺序照挂机版 H5 的关卡线——推图天南大陆 →
/// 血色禁地 → 乱星海狩猎 → 虚天殿玄关 → 坠魔谷 → 昆吾山 →
/// 广寒界 → 惊蛰十二变 → 玄界巡狩 → 飞升之路 → 小绿瓶之谜。
/// 建议战力 80→8200：只靠境界白板（满级 590）连第 4 章都打不过，
/// 每章都要配齐当期装备、升强化才能过；第 1 章打几只怪掉一件
/// 白装就能过，第 12 章要全身红装强化满级，混搭七彩更轻松。通关奖励
/// 不再给七彩装备（七彩只合成或通关塔 30 层得）。
const gameChapters = <GameChapter>[
  GameChapter(
    id: 'map01',
    title: '七玄门试炼',
    subtitle: '推图第 1 章 · 天南大陆',
    dungeon: '天南大陆',
    requiredPower: 80,
    requiredRealmXp: 0,
    xpReward: 100,
    yuanbaoReward: 10,
    equipRewardId: 'jin_guang_jian',
  ),
  GameChapter(
    id: 'map02',
    title: '黄枫谷入门',
    subtitle: '推图第 2 章 · 天南大陆',
    dungeon: '天南大陆',
    requiredPower: 300,
    requiredRealmXp: 300,
    xpReward: 200,
    yuanbaoReward: 15,
    equipRewardId: 'qing_yuan_jian',
  ),
  GameChapter(
    id: 'map03',
    title: '血色禁地',
    subtitle: '推图第 3 章 · 禁地试炼',
    dungeon: '血色禁地',
    requiredPower: 450,
    requiredRealmXp: 300,
    xpReward: 350,
    yuanbaoReward: 20,
    equipRewardId: 'yin_yang_zi_mu_huan',
  ),
  GameChapter(
    id: 'map04',
    title: '乱星海狩猎',
    subtitle: '推图第 4 章 · 猎妖取丹',
    dungeon: '乱星海',
    requiredPower: 700,
    requiredRealmXp: 1000,
    xpReward: 500,
    yuanbaoReward: 25,
    equipRewardId: 'pi_xie_shen_lei_zhu',
  ),
  GameChapter(
    id: 'map05',
    title: '虚天殿·玄关',
    subtitle: '推图第 5 章 · 虚天玄关',
    dungeon: '虚天殿',
    requiredPower: 1100,
    requiredRealmXp: 3000,
    xpReward: 700,
    yuanbaoReward: 30,
    equipRewardId: 'qing_zhu_feng_yun_jian',
  ),
  GameChapter(
    id: 'map06',
    title: '坠魔谷',
    subtitle: '推图第 6 章 · 古魔试炼',
    dungeon: '坠魔谷',
    requiredPower: 1600,
    requiredRealmXp: 3000,
    xpReward: 900,
    yuanbaoReward: 35,
    equipRewardId: 'feng_lei_chi',
  ),
  GameChapter(
    id: 'map07',
    title: '昆吾山',
    subtitle: '推图第 7 章 · 封印之地',
    dungeon: '昆吾山',
    requiredPower: 2300,
    requiredRealmXp: 8000,
    xpReward: 1200,
    yuanbaoReward: 40,
    equipRewardId: 'tian_can_bao_jia',
  ),
  GameChapter(
    id: 'map08',
    title: '广寒界',
    subtitle: '推图第 8 章 · 寒界秘境',
    dungeon: '广寒界',
    requiredPower: 3000,
    requiredRealmXp: 8000,
    xpReward: 1500,
    yuanbaoReward: 50,
    equipRewardId: 'yang_hun_mu_pei',
  ),
  GameChapter(
    id: 'map09',
    title: '惊蛰一变',
    subtitle: '推图第 9 章 · 渡劫十二变',
    dungeon: '惊蛰十二变',
    requiredPower: 4000,
    requiredRealmXp: 15000,
    xpReward: 2000,
    yuanbaoReward: 60,
    equipRewardId: 'xue_mo_jian',
  ),
  GameChapter(
    id: 'map10',
    title: '玄界巡狩',
    subtitle: '推图第 10 章 · 巡狩试炼',
    dungeon: '玄界',
    requiredPower: 5200,
    requiredRealmXp: 15000,
    xpReward: 2600,
    yuanbaoReward: 70,
    equipRewardId: 'xu_tian_ding',
  ),
  GameChapter(
    id: 'map11',
    title: '飞升之路',
    subtitle: '推图第 11 章 · 天劫闯关',
    dungeon: '飞升之路',
    requiredPower: 6800,
    requiredRealmXp: 30000,
    xpReward: 3500,
    yuanbaoReward: 90,
    equipRewardId: 'jin_lei_zhu_jian',
  ),
  GameChapter(
    id: 'map12',
    title: '小绿瓶之谜',
    subtitle: '推图第 12 章 · 掌天瓶',
    dungeon: '掌天瓶',
    requiredPower: 8200,
    requiredRealmXp: 60000,
    xpReward: 5000,
    yuanbaoReward: 120,
    equipRewardId: 'mo_ling_sheng_zhou',
  ),
];

/// 养成任务（挂机版 H5 的养成系统，一次性）。
class GameTrainingQuest {
  /// 任务 id。
  final String id;

  /// 任务名。
  final String title;

  /// 任务说明。
  final String subtitle;

  /// 要到的修为门槛。
  final int requiredRealmXp;

  /// 奖励修为。
  final int xpReward;

  /// 奖励元宝。
  final int yuanbaoReward;

  const GameTrainingQuest({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.requiredRealmXp,
    required this.xpReward,
    required this.yuanbaoReward,
  });
}

/// 养成任务 5 项：仙法学习、法宝觉醒、妖兽培育、法器锻造、傀儡操纵。
const gameTrainingQuests = <GameTrainingQuest>[
  GameTrainingQuest(
    id: 'train_xianfa',
    title: '仙法学习',
    subtitle: '学会第一门仙法，青元剑诀入门',
    requiredRealmXp: 0,
    xpReward: 150,
    yuanbaoReward: 10,
  ),
  GameTrainingQuest(
    id: 'train_fabao',
    title: '法宝觉醒',
    subtitle: '觉醒一件法宝，战力大涨',
    requiredRealmXp: 300,
    xpReward: 250,
    yuanbaoReward: 15,
  ),
  GameTrainingQuest(
    id: 'train_yaoshou',
    title: '妖兽培育',
    subtitle: '培育一只妖兽助战，乱星海猎妖',
    requiredRealmXp: 1000,
    xpReward: 400,
    yuanbaoReward: 20,
  ),
  GameTrainingQuest(
    id: 'train_faqi',
    title: '法器锻造',
    subtitle: '锻造一件法器，强化一件装备',
    requiredRealmXp: 3000,
    xpReward: 600,
    yuanbaoReward: 25,
  ),
  GameTrainingQuest(
    id: 'train_kuilei',
    title: '傀儡操纵',
    subtitle: '操纵一具傀儡，替你打怪',
    requiredRealmXp: 8000,
    xpReward: 900,
    yuanbaoReward: 30,
  ),
];

/// 试炼塔一层。
class GameTowerFloor {
  /// 层数（1 起）。
  final int floor;

  /// 所属副本。
  final String dungeon;

  /// 守层妖兽 id。
  final String monsterId;

  /// 建议战力。
  final int requiredPower;

  /// 通关修为奖励。
  final int xpReward;

  /// 通关元宝奖励。
  final int yuanbaoReward;

  const GameTowerFloor({
    required this.floor,
    required this.dungeon,
    required this.monsterId,
    required this.requiredPower,
    required this.xpReward,
    required this.yuanbaoReward,
  });
}

/// 试炼塔 30 层：血色禁地 1–6、虚天殿 7–12、坠魔谷 13–18、
/// 昆吾山 19–24、广寒界 25–30。
/// 建议战力 = 100 + 层数 ×65（第 1 层 165，第 30 层 2050）：
/// 每层加成只比原来（+60/层）略高一点，但战力公式改了，
/// 境界白板再也碾压不了塔，必须靠装备。通关 30 层得一件七彩装备。
List<GameTowerFloor> get gameTowerFloors {
  const dungeons = <String>['血色禁地', '虚天殿', '坠魔谷', '昆吾山', '广寒界'];
  const monsters = <String>[
    'ye_lang',
    'mo_jiao',
    'xue_yu_zhi_zhu',
    'jin_bei_yao_lang',
    'tie_huo_yi',
    'bing_huo_mang',
    'gu_mo',
    'yin_yue_yao_lang',
    'tian_gui',
    'jin_jiao_wang',
  ];
  return List<GameTowerFloor>.generate(30, (index) {
    final floor = index + 1;
    final dungeon = dungeons[(floor - 1) ~/ 6];
    final monster = monsters[(floor - 1) * monsters.length ~/ 30];
    return GameTowerFloor(
      floor: floor,
      dungeon: dungeon,
      monsterId: monster,
      requiredPower: 100 + floor * 65,
      xpReward: 50 + floor * 30,
      yuanbaoReward: 2 + floor ~/ 3,
    );
  });
}

/// 大招（按职业分，写实 2.5D 人物施展）。
class GameSkill {
  /// 技能 id。
  final String id;

  /// 技能名。
  final String name;

  /// 所属职业（天道/逍遥/金刚）；'共用' 为全职业大招。
  final String profession;

  /// 技能说明。
  final String desc;

  const GameSkill({
    required this.id,
    required this.name,
    required this.profession,
    required this.desc,
  });
}

/// 大招表：万剑归宗、青元剑诀、大庚剑阵、真魔功、泰阳诀、
/// 辟邪神雷、乾蓝冰焰与共用渡劫大招惊蛰十二变。
const gameSkills = <GameSkill>[
  GameSkill(id: 'qingyuan', name: '青元剑诀', profession: '天道', desc: '青剑齐出，剑气纵横'),
  GameSkill(id: 'dageng', name: '大庚剑阵', profession: '天道', desc: '剑阵布开，万剑归一'),
  GameSkill(id: 'wanjian', name: '万剑归宗', profession: '天道', desc: '万剑齐发，横扫全场'),
  GameSkill(id: 'zhenmo', name: '真魔功', profession: '逍遥', desc: '魔影重重，飞轮斩妖'),
  GameSkill(id: 'moying', name: '魔影遁', profession: '逍遥', desc: '残影瞬移，出其不意'),
  GameSkill(id: 'feilun', name: '飞轮斩', profession: '逍遥', desc: '双轮飞旋，割裂妖躯'),
  GameSkill(id: 'taiyang', name: '泰阳诀', profession: '金刚', desc: '金罩护体，反伤震敌'),
  GameSkill(id: 'jinzhong', name: '金钟罩', profession: '金刚', desc: '金钟长鸣，刀枪不入'),
  GameSkill(id: 'jingzhe', name: '惊蛰十二变', profession: '共用', desc: '渡劫大招，惊蛰化龙'),
  GameSkill(id: 'bixie', name: '辟邪神雷', profession: '共用', desc: '天雷劈下，专克妖魔'),
  GameSkill(id: 'qianlan', name: '乾蓝冰焰', profession: '共用', desc: '冰焰飞出，冻彻妖躯'),
];

/// 某职业的大招（天道/逍遥/金刚各 3 个 + 共用法术 3 个：
/// 惊蛰十二变、辟邪神雷、乾蓝冰焰）。
List<GameSkill> gameSkillsForProfession(String? profession) {
  final out = <GameSkill>[
    for (final skill in gameSkills)
      if (skill.profession == profession) skill,
    for (final skill in gameSkills)
      if (skill.profession == '共用') skill,
  ];
  if (out.length <= 1) {
    // 未知职业退化为天道大招 + 共用大招。
    return [
      for (final skill in gameSkills)
        if (skill.profession == '天道' || skill.profession == '共用') skill,
    ];
  }
  return out;
}

/// 按 id 取大招（未知 id 返回空）。
GameSkill? gameSkillsById(String id) {
  for (final skill in gameSkills) {
    if (skill.id == id) return skill;
  }
  return null;
}

/// 组队机器人：单机游戏里的虚拟队友，看着像真人玩家——
/// 名字、衣服、武器各不一样，会走位、会放技能、会喊话，
/// 3 人满队一起进副本围打 BOSS，不用真人联网。
class GameTeamBot {
  /// 队友名（头顶飘“境界+名字”）。
  final String name;

  /// 性别（立绘用）。
  final bool isFemale;

  /// 职业（天道/逍遥/金刚，决定武器与技能动画）。
  final String profession;

  /// 服饰 id（见 [cultivationCostumes]，跟道友穿得不一样）。
  final String costumeId;

  /// 修为偏移：队友境界按道友总修为 + 该偏移算，看着像
  /// 水平接近的真人队友。
  final int xpOffset;

  const GameTeamBot({
    required this.name,
    required this.isFemale,
    required this.profession,
    required this.costumeId,
    required this.xpOffset,
  });
}

/// 固定 2 名组队机器人（加道友正好 3 人满队）。
const gameTeamBots = <GameTeamBot>[
  GameTeamBot(
    name: '紫灵',
    isFemale: true,
    profession: '天道',
    costumeId: 'zi',
    xpOffset: 100,
  ),
  GameTeamBot(
    name: '厉飞雨',
    isFemale: false,
    profession: '金刚',
    costumeId: 'zhu',
    xpOffset: -150,
  ),
];

/// 站点通关节点：站点不靠钥匙、不靠买，绑境界与塔层，
/// 通过了就点亮能看，没通过显示锁定和差多少。
class GameSiteNode {
  /// 站点在分档表里的核心 id（见 [adultVideoSiteOrder]）。
  final String coreId;

  /// 节点显示名（影视区站名以影视区为准，这里是简称）。
  final String label;

  /// 要到的修为门槛。
  final int requiredRealmXp;

  /// 要打到的塔层。
  final int requiredTowerFloor;

  const GameSiteNode({
    required this.coreId,
    required this.label,
    required this.requiredRealmXp,
    required this.requiredTowerFloor,
  });

  /// 该节点是否已解锁。
  bool unlocked(int xp, int towerFloor) =>
      xp >= requiredRealmXp && towerFloor >= requiredTowerFloor;

  /// 该节点所属成人档位（0–3）：按修为门槛排，
  /// 3000 第 1 档、8000 第 2 档、15000 第 3 档、30000 第 4 档。
  /// 档位只用来在看片扣费提示里写清是哪一档，不参与定价；
  /// 进站免费（境界与塔层够了就能进，不扣元宝），看片费另算。
  int get tier => switch (requiredRealmXp) {
    >= 30000 => 3,
    >= 15000 => 2,
    >= 8000 => 1,
    _ => 0,
  };

  /// 还差多少修为；已够为 0。
  int xpShort(int xp) => xp >= requiredRealmXp ? 0 : requiredRealmXp - xp;

  /// 还差几层塔；已够为 0。
  int floorShort(int towerFloor) =>
      towerFloor >= requiredTowerFloor ? 0 : requiredTowerFloor - towerFloor;
}

/// 站点通关节点 13 个：按 4 档门槛与塔层排开。
const gameSiteNodes = <GameSiteNode>[
  GameSiteNode(
    coreId: 'sex8',
    label: 'Sex8',
    requiredRealmXp: 3000,
    requiredTowerFloor: 3,
  ),
  GameSiteNode(
    coreId: 'hddj',
    label: '黄豆短剧',
    requiredRealmXp: 3000,
    requiredTowerFloor: 3,
  ),
  GameSiteNode(
    coreId: 'huangguo',
    label: '黄果',
    requiredRealmXp: 3000,
    requiredTowerFloor: 6,
  ),
  GameSiteNode(
    coreId: 'huangguotv',
    label: '黄果TV',
    requiredRealmXp: 3000,
    requiredTowerFloor: 6,
  ),
  GameSiteNode(
    coreId: 'jable',
    label: 'Jable',
    requiredRealmXp: 8000,
    requiredTowerFloor: 12,
  ),
  GameSiteNode(
    coreId: 'javwine',
    label: 'JAV.WINE',
    requiredRealmXp: 8000,
    requiredTowerFloor: 15,
  ),
  GameSiteNode(
    coreId: 'pornhub',
    label: 'Pornhub',
    requiredRealmXp: 15000,
    requiredTowerFloor: 18,
  ),
  GameSiteNode(
    coreId: 'vjav',
    label: 'VJAV',
    requiredRealmXp: 15000,
    requiredTowerFloor: 21,
  ),
  GameSiteNode(
    coreId: 'abjav',
    label: 'ABJAV',
    requiredRealmXp: 15000,
    requiredTowerFloor: 24,
  ),
  GameSiteNode(
    coreId: 'asextv',
    label: 'AsexTV',
    requiredRealmXp: 15000,
    requiredTowerFloor: 27,
  ),
  GameSiteNode(
    coreId: 'xhamster',
    label: 'xHamster',
    requiredRealmXp: 30000,
    requiredTowerFloor: 27,
  ),
  GameSiteNode(
    coreId: 'missav',
    label: 'MissAV',
    requiredRealmXp: 30000,
    requiredTowerFloor: 30,
  ),
  GameSiteNode(
    coreId: 'javrate',
    label: '鉴黄师',
    requiredRealmXp: 30000,
    requiredTowerFloor: 30,
  ),
];

/// 影视区看一部片子扣多少元宝：每部 20，不分档。
/// 扣费点在进详情页（点一部片子进详情页时扣），不是进站、不是开播；
/// 同一部片子同一次进入里重复进详情页不再重复扣，换一部再扣 20。
const int gameAdultFilmCost = 20;

/// 元宝商城一件商品。
class GameShopItem {
  /// 商品 id。
  final String id;

  /// 商品名。
  final String name;

  /// 售价（元宝）。
  final int price;

  /// 商品说明。
  final String desc;

  const GameShopItem({
    required this.id,
    required this.name,
    required this.price,
    required this.desc,
  });
}

/// 元宝商城：聚气丹（+300 修为）、双倍修为符（双倍 1 小时）、
/// 法宝盲盒（随机一件装备）。
const gameShopItems = <GameShopItem>[
  GameShopItem(id: 'juqi_dan', name: '聚气丹', price: 50, desc: '服下 +300 修为'),
  GameShopItem(id: 'double_fu', name: '双倍修为符', price: 100, desc: '1 小时内修为双倍'),
  GameShopItem(id: 'fabao_box', name: '法宝盲盒', price: 200, desc: '随机开出一件装备'),
];

/// 挂机收益：每秒修为（与打坐同一速率，见 [cultivationXpPerSecond]，
/// 双倍符时 ×2）、每分钟元宝 1 个。
const gameIdleYuanbaoPerMinute = 1;

/// 离线结算上限：8 小时（鸿蒙 NEXT 杀后台严，超过 8 小时只按 8 小时算）。
const gameOfflineCapHours = 8;

/// 乱星海狩猎：每天 3 次，每次 +20 元宝、有几率掉装备。
const gameHuntPerDay = 3;

/// 掌天瓶：每天 1 次，+500 修为。
const gameBottleXp = 500;
