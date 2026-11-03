import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/tvbox_config.dart';

void main() {
  test('TVBox 配置解析：jar 站、接口站、py 站与跳过项', () {
    final parsed = parseTvboxConfig({
      'spider': 'https://example.com/spider.jar;0123456789abcdef0123456789abcdef',
      'sites': [
        {
          'key': 'siteA',
          'name': 'A站',
          'api': 'csp_AppYs',
          'ext': {'token': 'x'},
        },
        {'key': 'siteB', 'name': 'B站', 'api': 'csp_XBPQ'},
        {
          'key': 'siteC',
          'name': 'C站',
          'api': 'https://c.example.com/api.php/provide/vod/?ac=list',
        },
        {
          'key': 'siteD',
          'name': 'D站',
          'api': 'https://d.example.com/spider.py',
        },
        {'key': 'siteE', 'name': 'E站', 'api': 'csp_NoJar'},
        {'key': 'siteF', 'name': 'F站', 'api': ''},
      ],
    });
    expect(parsed.sites.length, 4);
    final jar = parsed.sites[0];
    expect(jar.kind, TvboxSiteKind.jar);
    expect(jar.className, 'com.github.catvod.spider.AppYs');
    expect(jar.jarUrl, 'https://example.com/spider.jar');
    expect(jar.md5, '0123456789abcdef0123456789abcdef');
    final api = parsed.sites[1];
    expect(api.kind, TvboxSiteKind.api);
    expect(api.apiUrl, 'https://c.example.com/');
    expect(parsed.sites[2].kind, TvboxSiteKind.py);
    expect(parsed.sites[3].kind, TvboxSiteKind.jar);
    expect(parsed.skipped.length, 2);
    expect(parsed.skipped.any((s) => s.contains('XBPQ')), isTrue);
    expect(parsed.skipped.any((s) => s.contains('F站')), isTrue);
    final noSpider = parseTvboxConfig({
      'sites': [
        {'key': 'only', 'name': '无 jar 站', 'api': 'csp_Orphan'},
      ],
    });
    expect(noSpider.sites, isEmpty);
    expect(noSpider.skipped.length, 1);
  });

  test('spider 引用解析与接口首页推导', () {
    expect(parseSpiderRef('https://x.com/a.jar;ABCDEF0123456789ABCDEF0123456789').url, 'https://x.com/a.jar');
    expect(parseSpiderRef('https://x.com/a.jar;ABCDEF0123456789ABCDEF0123456789').md5, 'abcdef0123456789abcdef0123456789');
    expect(homepageOfApi('https://x.com/'), 'https://x.com/');
    expect(homepageOfApi('https://x.com/api.php'), 'https://x.com/');
  });
}
