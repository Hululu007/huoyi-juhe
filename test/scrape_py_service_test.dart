import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/py_bridge.dart';
import 'package:fqapp/web_scrape/scrape_py_service.dart';
import 'package:fqapp/web_scrape/verification_detector.dart';

const String fakeTemplate = '''
SITE_NAME = "@NAME@"
SITE = "@SITE@"
BASES = @BASES@
API = "@API@"
FORCE = "@FORCE@"
IMGPROXY = "@IMGPROXY@"
MODE = "@MODE@"
TS = "@TS@"
''';

class FakeRegistrar implements ScrapePyRegistrar {
  ScrapePyEntryRef? existing;
  final List<String> calls = <String>[];
  String? addedFileBaseName;
  String? updatedTemplateCode;

  @override
  Future<void> load() async {}

  @override
  Future<ScrapePyEntryRef?> findPyImportByName(String name) async {
    calls.add('find:$name');
    return existing;
  }

  @override
  Future<ScrapePyEntryRef> addPyImport(
    String name,
    String source, {
    String? fileBaseName,
  }) async {
    calls.add('add:$name');
    addedFileBaseName = fileBaseName;
    return ScrapePyEntryRef(id: 'new-id', name: name);
  }

  @override
  Future<ScrapePyEntryRef> updatePyImportContent({
    required String id,
    required String source,
    String? templateCode,
  }) async {
    calls.add('update:$id');
    updatedTemplateCode = templateCode;
    return ScrapePyEntryRef(id: id, name: existing?.name ?? '');
  }
}

ScrapePyService makeService({
  Future<String> Function(String url)? fetch,
  Future<String?> Function(String url)? matchTemplate,
  Future<PyValidation?> Function(String source)? validate,
  ScrapePyRegistrar? registrar,
}) => ScrapePyService(
  fetch: fetch ?? (_) async => throw StateError('no network in test'),
  templateText: () async => fakeTemplate,
  matchTemplate: matchTemplate ?? (_) async => null,
  validate: validate ?? (_) async => null,
  registrar: registrar ?? FakeRegistrar(),
);

void main() {
  group('命名函数', () {
    test('safeName 去 www. 与端口、只留字母数字汉字', () {
      expect(
        ScrapePyService.safeName('https://www.example.com:8080/x'),
        'examplecom',
      );
      expect(ScrapePyService.safeName('https://example.com/'), 'examplecom');
      expect(ScrapePyService.safeName(''), '生成源');
    });

    test('sanitizeTitle 去引号反斜杠并截断 24 字', () {
      expect(ScrapePyService.sanitizeTitle('  “示例站” \\ 标题  '), '“示例站” 标题');
      expect(ScrapePyService.sanitizeTitle(''), '');
      expect(ScrapePyService.sanitizeTitle(null), '');
      expect(
        ScrapePyService.sanitizeTitle('这是一个超过二十四个字的很长很长的页面标题需要截断处理'),
        '这是一个超过二十四个字的很长很长的页面标题需要',
      );
    });

    test('pythonReprList 输出 Python 列表字面量', () {
      expect(
        ScrapePyService.pythonReprList(<String>['https://a.com']),
        "['https://a.com']",
      );
      expect(ScrapePyService.pythonReprList(<String>[]), '[]');
    });
  });

  group('探测链', () {
    test('苹果 CMS 命中：接口返回非空 list 即中，首页不重拉', () async {
      final seen = <String>[];
      final service = makeService(
        fetch: (url) async {
          seen.add(url);
          if (url.contains('/api.php/provide/vod')) {
            return '{"list":[{"vod_id":1}]}';
          }
          throw StateError('unexpected $url');
        },
      );
      final result = await service.generateFromScrape(
        scrapeUrl: 'https://example.com/some/page.html',
        html: '<html><head><title>示例站</title></head></html>',
        pageTitle: '示例站',
      );
      expect(result.templateId, 'apple_cms_v10');
      expect(result.mode, 'apple cms json');
      expect(result.api, 'https://example.com/api.php/provide/vod');
      expect(result.base, 'https://example.com');
      expect(result.siteName, '示例站');
      expect(result.fileName, 'examplecom.py');
      expect(seen, isNot(contains('https://example.com/some/page.html')));
    });

    test('MacCMS 由本次 HTML 命中', () async {
      final service = makeService();
      final result = await service.generateFromScrape(
        scrapeUrl: 'https://example.com/',
        html: '<html><a href="/vod/play/123.html">播放</a></html>',
      );
      expect(result.templateId, 'maccms_html');
      expect(result.mode, 'maccms html');
      expect(result.api, '');
    });

    test('MacCMS 由链接佐证命中', () async {
      final service = makeService();
      final result = await service.generateFromScrape(
        scrapeUrl: 'https://example.com/',
        html: '<html><body>plain</body></html>',
        linkUrls: <String>['https://example.com/vod/type/1.html'],
      );
      expect(result.templateId, 'maccms_html');
    });

    test('无特征走通用兜底', () async {
      final service = makeService();
      final result = await service.generateFromScrape(
        scrapeUrl: 'https://example.com/',
        html: '<html><body>plain page</body></html>',
      );
      expect(result.templateId, 'generic_html');
      expect(result.mode, 'generic html sniffing');
      expect(result.api, '');
    });

    test('域名模板 hint 置顶：hint 命中时先探 hint', () async {
      final seen = <String>[];
      final service = makeService(
        matchTemplate: (_) async => 'wordpress',
        fetch: (url) async {
          seen.add(url);
          if (url.contains('/wp-json/wp/v2/')) {
            return '{"name":"wp site","routes":{}}';
          }
          throw StateError('unexpected $url');
        },
      );
      final result = await service.generateFromScrape(
        scrapeUrl: 'https://example.com/',
        html: '<html><body>plain</body></html>',
      );
      expect(result.templateId, 'wordpress');
      expect(seen.first, contains('/wp-json/wp/v2/'));
    });
  });

  group('诚实报错', () {
    test('无页面内容时报错不编规则', () async {
      final service = makeService();
      await expectLater(
        service.generateFromScrape(
          scrapeUrl: 'https://example.com/',
          html: '   ',
        ),
        throwsA(
          isA<OneKeyException>().having(
            (e) => e.message,
            'message',
            contains('没有拿到页面内容'),
          ),
        ),
      );
    });

    test('解析不出基址时报错', () async {
      final service = makeService();
      await expectLater(
        service.generateFromScrape(
          scrapeUrl: 'not a url',
          html: '<html></html>',
        ),
        throwsA(isA<OneKeyException>()),
      );
    });

    test('探测命中验证页转为带指引的错误', () async {
      final service = makeService(
        fetch: (_) async => throw VerificationRequiredException(
          url: 'https://example.com/api.php/provide/vod?ac=list',
        ),
      );
      await expectLater(
        service.generateFromScrape(
          scrapeUrl: 'https://example.com/',
          html: '<html><body>plain</body></html>',
        ),
        throwsA(
          isA<OneKeyVerificationException>().having(
            (e) => e.message,
            'message',
            contains('请先在浏览器里完成验证'),
          ),
        ),
      );
    });

    test('校验失败时报错', () async {
      final service = makeService(
        validate: (_) async => const PyValidation(
          ok: false,
          hasSpider: false,
          missing: <String>['Spider'],
          error: '缺少 Spider 类',
        ),
      );
      await expectLater(
        service.generateFromScrape(
          scrapeUrl: 'https://example.com/',
          html: '<html><body>plain</body></html>',
        ),
        throwsA(
          isA<OneKeyException>().having(
            (e) => e.message,
            'message',
            contains('缺少 Spider 类'),
          ),
        ),
      );
    });
  });

  group('占位符填充', () {
    test('全部占位符被替换且无残留', () async {
      final service = makeService();
      final result = await service.generateFromScrape(
        scrapeUrl: 'https://example.com/',
        html: '<html><body>plain</body></html>',
        pageTitle: '示例站',
      );
      expect(result.code, contains('SITE_NAME = "示例站"'));
      expect(result.code, contains('SITE = "https://example.com"'));
      expect(result.code, contains("BASES = ['https://example.com']"));
      expect(result.code, contains('MODE = "generic html sniffing"'));
      expect(result.code, isNot(contains('@NAME@')));
      expect(result.code, isNot(contains('@SITE@')));
      expect(result.code, isNot(contains('@BASES@')));
      expect(result.code, isNot(contains('@API@')));
      expect(result.code, isNot(contains('@FORCE@')));
      expect(result.code, isNot(contains('@IMGPROXY@')));
      expect(result.code, isNot(contains('@MODE@')));
      expect(result.code, isNot(contains('@TS@')));
    });
  });

  group('registerGenerated', () {
    Future<OneKeyCodeResult> gen(ScrapePyService service) =>
        service.generateFromScrape(
          scrapeUrl: 'https://example.com/',
          html: '<html><body>plain</body></html>',
          pageTitle: '示例站',
        );

    test('新站注册：走 addPyImport，fileBaseName 去 .py 后缀', () async {
      final registrar = FakeRegistrar();
      final service = makeService(registrar: registrar);
      final result = await service.registerGenerated(
        generated: await gen(service),
      );
      expect(result.updated, isFalse);
      expect(result.entryId, 'new-id');
      expect(result.entryName, '示例站');
      expect(registrar.addedFileBaseName, 'examplecom');
      expect(registrar.calls, <String>['find:示例站', 'add:示例站']);
    });

    test('同名站更新：走 updatePyImportContent，旧站不动 id', () async {
      final registrar = FakeRegistrar()
        ..existing = const ScrapePyEntryRef(id: 'old-id', name: '示例站');
      final service = makeService(registrar: registrar);
      final result = await service.registerGenerated(
        generated: await gen(service),
      );
      expect(result.updated, isTrue);
      expect(result.entryId, 'old-id');
      expect(registrar.updatedTemplateCode, 'generic_html');
      expect(registrar.calls, <String>['find:示例站', 'update:old-id']);
    });
  });
}
