import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/web_scrape/verification_detector.dart';
import 'package:fqapp/web_scrape/web_scrape_service.dart';

ScrapeFetchResponse resp(
  String body, {
  int status = 200,
  Map<String, String> headers = const <String, String>{},
}) => ScrapeFetchResponse(
  statusCode: status,
  bodyBytes: utf8.encode(body),
  headers: headers,
);

void main() {
  group('WebScrapeService', () {
    test('general 模式抽链接并转绝对地址', () async {
      const html = '''
<html><head><title>示例站</title></head><body>
<a href="/vod/detail/1.html">第一部</a>
<a href="https://other.example/x">外站</a>
<a href="">空链接</a>
</body></html>''';
      final service = WebScrapeService.forTest((_) async => resp(html));
      final result = await service.scrape(
        'https://example.com/list',
        ScrapeMode.general,
      );
      expect(result.pageTitle, '示例站');
      expect(result.html, html);
      expect(result.links.map((l) => l.url), <String>[
        'https://example.com/vod/detail/1.html',
        'https://other.example/x',
      ]);
      expect(result.links.first.text, '第一部');
      expect(result.isEmpty, isFalse);
    });

    test('novel 模式抽段落并丢弃过短行', () async {
      const html = '''
<html><body><p>第一章 开始了</p><p> </p><p>。</p><p>第二段正文内容</p></body></html>''';
      final service = WebScrapeService.forTest((_) async => resp(html));
      final result = await service.scrape(
        'https://example.com/n/1',
        ScrapeMode.novel,
      );
      expect(result.paragraphs, <String>['第一章 开始了', '第二段正文内容']);
      expect(result.imageUrls, isEmpty);
    });

    test('article 模式同时抽段落与图片', () async {
      const html = '''
<html><body><p>正文第一段</p><img src="/a.jpg"></body></html>''';
      final service = WebScrapeService.forTest((_) async => resp(html));
      final result = await service.scrape(
        'https://example.com/post/1',
        ScrapeMode.article,
      );
      expect(result.paragraphs, <String>['正文第一段']);
      expect(result.imageUrls, <String>['https://example.com/a.jpg']);
    });

    test('comic 模式抽图片：src / data-src / data-original', () async {
      const html = '''
<html><body>
<img src="/1.jpg">
<img data-src="/2.jpg">
<img data-original="/3.jpg">
<img>
</body></html>''';
      final service = WebScrapeService.forTest((_) async => resp(html));
      final result = await service.scrape(
        'https://example.com/c/1',
        ScrapeMode.comic,
      );
      expect(result.imageUrls, <String>[
        'https://example.com/1.jpg',
        'https://example.com/2.jpg',
        'https://example.com/3.jpg',
      ]);
    });

    test('video 模式抽 video / source / iframe 地址', () async {
      const html = '''
<html><body>
<video src="/a.mp4"></video>
<video><source src="/b.m3u8"></video>
<iframe src="/player.html"></iframe>
</body></html>''';
      final service = WebScrapeService.forTest((_) async => resp(html));
      final result = await service.scrape(
        'https://example.com/v/1',
        ScrapeMode.video,
      );
      expect(result.videoUrls, <String>[
        'https://example.com/a.mp4',
        'https://example.com/b.m3u8',
        'https://example.com/player.html',
      ]);
    });

    test('空页面 isEmpty 为真', () async {
      final service = WebScrapeService.forTest(
        (_) async => resp('<html><body></body></html>'),
      );
      final result = await service.scrape(
        'https://example.com/',
        ScrapeMode.general,
      );
      expect(result.isEmpty, isTrue);
    });

    test('200 + 挑战特征抛 VerificationRequiredException', () async {
      final service = WebScrapeService.forTest(
        (_) async => resp('<html><title>Just a moment...</title></html>'),
      );
      await expectLater(
        service.scrape('https://example.com/', ScrapeMode.general),
        throwsA(isA<VerificationRequiredException>()),
      );
    });

    test('403 直接抛 VerificationRequiredException', () async {
      final service = WebScrapeService.forTest(
        (_) async => resp('forbidden', status: 403),
      );
      await expectLater(
        service.scrape('https://example.com/', ScrapeMode.general),
        throwsA(isA<VerificationRequiredException>()),
      );
    });

    test('404 抛 HttpStatusException', () async {
      final service = WebScrapeService.forTest(
        (_) async => resp('not found', status: 404),
      );
      await expectLater(
        service.scrape('https://example.com/', ScrapeMode.general),
        throwsA(
          isA<HttpStatusException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });

    test('注入的抓取只被调用一次且用传入的地址', () async {
      final seen = <String>[];
      final service = WebScrapeService.forTest((url) async {
        seen.add(url);
        return resp('<html><body><p>正文段落</p></body></html>');
      });
      await service.scrape('https://example.com/n/9', ScrapeMode.novel);
      expect(seen, <String>['https://example.com/n/9']);
    });
  });
}
