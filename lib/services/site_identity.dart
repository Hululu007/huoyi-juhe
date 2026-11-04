/// 同一站点的归一身份：导出写库、选站列表、本地库入口三处共用。
///
/// 同一站点不管从几处出现（书源导入、站点导入、jar 内置、py 导入），
/// 只存一份数据：db 里按归一键存、列表里按归一键列、导出时按归一键
/// 写同一批记录，不重复爬出第二份。认同一以站点身份为准（源地址、
/// 主机），不看显示名；镜像、不同地址的算不同站，不强行合并。
///
/// 键格式只有两种：
/// - `host:<归一主机>`：地址本身就是内容站地址时用（见
///   [addressIsSiteAddress] 的适用范围）；
/// - `id:<登记 id>`：地址不是内容站地址、或没有地址时用。
library;
///
/// 主机归一：小写、去 www. 前缀、去默认端口。Uri 解析已把主机小写，
/// 这里只处理 www. 前缀；端口由 Uri.host 本身排除，不进键。

/// 已核实主机表的内置站：只有从客户端代码里亲眼看到 baseUrl 的站
/// 才进表，猜的不进。
///
/// - 红果 hongguo：hongguoduanju.com（HongguoContentClient.baseUrl）。
/// - 苹果 CMS 四站：花果、发果、伍果、网果的 MaccmsContentClient
///   baseUrl 去 www. 后的主机。
/// - 红果镜像 hgtvmirror 刻意不进表：它与红果共用 hongguoduanju.com，
///   但在站点表里是独立的一站（自己的分类与播放线），按“镜像算
///   不同站”走 id 键，不与红果合并。
/// - 其余内置站主机未核实，不进表：宁可不合并，不错合并。
const knownBuiltinHosts = <String, String>{
  'hongguo': 'hongguoduanju.com',
  'huaguo': 'zywest263.com',
  'faguo': 'xzyx168.com',
  'wuguo': 'duanju55.com',
  'wangguo': 'duanju2.com',
};

String? _hostOf(String address) {
  final trimmed = address.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  var host = uri.host.trim().toLowerCase();
  if (host.isEmpty) return null;
  if (host.startsWith('www.')) host = host.substring('www.'.length);
  if (host.isEmpty) return null;
  return host;
}

/// 登记条目的地址是不是内容站本身的地址：只有这两类是。
/// - customMaccms：地址就是 CMS 接口地址，即内容站地址；
/// - legadoImport：书源的 source.url 就是内容站根地址。
/// 其余类的地址都不是内容站地址，不能按主机合并：
/// jar/py 的地址是包文件地址（文件主机不是内容站），
/// js/xbpq 的地址是本地文件名，remoteJson 的地址是配置文件地址。
bool addressIsSiteAddressForKind(String kindName) {
  return kindName == 'customMaccms' || kindName == 'legadoImport';
}

String canonicalSiteKey({
  required String siteId,
  String address = '',
  bool addressIsSiteAddress = false,
}) {
  if (addressIsSiteAddress) {
    final host = _hostOf(address);
    if (host != null) return 'host:$host';
  }
  final known = knownBuiltinHosts[siteId];
  if (known != null) return 'host:$known';
  if (siteId.startsWith('host:') || siteId.startsWith('id:')) {
    return siteId;
  }
  return 'id:$siteId';
}

/// 按归一键去重，保留每键第一次出现的那一项（内置站在前时，
/// 内置行胜出，后来的同站登记行被折掉，不重复列）。
List<T> dedupeByCanonicalKey<T>(
  List<T> items,
  String Function(T item) keyOf,
) {
  final seen = <String>{};
  return [
    for (final item in items)
      if (seen.add(keyOf(item))) item,
  ];
}
