import 'actress_adapter_models.dart' show AppFailure;
import 'actress_mjv_parse.dart';
import 'actress_online_parse.dart';
import 'actress_online_sources.dart';

/// 18AV（www.18av.nl）演员库在线源：Dart 直连移植（不走
/// jar 桥）。2026-11-27 盘点实测坐实它与 MJV 是同一套系统、
/// 同一内容库：搜索 `/zh/chinese_search/all/<番号>/1.html`、
/// 详情 `/zh/<ctype>_content/<num>/<番号>.html` 内嵌
/// hadeedg/mvarr 加密 pid（解密与 chaoliu.py 逐字对齐，见
/// actress_mjv_parse.dart）、取流 /js/player/play.php 出
/// 720/1080 两档（协议相对地址补 https:）。
///
/// 取数口径按盘点注意点：普通 GET 直发（盘点实测详情页
/// 普通头立即 200），不套 MJV 的年龄门重试回路。本机出口
/// 已实测全链通（搜索/详情/解密/取流/分片 206）；本 Dart
/// 移植与手机侧播放未验，界面按既有口径带「未验」小标、
/// 内部登记未验。
class Av18ActressSource extends ActressOnlineSource {
  const Av18ActressSource();

  @override
  String get id => 'av18';

  @override
  String get label => '18AV';

  @override
  String get site => av18Site;

  @override
  List<OnlineTabOption> get primaryTabs => kAv18Tabs;

  @override
  List<OnlineTabOption> get secondaryTabs => const [];

  @override
  String get defaultPrimaryId => 'chinese';

  @override
  String get defaultSecondaryId => '';

  @override
  Map<String, String> get pageHeaders => {
    'User-Agent': actressOnlineUserAgent,
    'Referer': '$site/',
  };

  @override
  Future<List<OnlineVideoCard>> fetchCards({
    required String primaryId,
    required String secondaryId,
    required String query,
    required int page,
    required ActressOnlineFetch fetch,
  }) async {
    final url = query.trim().isNotEmpty
        ? av18SearchUrl(query.trim(), page)
        : av18ListUrl(
            base: actressPickTab(primaryTabs, primaryId).value,
            page: page,
          );
    final html = await fetch(url, pageHeaders);
    return [
      for (final card in parseMjvCards(html))
        if (!av18NonVideoCtypes.contains(card.ctype))
          OnlineVideoCard(
            pageUrl: card.detailUrl(site),
            title: card.title.isNotEmpty ? card.title : card.slug,
            cover: card.cover,
          ),
    ];
  }

  @override
  Future<ActressOnlinePlay> resolvePlay(
    OnlineVideoCard card, {
    required ActressOnlineFetch fetch,
  }) async {
    final html = await fetch(card.pageUrl, pageHeaders);
    final info = parseMjvDetailInfo(html);
    final pids = extractMjvPids(html);
    if (pids.isEmpty) {
      throw AppFailure('这个视频暂时取不到播放地址');
    }
    final text = await fetch(
      av18PlayPhpUrl(pids.first, 720),
      pageHeaders,
    );
    var stream = parsePlayPhpStream(text, preferSize: 720);
    if (stream.isEmpty) {
      final text1080 = await fetch(
        av18PlayPhpUrl(pids.first, 1080),
        pageHeaders,
      );
      stream = parsePlayPhpStream(text1080, preferSize: 1080);
    }
    if (stream.isEmpty) {
      throw AppFailure('这个视频暂时取不到播放地址');
    }
    return ActressOnlinePlay(
      streamUrl: stream,
      headers: {'User-Agent': actressOnlineUserAgent, 'Referer': '$site/'},
      detail: OnlineDetailInfo(
        title: info.title.isNotEmpty ? info.title : card.title,
        poster: info.cover.isNotEmpty ? info.cover : card.cover,
      ),
    );
  }

  @override
  Future<OnlineDetailInfo?> fetchInfo(
    OnlineVideoCard card, {
    required ActressOnlineFetch fetch,
  }) async {
    final html = await fetch(card.pageUrl, pageHeaders);
    if (html.isEmpty) return null;
    final info = parseMjvDetailInfo(html);
    if (info.title.isEmpty && info.cover.isEmpty) return null;
    return OnlineDetailInfo(title: info.title, poster: info.cover);
  }

}

/// 18AV 站点根（盘点首选域名，其余三域名未逐个验全链，
/// 不进轮换表）。
const av18Site = 'https://www.18av.nl';

/// 18AV 一级页签 = MJV 模板视频分类（value 是 URL 里的
/// 分类基名，列表地址 `/zh/<base>_list/all/<页>.html`）。
const kAv18Tabs = <OnlineTabOption>[
  OnlineTabOption(id: 'chinese', name: '中文字幕', value: 'chinese'),
  OnlineTabOption(id: 'censored', name: '有码', value: 'censored'),
  OnlineTabOption(id: 'uncensored', name: '无码', value: 'uncensored'),
  OnlineTabOption(id: 'amateurjav', name: '素人', value: 'amateurjav'),
  OnlineTabOption(
    id: 'reducing-mosaic',
    name: '无码破解',
    value: 'reducing-mosaic',
  ),
];

/// 非视频分类（小说/图片系）：18AV 线只收视频卡。
const av18NonVideoCtypes = <String>{
  'novel',
  'cg',
  'cwp',
  '18H',
  'doujin',
};

String av18SearchUrl(String query, int page) =>
    '$av18Site/zh/chinese_search/all/${Uri.encodeComponent(query)}/$page.html';

String av18ListUrl({required String base, required int page}) =>
    '$av18Site/zh/${base}_list/all/$page.html';

String av18PlayPhpUrl(String pid, int resolution) =>
    '$av18Site/js/player/play.php?numresolution=$resolution&lo=on&id=$pid';

/// 18AV 卡命中判定：详情地址尾段就是番号 slug，归一化后
/// 与目标番号相等才算找到（与 123AV 同口径）。
bool av18CardMatches(OnlineVideoCard card, String code) {
  final target = actressCodeKey(code);
  if (target.isEmpty) return false;
  final slug = card.pageUrl.split('/').last.replaceAll('.html', '');
  return actressCodeKey(slug) == target;
}
