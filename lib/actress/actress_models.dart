// 女优模块：模型与纯逻辑（归一化、去重合并、名气分、硬线过滤）。
//
// 数据口径（2026-11-17 用户令 + 三家名册补令 + 2026-11-20 合并新规）：
// - 人物三家合并：潮流名册 + whos.tv + MissAV，按归一化名字去重；
// - 作品按（站，归一化番号）去重：同番号两站各留一条，各算一条可播
//   线路；无番号的按（站，归一化标题）去重；番号与播放链接完全一样
//   才算重复（那是爬取文件递增更新的精确重复口径，见兜底加载器）；
// - 站点来源信息只在内部流转（封面解析、探活），界面任何地方不显示。

/// 硬线词表：与潮流 jar 版分类过滤（ZakaChaoliu.BLOCKED_CAT_WORDS）
/// 同一套，一字不改；命中即整条剔除（人物整人不要、作品整部不要），
/// 绝不拿命中条目验播，绝不在界面与日志里引用命中原文。
const actressBlockedWords = <String>{
  '萝莉',
  '幼女',
  '初中生',
  '小学生',
  '未成年',
  '幼齿',
  'loli',
};

/// 文本是否含硬线词：大小写不敏感的子串匹配，与 jar 版过滤同一语义。
bool actressTextBlocked(String text) {
  if (text.isEmpty) return false;
  final lower = text.toLowerCase();
  for (final word in actressBlockedWords) {
    if (lower.contains(word)) return true;
  }
  return false;
}

/// 名字归一化键：去全部空白（含全角空格）、小写。去重只认这个键，
/// 显示永远用原始名字。
String actressNameKey(String name) =>
    name.replaceAll(RegExp(r'[\s\u3000\u00A0]+'), '').toLowerCase();

/// 名字切别名：潮流名册的 n 字段含逗号分隔的别名；`、` 与中文逗号
/// 同样切分。返回去重后的非空原形（不做归一化，归一化在比对时做）。
List<String> actressNameVariants(String rawName) {
  final seen = <String>{};
  final out = <String>[];
  for (final part in rawName.split(RegExp(r'[,，、]'))) {
    final name = part.trim();
    if (name.isEmpty) continue;
    if (seen.add(actressNameKey(name))) out.add(name);
  }
  return out;
}

/// 番号归一化键：chaoliu.py `_code_key` 的逐字移植——大写、去全部
/// 非字母数字、`前缀+去前导零的数字`（如 SSIS-00123 → SSIS123）。
/// 三家名册与全站搜索命中共用这一个键，去重口径才一致。
String normalizeAvCode(String code) {
  final cleaned = code.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  final match = RegExp(r'^([A-Z]+)0*(\d+)$').firstMatch(cleaned);
  if (match != null) return '${match.group(1)}${match.group(2)}';
  return cleaned;
}

/// 搜索框里的番号键：输入像番号时返回归一化番号键，否则 null。
/// 像番号 = 归一化后至少 3 位、同时含字母与数字（SSIS-123、abw123、
/// FC2-PPV-1234567 都认；纯名字、纯数字、纯字母都不认）。返回的键
/// 只含大写字母与数字，可直接拼进 SQL LIKE（无通配符）。
String? actressCodeQueryKey(String query) {
  final key = normalizeAvCode(query.trim());
  if (key.length < 3) return null;
  if (!RegExp(r'[A-Z]').hasMatch(key)) return null;
  if (!RegExp(r'[0-9]').hasMatch(key)) return null;
  return key;
}

/// 姓名分组键：通讯录式首字母分组，只看每个候选名字的首字符，不猜读音。
/// - 拉丁字母开头 → 该大写字母；
/// - 假名开头 → 按五十音行换算（あ行→A、か行→K、さ行→S、た行→T、
///   な行→N、は行→H、ま行→M、や行→Y、ら行→R、わ行→W，片假名同行）；
/// - 汉字/数字/其他开头 → 看别名里有没有拉丁或假名开头的名字，有则
///   用它的键；都没有 → '#'（未归类组，排在最后）。
String actressGroupKey(
  String displayName, [
  List<String> aliases = const [],
]) {
  for (final candidate in [displayName, ...aliases]) {
    final key = _groupKeyForFirstChar(candidate);
    if (key != null) return key;
  }
  return '#';
}

String? _groupKeyForFirstChar(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return null;
  final rune = trimmed.runes.first;
  if (rune >= 0x41 && rune <= 0x5A) return String.fromCharCode(rune);
  if (rune >= 0x61 && rune <= 0x7A) return String.fromCharCode(rune - 0x20);
  // 片假名与平假名差 0x60，归一到平假名再按行查。
  final hira = rune >= 0x30A1 && rune <= 0x30FA ? rune - 0x60 : rune;
  if (hira < 0x3041 || hira > 0x3093) return null;
  if (hira <= 0x304A) return 'A';
  if (hira <= 0x3054) return 'K';
  if (hira <= 0x305E) return 'S';
  if (hira <= 0x3069) return 'T';
  if (hira <= 0x306E) return 'N';
  if (hira <= 0x307D) return 'H';
  if (hira <= 0x3082) return 'M';
  if (hira <= 0x3088) return 'Y';
  if (hira <= 0x308D) return 'R';
  return 'W';
}

/// 无番号作品的标题去重键：小写、去空白与常见标点。只在番号为空时
/// 用作去重键，同一人物内有效。
String actressTitleKey(String title) => title.toLowerCase().replaceAll(
  RegExp(r'''[\s\-_·•:：,，。.!！?？()（）\[\]"'“”''/]'''),
  '',
);

/// 性别筛选：与浏览列表、排行榜同一口径。
enum ActressSexFilter { all, female, male }

/// 浏览排序：作品数从多到少，或名字升序，或最近更新（入库作品里
/// 最新作品日期倒序，无入库作品的人沉底）。
enum ActressSort { worksDesc, nameAsc, recentDesc }

extension ActressSortLabel on ActressSort {
  String get label => switch (this) {
    ActressSort.worksDesc => '按作品数',
    ActressSort.nameAsc => '按名字',
    ActressSort.recentDesc => '最近更新',
  };
}

/// 女优库左上角站点筛选：默认全部；选站后兜底数据与现爬都只走该站。
/// mjv = mjv011.com（潮流蜘蛛），whos = whos.tv（validator.nu 列表通道现爬）。
/// 片库站是动态项：站 id 即片库里的站 id、显示名即站名（见
/// [actressSiteFilterOptions]），与 mjv/whos 同一筛选语义。
class ActressSiteFilter {
  const ActressSiteFilter(this.siteId, this.label);

  static const all = ActressSiteFilter('all', '全部');
  static const mjv = ActressSiteFilter('mjv', 'mjv');
  static const whos = ActressSiteFilter('whos', 'whos');

  /// 站 id：'all' / 'mjv' / 'whos' / 片库站 id。
  final String siteId;

  /// 下拉里显示的名字：mjv/whos 用站 id 本身，片库站用站名。
  final String label;

  @override
  bool operator ==(Object other) =>
      other is ActressSiteFilter && other.siteId == siteId;

  @override
  int get hashCode => siteId.hashCode;
}

/// 第二排册别筛选：名册库按名册自带的标签字段筛（潮流名册 c 字段）；
/// 视频库（女优库.db）没有名册标签列，按视频主分类筛人（见
/// ActressDatabase.listPersons 视频库分支：tag 值当 main_category 用）。
/// 无标签的人物（whos/MissAV 名册不带标签）只进 [all]，不进分册。
/// 2026-11-24 用户令：数据库里有的分类全进这排，接在欧美后面平铺
/// （国产/4K/动漫/三级/其他，值取自 video_category.main_category
/// 在重合并库里的 DISTINCT 值，空值不单独成类）；名册里没有这些
/// 标签，名册库上点它们是空列表（不是 bug，是名册没这个维度）。
enum ActressTagFilter {
  all('三册全部', ''),
  coded('有码', '有码'),
  uncoded('无码', '无码'),
  western('欧美', '欧美'),
  domestic('国产', '国产'),
  fourK('4K', '4K'),
  anime('动漫', '动漫'),
  sanji('三级', '三级'),
  other('其他', '其他');

  const ActressTagFilter(this.label, this.tagValue);

  final String label;

  /// 匹配的标签值：空表示不过滤。
  final String tagValue;
}

/// 名册源标识：只在内部流转，界面不显示。
enum ActressRosterSourceId { chaoliu, whos, missav }

/// 名册拉回的一条人物（单源视角，合并前）。
class RosterPerson {
  const RosterPerson({
    required this.source,
    required this.sourceId,
    required this.name,
    this.sex = '',
    this.avatarUrl = '',
    this.tags = const [],
    this.worksHint = 0,
    this.recommended = false,
    this.rating,
    this.exactWorks = 0,
    this.aliases = const [],
    this.about = const {},
  });

  final ActressRosterSourceId source;

  /// 源内身份：潮流 actors.json 的 id、whos 的 slug、MissAV 的人物
  /// 相对路径。只用于取该人作品清单，界面不显示。
  final String sourceId;

  /// 原始名字（可能含逗号分隔的别名，合并时切分）。
  final String name;
  final String sex;
  final String avatarUrl;
  final List<String> tags;

  /// 名册自带的作品数提示（潮流 t 字段）；whos/MissAV 列表页没有，
  /// 为 0，作品数以实际同步到的作品行数为准。
  final int worksHint;

  /// 潮流名册 c 字段含“推荐”：编辑推荐，计入名气分。
  final bool recommended;

  /// whos 卡片/详情评分（0–10）；其余源没有，为 null。
  final double? rating;

  /// whos 卡片“ N 部作品”的精确数；0 = 未知，与 [worksHint]
  /// 分开存，互不覆盖。
  final int exactWorks;

  /// whos 卡片上的别名（独立字段，不在名字里）；合并时并入别名集。
  final List<String> aliases;

  /// whos 人物页的简介键值对（生日/身高/三围/出道年等）；whos 独有。
  final Map<String, String> about;
}

/// 名册源对应的视频站源 id（同步入库的作品封面直取用）：
/// - MissAV 名册的作品封面走 MissAV 视频站取详情；
/// - whos 封面只在 XOR 开关打开时才有，站源记 'whos'；
/// - 潮流名册不带封面，记空（有封面的条目不认站源、不写封面）。
String actressRosterCoverSource(ActressRosterSourceId source) =>
    switch (source) {
      ActressRosterSourceId.missav => 'jar:missav30:ZakaMissav',
      ActressRosterSourceId.whos => 'whos',
      ActressRosterSourceId.chaoliu => '',
    };

/// 名册拉回的一部作品（单源视角）。
class RosterFilm {
  const RosterFilm({
    required this.code,
    this.title = '',
    this.date = '',
    this.coverUrl = '',
    this.detailUrl = '',
    this.category = '',
  });

  /// 原始番号文本（可能为空，如 whos 标题里提不到番号的条目）。
  final String code;
  final String title;
  final String date;

  /// 作品爬取/镜像时的列表分类（如 mjv 的“中文字幕”/“国产自拍”/
  /// “无码破解”，由 json 的 type_name 或现爬的分类名来）；名册源
  /// 的作品清单没有分类时为空，不编假分类。入库后供详情页分类
  /// 筛选用；空分类的作品只在“全部”里显示，不丢数据。
  final String category;

  /// 封面直链：whos 只在 XOR 开关打开时解析，MissAV 同步时直接
  /// 取人物页 `.lozad` 图地址；开关关闭/无图时恒为空。
  final String coverUrl;

  /// 作品详情相对地址：whos 为影片页路径，MissAV 为视频页路径；
  /// 封面解析内部用（封面直取的站源见 [actressRosterCoverSource]）。
  final String detailUrl;

  String get codeKey => normalizeAvCode(code);
  String get titleKey => actressTitleKey(title.isEmpty ? code : title);
}

/// 头像地址是否“像能加载”：非空、http(s)、有 host、路径不是根。
/// 裸域名（`https://v.hersav.me/`、`https://v.hersav.me`）没有可请求
/// 的图片路径，Image.network 必失败——这种地址不许占住归并里的坑位。
/// （2026-11-24 头像修复：新库里 13,770 行头像是裸域名，行序在前会
/// 先赢；回退路 SQL 里的 LIKE '%://%/%_' 是同一口径的 SQL 写法。）
bool isLoadableAvatarUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return false;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (uri.host.isEmpty) return false;
  final path = uri.path;
  if (path.isEmpty || path == '/') return false;
  return true;
}

/// 头像归并：现有已有效时保留；现有无效、新候选有效时取新候选；
/// 两个都无效时保留现有（调用方决定留空还是旧值）。
String preferLoadableAvatar(String current, String candidate) {
  if (isLoadableAvatarUrl(current)) return current;
  if (isLoadableAvatarUrl(candidate)) return candidate;
  return current;
}

/// 本地库里合并后的一位演员：三家来源合并为一条，来源身份只存内部
/// 字段，界面只显示名字、头像、标签与作品数。
class ActressPerson {
  const ActressPerson({
    this.localId = 0,
    required this.displayName,
    this.aliases = const [],
    this.sex = '',
    this.avatarUrl = '',
    this.tags = const [],
    this.worksCount = 0,
    this.rosterWorks = 0,
    this.fromChaoliu = false,
    this.fromWhos = false,
    this.fromMissav = false,
    this.chaoliuId = '',
    this.whosSlug = '',
    this.missavPath = '',
    this.missavRank,
    this.recommended = false,
    this.filmsSyncedAt,
    this.enrichedAt,
    this.rating,
    this.exactWorks = 0,
    this.about = const {},
    this.whosRank,
  });

  final int localId;
  final String displayName;
  final List<String> aliases;
  final String sex;
  final String avatarUrl;
  final List<String> tags;

  /// 已入库的去重后作品行数（ films 同步后维护）。
  final int worksCount;

  /// 名册提示的作品数（取三家提示的最大值）：作品清单尚未同步时
  /// 界面显示用，同步完成后以 [worksCount] 为准。
  final int rosterWorks;

  final bool fromChaoliu;
  final bool fromWhos;
  final bool fromMissav;
  final String chaoliuId;
  final String whosSlug;
  final String missavPath;

  /// MissAV 排行名次（1 起）：名气分的主信号；未上榜为 null。
  final int? missavRank;
  final bool recommended;

  /// 任一源的作品清单同步完成时间（任一源完成即置），null = 还没
  /// 有任何一源的作品清单（首轮同步未跑到此人）。
  final int? filmsSyncedAt;

  /// 全站搜索补封面完成时间，null = 还没补过（下次打开继续补）。
  final int? enrichedAt;

  /// whos 评分（0–10）；三家都没有时为 null。
  final double? rating;

  /// whos 精确作品数；0 = 未知，与 [rosterWorks] 分开存。
  final int exactWorks;

  /// whos 人物页简介键值对；whos 独有，其余源不写。
  final Map<String, String> about;

  /// whos 日榜名次（1 起）：MissAV 无名次时的名气分后备信号，
  /// 只由排行阶段写，名册合并永不碰它（与 missavRank 同口径）。
  final int? whosRank;

  /// 界面显示的作品数：只算库里实际入库的作品数（2026-11-20 用户
  /// 令：要入库才算）。名册提示（rosterWorks，站方宣称数）不再
  /// 参与显示——同步未完成时宁可显示已入库的真实数，也不拿站方
  /// 宣称数充数；与 SQL 排序的 works_count 同一口径。
  int get displayWorks => worksCount;

  /// 该人在某源的身份 id（取作品清单用），没有返回 ''。
  String sourceIdFor(ActressRosterSourceId source) => switch (source) {
    ActressRosterSourceId.chaoliu => chaoliuId,
    ActressRosterSourceId.whos => whosSlug,
    ActressRosterSourceId.missav => missavPath,
  };

  bool hasSource(ActressRosterSourceId source) =>
      sourceIdFor(source).isNotEmpty;

  ActressPerson copyWith({
    int? localId,
    String? displayName,
    List<String>? aliases,
    String? sex,
    String? avatarUrl,
    List<String>? tags,
    int? worksCount,
    int? rosterWorks,
    bool? fromChaoliu,
    bool? fromWhos,
    bool? fromMissav,
    String? chaoliuId,
    String? whosSlug,
    String? missavPath,
    int? missavRank,
    bool? recommended,
    int? filmsSyncedAt,
    int? enrichedAt,
    double? rating,
    int? exactWorks,
    Map<String, String>? about,
    int? whosRank,
  }) => ActressPerson(
    localId: localId ?? this.localId,
    displayName: displayName ?? this.displayName,
    aliases: aliases ?? this.aliases,
    sex: sex ?? this.sex,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    tags: tags ?? this.tags,
    worksCount: worksCount ?? this.worksCount,
    rosterWorks: rosterWorks ?? this.rosterWorks,
    fromChaoliu: fromChaoliu ?? this.fromChaoliu,
    fromWhos: fromWhos ?? this.fromWhos,
    fromMissav: fromMissav ?? this.fromMissav,
    chaoliuId: chaoliuId ?? this.chaoliuId,
    whosSlug: whosSlug ?? this.whosSlug,
    missavPath: missavPath ?? this.missavPath,
    missavRank: missavRank ?? this.missavRank,
    recommended: recommended ?? this.recommended,
    filmsSyncedAt: filmsSyncedAt ?? this.filmsSyncedAt,
    enrichedAt: enrichedAt ?? this.enrichedAt,
    rating: rating ?? this.rating,
    exactWorks: exactWorks ?? this.exactWorks,
    about: about ?? this.about,
    whosRank: whosRank ?? this.whosRank,
  );
}

/// 三家名册人物合并规则（写死，测试钉死）：
/// - 命中条件：任一名字变体键相同即同一人；
/// - 显示名优先级：潮流 > whos > MissAV（潮流名字最规范、带别名）；
/// - 别名/标签取并集；头像取优先级最高的非空；性别取第一个非空；
/// - 作品提示取最大值；推荐取或；排行取最好名次；来源身份各自保留；
/// - 评分取第一个非空；精确作品数取最大值；简介并集、已有键优先；
/// - whos 别名并入别名集；whos 排行只由排行阶段写，合并永不碰。
ActressPerson mergeRosterIntoPerson(
  ActressPerson? existing,
  RosterPerson roster,
) {
  final variants = actressNameVariants(roster.name);
  final primary = variants.isEmpty ? roster.name.trim() : variants.first;
  if (existing == null) {
    final aliases = <String>[];
    final aliasKeys = <String>{actressNameKey(primary)};
    for (final candidate in [
      ...variants.skip(1),
      ...roster.aliases,
    ]) {
      if (aliasKeys.add(actressNameKey(candidate))) aliases.add(candidate);
    }
    return ActressPerson(
      displayName: primary,
      aliases: aliases,
      sex: roster.sex,
      avatarUrl: roster.avatarUrl,
      tags: roster.tags,
      rosterWorks: roster.worksHint,
      fromChaoliu: roster.source == ActressRosterSourceId.chaoliu,
      fromWhos: roster.source == ActressRosterSourceId.whos,
      fromMissav: roster.source == ActressRosterSourceId.missav,
      chaoliuId: roster.source == ActressRosterSourceId.chaoliu
          ? roster.sourceId
          : '',
      whosSlug: roster.source == ActressRosterSourceId.whos
          ? roster.sourceId
          : '',
      missavPath: roster.source == ActressRosterSourceId.missav
          ? roster.sourceId
          : '',
      recommended: roster.recommended,
      rating: roster.rating,
      exactWorks: roster.exactWorks,
      about: Map<String, String>.of(roster.about),
    );
  }
  // 显示名：已有名字来自低优先级源、且新名字来自更高优先级源时替换。
  int priority(ActressPerson person) => person.fromChaoliu
      ? 0
      : person.fromWhos
      ? 1
      : 2;
  final incomingPriority = switch (roster.source) {
    ActressRosterSourceId.chaoliu => 0,
    ActressRosterSourceId.whos => 1,
    ActressRosterSourceId.missav => 2,
  };
  final displayName = incomingPriority < priority(existing)
      ? primary
      : existing.displayName;
  // 别名 = 旧显示名 + 旧别名 + 新变体 + whos 别名，排除新显示名自身、按键去重。
  final aliases = <String>[];
  final aliasKeys = <String>{actressNameKey(displayName)};
  for (final candidate in [
    existing.displayName,
    ...existing.aliases,
    ...variants,
    ...roster.aliases,
  ]) {
    if (aliasKeys.add(actressNameKey(candidate))) aliases.add(candidate);
  }
  final tags = <String>{...existing.tags, ...roster.tags}.toList();
  return existing.copyWith(
    displayName: displayName,
    aliases: aliases,
    sex: existing.sex.isNotEmpty ? existing.sex : roster.sex,
    avatarUrl: preferLoadableAvatar(existing.avatarUrl, roster.avatarUrl),
    tags: tags,
    rosterWorks: roster.worksHint > existing.rosterWorks
        ? roster.worksHint
        : existing.rosterWorks,
    rating: existing.rating ?? roster.rating,
    exactWorks: roster.exactWorks > existing.exactWorks
        ? roster.exactWorks
        : existing.exactWorks,
    about: {...roster.about, ...existing.about},
    fromChaoliu:
        existing.fromChaoliu || roster.source == ActressRosterSourceId.chaoliu,
    fromWhos: existing.fromWhos || roster.source == ActressRosterSourceId.whos,
    fromMissav:
        existing.fromMissav || roster.source == ActressRosterSourceId.missav,
    chaoliuId: roster.source == ActressRosterSourceId.chaoliu
        ? roster.sourceId
        : existing.chaoliuId,
    whosSlug: roster.source == ActressRosterSourceId.whos
        ? roster.sourceId
        : existing.whosSlug,
    missavPath: roster.source == ActressRosterSourceId.missav
        ? roster.sourceId
        : existing.missavPath,
    recommended: existing.recommended || roster.recommended,
  );
}

/// 排行榜综合分（名气为主、作品数为辅，榜内口径一致）：
/// - 名气分：排行名次换算，第 1 名 1000 分，每后一名减 1 分，
/// 1000 名开外 0 分；MissAV 名次优先，无 MissAV 名次时用 whos
/// 日榜名次（同一换算尺）；潮流“推荐”加 50 分；
/// - 作品分：显示作品数，封顶 500 分（避免超多产一人压过全部名气分，
/// 同分时再按实际作品数排）；
/// - 总分 = 名气分 + 作品分。
int actressRankScore(ActressPerson person) {
  var fame = 0;
  final rank = person.missavRank ?? person.whosRank;
  if (rank != null && rank >= 1 && rank <= 1000) fame += 1001 - rank;
  if (person.recommended) fame += 50;
  final works = person.displayWorks.clamp(0, 500);
  return fame + works;
}

/// 排行榜比较：综合分高者在前，同分作品多者在前，再同名按名字。
int compareActressRank(ActressPerson a, ActressPerson b) {
  final score = actressRankScore(b).compareTo(actressRankScore(a));
  if (score != 0) return score;
  final works = b.displayWorks.compareTo(a.displayWorks);
  if (works != 0) return works;
  return a.displayName.compareTo(b.displayName);
}

/// 本地库里的一部作品：按（站，归一化番号）去重，无番号按
/// （站，标题）去重——同番号两站各留一条，各算一条可播线路。
/// [coverSource]/[coverDramaId]/[coverUrl] 只供封面解析内部用，
/// 界面绝不显示其中任何一项。
class ActressWork {
  const ActressWork({
    this.id = 0,
    required this.personId,
    required this.codeKey,
    required this.titleKey,
    this.site = '',
    this.codeDisplay = '',
    this.title = '',
    this.date = '',
    this.coverSource = '',
    this.coverDramaId = '',
    this.coverUrl = '',
    this.fromCrossSite = false,
    this.category = '',
  });

  final int id;
  final int personId;
  final String codeKey;
  final String titleKey;

  /// 该行来自哪站（名册源名或蜘蛛站 id，如 'chaoliu'/'whos'/
  /// 'missav' 或跨站发现的命中站 id）：去重键的一部分。
  /// 旧库行（建表 v2 及以前）没有该列，读出来为空。
  final String site;

  final String codeDisplay;
  final String title;
  final String date;
  final String coverSource;
  final String coverDramaId;
  final String coverUrl;
  final bool fromCrossSite;

  /// 入库时记下的列表分类（json 的 type_name / 现爬的分类名）：
  /// 空 = 入库时没有分类（名册源作品、旧库行），只在“全部”里显示。
  final String category;

  /// 卡片主标题：有真实标题用标题，否则用番号。
  String get displayTitle => title.isNotEmpty ? title : codeDisplay;

  /// 卡片副标题：日期 + 番号（标题已是番号时只剩日期）。
  String get displaySubtitle {
    final parts = <String>[];
    if (date.isNotEmpty) parts.add(date);
    if (title.isNotEmpty && codeDisplay.isNotEmpty) parts.add(codeDisplay);
    return parts.join(' · ');
  }

  bool get hasCover =>
      coverSource.isNotEmpty && coverDramaId.isNotEmpty && coverUrl.isNotEmpty;

  /// 播放用番号：优先归一化番号对应的显示形，其次从标题里现取。
  String get playCode => codeDisplay;

  ActressWork copyWith({
    int? id,
    int? personId,
    String? codeKey,
    String? titleKey,
    String? site,
    String? codeDisplay,
    String? title,
    String? date,
    String? coverSource,
    String? coverDramaId,
    String? coverUrl,
    bool? fromCrossSite,
    String? category,
  }) => ActressWork(
    id: id ?? this.id,
    personId: personId ?? this.personId,
    codeKey: codeKey ?? this.codeKey,
    titleKey: titleKey ?? this.titleKey,
    site: site ?? this.site,
    codeDisplay: codeDisplay ?? this.codeDisplay,
    title: title ?? this.title,
    date: date ?? this.date,
    coverSource: coverSource ?? this.coverSource,
    coverDramaId: coverDramaId ?? this.coverDramaId,
    coverUrl: coverUrl ?? this.coverUrl,
    fromCrossSite: fromCrossSite ?? this.fromCrossSite,
    category: category ?? this.category,
  );
}

/// 视频库（MYTV/db/女优库.db）的一条视频：videos / video_category
/// 行的合并输入。vodId 是 videos 主键；playUrl 是去掉了 `正片$`
/// 前缀的直链地址（m3u8_url 与 vod_play_url 两列同值）；category
/// 是 video_category.main_category（条目的分类，空就留空）；
/// actressName 为空时不写 video_actress（whos 条目本来就没女优名）。
typedef VideoLibraryEntry = ({
  String vodId,
  String title,
  String picUrl,
  String playUrl,
  String remarks,
  String pubdate,
  String area,
  String year,
  String content,
  String playFrom,
  String typeName,
  String category,
  String actressName,
});

/// 视频库合并规则的判定结果（纯函数，供测试与实现共用）：
/// skip = 同 vod_id 且播放地址相同，不动；update = 同 vod_id 但
/// 播放地址不同，只换播放地址（标题/封面只在新值非空时才换，
/// 分类不动）；insert = 新 vod_id，插 videos + video_category。
enum VideoLibraryMergeAction { skip, update, insert }

/// 视频库 vod_id 归一化：小写番号（库里 vod_id 是小写、带横杠）。
/// 只做小写 + 横杠还原 + FC2 归一：whos 卡片的 'fc2ppv-1234567'
/// 归成库里 的 'fc2-ppv-1234567'；归一化后无横杠的 'ssis123'
/// 还原成 'ssis-123'（字母段 + 数字段之间补横杠）；已带横杠的
/// 原样。不去前导零——库里 'mmym-032' 这类就是带零的，去零反而
/// 对不上已有行。
String videoLibraryVodId(String code) {
  final raw = code.trim().toLowerCase();
  if (raw.isEmpty) return '';
  // FC2：fc2ppv-1234567 / fc2ppv1234567 → fc2-ppv-1234567。
  final fc2 = RegExp(r'^fc2[-_]?ppv[-_]?(\d{5,7})$').firstMatch(raw);
  if (fc2 != null) return 'fc2-ppv-${fc2.group(1)}';
  // 已带横杠（ssis-123）：原样。
  if (raw.contains('-')) return raw;
  // 归一化后无横杠（ssis123）：字母段 + 数字段之间补横杠。
  final m = RegExp(r'^([a-z]+)(\d+)$').firstMatch(raw);
  if (m != null) return '${m.group(1)}-${m.group(2)}';
  return raw;
}

/// 名册补新人时 actresses.cate_id 的拼法：来源前缀 + 来源 id。
/// whos 用 'whos:' + slug、mjv（潮流）用 'mjv:' + chaoliuId、
/// MissAV 用 'missav:' + 人物相对路径。原库 29237 行的 cate_id
/// 就是名字本身（无前缀），新补的行用前缀区分来源。
String rosterVideoLibraryCateId(
  ActressRosterSourceId source,
  String sourceId,
) {
  final prefix = switch (source) {
    ActressRosterSourceId.whos => 'whos:',
    ActressRosterSourceId.chaoliu => 'mjv:',
    ActressRosterSourceId.missav => 'missav:',
  };
  return '$prefix$sourceId';
}
VideoLibraryMergeAction videoLibraryMergeAction(
  String? existingPlayUrl,
  String newPlayUrl,
) {
  if (existingPlayUrl == null) return VideoLibraryMergeAction.insert;
  if (newPlayUrl.isEmpty) return VideoLibraryMergeAction.skip;
  if (existingPlayUrl == newPlayUrl) return VideoLibraryMergeAction.skip;
  return VideoLibraryMergeAction.update;
}
