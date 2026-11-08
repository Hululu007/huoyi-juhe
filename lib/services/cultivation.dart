import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 修仙修炼体系（凡人修仙传境界划分）。
///
/// 境界分组：下境界·人界（炼气、筑基、结丹、元婴、化神）、
/// 中境界·灵界（炼虚、合体、大乘）、上境界·仙界（渡劫、真仙、金仙、
/// 太乙玉仙、大罗金仙、道祖）。每境分初期/中期/后期三档（炼气期
/// 0～299 三等分：初期 0～99、中期 100～199、后期 200～299），
/// 道祖是顶峰，不再分期。人物等级与境界小档一一对应，炼气初期
/// Lv.1……道祖 Lv.40 封顶。
///
/// 修为获得：活动 1 小时得 1000 修为（基础速率，约 16.67/分钟），
/// 全局 ×1.8 加成后约 1800/小时（30/分钟）；看完 1 集短剧 +300
/// 修为（≈10 分钟活动量）、读完 1 章小说/漫画 +150 修为、听完
/// 1 章听书 +150 修为（≈5 分钟活动量）；打坐与看/读/听同一速率。
/// 修为与各分类时长落盘持久化（SharedPreferences），覆盖安装不丢。

/// 境界所属分组。
enum CultivationGroup {
  /// 下境界·人界。
  human,

  /// 中境界·灵界。
  spirit,

  /// 上境界·仙界。
  immortal,
}

/// 一个境界的静态定义。
class CultivationRealm {
  /// 境界名（炼气期 / 筑基期 / … / 真仙 / 道祖）。
  final String name;

  /// 所属分组。
  final CultivationGroup group;

  /// 累计修为门槛。
  final int threshold;

  /// 是否道祖（顶峰，不再分期）。
  final bool isPeak;

  const CultivationRealm({
    required this.name,
    required this.group,
    required this.threshold,
    this.isPeak = false,
  });
}

/// 境界表（按修为门槛升序）。
const cultivationRealms = <CultivationRealm>[
  CultivationRealm(
    name: '炼气期',
    group: CultivationGroup.human,
    threshold: 0,
  ),
  CultivationRealm(
    name: '筑基期',
    group: CultivationGroup.human,
    threshold: 300,
  ),
  CultivationRealm(
    name: '结丹期',
    group: CultivationGroup.human,
    threshold: 1000,
  ),
  CultivationRealm(
    name: '元婴期',
    group: CultivationGroup.human,
    threshold: 3000,
  ),
  CultivationRealm(
    name: '化神期',
    group: CultivationGroup.human,
    threshold: 8000,
  ),
  CultivationRealm(
    name: '炼虚期',
    group: CultivationGroup.spirit,
    threshold: 15000,
  ),
  CultivationRealm(
    name: '合体期',
    group: CultivationGroup.spirit,
    threshold: 30000,
  ),
  CultivationRealm(
    name: '大乘期',
    group: CultivationGroup.spirit,
    threshold: 60000,
  ),
  CultivationRealm(
    name: '渡劫期',
    group: CultivationGroup.immortal,
    threshold: 100000,
  ),
  CultivationRealm(
    name: '真仙',
    group: CultivationGroup.immortal,
    threshold: 200000,
  ),
  CultivationRealm(
    name: '金仙',
    group: CultivationGroup.immortal,
    threshold: 400000,
  ),
  CultivationRealm(
    name: '太乙玉仙',
    group: CultivationGroup.immortal,
    threshold: 800000,
  ),
  CultivationRealm(
    name: '大罗金仙',
    group: CultivationGroup.immortal,
    threshold: 1600000,
  ),
  CultivationRealm(
    name: '道祖',
    group: CultivationGroup.immortal,
    threshold: 3200000,
    isPeak: true,
  ),
];

/// 分组显示名。
String cultivationGroupName(CultivationGroup group) => switch (group) {
  CultivationGroup.human => '下境界·人界',
  CultivationGroup.spirit => '中境界·灵界',
  CultivationGroup.immortal => '上境界·仙界',
};

/// 小期名：初期 / 中期 / 后期。
const _phaseNames = <String>['初期', '中期', '后期'];

/// 人物等级上限：道祖 Lv.270 封顶。等级按游戏里的级数，每境 20 级：
/// 炼气 Lv.10-29、筑基 Lv.30-49、结丹 Lv.50-69、元婴 Lv.70-89、
/// 化神 Lv.90-109、炼虚 Lv.110-129、合体 Lv.130-149、大乘
/// Lv.150-169、渡劫 Lv.170-189、真仙 Lv.190-209、金仙 Lv.210-229、
/// 太乙 Lv.230-249、大罗 Lv.250-269、道祖 Lv.270。
/// 每境 3 小档按 7/7/6 分级（初期 7 级、中期 7 级、后期 6 级），
/// 如结丹初期 50-56、中期 57-63、后期 64-69。炼气从 10 级起
/// （1-9 级为凡人阶段），新建人物是炼气初期即 Lv.10。
const maxCultivationLevel = 270;

/// 每境的等级数。
const _levelsPerRealm = 20;

/// 各小档的等级数：初期 7 级、中期 7 级、后期 6 级。
const _levelsPerPhase = <int>[7, 7, 6];

/// 某境界的起始等级（炼气 10、筑基 30……大罗 250；道祖 270 单独算）。
int _realmBaseLevel(int realmIndex) => 10 + realmIndex * _levelsPerRealm;

/// 修为换算成人物等级（纯函数）：先按修为定境界与小档，再在该小档
/// 的修为区间内按该档级数等分。道祖封顶 Lv.270。
int levelForXp(int xp) {
  final info = realmForXp(xp);
  return info.level;
}

/// 某修为对应的境界信息（纯函数）。
class RealmInfo {
  /// 境界在境界表里的下标。
  final int realmIndex;

  /// 境界定义。
  final CultivationRealm realm;

  /// 境界显示名：炼气期 初期 / 结丹期 中期 / 真仙初期 / 道祖。
  final String displayName;

  /// 徽章第一行：境界名（炼气期 / 结丹期 / 真仙 / 道祖）。
  final String badgeLine1;

  /// 徽章第二行：小期（初期 / 中期 / 后期 / 顶峰）。
  final String badgeLine2;

  /// 人物等级：与境界小档一一对应，炼气初期 Lv.1……道祖 Lv.40 封顶。
  final int level;

  /// 等级显示：Lv.1 / Lv.40。
  String get levelLabel => 'Lv.$level';

  /// 所属分组显示名：下境界·人界 / 中境界·灵界 / 上境界·仙界。
  final String groupName;

  /// 到下一境界还差多少修为；道祖为 0。
  final int xpToNext;

  /// 下一境界名；道祖为空。
  final String? nextRealmName;

  /// 在当前境界内的进度 0..1；道祖为 1。
  final double progress;

  const RealmInfo({
    required this.realmIndex,
    required this.realm,
    required this.displayName,
    required this.badgeLine1,
    required this.badgeLine2,
    required this.level,
    required this.groupName,
    required this.xpToNext,
    required this.nextRealmName,
    required this.progress,
  });
}

/// 修为换算成境界（纯函数）。
RealmInfo realmForXp(int xp) {
  final value = xp < 0 ? 0 : xp;
  var index = 0;
  for (var i = 0; i < cultivationRealms.length; i++) {
    if (value >= cultivationRealms[i].threshold) index = i;
  }
  final realm = cultivationRealms[index];
  final groupName = cultivationGroupName(realm.group);
  final isLast = index >= cultivationRealms.length - 1;
  final nextThreshold = isLast
      ? null
      : cultivationRealms[index + 1].threshold;
  final xpToNext = nextThreshold == null ? 0 : nextThreshold - value;
  final nextRealmName = isLast ? null : cultivationRealms[index + 1].name;
  final progress = nextThreshold == null
      ? 1.0
      : ((value - realm.threshold) / (nextThreshold - realm.threshold))
            .clamp(0.0, 1.0);

  if (realm.isPeak) {
    return RealmInfo(
      realmIndex: index,
      realm: realm,
      displayName: '道祖',
      badgeLine1: '道祖',
      badgeLine2: '顶峰',
      level: maxCultivationLevel,
      groupName: groupName,
      xpToNext: 0,
      nextRealmName: null,
      progress: 1.0,
    );
  }
  // 每境按修为区间三等分初期/中期/后期（炼气期 0～299 也一样：
  // 初期 0～99、中期 100～199、后期 200～299）。道祖已在上面返回，
  // 这里 nextThreshold 一定非空。
  final next = nextThreshold!;
  final range = next - realm.threshold;
  final phaseIndex =
      min(((value - realm.threshold) * 3) ~/ range, 2);
  final phase = _phaseNames[phaseIndex];
  // 等级：每境 20 级（炼气 10-29、筑基 30-49……大罗 250-269），
  // 小档按 7/7/6 分级（初期 7 级、中期 7 级、后期 6 级）；先定
  // 境界与小档，再在该小档的修为区间内按该档级数等分。
  // 小档修为区间边界（与上面 phaseIndex 的换算一致，用向上取整）：
  // 初期 [threshold, threshold+ceil(range/3))，中期 [.., ..+ceil(2range/3))，
  // 后期 [.., next)。
  final phaseStart = realm.threshold + (range * phaseIndex + 2) ~/ 3;
  final phaseEnd = phaseIndex >= 2
      ? next
      : realm.threshold + (range * (phaseIndex + 1) + 2) ~/ 3;
  final levelsInPhase = _levelsPerPhase[phaseIndex];
  final phaseOffset = phaseIndex == 0
      ? 0
      : phaseIndex == 1
          ? _levelsPerPhase[0]
          : _levelsPerPhase[0] + _levelsPerPhase[1];
  final withinPhase = min(
    (value - phaseStart) * levelsInPhase ~/ (phaseEnd - phaseStart),
    levelsInPhase - 1,
  );
  final level = _realmBaseLevel(index) + phaseOffset + withinPhase;
  // 真仙起的仙境名本身不带“期”，显示为“真仙初期”；筑基期起的人界/
  // 灵界境名带“期”，显示为“结丹期 中期”。
  final hasQiSuffix = realm.name.endsWith('期');
  return RealmInfo(
    realmIndex: index,
    realm: realm,
    displayName: hasQiSuffix ? '${realm.name} $phase' : '${realm.name}$phase',
    badgeLine1: realm.name,
    badgeLine2: phase,
    level: level,
    groupName: groupName,
    xpToNext: xpToNext,
    nextRealmName: nextRealmName,
    progress: progress,
  );
}

/// 修为分类（修为按分类分别计时）。
enum CultivationCategory {
  /// 小说。
  novel,

  /// 漫画。
  comic,

  /// 听书。
  audio,

  /// 影视。
  video,

  /// 短剧。
  drama,
}

/// 分类显示名。
String cultivationCategoryName(CultivationCategory category) =>
    switch (category) {
      CultivationCategory.novel => '小说',
      CultivationCategory.comic => '漫画',
      CultivationCategory.audio => '听书',
      CultivationCategory.video => '影视',
      CultivationCategory.drama => '短剧',
    };

/// 主修分类对应的灵根名。
String spiritRootName(CultivationCategory category) => switch (category) {
  CultivationCategory.novel => '文灵根',
  CultivationCategory.comic => '画灵根',
  CultivationCategory.audio => '音灵根',
  CultivationCategory.video => '影灵根',
  CultivationCategory.drama => '剧灵根',
};

/// 性别（创建道友档案时选）。
enum CultivationGender {
  /// 男。
  male,

  /// 女。
  female,
}

/// 性别显示名。
String cultivationGenderName(CultivationGender gender) =>
    gender == CultivationGender.male ? '男' : '女';

/// 性别存盘值。
String _cultivationGenderStorage(CultivationGender gender) =>
    gender == CultivationGender.male ? 'male' : 'female';

CultivationGender? _cultivationGenderFromStorage(String? value) =>
    switch (value) {
      'male' => CultivationGender.male,
      'female' => CultivationGender.female,
      _ => null,
    };

/// 宗门：越国七派（凡人修仙传）。
const cultivationSects = <String>[
  '黄枫谷',
  '掩月宗',
  '清虚门',
  '化刀坞',
  '天阙堡',
  '巨剑门',
  '灵兽山',
];

/// 职业：修行路子（老版《凡人修仙传》网游职业设定：天道、逍遥、
/// 金刚三个；之前剑修/体修/魔修/法修四职业已作废）。
const cultivationProfessions = <String>['天道', '逍遥', '金刚'];

/// 默认职业：天道。
const defaultCultivationProfession = '天道';

/// 各职业的招牌技能名（打坐小人放技能时用）：
/// 天道（剑修）万剑归宗、逍遥（身法/飞轮）真魔功、
/// 金刚（防御/反伤）泰阳诀。未知职业退化为天道·万剑归宗。
String cultivationProfessionSkill(String? profession) {
  return switch (profession) {
    '逍遥' => '真魔功',
    '金刚' => '泰阳诀',
    _ => '万剑归宗',
  };
}

/// 职业是否合法（天道/逍遥/金刚三项之一）。
bool isCultivationProfession(String? profession) =>
    cultivationProfessions.contains(profession);

/// 打坐小人袍面上的纹样（画在袍子上的细节）。
enum CultivationCostumePattern {
  /// 云纹。
  cloud,

  /// 梅花。
  plum,

  /// 仙鹤。
  crane,

  /// 符文/火焰纹。
  flame,

  /// 波纹。
  wave,
}

/// 一套古代卡通服饰：颜色与领口/腰带/纹样细节，全部用 Flutter
/// 代码画，不依赖外部图片素材。
class CultivationCostume {
  /// 服饰 id（落盘用）。
  final String id;

  /// 显示名（如 青色道袍）。
  final String name;

  /// 袍子主色。
  final Color robe;

  /// 领口/袖口镶边色。
  final Color trim;

  /// 腰带色。
  final Color belt;

  /// 袍面纹样。
  final CultivationCostumePattern pattern;

  const CultivationCostume({
    required this.id,
    required this.name,
    required this.robe,
    required this.trim,
    required this.belt,
    required this.pattern,
  });
}

/// 6 套古代服饰（创建档案弹窗与档案卡换装共用）：区别在颜色与
/// 领口/腰带/纹样细节上。
const cultivationCostumes = <CultivationCostume>[
  CultivationCostume(
    id: 'qing',
    name: '青色道袍',
    robe: Color(0xFF5B8C7B),
    trim: Color(0xFFD4AF37),
    belt: Color(0xFF2F4F45),
    pattern: CultivationCostumePattern.cloud,
  ),
  CultivationCostume(
    id: 'bai',
    name: '白色汉服',
    robe: Color(0xFFF5F0E6),
    trim: Color(0xFFE8B4C8),
    belt: Color(0xFFC77D9B),
    pattern: CultivationCostumePattern.plum,
  ),
  CultivationCostume(
    id: 'zi',
    name: '紫色锦袍',
    robe: Color(0xFF7B5BA6),
    trim: Color(0xFFD4AF37),
    belt: Color(0xFF4A3573),
    pattern: CultivationCostumePattern.crane,
  ),
  CultivationCostume(
    id: 'xuan',
    name: '玄色法袍',
    robe: Color(0xFF2B2B33),
    trim: Color(0xFFC0C0C0),
    belt: Color(0xFF8B2E2E),
    pattern: CultivationCostumePattern.flame,
  ),
  CultivationCostume(
    id: 'yue',
    name: '月白儒衫',
    robe: Color(0xFFE8EDF2),
    trim: Color(0xFF8FA8C8),
    belt: Color(0xFF5B7A9E),
    pattern: CultivationCostumePattern.wave,
  ),
  CultivationCostume(
    id: 'zhu',
    name: '朱红战袍',
    robe: Color(0xFFB03A2E),
    trim: Color(0xFFD4AF37),
    belt: Color(0xFF2B2B33),
    pattern: CultivationCostumePattern.flame,
  ),
];

/// 默认服饰：青色道袍。
const defaultCultivationCostumeId = 'qing';

/// 按 id 取服饰；未知 id（或空）退化为默认青色道袍。
CultivationCostume cultivationCostumeById(String? id) {
  for (final costume in cultivationCostumes) {
    if (costume.id == id) return costume;
  }
  return cultivationCostumes.first;
}

/// 脸型（创建人物时选，3 款，画出来区分）。
const cultivationFaces = <String>['瓜子脸', '方脸', '圆脸'];

/// 默认脸型：瓜子脸。
const defaultCultivationFace = '瓜子脸';

/// 发型（创建人物时选，3 款，画出来区分）。
const cultivationHairstyles = <String>['道髻', '披发', '高马尾'];

/// 默认发型：道髻。
const defaultCultivationHairstyle = '道髻';

/// 一种发色（创建人物时选，3 色）。
class CultivationHairColor {
  /// 发色 id（落盘用）。
  final String id;

  /// 显示名（如 黑）。
  final String name;

  /// 头发颜色。
  final Color color;

  const CultivationHairColor({
    required this.id,
    required this.name,
    required this.color,
  });
}

/// 发色（创建人物时选，3 色）。
const cultivationHairColors = <CultivationHairColor>[
  CultivationHairColor(id: 'black', name: '黑', color: Color(0xFF1A1A1A)),
  CultivationHairColor(id: 'brown', name: '棕', color: Color(0xFF6B4226)),
  CultivationHairColor(id: 'silver', name: '银白', color: Color(0xFFE8E8E8)),
];

/// 默认发色：黑。
const defaultCultivationHairColorId = 'black';

/// 按 id 取发色；未知 id（或空）退化为默认黑。
CultivationHairColor cultivationHairColorById(String? id) {
  for (final hairColor in cultivationHairColors) {
    if (hairColor.id == id) return hairColor;
  }
  return cultivationHairColors.first;
}

/// 修为速率：活动 1 小时得 1000 修为（基础，约 16.67/分钟）。
const cultivationXpPerHour = 1000;

/// 全局修为加成 ×1.8（作用于所有修为来源：每分钟、看完一集、
/// 读完一章、听完一章、打坐）。
const cultivationXpMultiplier = 1.8;

/// 每秒修为（计加成后）：1000/3600 × 1.8 = 0.5，即 2 秒 1 修为，
/// 活动 1 小时约 1800 修为（30/分钟）。
const cultivationXpPerSecond = 0.5;

/// 看完 1 集短剧的修为（≈10 分钟活动量，计加成后 300）。
const dramaEpisodeXp = 300;

/// 读完 1 章小说/漫画、听完 1 章听书的修为（≈5 分钟活动量，
/// 计加成后 150）。
const chapterXp = 150;

/// 境界解锁门禁临时关闭开关（测试期间用，用户 2026-11-07 07:45 令：
/// 境界解锁权限先关了，测试时所有站不管修为多少都显示）。
///
/// - true（当前值）：门禁关闭，[adultTierUnlocked] 对全部合法档位
///   （0～3 档）都返回 true，影视区（[visibleSiteIds] 经
///   `visibleVideoZoneSites`）与阅读区成人三分类
///   （`visibleFilmZoneSites`）的站全部可见；分档与解锁逻辑本身
///   没删，[adultTierForIndex]、[adultTierThresholds]、
///   [adultTierSiteIds]、[visibleSiteIds] 原样不动。
/// - false：恢复正常，修为不到门槛的档位继续隐藏。
///
/// 恢复方法：只改这一处，把 true 改回 false，不用改任何页面与调用点。
/// 首次安装建人物硬门槛、升境弹窗、修为统计、打坐、称号
/// 都不走这个开关，一字不动。
///
/// 注意：这里故意用顶层可写 bool 而不用 const，只为单测能验证
/// 开/关两种状态（见 test/cultivation_gate_switch_test.dart）；
/// 正式恢复仍只改这一处的初值。
bool cultivationAdultTierGateDisabledForTesting = false;

/// 解锁门槛（累计修为）：漫画 300（筑基）、听书 1000（结丹）、
/// 影视区 3000（元婴）、影视全部分类 + 称号 8000（化神）。
const comicUnlockXp = 300;
const audioUnlockXp = 1000;
const videoZoneUnlockXp = 3000;
const videoAllCategoriesUnlockXp = 8000;

/// 成人站档位解锁门槛（累计修为）：第 1 档元婴 3000、第 2 档化神
/// 8000、第 3 档炼虚 15000、第 4 档合体 30000。
const adultTierThresholds = <int>[3000, 8000, 15000, 30000];

/// 成人站档位对应的解锁境界名。
const adultTierRealmNames = <String>['元婴期', '化神期', '炼虚期', '合体期'];

/// 成人站分档登记顺序（内嵌版）：批量转站后核心只剩 hgdj/hgdj58/hgdjv
/// 3 站，分档不再读 coreVideoSiteIds，改读这张表。
///
/// 这 201 个 id 是删核心之前的核心登记顺序 201 条，加上 2026-11-07
/// 新入的中国X站精选（chinaxjx，插在末站 wohs 之前进第 4 档），再减
/// 2026-11-08 摘掉的 AOXX69（aoxx69，站方主机无响应，见
/// zakatvExcludedSites 墓碑）。
/// 原 201 条与删核心之前的核心登记顺序一字不差（来源：
/// `~/workspace/batch_convert_work/delete/backup/drama_site_content.dart.bak`
/// 里的旧 coreVideoSiteIds，201 条、无重复；分档只认顺序不认来源，
/// 所以原来在第几档、现在还在第几档，不洗牌）。
/// 201 站时档位是 49/50/50/52（ai4k 因总数变 202 从第 4 档回到第 3 档，
/// 其余抽查站不动；见 adult_tier_embedded_test）。摘 AOXX69 后总数
/// 202→201，只动两站的档：rou 1→0、hgdj 2→1（解锁各提前一档），
/// 其余抽查站不动。
///
/// 注意：不要为短剧区新站往这张表追加——档位是按总数比例均分的，
/// 总数一变边界站就换档（实测：201→203 会让 hgdj 2→1、ai4k 3→2、
/// muzi 3→2，其中 muzi 是影视区站，解锁会从合体 30000 提前到炼虚
/// 15000）。短剧站不进影视区，本表对它不可见；新短剧站（aihi、
/// aipornx）暂不进表，等分档规则本身改版时再议。
///
/// 表里是核心站 id（裸 id，如 `mjv011`）；影视区统一表里的行 id
/// 是另一套写法（种子 `seed_<id>`、jar `jar:zakatv:<key>`、核心裸 id），
/// 查档位前先过 adultSiteIdForUnifiedId 归一化。
///
/// 增减站时同步改这里：新站追加到末尾进第 4 档、或插到指定位置；
/// 删站时删掉对应行；不动 adultTierThresholds 门槛。
/// 从未进过核心的站（jar/种子独占站，如 JAV Verse、91三级）不在表里，
/// 查档位返回 null、按非成人站原样保留——删核心之前它们也没分过档。
const adultVideoSiteOrder = <String>[
  'mjv011', 'huangguo', 'huangguotv', 'hgtvim', 'huai', 'hl365', 'sex8', 'hgdjv',
  'km2', 'cucumber', 'haijiao', 'md', 'utube', 'av91', 'lxs', 'javrate',
  'xszav', 'txfans', 'juyin', '99jj', 'dayday', 'dsav', 'kuaihuo', 'jack20',
  'gqck', 'wuyetv', 'hjw', 'pigav', 'sihucdn', 'sihu', 'xx9',
  '69vj', 'avcnn', 'javhd', 'fq', 'wnzs', 'tudou', 'xjh5', 'xj2',
  'missav', 'hddj', 'jm', 'getav', 'hsck', 'missavoff', 'mirror', '123av',
  'dsd', 'lissav', 'xhamster', 'rou', 'pb', 'rouav', 'av18av', 'dage',
  'sporn', 'okxxx', '591av', 'avjoy', 'hanime', 'xvideo', 'ptt01', 'cporn',
  'xanimu', 'xx01', 'netflav', 'goodav', 'av6k', 'jav', 'jav777', 'airav',
  'go2av', 'mmtv7', 'zggjav', 'avbigplat', 'xhy11', 'pj5ti', 'thdh', 'hjapp',
  '17rip', 'javplay', 'javguru', 'missavt', 'wukong', 'chengren91', 'badyi', 'aiye',
  'av18avmcg', 'avtoday', 'hohoj', 'jptt', 'xojav', 'px8x', 'tinyav', 'pachub',
  'ssis', 'aisxpc', '321av', 'porncgw', 'xlook', 'hgdj', 'javmap', 'madao',
  'chinax', 'swagr', 'tanhua91', 'theporny', 'aimove', 'henhenlu', 'pandatv', 'mianfeiai',
  'avyanjiuyuan', 'xingkongfuli', 'ai2026', 'dj91', 'toptv', 'jin18', 'klxq', 'taose',
  'hongyan', 'naihenda', 'haijiao4k', 'uudj', 'madou', 'dj69', 'ywmm', 'luoliai',
  'shaofu', 'hgai', 'danai', 'yunmeng', 'javzw', 'hduanju', 'rscg91', 'aidj',
  'mose365', 'yiren', 'zwdj', 'hongxing', 'shunvwang', 'heitaoduanju', 'dingjiaseku', 'aiduanju',
  'fuchou', 'shunvqu', 'huangguazy', 'zwwm', 'hgaidj', 'jiuse', 'xianxia', 'ai4k',
  'muzi', 'guzhuang', 'nvdi', 'caoliu', 'djwo', 'hgkpz', 'huangduanju', 'jiuseduanju',
  'xj', 'hbook', 'hgdj58', 'jav188', 'duanjuone', 'crdj', 'javher', 'javwine',
  'lissavcn', 'pornhub', 'hongluo', 'ddys', 'javgg', 'javtiful', 'jable', 'vjav',
  'tiktvod', 'topjav', 'avhwa', 'javdino', 'javhdtube', 'javmit', 'roshy', 'abjav',
  'herexxx', 'japanwhores', 'javfun', 'koreanporn', 'mythav', 'senzuri', 'tokyomotion', 'x51',
  'taiav', 'rouvideo', 'porna91', 'asextv', 'kissjav', 'javtsunami', 'javsiri', 'sexkbj',
  'chinaxjx', 'wohs',
];

/// 成人站档位：按在核心登记表里的下标均分 4 档。
/// 档 = min(3, 下标 × 4 ~/ 站总数)，以后再加站也按比例分。
int adultTierForIndex(int index, int total) {
  if (total <= 0 || index < 0) return 0;
  final tier = index * 4 ~/ total;
  return tier > 3 ? 3 : tier;
}

/// 指定档位在该修为下是否已解锁。
///
/// 门禁临时关闭时（[cultivationAdultTierGateDisabledForTesting]
/// 为 true，测试期间）：合法档位（0～3 档）不管修为多少都算已解锁；
/// 非法档位（< 0 或 >= 4）仍返回 false，不放行。
bool adultTierUnlocked(int tier, int xp) {
  if (tier < 0 || tier >= adultTierThresholds.length) return false;
  if (cultivationAdultTierGateDisabledForTesting) return true;
  return xp >= adultTierThresholds[tier];
}

/// jar 登记 key → 核心站 id 的别名（只列规则算不出来的）：
/// - 数字头站：jar key 是 Rust 模块名（如 `av123`），核心站 id 是
///   文件名（如 `123av`），mod.rs 里 `#[path]` 映射过来的；
/// - `zaketxfans`：jar 登记 key 本身少写了一个 a（应为 `zakatxfans`），
///   类名是 `ZakaTxfansAmns`，站是 `txfans`；
/// - `whos`：核心站 id 是旧拼写 `wohs`（whos.tv），jar 登记已用修正
///   拼写，另有一条 key 就是 `wohs` 的登记，两行同站同档。
const _adultJarKeyAliases = <String, String>{
  'av123': '123av',
  'av321': '321av',
  'av591': '591av',
  'jj99': '99jj',
  'rip17': '17rip',
  'vj69': '69vj',
  'zaketxfans': 'txfans',
  'whos': 'wohs',
};

/// 影视区统一表里的行 id → 核心站 id（分档用的裸 id）。
///
/// - 种子行 `seed_<id>`：seedId 本身就是核心站 id；
/// - jar 行 `jar:<jarId>:<key>`：key 去掉 `Zaka`/`zaka` 前缀后全小写，
///   再过一遍别名表；key 本身就是核心站 id 的（如 `haijiao4k`、
///   `hgdj58`、`rouvideo`、`wohs`、`xj2`、`dsav`）原样返回；
/// - 核心行等裸 id：原样返回。
/// 归一化后仍不在登记表里的（如从未进过核心的 jar/种子站、YouTube、
/// 直播站）查档位返回 null，按非成人站原样保留——删核心之前它们
/// 也没分过档，行为不变。
String adultSiteIdForUnifiedId(String unifiedId) {
  if (unifiedId.startsWith('seed_')) return unifiedId.substring(5);
  if (unifiedId.startsWith('jar:')) {
    final key = unifiedId.split(':').last;
    return adultJarKeyToCoreId(key);
  }
  return unifiedId;
}

/// jar 登记 key → 核心站 id（见 _adultJarKeyAliases）。短剧区加载代码
/// 复用同一份归一化：jar 内置站按 key 找到对应的裸站 id。
String adultJarKeyToCoreId(String key) {
  var stripped = key;
  if (stripped.toLowerCase().startsWith('zaka')) {
    stripped = stripped.substring(4);
  }
  final lowered = stripped.toLowerCase();
  return _adultJarKeyAliases[lowered] ?? lowered;
}

/// 某站在登记表里的档位；不在表里返回 null（不是成人站，不分档）。
/// missav 与鉴黄师（javrate）强制钉到第 4 档末尾，不管它俩在表里
/// 的位置（表里鉴黄师第 16 位、missav 第 41 位）；分档时先按表顺序
/// 正常分 4 档，再把这两站移出、放到第 4 档末尾，不改注册表顺序。
///
/// [siteId] 可以是统一表里的行 id（种子 `seed_<id>`、jar
/// `jar:<jarId>:<key>`、核心裸 id），先归一化成核心站 id 再查表。
int? adultTierForSiteId(String siteId, List<String> registryOrder) {
  final coreId = adultSiteIdForUnifiedId(siteId);
  if (adultTierLastSiteIds.contains(coreId)) return 3;
  final index = registryOrder.indexOf(coreId);
  if (index < 0) return null;
  return adultTierForIndex(index, registryOrder.length);
}

/// 强制钉到第 4 档末尾的两站（按此顺序排在第 4 档最后）：
/// missav 在前、鉴黄师（javrate）压最后。两站先后待用户一句话确认，
/// 用户说换就换这里的顺序。
const adultTierLastSiteIds = <String>['missav', 'javrate'];

/// 某档的站 id 列表（按登记表顺序；第 4 档里强制钉尾的两站排最后，
/// missav 在前、鉴黄师压最后）。供升境解锁弹窗按站名列出。
List<String> adultTierSiteIds(int tier, List<String> registryOrder) {
  final inTier = <String>[];
  for (final id in registryOrder) {
    if (adultTierForSiteId(id, registryOrder) == tier) inTier.add(id);
  }
  if (tier != 3) return inTier;
  // 第 4 档：把钉尾的两站移到最后（按 adultTierLastSiteIds 的顺序）。
  final pinned = <String>[];
  final rest = <String>[];
  for (final id in inTier) {
    if (adultTierLastSiteIds.contains(id)) {
      pinned.add(id);
    } else {
      rest.add(id);
    }
  }
  pinned.sort(
    (a, b) => adultTierLastSiteIds
        .indexOf(a)
        .compareTo(adultTierLastSiteIds.indexOf(b)),
  );
  return [...rest, ...pinned];
}

/// 只留已解锁的站：未解锁的成人站完全隐藏（不在列表里出现）；
/// 非成人站（不在登记表里）原样保留。
List<String> visibleSiteIds(
  List<String> siteIds,
  List<String> adultRegistryOrder,
  int xp,
) {
  final out = <String>[];
  for (final id in siteIds) {
    final tier = adultTierForSiteId(id, adultRegistryOrder);
    if (tier == null || adultTierUnlocked(tier, xp)) out.add(id);
  }
  return out;
}

/// 一次修为变化跨过的境界下标（升序），供升境弹窗用；
/// 没跨过境界返回空。
List<int> crossedRealmIndexes(int oldXp, int newXp) {
  if (newXp <= oldXp) return const [];
  final out = <int>[];
  for (var i = 0; i < cultivationRealms.length; i++) {
    final threshold = cultivationRealms[i].threshold;
    if (oldXp < threshold && newXp >= threshold) out.add(i);
  }
  return out;
}

/// 某境界新解锁的内容区（供升境弹窗列出）：筑基→漫画、结丹→听书、
/// 元婴→影视区（第 1 档站）+ 直播成人源、化神→影视全部分类 + 称号 +
/// 第 2 档站、炼虚→第 3 档站、合体→第 4 档站（全部开完）；
/// 其余境界无新区，返回空。
List<String> realmUnlockZones(int realmIndex) {
  return switch (cultivationRealms[realmIndex].name) {
    '筑基期' => ['漫画区'],
    '结丹期' => ['听书区'],
    '元婴期' => ['影视区（第 1 档站）', '直播成人源'],
    '化神期' => ['影视全部分类', '称号', '影视区第 2 档站'],
    '炼虚期' => ['影视区第 3 档站'],
    '合体期' => ['影视区第 4 档站（全部开完）'],
    _ => const [],
  };
}

/// 某境界新解锁的成人站档位（没有返回 null）：元婴→第 1 档、
/// 化神→第 2 档、炼虚→第 3 档、合体→第 4 档。
int? realmUnlockAdultTier(int realmIndex) {
  return switch (cultivationRealms[realmIndex].name) {
    '元婴期' => 0,
    '化神期' => 1,
    '炼虚期' => 2,
    '合体期' => 3,
    _ => null,
  };
}

/// 称号特效种类（Flutter 实现，不依赖外部素材）。
enum CultivationTitleEffect {
  /// 无特效（无称号的境界行）。
  none,

  /// 绿色微光（黄枫谷精英）。
  greenGlow,

  /// 蓝色微光（所选宗门精英，按宗门微调色）。
  blueGlow,

  /// 金色流光扫过（一马当先）。
  goldShine,

  /// 紫色辉光 + 缓缓上升的光点（虚天殿魁首）。
  purpleGlowDots,

  /// 红橙焰光 + 光点（升仙会魁首）。
  flameGlowDots,

  /// 金色 + 彩虹流光 + 辉光 + 光点（仙界接引，绝版称号，最华丽）。
  rainbowGlowDots,

  /// 前三特效称号（唯我独尊、超凡入化、待补充之三）：大辉光 + 流光 +
  /// 上升光点 + 描边，全榜最华丽，飘在打坐小人头顶。
  grandGlowDots,
}

/// 称号排行榜上的一档：按修为里程碑排，每境一行（名次、称号名、
/// 所需修为与对应境界、达成状态）。称号用《凡人修仙传：人界篇》
/// 游戏里的真实称号；大乘/渡劫/真仙/金仙不配新称号，仍是仙界接引，
/// 到太乙才换前三特效称号（唯我独尊、超凡入化、待补充之三）。
class CultivationTitleTier {
  /// 名次（从 1 开始）。
  final int rank;

  /// 称号名；无新称号的境界行（炼气期、大乘/渡劫/真仙/金仙）为空。
  final String? titleName;

  /// 达成该档所需修为。
  final int requiredXp;

  /// 所属境界在境界表里的下标。
  final int realmIndex;

  /// 境界名（炼气期 / 筑基期 / … / 道祖）。
  final String realmName;

  /// 所属分组显示名。
  final String groupName;

  /// 该称号的特效种类；无称号为 none。
  final CultivationTitleEffect effect;

  /// 是否是排行榜最顶上的三个特效称号（太乙/大罗/道祖档）。
  final bool isTopThree;

  /// 称号名是否是占位（第三个前三称号，用户想不起来名字，
  /// 先留「待补充·前三称号之三」，不是编出来的名字）。
  final bool isPlaceholderTitle;

  const CultivationTitleTier({
    required this.rank,
    required this.titleName,
    required this.requiredXp,
    required this.realmIndex,
    required this.realmName,
    required this.groupName,
    required this.effect,
    this.isTopThree = false,
    this.isPlaceholderTitle = false,
  });

  /// 该档是否有称号。
  bool get hasTitle => titleName != null;
}

/// 所选宗门的精英称号：按「黄枫谷精英」的格式，即「[宗门名]精英」
/// （如落云宗精英、天魔宗精英）。游戏里四个二选宗门称号的具体原名
/// 公开攻略里没写，只写了各不一样，这里按格式套。未选宗门时为通用名。
String sectEliteTitleName(String? sect) {
  final name = sect?.trim() ?? '';
  if (name.isEmpty) return '宗门精英';
  return '$name精英';
}

/// 称号排行榜：每境一行，共 14 档，按修为里程碑从低到高。
/// 筑基 300 黄枫谷精英、结丹 1000 所选宗门精英、元婴 3000 一马当先、
/// 化神 8000 虚天殿魁首、炼虚 15000 升仙会魁首、合体 30000 仙界接引；
/// 大乘/渡劫/真仙/金仙不配新称号，仍是仙界接引；到太乙才换前三
/// 特效称号：太乙 800000「待补充·前三称号之三」（占位，用户想不起
/// 名字先留空，不编名字）、大罗 1600000 超凡入化、道祖 3200000
/// 唯我独尊。前三称号特效最华丽，飘在打坐小人头顶。
List<CultivationTitleTier> cultivationTitleLadder({String? sect}) {
  final tiers = <CultivationTitleTier>[];
  for (var i = 0; i < cultivationRealms.length; i++) {
    final realm = cultivationRealms[i];
    final (
      String? titleName,
      CultivationTitleEffect effect,
      bool isTopThree,
      bool isPlaceholderTitle,
    ) = switch (realm.name) {
      '筑基期' => (
        '黄枫谷精英',
        CultivationTitleEffect.greenGlow,
        false,
        false,
      ),
      '结丹期' => (
        sectEliteTitleName(sect),
        CultivationTitleEffect.blueGlow,
        false,
        false,
      ),
      '元婴期' => ('一马当先', CultivationTitleEffect.goldShine, false, false),
      '化神期' => (
        '虚天殿魁首',
        CultivationTitleEffect.purpleGlowDots,
        false,
        false,
      ),
      '炼虚期' => (
        '升仙会魁首',
        CultivationTitleEffect.flameGlowDots,
        false,
        false,
      ),
      '合体期' => (
        '仙界接引',
        CultivationTitleEffect.rainbowGlowDots,
        false,
        false,
      ),
      '太乙玉仙' => (
        '待补充·前三称号之三',
        CultivationTitleEffect.grandGlowDots,
        true,
        true,
      ),
      '大罗金仙' => (
        '超凡入化',
        CultivationTitleEffect.grandGlowDots,
        true,
        false,
      ),
      '道祖' => (
        '唯我独尊',
        CultivationTitleEffect.grandGlowDots,
        true,
        false,
      ),
      _ => (null, CultivationTitleEffect.none, false, false),
    };
    tiers.add(
      CultivationTitleTier(
        rank: i + 1,
        titleName: titleName,
        requiredXp: realm.threshold,
        realmIndex: i,
        realmName: realm.name,
        groupName: cultivationGroupName(realm.group),
        effect: effect,
        isTopThree: isTopThree,
        isPlaceholderTitle: isPlaceholderTitle,
      ),
    );
  }
  return tiers;
}

/// 用户当前所处的境界行下标（所需修为 <= xp 的最大档），用于榜单
/// 高亮「当前」行。
int currentTitleTierIndex(int xp, [List<CultivationTitleTier>? ladder]) {
  final tiers = ladder ?? cultivationTitleLadder();
  var index = 0;
  for (var i = 0; i < tiers.length; i++) {
    if (xp >= tiers[i].requiredXp) index = i;
  }
  return index;
}

/// 用户当前称号（所需修为 <= xp 的最高称号档）；修为不到筑基期时
/// 还没有称号，返回 null。
CultivationTitleTier? currentTitleTier(int xp, {String? sect}) {
  final tiers = cultivationTitleLadder(sect: sect);
  CultivationTitleTier? current;
  for (final tier in tiers) {
    if (tier.hasTitle && xp >= tier.requiredXp) current = tier;
  }
  return current;
}

/// 修为快照（不可变；每次修为变化重建一份并通知）。
class CultivationSnapshot {
  /// 各分类累计秒数。
  final Map<CultivationCategory, double> seconds;

  /// 打坐累计秒数（与看/读/听同一速率计修为，不占分类）。
  final double meditationSeconds;

  /// 完结奖励累计修为（短剧每集 +300、小说/漫画/听书每章 +150）。
  final int bonusXp;

  /// 看完的短剧集数。
  final int dramaEpisodes;

  /// 读完的小说章数。
  final int novelChapters;

  /// 读完的漫画章数。
  final int comicChapters;

  /// 听完的听书章数。
  final int audioChapters;

  /// 用户 ID（HY + 8 位随机数字）。
  final String userId;

  /// 用户名（道友 + 4 位随机数字，可改名）。
  final String username;

  /// 性别（创建道友档案时选；未建档为空）。
  final CultivationGender? gender;

  /// 宗门（创建道友档案时选；未建档为空）。
  final String sect;

  /// 职业（创建道友档案时选；未建档为空）。
  final String profession;

  /// 打坐小人选的服饰 id（默认青色道袍；未建档为空时取默认）。
  final String costumeId;

  /// 脸型（创建人物时选，默认瓜子脸）。
  final String face;

  /// 发型（创建人物时选，默认道髻）。
  final String hairstyle;

  /// 发色 id（创建人物时选，默认黑）。
  final String hairColorId;

  const CultivationSnapshot({
    this.seconds = const {},
    this.meditationSeconds = 0,
    this.bonusXp = 0,
    this.dramaEpisodes = 0,
    this.novelChapters = 0,
    this.comicChapters = 0,
    this.audioChapters = 0,
    this.userId = '',
    this.username = '',
    this.gender,
    this.sect = '',
    this.profession = '',
    this.costumeId = defaultCultivationCostumeId,
    this.face = defaultCultivationFace,
    this.hairstyle = defaultCultivationHairstyle,
    this.hairColorId = defaultCultivationHairColorId,
  });

  static const empty = CultivationSnapshot();

  /// 是否已创建道友档案（首次启动弹窗选完性别/宗门/职业、点
  /// 「开始修仙」后才为真；之前未建档时我的页与主界面先弹创建弹窗）。
  bool get hasProfile =>
      userId.isNotEmpty &&
      username.isNotEmpty &&
      gender != null &&
      sect.isNotEmpty &&
      profession.isNotEmpty;

  /// 全部实际时长（秒）。
  double get totalSeconds =>
      seconds.values.fold(0.0, (a, b) => a + b);

  /// 总修为 = 全部活动时长 × 每秒修为（计 ×1.8 加成后 0.5/秒，
  /// 活动 1 小时约 1800 修为）+ 完结奖励。
  int get totalXp =>
      ((totalSeconds + meditationSeconds) * cultivationXpPerSecond)
              .floor() +
          bonusXp;

  /// 当前境界。
  RealmInfo get realm => realmForXp(totalXp);

  /// 人物等级（与境界小档一一对应，炼气初期 Lv.1……道祖 Lv.40）。
  int get level => realm.level;

  /// 打坐累计分钟。
  double get meditationMinutes => meditationSeconds / 60;

  /// 某分类累计分钟。
  double minutesFor(CultivationCategory category) =>
      (seconds[category] ?? 0) / 60;

  /// 漫画是否已解锁（筑基 300）。
  bool get unlockedComic => totalXp >= comicUnlockXp;

  /// 听书是否已解锁（结丹 1000）。
  bool get unlockedAudio => totalXp >= audioUnlockXp;

  /// 影视区是否已解锁（元婴 3000）。
  bool get unlockedVideo => totalXp >= videoZoneUnlockXp;

  /// 影视全部分类与称号是否已解锁（化神 8000）。
  bool get unlockedVideoAllCategories => totalXp >= videoAllCategoriesUnlockXp;

  /// 到影视区解锁还差多少修为；已解锁为 0。
  int get xpToVideoZone =>
      totalXp >= videoZoneUnlockXp ? 0 : videoZoneUnlockXp - totalXp;

  /// 到影视区解锁约还差多少集短剧（1 集 +300 修为，向上取整）。
  int get episodesToVideoZone =>
      (xpToVideoZone + dramaEpisodeXp - 1) ~/ dramaEpisodeXp;

  /// 耗时最多的分类（主修）；都没看过为空。
  CultivationCategory? get mainCategory {
    CultivationCategory? best;
    var bestSeconds = 0.0;
    for (final entry in seconds.entries) {
      if (entry.value > bestSeconds) {
        bestSeconds = entry.value;
        best = entry.key;
      }
    }
    return best;
  }

  /// 主修对应的灵根；都没看过为“未觉醒”。
  String get spiritRoot {
    final main = mainCategory;
    if (main == null) return '未觉醒';
    return spiritRootName(main);
  }

  /// 当前服饰（未知 id 退化为默认青色道袍）。
  CultivationCostume get costume => cultivationCostumeById(costumeId);

  /// 当前发色（未知 id 退化为默认黑）。
  CultivationHairColor get hairColor =>
      cultivationHairColorById(hairColorId);

  /// 当前称号档（所需修为 <= 总修为的最高称号；修为不到筑基期时
  /// 还没有称号，返回 null）。大乘/渡劫/真仙/金仙不配新称号，仍是
  /// 仙界接引；到太乙才换前三特效称号。
  CultivationTitleTier? get currentTitle =>
      currentTitleTier(totalXp, sect: sect.isEmpty ? null : sect);

  CultivationSnapshot copyWith({
    Map<CultivationCategory, double>? seconds,
    double? meditationSeconds,
    int? bonusXp,
    int? dramaEpisodes,
    int? novelChapters,
    int? comicChapters,
    int? audioChapters,
    String? userId,
    String? username,
    CultivationGender? gender,
    String? sect,
    String? profession,
    String? costumeId,
    String? face,
    String? hairstyle,
    String? hairColorId,
  }) => CultivationSnapshot(
    seconds: seconds ?? this.seconds,
    meditationSeconds: meditationSeconds ?? this.meditationSeconds,
    bonusXp: bonusXp ?? this.bonusXp,
    dramaEpisodes: dramaEpisodes ?? this.dramaEpisodes,
    novelChapters: novelChapters ?? this.novelChapters,
    comicChapters: comicChapters ?? this.comicChapters,
    audioChapters: audioChapters ?? this.audioChapters,
    userId: userId ?? this.userId,
    username: username ?? this.username,
    gender: gender ?? this.gender,
    sect: sect ?? this.sect,
    profession: profession ?? this.profession,
    costumeId: costumeId ?? this.costumeId,
    face: face ?? this.face,
    hairstyle: hairstyle ?? this.hairstyle,
    hairColorId: hairColorId ?? this.hairColorId,
  );
}

/// 随机用户 ID：HY + 8 位随机数字（如 HY48392017）。
String generateCultivationUserId([Random? random]) {
  final r = random ?? Random();
  final digits = StringBuffer();
  digits.write(1 + r.nextInt(9));
  for (var i = 0; i < 7; i++) {
    digits.write(r.nextInt(10));
  }
  return 'HY$digits';
}

/// 随机用户名：道友 + 4 位随机数字（如 道友4839）。
String generateCultivationUsername([Random? random]) {
  final r = random ?? Random();
  final digits = StringBuffer();
  digits.write(1 + r.nextInt(9));
  for (var i = 0; i < 3; i++) {
    digits.write(r.nextInt(10));
  }
  return '道友$digits';
}

/// 修为服务：修为累计、境界换算、解锁判定、随机身份，全部落盘
/// SharedPreferences，覆盖安装不丢失。页面用 snapshotNotifier 监听。
class CultivationService {
  CultivationService._();

  static final CultivationService instance = CultivationService._();

  static const _secondsPrefix = 'cultivation_seconds_';
  static const _meditationSecondsKey = 'cultivation_meditation_seconds';
  static const _bonusXpKey = 'cultivation_bonus_xp';
  static const _dramaEpisodesKey = 'cultivation_drama_episodes';
  static const _novelChaptersKey = 'cultivation_novel_chapters';
  static const _comicChaptersKey = 'cultivation_comic_chapters';
  static const _audioChaptersKey = 'cultivation_audio_chapters';
  static const _userIdKey = 'cultivation_user_id';
  static const _usernameKey = 'cultivation_username';
  static const _genderKey = 'cultivation_gender';
  static const _sectKey = 'cultivation_sect';
  static const _professionKey = 'cultivation_profession';
  static const _costumeKey = 'cultivation_costume_id';
  static const _faceKey = 'cultivation_face';
  static const _hairstyleKey = 'cultivation_hairstyle';
  static const _hairColorKey = 'cultivation_hair_color_id';

  final ValueNotifier<CultivationSnapshot> snapshotNotifier =
      ValueNotifier<CultivationSnapshot>(CultivationSnapshot.empty);

  CultivationSnapshot get snapshot => snapshotNotifier.value;

  int get totalXp => snapshot.totalXp;

  Future<void>? _loadFuture;
  Future<void> _persistChain = Future<void>.value();

  /// 启动时调用：读盘。首次安装且本地无用户标识时不静默注册，
  /// 由主界面弹「创建道友档案」弹窗，用户选完性别/宗门/职业、
  /// 点「开始修仙」后才建档（见 [createProfile]）。
  Future<void> ensureInitialized() => _ensureLoaded();

  Future<void> _ensureLoaded() {
    return _loadFuture ??= _load();
  }

  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final seconds = <CultivationCategory, double>{};
      for (final category in CultivationCategory.values) {
        final value = sp.getDouble('$_secondsPrefix${category.name}');
        if (value != null && value > 0) seconds[category] = value;
      }
      snapshotNotifier.value = CultivationSnapshot(
        seconds: seconds,
        meditationSeconds: sp.getDouble(_meditationSecondsKey) ?? 0,
        bonusXp: sp.getInt(_bonusXpKey) ?? 0,
        dramaEpisodes: sp.getInt(_dramaEpisodesKey) ?? 0,
        novelChapters: sp.getInt(_novelChaptersKey) ?? 0,
        comicChapters: sp.getInt(_comicChaptersKey) ?? 0,
        audioChapters: sp.getInt(_audioChaptersKey) ?? 0,
        userId: sp.getString(_userIdKey) ?? '',
        username: sp.getString(_usernameKey) ?? '',
        gender: _cultivationGenderFromStorage(sp.getString(_genderKey)),
        sect: sp.getString(_sectKey) ?? '',
        profession: sp.getString(_professionKey) ?? '',
        costumeId:
            cultivationCostumeById(sp.getString(_costumeKey)).id,
        face: cultivationFaces.contains(sp.getString(_faceKey))
            ? sp.getString(_faceKey)!
            : defaultCultivationFace,
        hairstyle: cultivationHairstyles.contains(sp.getString(_hairstyleKey))
            ? sp.getString(_hairstyleKey)!
            : defaultCultivationHairstyle,
        hairColorId:
            cultivationHairColorById(sp.getString(_hairColorKey)).id,
      );
    } catch (_) {
      // 读盘失败退化为空快照，不拖住启动；建档弹窗下次启动再弹。
      snapshotNotifier.value = CultivationSnapshot.empty;
    }
  }

  /// 创建道友档案：点「开始修仙」后调用。性别/宗门/职业/服饰/
  /// 脸型/发型/发色一起落盘；ID 与用户名默认随机生成，创建人物
  /// 界面传了已展示的 ID/用户名时用传来的（用户可点刷新换一个）。
  /// 服饰不传时默认青色道袍；职业不在天道/逍遥/金刚三项里时
  /// 退化为默认天道；脸型/发型/发色不在选项里时退化为默认。
  Future<void> createProfile({
    required CultivationGender gender,
    required String sect,
    required String profession,
    String? costumeId,
    String? face,
    String? hairstyle,
    String? hairColorId,
    String? userId,
    String? username,
  }) async {
    await _ensureLoaded();
    snapshotNotifier.value = snapshot.copyWith(
      userId: userId ?? generateCultivationUserId(),
      username: username ?? generateCultivationUsername(),
      gender: gender,
      sect: sect,
      profession: isCultivationProfession(profession)
          ? profession
          : defaultCultivationProfession,
      costumeId: cultivationCostumeById(costumeId).id,
      face: cultivationFaces.contains(face)
          ? face!
          : defaultCultivationFace,
      hairstyle: cultivationHairstyles.contains(hairstyle)
          ? hairstyle!
          : defaultCultivationHairstyle,
      hairColorId: cultivationHairColorById(hairColorId).id,
    );
    await _persist();
  }

  /// 换服饰（落盘；未知 id 退化为默认青色道袍）。
  Future<void> setCostume(String costumeId) async {
    await _ensureLoaded();
    snapshotNotifier.value = snapshot.copyWith(
      costumeId: cultivationCostumeById(costumeId).id,
    );
    await _persist();
  }

  /// 记一次实际时长（秒）：1 分钟 = 1 修为。调用方在真实阅读/
  /// 观看/收听结算时调，不要刷假数据。
  Future<void> addSeconds(CultivationCategory category, double seconds) async {
    if (!seconds.isFinite || seconds <= 0) return;
    await _ensureLoaded();
    final next = Map<CultivationCategory, double>.of(snapshot.seconds);
    next[category] = (next[category] ?? 0) + seconds;
    snapshotNotifier.value = snapshot.copyWith(seconds: next);
    await _persist();
  }

  /// 看完 1 集短剧：+300 修为（≈10 分钟活动量）。
  Future<void> addDramaEpisodeCompleted() async {
    await _ensureLoaded();
    snapshotNotifier.value = snapshot.copyWith(
      bonusXp: snapshot.bonusXp + dramaEpisodeXp,
      dramaEpisodes: snapshot.dramaEpisodes + 1,
    );
    await _persist();
  }

  /// 读完 1 章小说/漫画，或听完 1 章听书：+150 修为（≈5 分钟活动量）。
  Future<void> addChapterCompleted(CultivationCategory category) async {
    await _ensureLoaded();
    final current = snapshot;
    switch (category) {
      case CultivationCategory.novel:
        snapshotNotifier.value = current.copyWith(
          bonusXp: current.bonusXp + chapterXp,
          novelChapters: current.novelChapters + 1,
        );
      case CultivationCategory.comic:
        snapshotNotifier.value = current.copyWith(
          bonusXp: current.bonusXp + chapterXp,
          comicChapters: current.comicChapters + 1,
        );
      case CultivationCategory.audio:
        snapshotNotifier.value = current.copyWith(
          bonusXp: current.bonusXp + chapterXp,
          audioChapters: current.audioChapters + 1,
        );
      case CultivationCategory.video:
      case CultivationCategory.drama:
        return;
    }
    await _persist();
  }

  /// 打坐累计（秒）：与看/读/听同一速率计修为。档案卡上点「打坐」
  /// 开始累计、再点停止；调用方按固定间隔（如每 5 秒）调一次。
  Future<void> addMeditationSeconds(double seconds) async {
    if (!seconds.isFinite || seconds <= 0) return;
    await _ensureLoaded();
    snapshotNotifier.value = snapshot.copyWith(
      meditationSeconds: snapshot.meditationSeconds + seconds,
    );
    await _persist();
  }

  /// 改名（落盘）。
  Future<void> renameUser(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _ensureLoaded();
    snapshotNotifier.value = snapshot.copyWith(username: trimmed);
    await _persist();
  }

  /// 换职业（落盘；不在天道/逍遥/金刚三项里时不改）。
  /// 换了职业，打坐小人的技能动画跟着换。
  Future<void> setProfession(String profession) async {
    if (!isCultivationProfession(profession)) return;
    await _ensureLoaded();
    snapshotNotifier.value = snapshot.copyWith(profession: profession);
    await _persist();
  }

  /// 游戏直接加修为（击杀、推图、爬塔、商城丹药用）：
  /// 修为直接加到完结奖励里并落盘；<= 0 不加。
  Future<void> addGameXp(int xp) async {
    if (xp <= 0) return;
    await _ensureLoaded();
    snapshotNotifier.value = snapshot.copyWith(
      bonusXp: snapshot.bonusXp + xp,
    );
    await _persist();
  }

  /// 串行落盘：多次累计并发时按顺序写，避免旧快照盖掉新快照。
  Future<void> _persist() {
    final run = _persistChain.then((_) async {
      final current = snapshot;
      final sp = await SharedPreferences.getInstance();
      for (final category in CultivationCategory.values) {
        await sp.setDouble(
          '$_secondsPrefix${category.name}',
          current.seconds[category] ?? 0,
        );
      }
      await sp.setDouble(
        _meditationSecondsKey,
        current.meditationSeconds,
      );
      await sp.setInt(_bonusXpKey, current.bonusXp);
      await sp.setInt(_dramaEpisodesKey, current.dramaEpisodes);
      await sp.setInt(_novelChaptersKey, current.novelChapters);
      await sp.setInt(_comicChaptersKey, current.comicChapters);
      await sp.setInt(_audioChaptersKey, current.audioChapters);
      if (current.userId.isNotEmpty) {
        await sp.setString(_userIdKey, current.userId);
      }
      if (current.username.isNotEmpty) {
        await sp.setString(_usernameKey, current.username);
      }
      final gender = current.gender;
      if (gender != null) {
        await sp.setString(_genderKey, _cultivationGenderStorage(gender));
      }
      if (current.sect.isNotEmpty) {
        await sp.setString(_sectKey, current.sect);
      }
      if (current.profession.isNotEmpty) {
        await sp.setString(_professionKey, current.profession);
      }
      await sp.setString(_costumeKey, current.costumeId);
      await sp.setString(_faceKey, current.face);
      await sp.setString(_hairstyleKey, current.hairstyle);
      await sp.setString(_hairColorKey, current.hairColorId);
    });
    _persistChain = run.catchError((Object _) {});
    return run;
  }

  /// 测试用：只清内存、不清落盘，重新从盘里读一次（模拟二次启动）。
  @visibleForTesting
  Future<void> reloadForTest() async {
    _loadFuture = null;
    snapshotNotifier.value = CultivationSnapshot.empty;
    await _ensureLoaded();
  }

  /// 测试用：清掉内存与落盘的修为数据，恢复到未初始化。
  @visibleForTesting
  Future<void> resetForTest() async {
    _loadFuture = null;
    _persistChain = Future<void>.value();
    snapshotNotifier.value = CultivationSnapshot.empty;
    try {
      final sp = await SharedPreferences.getInstance();
      for (final category in CultivationCategory.values) {
        await sp.remove('$_secondsPrefix${category.name}');
      }
      await sp.remove(_meditationSecondsKey);
      await sp.remove(_bonusXpKey);
      await sp.remove(_dramaEpisodesKey);
      await sp.remove(_novelChaptersKey);
      await sp.remove(_comicChaptersKey);
      await sp.remove(_audioChaptersKey);
      await sp.remove(_userIdKey);
      await sp.remove(_usernameKey);
      await sp.remove(_genderKey);
      await sp.remove(_sectKey);
      await sp.remove(_professionKey);
      await sp.remove(_costumeKey);
      await sp.remove(_faceKey);
      await sp.remove(_hairstyleKey);
      await sp.remove(_hairColorKey);
    } catch (_) {}
  }
}
