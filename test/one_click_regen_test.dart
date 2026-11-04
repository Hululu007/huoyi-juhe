import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/one_click_py.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _textResponse(String body, {int status = 200}) {
  return http.Response.bytes(utf8.encode(body), status);
}

class _FakeDownloadSink implements OneClickDownloadSink {
  String? savedFileName;
  String? savedText;

  @override
  Future<String> saveText({
    required String fileName,
    required String text,
  }) async {
    savedFileName = fileName;
    savedText = text;
    return '/Download/$fileName';
  }
}

class _MemoryHistoryStore extends OneClickHistoryStore {
  var entries = <OneClickHistoryEntry>[];

  @override
  Future<List<OneClickHistoryEntry>> load() async => entries;

  @override
  Future<void> add(OneClickHistoryEntry entry) async {
    entries = addHistoryEntry(entries, entry);
  }
}

class _UpdateCall {
  _UpdateCall({
    required this.id,
    required this.source,
    required this.downloadPath,
    required this.templateCode,
    required this.siteOrigin,
  });

  final String id;
  final String source;
  final String? downloadPath;
  final String? templateCode;
  final String? siteOrigin;
}

SourceEntry _oldEntry({Map<String, Object?> extra = const {}}) {
  return SourceEntry(
    id: 'import_1',
    name: '老站',
    kind: SourceKind.pyImport,
    address: 'oldkey.py',
    detail: 'Python 蜘蛛 · 已导入',
    extra: {
      'path': '/tmp/old.py',
      'contentType': 'video',
      ...extra,
    },
  );
}

MockClient _t1Client() {
  return MockClient((request) async {
    final url = request.url;
    if (url.host == 'cdn.example.com') {
      return _textResponse('#EXTM3U\n#EXT-X-VERSION:3\n');
    }
    if (url.path.contains('api.php')) {
      final query = url.queryParameters;
      if (query['ac'] == 'detail') {
        return _textResponse(
          '{"code":1,"list":[{"vod_id":1,"vod_name":"片甲",'
          '"vod_play_url":"https://cdn.example.com/a.m3u8"}]}',
        );
      }
      if (query.containsKey('wd')) {
        return _textResponse(
          '{"code":1,"list":[{"vod_id":1,"vod_name":"片甲",'
          '"vod_play_url":"https://cdn.example.com/a.m3u8"}]}',
        );
      }
      if (query['pg'] == '2') {
        return _textResponse('{"code":1,"list":[]}');
      }
      return _textResponse(
        '{"code":1,"list":[{"vod_id":1,"vod_name":"片甲",'
        '"vod_play_url":"https://cdn.example.com/a.m3u8"}]}',
      );
    }
    if (url.path == '/' || url.path.isEmpty) {
      return _textResponse('<html><body>欢迎</body></html>');
    }
    return _textResponse('not found', status: 404);
  });
}

MockClient _deadClient() {
  return MockClient((request) async {
    if (request.url.path.contains('api.php')) {
      return _textResponse('not found', status: 404);
    }
    return _textResponse('');
  });
}

void main() {
  group('RegenDeliveryCheck 步骤映射', () {
    test('在搜索失败时，前两项通过、后两项未通过', () {
      final check = RegenDeliveryCheck.failed('搜索');
      expect(check.passed, isFalse);
      expect(check.steps['分类首页'], isTrue);
      expect(check.steps['详情'], isTrue);
      expect(check.steps['搜索'], isFalse);
      expect(check.steps['取流'], isFalse);
    });
  });

  group('regenerateSiteDomain', () {
    test('默认自检走 T1 试套验证器：通过后就地更新，不新建站', () async {
      final sink = _FakeDownloadSink();
      final history = _MemoryHistoryStore();
      _UpdateCall? captured;
      final result = await regenerateSiteDomain(
        oldEntry: _oldEntry(
          extra: {'siteOrigin': 'https://old.example.com'},
        ),
        newDomain: 'https://new.example.com',
        client: _t1Client(),
        downloadSink: sink,
        historyStore: history,
        updateSite: ({
          required id,
          required source,
          String? downloadPath,
          String? templateCode,
          String? siteOrigin,
        }) async {
          captured = _UpdateCall(
            id: id,
            source: source,
            downloadPath: downloadPath,
            templateCode: templateCode,
            siteOrigin: siteOrigin,
          );
          return SourceEntry(
            id: id,
            name: '老站',
            kind: SourceKind.pyImport,
            address: 'oldkey.py',
            detail: 'Python 蜘蛛 · 已导入',
            extra: {'path': '/tmp/old.py', 'contentType': 'video'},
          );
        },
      );
      expect(result.entry.id, 'import_1');
      expect(result.displayName, '老站');
      expect(result.identification.template.code, 'T1');
      expect(result.check.passed, isTrue);
      expect(result.check.steps['取流'], isTrue);
      expect(captured, isNotNull);
      expect(captured!.id, 'import_1');
      expect(captured!.source, contains('https://new.example.com'));
      expect(captured!.source, isNot(contains('old.example.com')));
      expect(captured!.templateCode, 'T1');
      expect(captured!.siteOrigin, 'https://new.example.com');
      expect(sink.savedFileName, 'new.py');
      expect(history.entries.length, 1);
      expect(history.entries.first.url, 'https://new.example.com');
      expect(history.entries.first.templateCode, 'T1');
    });

    test('自检失败时旧站不动：不更新、不记历史', () async {
      final sink = _FakeDownloadSink();
      final history = _MemoryHistoryStore();
      var updated = false;
      await expectLater(
        regenerateSiteDomain(
          oldEntry: _oldEntry(),
          newDomain: 'https://new.example.com',
          client: _t1Client(),
          downloadSink: sink,
          historyStore: history,
          verifyRegenerated: (_, _) async =>
              RegenDeliveryCheck.failed('搜索'),
          updateSite: ({
            required id,
            required source,
            String? downloadPath,
            String? templateCode,
            String? siteOrigin,
          }) async {
            updated = true;
            throw StateError('不应走到更新');
          },
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('旧站未动'),
          ),
        ),
      );
      expect(updated, isFalse);
      expect(history.entries, isEmpty);
      expect(sink.savedText, isNull);
    });

    test('新域名试套不上时如实报错，不导入、不记历史', () async {
      final history = _MemoryHistoryStore();
      var updated = false;
      await expectLater(
        regenerateSiteDomain(
          oldEntry: _oldEntry(),
          newDomain: 'https://dead.example.com',
          client: _deadClient(),
          historyStore: history,
          updateSite: ({
            required id,
            required source,
            String? downloadPath,
            String? templateCode,
            String? siteOrigin,
          }) async {
            updated = true;
            throw StateError('不应走到更新');
          },
        ),
        throwsA(
          isA<OneClickUnsupported>().having(
            (error) => error.reason,
            'reason',
            contains('试套不上'),
          ),
        ),
      );
      expect(updated, isFalse);
      expect(history.entries, isEmpty);
    });

    test('旧站登记模板与新匹配不一致时只提示，不拦截', () async {
      final result = await regenerateSiteDomain(
        oldEntry: _oldEntry(extra: {'templateCode': 'T6'}),
        newDomain: 'https://new.example.com',
        client: _t1Client(),
        downloadSink: _FakeDownloadSink(),
        historyStore: _MemoryHistoryStore(),
        updateSite: ({
          required id,
          required source,
          String? downloadPath,
          String? templateCode,
          String? siteOrigin,
        }) async {
          return SourceEntry(
            id: id,
            name: '老站',
            kind: SourceKind.pyImport,
            address: 'oldkey.py',
            detail: 'Python 蜘蛛 · 已导入',
            extra: {'path': '/tmp/old.py', 'contentType': 'video'},
          );
        },
      );
      expect(result.templateChangedNote, contains('T6'));
      expect(result.templateChangedNote, contains('T1'));
    });

    test('非 py 站拒绝换域名重生成', () async {
      final jarEntry = SourceEntry(
        id: 'jar_1',
        name: 'jar 站',
        kind: SourceKind.jarImport,
        address: 'https://example.com/app.jar',
        detail: 'jar 站',
        extra: const {},
      );
      await expectLater(
        regenerateSiteDomain(
          oldEntry: jarEntry,
          newDomain: 'https://new.example.com',
          client: _t1Client(),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('只有 py 站'),
          ),
        ),
      );
    });
  });
}
