// 移植自 NexHub（https://github.com/nexhub-app/NexHub，提交 37ddbdd，Apache-2.0）。
// 原始路径：lib/core/scraper/web_scrape_service.dart。
// 移植状态：改编——HttpFetcher（dio）未随本批移植，抓取改走本树现有
// package:http（与红果等 Dart 直取客户端同款的 plain http.Client，
// 系统代理只交给 Rust 核心与 jar 侧、VPN 走网络层，见下方抓取层注释）
// + gbk_codec 的 decodeHttpBody 解码；验证页判定改走随本批移植的
// VerificationDetector，命中时同样抛 VerificationRequiredException，契约不变。
// 抽取逻辑（ScrapeMode/ScrapeResult/ScrapeLink 与各模式分支）与原文一致；
// ScrapeResult 保留 html 字段（一键生成 py 的探测依据，不再重拉首页）。
// 另加可注入的 fetchHtml 供测试使用（默认走真实网络）。
/// 网页爬取服务。
///
/// 基于 [fetchScrapeResponse] 拉取 HTML，再用 [HtmlUtils] 按模式抽取内容。
/// 设计目标：把「抓取 + 解析」与 UI 隔离，UI 只负责展示。
library;

import 'package:http/http.dart' as http;

import '../services/gbk_codec.dart';
import 'html_utils.dart';
import 'verification_detector.dart';

/// 爬取模式：影响抽取策略与结果展示形态。
enum ScrapeMode { general, novel, comic, video, article }

/// 通用链接条目（供 general 模式展示）。
class ScrapeLink {
  final String text;
  final String url;
  const ScrapeLink({required this.text, required this.url});
}

/// 爬取结果：按模式填充不同字段，UI 按需渲染。
///
/// [html] 是本次实际拉取到的页面原文：一键生成 py 时直接用它做结构
/// 探测依据，不再重新拉取首页。
class ScrapeResult {
  final String url;
  final String? pageTitle;
  final String html;
  final List<String> paragraphs;
  final List<String> imageUrls;
  final List<String> videoUrls;
  final List<ScrapeLink> links;

  const ScrapeResult({
    required this.url,
    this.pageTitle,
    this.html = '',
    this.paragraphs = const <String>[],
    this.imageUrls = const <String>[],
    this.videoUrls = const <String>[],
    this.links = const <ScrapeLink>[],
  });

  bool get isEmpty =>
      pageTitle == null &&
      paragraphs.isEmpty &&
      imageUrls.isEmpty &&
      videoUrls.isEmpty &&
      links.isEmpty;
}

/// 一次抓取的原始响应（供测试注入假响应、供抓取层与校验层共用）。
class ScrapeFetchResponse {
  const ScrapeFetchResponse({
    required this.statusCode,
    required this.bodyBytes,
    this.headers = const <String, String>{},
  });

  final int statusCode;
  final List<int> bodyBytes;
  final Map<String, String> headers;
}

/// 抓取函数形态：测试注入假响应时用；默认实现是 [fetchScrapeResponse]。
typedef ScrapeFetcher = Future<ScrapeFetchResponse> Function(String url);

/// 抓取层默认实现：`package:http` GET + 浏览器 UA + 30 秒超时。
///
/// 代理说明（实施前已核对本树现有链路）：本树 Dart 侧直取客户端（红果、
/// 各果站、MacCMS 等）一律用 plain `http.Client()`，没有任何一处给 Dart
/// 的 http 配代理；系统代理只由 SystemProxyService 交给 Rust 核心与 jar
/// 侧，Dart 直取靠用户 VPN 走网络层。本抓取沿用同一写法，不另发明代理
/// 配置；[client] 可注入（测试用假客户端），不传时每次请求新建并关闭。
Future<ScrapeFetchResponse> fetchScrapeResponse(
  String url, {
  http.Client? client,
}) async {
  final owned = client == null;
  final httpClient = client ?? http.Client();
  try {
    final response = await httpClient
        .get(
          Uri.parse(url),
          headers: const <String, String>{
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          },
        )
        .timeout(const Duration(seconds: 30));
    return ScrapeFetchResponse(
      statusCode: response.statusCode,
      bodyBytes: response.bodyBytes,
      headers: response.headers,
    );
  } finally {
    if (owned) httpClient.close();
  }
}

/// 解码 + 校验一次抓取响应：GBK 感知解码；命中验证特征抛
/// [VerificationRequiredException]；其余 ≥400 状态抛 [HttpStatusException]；
/// 否则返回解码后的正文。爬取服务与 py 生成探测共用同一口。
String decodeAndCheckScrapeResponse(ScrapeFetchResponse response, String url) {
  final html = decodeHttpBody(
    response.bodyBytes,
    contentType: response.headers['content-type'],
  );
  if (VerificationDetector.isVerificationRequired(
    statusCode: response.statusCode,
    body: html,
    headers: response.headers,
  )) {
    throw VerificationRequiredException(
      url: url,
      statusCode: response.statusCode,
      body: html,
    );
  }
  if (response.statusCode >= 400) {
    throw HttpStatusException(
      url: url,
      statusCode: response.statusCode,
      body: html,
    );
  }
  return html;
}

/// 抓取 [url] 并返回解码后的正文（验证/错误状态抛异常，见
/// [decodeAndCheckScrapeResponse]）。py 生成探测的默认取数口。
Future<String> fetchScrapeHtml(
  String url, {
  http.Client? client,
  ScrapeFetcher? fetch,
}) async {
  final response = fetch != null
      ? await fetch(url)
      : await fetchScrapeResponse(url, client: client);
  return decodeAndCheckScrapeResponse(response, url);
}

/// 网页爬取服务——全应用单例。
class WebScrapeService {
  WebScrapeService._({this._fetchHtml});

  static final WebScrapeService instance = WebScrapeService._();

  /// 测试用构造：注入假抓取，替代真实网络。
  factory WebScrapeService.forTest(ScrapeFetcher fetchHtml) =>
      WebScrapeService._(fetchHtml: fetchHtml);

  final ScrapeFetcher? _fetchHtml;

  /// 抓取 [url] 并按 [mode] 抽取内容。
  ///
  /// 相对地址会自动基于 [url] 解析为绝对地址。命中验证特征时抛出
  /// [VerificationRequiredException]（由调用方决定报错指引或跳转验证）。
  Future<ScrapeResult> scrape(String url, ScrapeMode mode) async {
    final fetch = _fetchHtml;
    final response = fetch != null
        ? await fetch(url)
        : await fetchScrapeResponse(url);
    final html = decodeAndCheckScrapeResponse(response, url);
    final base = Uri.tryParse(url);
    String? absolutize(String? raw) {
      if (raw == null || raw.isEmpty) return null;
      final uri = Uri.tryParse(raw);
      if (uri == null) return null;
      final resolved = base != null ? base.resolveUri(uri) : uri;
      return resolved.toString();
    }

    final pageTitle = HtmlUtils.query(html, 'title');

    switch (mode) {
      case ScrapeMode.general:
        final links = HtmlUtils.elements(html, 'a')
            .map(
              (e) => ScrapeLink(
                text: e.text.trim(),
                url: absolutize(e.attributes['href']) ?? '',
              ),
            )
            .where((l) => l.url.isNotEmpty)
            .toList();
        return ScrapeResult(
          url: url,
          pageTitle: pageTitle,
          html: html,
          links: links,
        );

      case ScrapeMode.novel:
      case ScrapeMode.article:
        final paragraphs = HtmlUtils.queryAll(
          html,
          'p',
        ).where((s) => s.trim().length > 1).toList();
        final imageUrls = mode == ScrapeMode.article
            ? _extractImages(html)
                  .map((s) => absolutize(s))
                  .where((s) => s != null)
                  .cast<String>()
                  .toList()
            : const <String>[];
        return ScrapeResult(
          url: url,
          pageTitle: pageTitle,
          html: html,
          paragraphs: paragraphs,
          imageUrls: imageUrls,
        );

      case ScrapeMode.comic:
        final imageUrls = _extractImages(html)
            .map((s) => absolutize(s))
            .where((s) => s != null)
            .cast<String>()
            .toList();
        return ScrapeResult(
          url: url,
          pageTitle: pageTitle,
          html: html,
          imageUrls: imageUrls,
        );

      case ScrapeMode.video:
        final videoUrls = _extractVideos(html)
            .map((s) => absolutize(s))
            .where((s) => s != null)
            .cast<String>()
            .toList();
        return ScrapeResult(
          url: url,
          pageTitle: pageTitle,
          html: html,
          videoUrls: videoUrls,
        );
    }
  }

  List<String> _extractImages(String html) => HtmlUtils.elements(html, 'img')
      .map(
        (e) =>
            e.attributes['src'] ??
            e.attributes['data-src'] ??
            e.attributes['data-original'] ??
            '',
      )
      .where((s) => s.isNotEmpty)
      .toList();

  List<String> _extractVideos(String html) {
    final list = <String>[];
    for (final e in HtmlUtils.elements(html, 'video')) {
      final src = e.attributes['src'];
      if (src != null && src.isNotEmpty) list.add(src);
    }
    for (final e in HtmlUtils.elements(html, 'video source')) {
      final src = e.attributes['src'];
      if (src != null && src.isNotEmpty) list.add(src);
    }
    for (final e in HtmlUtils.elements(html, 'iframe')) {
      final src = e.attributes['src'];
      if (src != null && src.isNotEmpty) list.add(src);
    }
    return list;
  }
}
