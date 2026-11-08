/// TG影视库硬编频道表：从火蚁TV tg频道（ZakaTgAmns.java）原样拷过来。
///
/// 与 jar 的两张表同源、同一顺序：
/// - [hardcodedChannels]：52 条主表（HARDCODED），用户名 + TG 频道裸号；
/// - [extChannels]：7 条（DEF，即 tree_104 里 ZakaTg ext 的 channels）。
///
/// 用户名为空的 4 条只有裸号，频道 id 用裸号算出的完整 TG 号
/// （-(1000000000000 + 裸号)，与 jar 的 fullTgId 同算法）。
/// 插件里没有这些频道时，点频道按裸号触发单频道同步。
class TgHardcodedChannel {
  const TgHardcodedChannel(this.name, this.username, this.bareTgId);

  /// 频道显示名（jar 里的 HARDCODED 第一列）。
  final String name;

  /// TG 用户名（jar 里的 HARDCODED 第二列），为空时只有裸号。
  final String username;

  /// TG 频道裸号（jar 里的 HARDCODED 第三列，不带 -100 前缀）。
  final String bareTgId;

  /// 完整 TG 频道号（与 jar 的 fullTgId 同算法）。
  int get fullTgId => -(1000000000000 + int.parse(bareTgId));
}

/// 52 条硬编主表（与 ZakaTgAmns.HARDCODED 同序）。
const List<TgHardcodedChannel> hardcodedChannels = [
  TgHardcodedChannel("日本精品av|中文字幕|Jav", "jav_all", "2753266064"),
  TgHardcodedChannel("日本AV|母子乱伦|巨乳调教💯", "JableTVB", "2698059227"),
  TgHardcodedChannel("AI成人短剧/黄果短剧/黄豆魔改短剧", "craimgd", "3523242707"),
  TgHardcodedChannel("收藏AV", "shoucangav", "1519261559"),
  TgHardcodedChannel("中文字幕 | 日本AV即是正义！", "cosfulimax", "2124166721"),
  TgHardcodedChannel("无码FC2｜优质精选｜高画质｜磁力链接｜115·迅雷·PikPak", "NEWFC2", "3436294431"),
  TgHardcodedChannel("JAV中字", "onlyjavzh", "1928340095"),
  TgHardcodedChannel("日本 AV 一本道", "AVkanpian01", "4327733666"),
  TgHardcodedChannel("中文字幕👩‍🦯🏃‍♀小日子电影6", "", "3761040325"),
  TgHardcodedChannel("母子乱伦|伦理|妈妈", "muziLL01", "4474113674"),
  TgHardcodedChannel("绝美反差学生少妇", "JMFCXMG", "3704977995"),
  TgHardcodedChannel("日本 AV💋 无码 高清", "AVGQWM8", "1354793440"),
  TgHardcodedChannel("AV番号精选-种子磁链下载", "javbest", "1480171113"),
  TgHardcodedChannel("AV日报-无码|步兵|种子|磁链|下载|高清|日本", "avpush2", "1122461141"),
  TgHardcodedChannel("AV日报-种子|磁链|下载链接|日本|有码|无码|骑兵|步兵", "javday", "1219457818"),
  TgHardcodedChannel("推特精选", "bbbjhbgq", "4299635687"),
  TgHardcodedChannel("磁力链接精选福利集", "cili8888", "1693277285"),
  TgHardcodedChannel("那些极品姐姐", "zfjp1024", "1879901314"),
  TgHardcodedChannel("🫦91|麻豆|国产|反差|海角🫦", "", "2604815578"),
  TgHardcodedChannel("抖音网红丨色料吃瓜", "seliao212", "2648812064"),
  TgHardcodedChannel("黄果漫剧", "hgmanju", "3905645410"),
  TgHardcodedChannel("超清AV |中文字幕|热门女优", "", "1301075074"),
  TgHardcodedChannel("AV/番号/无码/高清💿", "AV_cao", "2591554205"),
  TgHardcodedChannel("成人小说/色情有声小说🔴", "YSxiaoshuo01", "4435379058"),
  TgHardcodedChannel("🎥日本AV| JAV |中文字幕|番号资源库", "porncloud004", "3628483985"),
  TgHardcodedChannel("🇭🇰男人唔咸濕AV專線", "mic6388av", "2124172984"),
  TgHardcodedChannel("日本AV无码🎀fc2素人高清🎀字母圈暗网", "wmav91", "1853804800"),
  TgHardcodedChannel("AV无码原片-日本", "avwmjav", "1901957482"),
  TgHardcodedChannel("st站每日开票预览", "MXFLJ6", "3802482805"),
  TgHardcodedChannel("🎥 色情云|日本AV| JAV |中文字幕|番号资源库", "av8plus", "1981480055"),
  TgHardcodedChannel("推特反差淫妻", "tuite905", "4422690627"),
  TgHardcodedChannel("AV精选|AI短剧|中文字幕|无码|破解|国产|直播|欧美", "avjx_zongbu", "4361772103"),
  TgHardcodedChannel("海角少妇御姐少女", "hing475", "3418006020"),
  TgHardcodedChannel("日本AV中文学习资料", "rbav00", "2052699130"),
  TgHardcodedChannel("日本精选无码优质av资源分享", "rbjx336", "3915334056"),
  TgHardcodedChannel("淫妻反差俱乐部", "lspjsn", "3684099016"),
  TgHardcodedChannel("PIKPAK成人磁力资源大全", "pikpaklove", "2415398795"),
  TgHardcodedChannel("网红 肛交 直播 泄密", "knapianzhibo", "3479159773"),
  TgHardcodedChannel("日本AV｜中文字幕｜无码高清", "misscctav", "2347289238"),
  TgHardcodedChannel("国产AV｜优质精选｜@AV114514", "AV114514", "3961122432"),
  TgHardcodedChannel("飞鸟社备用", "seqingtvb", "2304875899"),
  TgHardcodedChannel("AV收藏|优质精选|无码破解|中文字幕|番号磁力大全", "AV688", "1488881373"),
  TgHardcodedChannel("Stymei全网综合分享", "", "2543598876"),
  TgHardcodedChannel("人妻|素人|少妇", "SURENrenqi01", "3915473772"),
  TgHardcodedChannel("每日大赛|中文福利", "ZWmeiriDS", "4375112420"),
  TgHardcodedChannel("短剧在线看(短剧频道）", "DuanJuPD", "2871409701"),
  TgHardcodedChannel("Cos涩涩大杂烩", "CosSSDZH", "2241401720"),
  TgHardcodedChannel("【番号帝】番号查询", "FLLAVWM", "1563276756"),
  TgHardcodedChannel("TG免费高速代理-免费VPN高速节点", "gydlpd", "4305291478"),
  TgHardcodedChannel("BiBi色区🔞丨自拍丨熟女丨国产", "bisequcom", "1853403121"),
  TgHardcodedChannel("全网精选资源🔞", "xianyu44", "2038170041"),
  TgHardcodedChannel("海角社区|偷情乱伦精选", "haijiaojingxuan", "2401842508"),
];

/// 7 条 ext 表（与 ZakaTgAmns.DEF / tree_104 的 ZakaTg ext 同序）。
const List<TgHardcodedChannel> extChannels = [
  TgHardcodedChannel("超清AV", "cctv_av", ''),
  TgHardcodedChannel("那些极品姐姐", "zfjp1024", ''),
  TgHardcodedChannel("麻豆 girl", "madougirl", ''),
  TgHardcodedChannel("黄果漫剧", "hgmanju", ''),
  TgHardcodedChannel("海角 AV", "hjgc0", ''),
  TgHardcodedChannel("无码 91", "wmav91", ''),
  TgHardcodedChannel("收藏 AV", "shoucangav", ''),
];
