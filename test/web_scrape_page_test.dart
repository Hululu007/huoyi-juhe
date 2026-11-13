import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/web_scrape_page.dart';
import 'package:fqapp/services/py_bridge.dart';
import 'package:fqapp/web_scrape/scrape_py_service.dart';
import 'package:fqapp/web_scrape/verification_detector.dart';
import 'package:fqapp/web_scrape/web_scrape_service.dart';

const String _pageHtml = '''
<html><head><title>示例站</title></head><body>
<a href="/vod/detail/1.html">第一部</a>
<a href="/vod/detail/2.html">第二部</a>
</body></html>''';

const String _fakeTemplate = '''
SITE_NAME = "@NAME@"
SITE = "@SITE@"
BASES = @BASES@
API = "@API@"
FORCE = "@FORCE@"
IMGPROXY = "@IMGPROXY@"
MODE = "@MODE@"
TS = "@TS@"
''';

WebScrapeService fakeScrapeService() => WebScrapeService.forTest(
  (_) async =>
      ScrapeFetchResponse(statusCode: 200, bodyBytes: utf8.encode(_pageHtml)),
);

class _FakeRegistrar implements ScrapePyRegistrar {
  final List<String> calls = <String>[];

  @override
  Future<void> load() async {}

  @override
  Future<ScrapePyEntryRef?> findPyImportByName(String name) async {
    calls.add('find:$name');
    return null;
  }

  @override
  Future<ScrapePyEntryRef> addPyImport(
    String name,
    String source, {
    String? fileBaseName,
  }) async {
    calls.add('add:$name');
    return ScrapePyEntryRef(id: 'new-id', name: name);
  }

  @override
  Future<ScrapePyEntryRef> updatePyImportContent({
    required String id,
    required String source,
    String? templateCode,
  }) async {
    calls.add('update:$id');
    return ScrapePyEntryRef(id: id, name: '');
  }
}

ScrapePyService fakePyService({
  Future<PyValidation?> Function(String source)? validate,
  ScrapePyRegistrar? registrar,
}) => ScrapePyService(
  fetch: (_) async => throw StateError('no network in test'),
  templateText: () async => _fakeTemplate,
  matchTemplate: (_) async => null,
  validate: validate ?? (_) async => null,
  registrar: registrar ?? _FakeRegistrar(),
);

Future<void> pumpPage(
  WidgetTester tester, {
  WebScrapeService? scrapeService,
  ScrapePyService? pyService,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: WebScrapePage(
        scrapeService: scrapeService ?? fakeScrapeService(),
        pyService: pyService ?? fakePyService(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> scrapeExample(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), 'https://example.com/list');
  await tester.tap(find.text('爬取'));
  await tester.pumpAndSettle();
}

void main() {
  group('WebScrapePage', () {
    testWidgets('初始态：标题、五段模式、空态提示，无 py 卡片', (tester) async {
      await pumpPage(tester);
      expect(find.text('网页爬取'), findsOneWidget);
      expect(find.text('通用'), findsOneWidget);
      expect(find.text('小说'), findsOneWidget);
      expect(find.text('漫画'), findsOneWidget);
      expect(find.text('视频'), findsOneWidget);
      expect(find.text('文章'), findsOneWidget);
      expect(find.text('输入网址开始爬取'), findsOneWidget);
      expect(find.text('一键生成 py 蜘蛛'), findsNothing);
    });

    testWidgets('爬取后显示标题、py 卡片与链接列表', (tester) async {
      await pumpPage(tester);
      await scrapeExample(tester);
      expect(find.text('示例站'), findsOneWidget);
      expect(find.text('一键生成 py 蜘蛛'), findsOneWidget);
      expect(find.text('一键生成并导出 py'), findsOneWidget);
      expect(find.text('第一部'), findsOneWidget);
      expect(find.text('第二部'), findsOneWidget);
    });

    testWidgets('生成成功后显示站名/文件/模板与导出、注册按钮', (tester) async {
      await pumpPage(tester);
      await scrapeExample(tester);
      await tester.tap(find.text('一键生成并导出 py'));
      await tester.pumpAndSettle();
      expect(find.text('已生成：示例站'), findsOneWidget);
      expect(find.text('文件：examplecom.py'), findsOneWidget);
      await tester.ensureVisible(find.text('导出 py 文件'));
      expect(find.text('导出 py 文件'), findsOneWidget);
      await tester.ensureVisible(find.text('注册进站点列表'));
      expect(find.text('注册进站点列表'), findsOneWidget);
    });

    testWidgets('注册后按钮禁用并提示去站源管理查看', (tester) async {
      final registrar = _FakeRegistrar();
      await pumpPage(tester, pyService: fakePyService(registrar: registrar));
      await scrapeExample(tester);
      await tester.tap(find.text('一键生成并导出 py'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('注册进站点列表'));
      await tester.tap(find.text('注册进站点列表'));
      await tester.pumpAndSettle();
      expect(registrar.calls, <String>['find:示例站', 'add:示例站']);
      expect(find.text('已注册进站点列表'), findsOneWidget);
      await tester.ensureVisible(find.text('去站源管理查看'));
      expect(find.text('去站源管理查看'), findsOneWidget);
      final OutlinedButton button = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('已注册进站点列表'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('生成失败显示错误块', (tester) async {
      await pumpPage(
        tester,
        pyService: fakePyService(
          validate: (_) async => const PyValidation(
            ok: false,
            hasSpider: false,
            missing: <String>['Spider'],
            error: '缺少 Spider 类',
          ),
        ),
      );
      await scrapeExample(tester);
      await tester.tap(find.text('一键生成并导出 py'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.textContaining('缺少 Spider 类'));
      expect(find.textContaining('缺少 Spider 类'), findsOneWidget);
      expect(find.text('导出 py 文件'), findsNothing);
    });

    testWidgets('验证拦截：诚实报错 + 浏览器打开按钮', (tester) async {
      final blocking = WebScrapeService.forTest(
        (_) async =>
            throw VerificationRequiredException(url: 'https://example.com/'),
      );
      await pumpPage(tester, scrapeService: blocking);
      await scrapeExample(tester);
      expect(find.textContaining('需要验证后才能访问'), findsOneWidget);
      expect(find.text('在浏览器打开'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('地址无效时报错不爬取', (tester) async {
      var called = false;
      final counting = WebScrapeService.forTest((_) async {
        called = true;
        return ScrapeFetchResponse(
          statusCode: 200,
          bodyBytes: utf8.encode(_pageHtml),
        );
      });
      await pumpPage(tester, scrapeService: counting);
      await tester.enterText(find.byType(TextField), 'not a url');
      await tester.tap(find.text('爬取'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请输入正确的网址'), findsOneWidget);
      expect(called, isFalse);
    });

    test('normalizeScrapeUrl：补协议、判 host', () {
      expect(normalizeScrapeUrl('example.com/x'), 'https://example.com/x');
      expect(
        normalizeScrapeUrl('  http://example.com/  '),
        'http://example.com/',
      );
      expect(normalizeScrapeUrl('not a url'), isNull);
      expect(normalizeScrapeUrl(''), isNull);
    });
  });
}
