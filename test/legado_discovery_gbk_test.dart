import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/site_browse_page.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/gbk_codec.dart';
import 'package:fqapp/services/legado_content.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<int> _gbk(String asciiHead, List<int> body) =>
    [...ascii.encode(asciiHead), ...body];

void main() {
  group('GBK 解码', () {
    test('content-type 声明 GBK 时走 GBK', () {
      expect(
        decodeHttpBody(
          const [0xD6, 0xD0, 0xCE, 0xC4],
          contentType: 'text/html; charset=gbk',
        ),
        '中文',
      );
      expect(
        decodeHttpBody(
          const [0xD6, 0xD0, 0xCE, 0xC4],
          contentType: 'text/html; charset=gb2312',
        ),
        '中文',
      );
      expect(
        decodeHttpBody(
          const [0xB2, 0xE2, 0xCA, 0xD4],
          contentType: 'text/html; charset=gbk',
        ),
        '测试',
      );
    });

    test('meta 声明 GBK 且无 content-type 时走 GBK', () {
      final body = _gbk('<meta charset="gbk">', const [
        0xD6, 0xD0, 0xCE, 0xC4,
      ]);
      final decoded = decodeHttpBody(body);
      expect(decoded.startsWith('<meta charset="gbk">'), isTrue);
      expect(decoded.contains('中文'), isTrue);
    });

    test('meta 声明 GBK 但字节可通过 UTF-8 解码时仍走 GBK，不乱码', () {
      // D0 A1 在 GBK 里是“小”，按 UTF-8 解是 U+0421：旧顺序（先试 UTF-8）
      // 会静默出 U+0421，新顺序先嗅探 meta，必须出“小”。
      expect(utf8.decode(const [0xD0, 0xA1]), '\u0421');
      expect(gbkDecode(const [0xD0, 0xA1]), '小');
      final body = _gbk('<meta charset="gbk">', const [0xD0, 0xA1]);
      expect(decodeHttpBody(body), '<meta charset="gbk">小');
    });

    test('纯 UTF-8 不变', () {
      expect(decodeHttpBody(utf8.encode('中文测试')), '中文测试');
      expect(decodeHttpBody(utf8.encode('第一章 天亮了。')), '第一章 天亮了。');
    });
  });

  group('挑战页判定', () {
    test('各强标记命中', () {
      const hits = [
        '<script src="https://challenges.cloudflare.com/turnstile/v0/api.js">',
        '<div id="cf-challenge"></div>',
        'jschl_vc=abc123&pass=1',
        'turnstile.render("#box")',
        '<title>Attention Required! | Cloudflare</title>',
        '<title>Just a moment...</title>',
        '请完成安全验证后继续访问',
        '正在进行人机验证',
        '请验证您是人类',
        'set-cookie: cf_clearance=token123',
        'DDoS-Guard',
      ];
      for (final snippet in hits) {
        expect(isChallengePage(snippet), isTrue, reason: snippet);
      }
    });

    test('大小写不敏感', () {
      expect(isChallengePage('<title>JUST A MOMENT...</title>'), isTrue);
      expect(isChallengePage('CF-CHALLENGE'), isTrue);
      expect(isChallengePage('ATTENTION REQUIRED'), isTrue);
    });

    test('正常小说正文与普通页不误杀', () {
      expect(isChallengePage('他验证了自己的身份，继续往前走。'), isFalse);
      expect(isChallengePage('第三章 验证通过后，他推开了门。'), isFalse);
      expect(
        isChallengePage(
          '<html><head><title>小说站</title></head>'
          '<body><h1>第一章</h1><p>天亮了。</p></body></html>',
        ),
        isFalse,
      );
    });
  });

  group('浏览页分类回退', () {
    test('无分类只显示全部', () {
      expect(browseCategories(const []), [
        const DramaSiteCategory('all', '全部'),
      ]);
    });

    test('有分类原样返回', () {
      const cats = [
        DramaSiteCategory('a', '玄幻'),
        DramaSiteCategory('b', '都市'),
      ];
      expect(browseCategories(cats), cats);
    });
  });

  group('浏览页', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    Future<void> pumpPage(
      WidgetTester tester,
      DramaSiteContentClient client,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SiteBrowsePage(
            siteId: 'browse-test-site',
            siteName: '测试站',
            client: client,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('无分类时显示全部', (tester) async {
      await pumpPage(tester, _FakeBrowseClient(categoriesResult: const []));
      expect(find.text('全部'), findsOneWidget);
    });

    testWidgets('取分类失败时错误可见且仍显示全部', (tester) async {
      await pumpPage(
        tester,
        _FakeBrowseClient(categoriesError: StateError('该书源未给发现列表规则')),
      );
      expect(find.textContaining('取分类失败'), findsOneWidget);
      expect(find.text('全部'), findsOneWidget);
    });
  });
}

class _FakeBrowseClient extends DramaSiteContentClient {
  _FakeBrowseClient({this.categoriesResult, this.categoriesError});

  final List<DramaSiteCategory>? categoriesResult;
  final Object? categoriesError;

  @override
  Future<List<DramaSiteCategory>> categories() async {
    if (categoriesError != null) throw categoriesError!;
    return categoriesResult ?? const [];
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async =>
      const DramaSiteCatalogPage(items: [], hasMore: false);

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    throw UnimplementedError();
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    throw UnimplementedError();
  }
}
