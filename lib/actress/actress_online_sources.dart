import 'actress_adapter_http.dart' show ContentHttp;
import 'actress_adapter_models.dart' show AppFailure;
import 'actress_av18_source.dart';
import 'actress_online_parse.dart';

/// 演员库在线源（123AV / PH）的取数服务：Dart 直连站点页面，
/// 解析在 actress_online_parse.dart（2026-11-27 照魔蚁侧修正版
/// 逐项对齐移植：123AV 内联 player JSON 取址 + /stream 换流、
/// Referer 用嵌入页；PH flashvars 取流）。播放不走 jar 旧链：
/// 点卡/线路现取播放地址后组装成 direct 直链 + 播放头，交
/// 作品详情页内嵌播放（见 actress_work_detail_page.dart）。
///
/// 取数函数可注入（[ActressOnlineFetch]），测试/预览用假取数，
/// 不碰真网络；生产默认走适配层 [ContentHttp]（直连）。

/// 在线源取数函数：给地址与请求头，回网页文本；失败抛
/// [AppFailure]（文案已是中文人话，界面直接用）。
typedef ActressOnlineFetch =
    Future<String> Function(String url, Map<String, String> headers);

/// 在线源统一 UA：与魔蚁修正版口径一致的桌面 Chrome。
const actressOnlineUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/122.0.0.0 Safari/537.36';

/// 默认取数客户端：包一层 [ContentHttp]，超时放宽到 25 秒
/// （两站页面较大，移动网络慢时短超时容易误杀）。
class ActressOnlineClient {
  ActressOnlineClient([ContentHttp? http]) : _http = http ?? ContentHttp();

  final ContentHttp _http;

  Future<String> get(String url, Map<String, String> headers) =>
      _http.get(url, headers: headers, timeout: const Duration(seconds: 25));
}

/// 一次取流的结果：最终播放地址 + 播放请求头 + 详情信息。
class ActressOnlinePlay {
  const ActressOnlinePlay({
    required this.streamUrl,
    required this.headers,
    required this.detail,
  });

  final String streamUrl;

  /// 播放请求头（UA + Referer），起播前经本地代理注册带上
  /// （裸地址喂播放器、头随代理会话走）。
  final Map<String, String> headers;

  final OnlineDetailInfo detail;
}

/// 在线源定义：界面只认这套接口（页签、列表、取流）。
abstract class ActressOnlineSource {
  const ActressOnlineSource();

  /// 源 id（与原生页源条一致：'123av' / 'pornhub'）。
  String get id;

  /// 源切换条上的名字。
  String get label;

  /// 站点根地址。
  String get site;

  /// 一级页签：PH 是排序，123AV 是栏目。
  List<OnlineTabOption> get primaryTabs;

  /// 二级页签：只有 PH 有（分类）；123AV 为空。
  List<OnlineTabOption> get secondaryTabs;

  String get defaultPrimaryId;
  String get defaultSecondaryId;

  /// 页面请求头（列表/详情共用）。
  Map<String, String> get pageHeaders => {
    'User-Agent': actressOnlineUserAgent,
    'Referer': '$site/',
  };

  OnlineTabOption _pick(List<OnlineTabOption> tabs, String id) =>
      actressPickTab(tabs, id);

  /// 取一页卡片。[query] 非空时走搜索（页签不参与拼址，与站方
  /// 搜索口径一致）。取不到/解析为空回空列表，失败抛 AppFailure。
  Future<List<OnlineVideoCard>> fetchCards({
    required String primaryId,
    required String secondaryId,
    required String query,
    required int page,
    required ActressOnlineFetch fetch,
  });

  /// 点卡取流：打开详情页解析出播放地址；取不到抛 AppFailure。
  Future<ActressOnlinePlay> resolvePlay(
    OnlineVideoCard card, {
    required ActressOnlineFetch fetch,
  });

  /// 只拉详情页信息（剧照/演员/字段回填用，不取流）：详情
  /// 页开页后台调用；拉不到回 null，不抛。
  Future<OnlineDetailInfo?> fetchInfo(
    OnlineVideoCard card, {
    required ActressOnlineFetch fetch,
  });
}

/// PH（cn.pornhub.com）：一级排序 + 二级分类，详情页 flashvars
/// 里带 mediaDefinitions 签名 m3u8（签名绑取页出口 IP：手机上
/// 取页与取流同一出口，链路成立；本机机房出口每连接换 IP，
/// 本机验不到分片，按未验标，见本批报告）。
class PhActressSource extends ActressOnlineSource {
  const PhActressSource();

  @override
  String get id => 'pornhub';

  @override
  String get label => 'PH';

  @override
  String get site => phSite;

  @override
  List<OnlineTabOption> get primaryTabs => kPhSortTabs;

  @override
  List<OnlineTabOption> get secondaryTabs => kPhGenreCats;

  @override
  String get defaultPrimaryId => 'hot';

  @override
  String get defaultSecondaryId => 'all';

  @override
  Future<List<OnlineVideoCard>> fetchCards({
    required String primaryId,
    required String secondaryId,
    required String query,
    required int page,
    required ActressOnlineFetch fetch,
  }) async {
    final url = phListUrl(
      sortValue: _pick(primaryTabs, primaryId).value,
      catValue: _pick(secondaryTabs, secondaryId).value,
      query: query,
      page: page,
    );
    final html = await fetch(url, pageHeaders);
    return parsePhCards(html);
  }

  @override
  Future<ActressOnlinePlay> resolvePlay(
    OnlineVideoCard card, {
    required ActressOnlineFetch fetch,
  }) async {
    final html = await fetch(card.pageUrl, pageHeaders);
    final detail = parsePhDetail(html);
    final stream = extractPhStream(html);
    if (stream.isEmpty) {
      throw AppFailure('这个视频暂时取不到播放地址');
    }
    return ActressOnlinePlay(
      streamUrl: stream,
      headers: {'User-Agent': actressOnlineUserAgent, 'Referer': '$site/'},
      detail: detail,
    );
  }

  @override
  Future<OnlineDetailInfo?> fetchInfo(
    OnlineVideoCard card, {
    required ActressOnlineFetch fetch,
  }) async {
    final html = await fetch(card.pageUrl, pageHeaders);
    if (html.isEmpty) return null;
    return parsePhDetail(html);
  }
}

/// 123AV（123av.com）：一级栏目页签；取址走详情页内联
/// player(JSON.parse(…)) 的集数 JSON（嵌入域名现读不写
/// 死），再走嵌入源 /stream 接口换 m3u8（魔蚁侧出口补验批
/// 全链实证：列表 200 → 全长分片 → 首分片 Range 206）。
class Av123ActressSource extends ActressOnlineSource {
  const Av123ActressSource();

  @override
  String get id => '123av';

  @override
  String get label => '123AV';

  @override
  String get site => av123Site;

  @override
  List<OnlineTabOption> get primaryTabs => kAv123Tabs;

  @override
  List<OnlineTabOption> get secondaryTabs => const [];

  @override
  String get defaultPrimaryId => 'recent';

  @override
  String get defaultSecondaryId => '';

  @override
  Future<List<OnlineVideoCard>> fetchCards({
    required String primaryId,
    required String secondaryId,
    required String query,
    required int page,
    required ActressOnlineFetch fetch,
  }) async {
    final url = av123ListUrl(
      path: _pick(primaryTabs, primaryId).value,
      query: query,
      page: page,
    );
    final html = await fetch(url, pageHeaders);
    return parseAv123Cards(html);
  }

  @override
  Future<ActressOnlinePlay> resolvePlay(
    OnlineVideoCard card, {
    required ActressOnlineFetch fetch,
  }) async {
    final html = await fetch(card.pageUrl, pageHeaders);
    final detail = parseAv123Detail(html);
    final embed = av123EmbedOf(html);
    if (embed.isEmpty) {
      throw AppFailure('这个视频暂时取不到播放地址');
    }
    final request = av123StreamRequest(embed);
    if (request == null) {
      // 嵌入地址不是 /e/ 形：本身就是媒体地址才直接用。
      if (embed.contains('.m3u8') || embed.contains('.mp4')) {
        return ActressOnlinePlay(
          streamUrl: embed,
          headers: {
            'User-Agent': actressOnlineUserAgent,
            'Referer': '$site/',
          },
          detail: detail,
        );
      }
      throw AppFailure('这个视频暂时取不到播放地址');
    }
    // 取流请求头 Referer 用嵌入页地址（补验批实证口径）；
    // 播放地址的 Referer 同用嵌入页地址。
    final text = await fetch(request.apiUrl, {
      'User-Agent': actressOnlineUserAgent,
      'Referer': embed,
    });
    final stream = extractAv123Stream(text);
    if (stream.isEmpty) {
      throw AppFailure('这个视频暂时取不到播放地址');
    }
    return ActressOnlinePlay(
      streamUrl: stream,
      headers: {'User-Agent': actressOnlineUserAgent, 'Referer': embed},
      detail: detail,
    );
  }

  @override
  Future<OnlineDetailInfo?> fetchInfo(
    OnlineVideoCard card, {
    required ActressOnlineFetch fetch,
  }) async {
    final html = await fetch(card.pageUrl, pageHeaders);
    if (html.isEmpty) return null;
    return parseAv123Detail(html);
  }
}

/// 全部 Dart 直连在线源（竞速同层顺序：123AV → PH →
/// 18AV）。MissAV / 潮流 / MJV 走 py 桥，不在这张表里
/// （见 actress_py_lines.dart）。
const kActressOnlineSources = <ActressOnlineSource>[
  Av123ActressSource(),
  PhActressSource(),
  Av18ActressSource(),
];

/// 线路全集（详情页按番号搜线路用）：与可浏览源同一份。
const kActressLineSources = kActressOnlineSources;

/// 按 id 取在线源；取不到回 null（'' 与 'whos' 不是 Dart 直连源）。
ActressOnlineSource? actressOnlineSourceById(String id) {
  for (final source in kActressOnlineSources) {
    if (source.id == id) return source;
  }
  return null;
}

/// 按 id 选页签，选不到回第一项（各源 fetchCards 共用）。
OnlineTabOption actressPickTab(List<OnlineTabOption> tabs, String id) =>
    tabs.firstWhere((row) => row.id == id, orElse: () => tabs.first);

/// 番号归一化（去分隔符、大写）：123AV/PH 搜索命中判定用。
/// 空番号不参与匹配（返回空串，调用方按未找到处理）。
String actressCodeKey(String code) =>
    code.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// 一张在线卡是否就是这部片：
/// - 123AV：详情页地址里的番号与目标番号归一化后相等；
/// - PH：没有番号体系，只认标题里带目标番号（归一化后包含），
///   对不上不算找到——不拿别的片充数（2026-11-26 用户令）。
bool actressOnlineCardMatches({
  required ActressOnlineSource source,
  required OnlineVideoCard card,
  required String code,
}) {
  final target = actressCodeKey(code);
  if (target.isEmpty) return false;
  if (source.id == '123av') {
    return actressCodeKey(av123CodeOf(card.pageUrl)) == target;
  }
  if (source.id == 'av18') {
    return av18CardMatches(card, code);
  }
  return actressCodeKey(card.title).contains(target);
}
