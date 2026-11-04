import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/one_click_py.dart';
import 'package:fqapp/services/platform_channel.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

OneClickIdentification _id(
  String code, {
  List<String> apiLinks = const [],
}) {
  return OneClickIdentification(
    template: oneClickTemplates[code]!,
    origin: 'https://example.com',
    siteKey: 'example',
    siteName: 'example',
    apiLinks: apiLinks,
  );
}

http.Response _textResponse(String body, {int status = 200}) {
  return http.Response.bytes(utf8.encode(body), status);
}

class _FakeDownloadSink implements OneClickDownloadSink {
  _FakeDownloadSink({this.shouldFail = false});

  final bool shouldFail;
  String? savedFileName;
  String? savedText;

  @override
  Future<String> saveText({
    required String fileName,
    required String text,
  }) async {
    if (shouldFail) {
      throw StateError('通道不可用');
    }
    savedFileName = fileName;
    savedText = text;
    return '/Download/$fileName';
  }
}

class _ImportCall {
  _ImportCall({
    required this.name,
    required this.source,
    required this.contentType,
    required this.fileBaseName,
    required this.oneClick,
    required this.downloadPath,
  });

  final String name;
  final String source;
  final ContentType contentType;
  final String fileBaseName;
  final bool oneClick;
  final String? downloadPath;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('网址归一化与 key 派生', () {
    test('无 scheme 时补 https', () {
      expect(normalizeSiteUrl('example.com'), 'https://example.com');
    });

    test('根路径尾斜杠去掉', () {
      expect(normalizeSiteUrl('https://example.com/'), 'https://example.com');
    });

    test('非法网址抛错', () {
      expect(() => normalizeSiteUrl(''), throwsStateError);
      expect(() => normalizeSiteUrl('ftp://example.com'), throwsStateError);
    });

    test('key 去 www 后首段清洗', () {
      expect(siteKeyFromHost('www.example-site.com'), 'example_site');
      expect(siteKeyFromHost('a.b.co'), 'a');
      expect(siteKeyFromHost('123.com'), '123');
    });

    test('站名取 host 首段', () {
      expect(displayNameFromHost('www.example.com'), 'example');
    });
  });

  group('URL 特征识别', () {
    test('T3 文章改写', () {
      expect(
        matchUrlPatterns('https://www.foo.com/arttype/12/').templateCode,
        'T3',
      );
      expect(
        matchUrlPatterns('https://www.foo.com/artdetail-abc/').templateCode,
        'T3',
      );
    });

    test('T4 文章改写变体', () {
      expect(
        matchUrlPatterns('https://x.com/cstype/5-2/').templateCode,
        'T4',
      );
    });

    test('T10 论坛与 T8 查询接口', () {
      expect(
        matchUrlPatterns(
          'https://x.com/forum.php?mod=forumdisplay&fid=2',
        ).templateCode,
        'T10',
      );
      expect(
        matchUrlPatterns('https://x.com/list.php?id=3&page=1').templateCode,
        'T8',
      );
    });

    test('T2 与 T1 与 T5 与 T14 与 T15', () {
      expect(
        matchUrlPatterns('https://x.com/type/id/12.html').templateCode,
        'T2',
      );
      expect(
        matchUrlPatterns(
          'https://x.com/api.php/provide/vod/?ac=list',
        ).templateCode,
        'T1',
      );
      expect(matchUrlPatterns('https://x.com/?s=abc').templateCode, 'T5');
      expect(
        matchUrlPatterns('https://x.com/novel/show/12').templateCode,
        'T14',
      );
      expect(
        matchUrlPatterns('https://x.com/_getcontent.php?id=1').templateCode,
        'T15',
      );
    });

    test('YouTube 与红果直判不支持', () {
      expect(
        matchUrlPatterns('https://www.youtube.com/watch?v=1').unsupportedKind,
        'youtube',
      );
      expect(
        matchUrlPatterns('https://youtu.be/abc').unsupportedKind,
        'youtube',
      );
      expect(
        matchUrlPatterns('https://hongguoduanju.com/xxx').unsupportedKind,
        'hongguo',
      );
    });
  });

  group('MockClient 识别', () {
    test('T1 探通', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('api.php')) {
          return _textResponse(
            '{"code":1,"page":1,"pagecount":1,"list":[{"vod_id":1,"vod_name":"a"}]}',
          );
        }
        return _textResponse('not found', status: 404);
      });
      final identification = await identifySite(
        'https://example.com',
        client: client,
      );
      expect(identification.template.code, 'T1');
    });

    test('首页信号命中 T3', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('api.php')) {
          return _textResponse('not found', status: 404);
        }
        return _textResponse(
          '<html><body><a href="/arttype/12/">分类</a>'
          '<a href="/artdetail-abc/">文章</a></body></html>',
        );
      });
      final identification = await identifySite(
        'https://example.com',
        client: client,
      );
      expect(identification.template.code, 'T3');
    });

    test('首页无信号时进试套模式而非直接判死', () async {
      final client = MockClient((_) async => _textResponse('<html></html>'));
      final identification = await identifySite(
        'https://example.com',
        client: client,
      );
      expect(identification.trialMode, isTrue);
      expect(identification.trialCandidates, oneClickTrialOrder);
    });

    test('壳特征判不支持', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('api.php')) {
          return _textResponse('not found', status: 404);
        }
        return _textResponse(
          '<html><script src="/obfuscate/js/t/abcdef"></script></html>',
        );
      });
      await expectLater(
        identifySite('https://example.com', client: client),
        throwsA(
          isA<OneClickUnsupported>().having(
            (error) => error.needsFullFlow,
            'needsFullFlow',
            isTrue,
          ),
        ),
      );
    });

    test('Next.js 特征判 T7 不在首版', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('api.php')) {
          return _textResponse('not found', status: 404);
        }
        return _textResponse(
          '<html><script>self.__next_f.push([1,"x"])</script></html>',
        );
      });
      await expectLater(
        identifySite('https://example.com', client: client),
        throwsA(isA<OneClickUnsupported>()),
      );
    });

    test('仅视频特征时 T6 试套并注明', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('api.php')) {
          return _textResponse('not found', status: 404);
        }
        return _textResponse(
          '<html><body><video src="https://x.com/a.m3u8"></video></body></html>',
        );
      });
      final identification = await identifySite(
        'https://example.com',
        client: client,
      );
      expect(identification.template.code, 'T6');
      expect(identification.fallbackNote, isNotNull);
    });

    test('历史同 host 复用模板且不发请求', () async {
      final client = MockClient((_) async {
        throw StateError('should not be called');
      });
      final history = [
        OneClickHistoryEntry(
          name: 'example',
          url: 'https://example.com',
          templateCode: 'T5',
          updatedAt: 1,
        ),
      ];
      final identification = await identifySite(
        'https://example.com/any',
        client: client,
        history: history,
      );
      expect(identification.template.code, 'T5');
    });

    test('T9 未探到接口路径时不生成', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('api.php')) {
          return _textResponse('not found', status: 404);
        }
        return _textResponse('<html><body><a href="/api/">接口</a></body></html>');
      });
      final identification = await identifySite(
        'https://example.com',
        client: client,
      );
      expect(identification.template.code, 'T9');
      expect(identification.apiLinks, isNotEmpty);
    });
  });

  group('试套用', () {
    const detailHtml =
        '<html><head><title>文章甲标题</title></head><body>'
        '<h1>文章甲标题</h1>'
        '<p>这是一段超过十个字的正文内容，用来通过试套自检。</p>'
        '<p>第二段正文内容同样超过十个字，可以继续凑字数。</p>'
        '</body></html>';

    MockClient trialClient({
      required String sectionHtml,
      required Map<String, String> pages,
    }) {
      return MockClient((request) async {
        final url = request.url;
        if (url.path.contains('api.php')) {
          return _textResponse('not found', status: 404);
        }
        if (url.path == '/section') {
          return _textResponse(sectionHtml);
        }
        final body = pages[url.path];
        if (body != null) {
          return _textResponse(body);
        }
        if ((url.path == '/' || url.path.isEmpty) &&
            url.queryParameters.containsKey('s')) {
          final searchBody = pages['/?s='];
          if (searchBody != null) {
            return _textResponse(searchBody);
          }
          return _textResponse('not found', status: 404);
        }
        if (url.path == '/' || url.path.isEmpty) {
          return _textResponse('<html><body>欢迎</body></html>');
        }
        return _textResponse('not found', status: 404);
      });
    }

    test('T5 试套成功且导入用胜出模板', () async {
      final client = trialClient(
        sectionHtml:
            '<html><body><a href="/post/a">文章甲</a>'
            '<a href="/post/b">文章乙</a></body></html>',
        pages: {
          '/post/a': detailHtml,
          '/?s=':
              '<html><body><a href="/post/a">文章甲</a></body></html>',
        },
      );
      _ImportCall? captured;
      final sink = _FakeDownloadSink();
      final result = await generateAndImport(
        url: 'https://example.com/section',
        client: client,
        downloadSink: sink,
        importSite: ({
          required name,
          required source,
          required contentType,
          required fileBaseName,
          required oneClick,
          required String? downloadPath,
        }) async {
          captured = _ImportCall(
            name: name,
            source: source,
            contentType: contentType,
            fileBaseName: fileBaseName,
            oneClick: oneClick,
            downloadPath: downloadPath,
          );
          return SourceEntry(
            id: 'trial_2',
            name: name,
            kind: SourceKind.pyImport,
            detail: 'Python 蜘蛛 · 已导入',
          );
        },
      );
      expect(captured, isNotNull);
      expect(captured!.source, contains('TMPL = "T5"'));
      expect(result.identification.template.code, 'T5');
      expect(result.identification.fallbackNote, contains('试套用'));
      expect(result.identification.fallbackNote, contains('搜索通过'));
      final saved = await OneClickHistoryStore().load();
      expect(saved.first.templateCode, 'T5');
    });

    test('T3 试套成功：输入栏目页有文章改写分类', () async {
      final client = trialClient(
        sectionHtml:
            '<html><body><a href="/arttype/12/">分类甲</a>'
            '<a href="/arttype/13/">分类乙</a></body></html>',
        pages: {
          '/arttype/12/':
              '<html><body><a href="/artdetail-abc/">文章甲</a>'
              '<a href="/artdetail-def/">文章乙</a></body></html>',
          '/artdetail-abc/': detailHtml,
          '/artsearch/-------/':
              '<html><body><a href="/artdetail-abc/">文章甲</a></body></html>',
        },
      );
      _ImportCall? captured;
      final result = await generateAndImport(
        url: 'https://example.com/section',
        client: client,
        downloadSink: _FakeDownloadSink(),
        importSite: ({
          required name,
          required source,
          required contentType,
          required fileBaseName,
          required oneClick,
          required String? downloadPath,
        }) async {
          captured = _ImportCall(
            name: name,
            source: source,
            contentType: contentType,
            fileBaseName: fileBaseName,
            oneClick: oneClick,
            downloadPath: downloadPath,
          );
          return SourceEntry(
            id: 'trial_3',
            name: name,
            kind: SourceKind.pyImport,
            detail: 'Python 蜘蛛 · 已导入',
          );
        },
      );
      expect(captured!.source, contains('TMPL = "T3"'));
      expect(result.identification.template.code, 'T3');
    });

    test('T6 试套成功：输入栏目页带可播地址', () async {
      final client = trialClient(
        sectionHtml:
            '<html><head><title>视频站标题</title></head><body>'
            '<video src="http://cdn.example.com/a.m3u8"></video>'
            '<a href="/v/1">视频一</a></body></html>',
        pages: {
          '/?s=':
              '<html><body><a href="/v/1">视频一</a></body></html>',
          '/a.m3u8': '#EXTM3U\n#EXTINF:10,\nseg.ts\n',
        },
      );
      _ImportCall? captured;
      final result = await generateAndImport(
        url: 'https://example.com/section',
        client: client,
        downloadSink: _FakeDownloadSink(),
        importSite: ({
          required name,
          required source,
          required contentType,
          required fileBaseName,
          required oneClick,
          required String? downloadPath,
        }) async {
          captured = _ImportCall(
            name: name,
            source: source,
            contentType: contentType,
            fileBaseName: fileBaseName,
            oneClick: oneClick,
            downloadPath: downloadPath,
          );
          return SourceEntry(
            id: 'trial_6',
            name: name,
            kind: SourceKind.pyImport,
            detail: 'Python 蜘蛛 · 已导入',
          );
        },
      );
      expect(captured!.source, contains('TMPL = "T6"'));
      expect(result.identification.template.code, 'T6');
    });

    test('T9 试套成功：输入地址本身就是接口地址', () async {
      final client = MockClient((request) async {
        final url = request.url;
        if (url.path.contains('api.php')) {
          return _textResponse('not found', status: 404);
        }
        if (url.path == '/api/media') {
          if (url.queryParameters.containsKey('id')) {
            return _textResponse(
              '{"vod_id":1,"vod_name":"剧目甲","play_url":"http://cdn.example.com/a.m3u8"}',
            );
          }
          return _textResponse(
            '{"list":[{"vod_id":1,"vod_name":"剧目甲","vod_pic":"http://x/y.jpg"}]}',
          );
        }
        if (url.path == '/a.m3u8') {
          return _textResponse('#EXTM3U\n#EXTINF:10,\nseg.ts\n');
        }
        if (url.path == '/') {
          return _textResponse('<html><body>欢迎</body></html>');
        }
        return _textResponse('not found', status: 404);
      });
      _ImportCall? captured;
      final result = await generateAndImport(
        url: 'https://example.com/api/media',
        client: client,
        downloadSink: _FakeDownloadSink(),
        importSite: ({
          required name,
          required source,
          required contentType,
          required fileBaseName,
          required oneClick,
          required String? downloadPath,
        }) async {
          captured = _ImportCall(
            name: name,
            source: source,
            contentType: contentType,
            fileBaseName: fileBaseName,
            oneClick: oneClick,
            downloadPath: downloadPath,
          );
          return SourceEntry(
            id: 'trial_4',
            name: name,
            kind: SourceKind.pyImport,
            detail: 'Python 蜘蛛 · 已导入',
          );
        },
      );
      expect(captured!.source, contains('TMPL = "T9"'));
      expect(captured!.source, contains('https://example.com/api/media'));
      expect(result.identification.template.code, 'T9');
    });

    test('试套全败时报套不上且不导入不记历史', () async {
      var imported = false;
      final client = MockClient(
        (_) async => _textResponse('<html></html>'),
      );
      await expectLater(
        generateAndImport(
          url: 'https://example.com',
          client: client,
          downloadSink: _FakeDownloadSink(),
          importSite: ({
            required name,
            required source,
            required contentType,
            required fileBaseName,
            required oneClick,
            required String? downloadPath,
          }) async {
            imported = true;
            return SourceEntry(
              id: 'trial_5',
              name: name,
              kind: SourceKind.pyImport,
              detail: 'Python 蜘蛛 · 已导入',
            );
          },
        ),
        throwsA(
          isA<OneClickUnsupported>().having(
            (error) => error.message,
            'message',
            contains('试套不上'),
          ),
        ),
      );
      expect(imported, isFalse);
      expect(await OneClickHistoryStore().load(), isEmpty);
    });
  });

  group('历史记录', () {
    test('关键字按名称与网址过滤', () {
      final entries = [
        OneClickHistoryEntry(
          name: 'alpha',
          url: 'https://alpha.com',
          templateCode: 'T1',
          updatedAt: 1,
        ),
        OneClickHistoryEntry(
          name: 'beta',
          url: 'https://beta.com',
          templateCode: 'T3',
          updatedAt: 2,
        ),
      ];
      expect(filterHistory(entries, 'alp').length, 1);
      expect(filterHistory(entries, 'BETA.COM').length, 1);
      expect(filterHistory(entries, '').length, 2);
    });

    test('JSON 往返', () {
      final entry = OneClickHistoryEntry(
        name: 'alpha',
        url: 'https://alpha.com',
        templateCode: 'T1',
        apiLinks: ['https://alpha.com/api/media'],
        updatedAt: 42,
      );
      final restored = OneClickHistoryEntry.fromJson(entry.toJson());
      expect(restored?.name, 'alpha');
      expect(restored?.apiLinks, ['https://alpha.com/api/media']);
      expect(restored?.updatedAt, 42);
    });

    test('按网址去重、最近在前、上限 50', () {
      var entries = <OneClickHistoryEntry>[];
      for (var i = 0; i < 55; i++) {
        entries = addHistoryEntry(
          entries,
          OneClickHistoryEntry(
            name: 'site$i',
            url: 'https://site$i.com',
            templateCode: 'T1',
            updatedAt: i,
          ),
        );
      }
      expect(entries.length, 50);
      expect(entries.first.name, 'site54');
      entries = addHistoryEntry(
        entries,
        OneClickHistoryEntry(
          name: 'site54-new',
          url: 'https://site54.com/',
          templateCode: 'T3',
          updatedAt: 99,
        ),
      );
      expect(entries.length, 50);
      expect(entries.first.name, 'site54-new');
    });
  });

  group('结构自检', () {
    test('缺方法与中文注释与 RE 块都拦住', () {
      expect(OneClickStructureCheck.check('print(1)'), isNotNull);
      final withComment = [
        'class Spider:',
        for (final method in OneClickStructureCheck.requiredMethods)
          '    def $method(self): pass',
        '# 这是中文注释',
      ].join('\n');
      expect(OneClickStructureCheck.check(withComment), contains('中文注释'));
      final withRe = [
        'class Spider:',
        for (final method in OneClickStructureCheck.requiredMethods)
          '    def $method(self): pass',
        '# RE_TARGET: x',
      ].join('\n');
      expect(OneClickStructureCheck.check(withRe), contains('RE'));
    });
  });

  group('生成结构检查', () {
    final cases = <String, Map<String, Object>>{
      'T1': {'feature': 'api.php/provide/vod', 'ctype': 'video'},
      'T2': {'feature': '/type/id/', 'ctype': 'video'},
      'T3': {'feature': 'arttype', 'ctype': 'novel', 'novel': true},
      'T4': {'feature': 'cstype', 'ctype': 'comic', 'comic': true},
      'T5': {'feature': '/?s=', 'ctype': 'novel', 'novel': true},
      'T6': {'feature': 'm3u8', 'ctype': 'video'},
      'T8': {'feature': 'list.php', 'ctype': 'video'},
      'T9': {
        'feature': 'https://example.com/api/media',
        'ctype': 'video',
        'api': true,
      },
      'T10': {'feature': 'forum.php', 'ctype': 'video'},
      'T12': {'feature': 'album', 'ctype': 'comic', 'comic': true},
      'T13': {
        'feature': 'https://example.com/api/comic',
        'ctype': 'comic',
        'comic': true,
        'api': true,
      },
      'T14': {'feature': '/discovery', 'ctype': 'novel', 'novel': true},
      'T15': {'feature': '_getcontent.php', 'ctype': 'novel', 'novel': true},
      'T16': {'feature': 'listening', 'ctype': 'audio', 'api': true},
    };
    for (final entry in cases.entries) {
      test('${entry.key} 结构齐全', () {
        final apiLinks = <String>[];
        if (entry.value['api'] == true) {
          apiLinks.add(entry.value['feature'] as String);
        }
        final py = buildOneClickPy(
          _id(entry.key, apiLinks: apiLinks),
          siteName: 'example',
        );
        expect(OneClickStructureCheck.check(py), isNull);
        expect(py, contains('"parse": 0'));
        expect(py, contains('"header"'));
        expect(py.contains("'parse': 1"), isFalse);
        expect(py, contains('TMPL = "${entry.key}"'));
        expect(py, contains('CTYPE = "${entry.value['ctype']}"'));
        expect(py, contains(entry.value['feature'] as String));
        if (entry.value['novel'] == true) {
          expect(py, contains('novel://'));
        }
        if (entry.value['comic'] == true) {
          expect(py, contains('pics://'));
        }
      });
    }

    test('T5 可改漫画', () {
      final py = buildOneClickPy(
        _id('T5'),
        siteName: 'example',
        contentOverride: OneClickContent.comic,
      );
      expect(py, contains('CTYPE = "comic"'));
      expect(py, contains('pics://'));
    });
  });

  group('generateAndImport 全流程', () {
    MockClient t1Client() {
      return MockClient((request) async {
        if (request.url.path.contains('api.php')) {
          return _textResponse(
            '{"code":1,"list":[{"vod_id":1,"vod_name":"a"}]}',
          );
        }
        return _textResponse('not found', status: 404);
      });
    }

    test('成功路径：登记参数与历史落盘', () async {
      final sink = _FakeDownloadSink();
      _ImportCall? captured;
      final store = OneClickHistoryStore();
      final result = await generateAndImport(
        url: 'https://example.com',
        client: t1Client(),
        downloadSink: sink,
        importSite: ({
          required name,
          required source,
          required contentType,
          required fileBaseName,
          required oneClick,
          required String? downloadPath,
        }) async {
          captured = _ImportCall(
            name: name,
            source: source,
            contentType: contentType,
            fileBaseName: fileBaseName,
            oneClick: oneClick,
            downloadPath: downloadPath,
          );
          return SourceEntry(
            id: 'import_1',
            name: name,
            kind: SourceKind.pyImport,
            detail: 'Python 蜘蛛 · 已导入',
          );
        },
        historyStore: store,
      );
      expect(captured, isNotNull);
      expect(captured!.name, 'example');
      expect(captured!.fileBaseName, 'example');
      expect(captured!.oneClick, isTrue);
      expect(captured!.contentType, ContentType.video);
      expect(captured!.downloadPath, '/Download/example.py');
      expect(sink.savedFileName, 'example.py');
      expect(OneClickStructureCheck.check(captured!.source), isNull);
      expect(result.downloadPath, '/Download/example.py');
      final saved = await store.load();
      expect(saved.length, 1);
      expect(saved.first.templateCode, 'T1');
    });

    test('成人站显示名加前缀', () async {
      String? capturedName;
      await generateAndImport(
        url: 'https://example.com',
        adult: true,
        client: t1Client(),
        downloadSink: _FakeDownloadSink(),
        importSite: ({
          required name,
          required source,
          required contentType,
          required fileBaseName,
          required oneClick,
          required String? downloadPath,
        }) async {
          capturedName = name;
          return SourceEntry(
            id: 'import_2',
            name: name,
            kind: SourceKind.pyImport,
            detail: 'Python 蜘蛛 · 已导入',
          );
        },
      );
      expect(capturedName, '🔞example');
    });

    test('校验失败撤登记并抛错', () async {
      String? removedId;
      await expectLater(
        generateAndImport(
          url: 'https://example.com',
          client: t1Client(),
          downloadSink: _FakeDownloadSink(),
          importSite: ({
            required name,
            required source,
            required contentType,
            required fileBaseName,
            required oneClick,
            required String? downloadPath,
          }) async {
            return SourceEntry(
              id: 'import_3',
              name: name,
              kind: SourceKind.pyImport,
              detail: 'Python 蜘蛛 · 校验未通过：缺少核心方法',
            );
          },
          removeSite: (id) async {
            removedId = id;
          },
        ),
        throwsStateError,
      );
      expect(removedId, 'import_3');
      final saved = await OneClickHistoryStore().load();
      expect(saved, isEmpty);
    });

    test('下载失败则不导入、不记历史', () async {
      var imported = false;
      await expectLater(
        generateAndImport(
          url: 'https://example.com',
          client: t1Client(),
          downloadSink: _FakeDownloadSink(shouldFail: true),
          importSite: ({
            required name,
            required source,
            required contentType,
            required fileBaseName,
            required oneClick,
            required String? downloadPath,
          }) async {
            imported = true;
            return SourceEntry(
              id: 'import_4',
              name: name,
              kind: SourceKind.pyImport,
              detail: 'Python 蜘蛛 · 已导入',
            );
          },
        ),
        throwsStateError,
      );
      expect(imported, isFalse);
      final saved = await OneClickHistoryStore().load();
      expect(saved, isEmpty);
    });
  });

  group('平台下载通道', () {
    tearDown(() {
      PlatformChannels.invoke = null;
    });

    test('非公开目录回退时抛错，不当成下载成功', () async {
      PlatformChannels.invoke = (channel, method, args) async {
        if (channel == 'fqapp/downloads' && method == 'saveText') {
          return {
            'path': '/data/data/com.example/files/Download/example.py',
            'public': false,
          };
        }
        return null;
      };
      await expectLater(
        const PlatformOneClickDownloadSink()
            .saveText(fileName: 'example.py', text: 'x'),
        throwsStateError,
      );
    });

    test('公开下载目录时返回系统下载路径', () async {
      PlatformChannels.invoke = (channel, method, args) async {
        if (channel == 'fqapp/downloads' && method == 'saveText') {
          return {
            'path': '/storage/emulated/0/Download/example.py',
            'public': true,
          };
        }
        return null;
      };
      expect(
        await const PlatformOneClickDownloadSink()
            .saveText(fileName: 'example.py', text: 'x'),
        '/storage/emulated/0/Download/example.py',
      );
    });
  });
}
