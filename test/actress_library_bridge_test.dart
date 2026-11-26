// 合并演员库页宿主桥（ActressLibraryBridge）单元测试：分发、
// cache 往返、req 形态与 Cookie 罐、play/vodInline 归一、
// panPlay 嗅探、libraryQuery 透传。HTTP 与播放都注入假实现，
// 不走真网络、不推真页面。
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_library_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeHttp {
  final requests = <ActressLibHttpRequest>[];
  ActressLibHttpResult Function(ActressLibHttpRequest request)? responder;
  Object? failure;

  Future<ActressLibHttpResult> call(ActressLibHttpRequest request) async {
    requests.add(request);
    final failure = this.failure;
    if (failure != null) throw failure;
    final responder = this.responder;
    if (responder != null) return responder(request);
    return ActressLibHttpResult(
      status: 200,
      headers: const {},
      body: 'hello',
      finalUrl: request.url.toString(),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ActressLibraryBridge', () {
    test('cache set/get/remove 往返（带命名空间）', () async {
      final bridge = ActressLibraryBridge(playHandler: (_) async {});
      await bridge.dispatch('cache', {
        'op': 'set',
        'key': 'theme',
        'value': 'rose',
        'ns': 'combo',
      });
      expect(
        await bridge.dispatch('cache', {
          'op': 'get',
          'key': 'theme',
          'ns': 'combo',
        }),
        'rose',
      );
      // 命名空间隔离：另一个 ns 读不到。
      expect(
        await bridge.dispatch('cache', {
          'op': 'get',
          'key': 'theme',
          'ns': 'other',
        }),
        isNull,
      );
      await bridge.dispatch('cache', {
        'op': 'remove',
        'key': 'theme',
        'ns': 'combo',
      });
      expect(
        await bridge.dispatch('cache', {
          'op': 'get',
          'key': 'theme',
          'ns': 'combo',
        }),
        isNull,
      );
    });

    test('req：GET 透传状态与正文，方法归一小写', () async {
      final http = _FakeHttp();
      final bridge = ActressLibraryBridge(
        httpExecutor: http.call,
        playHandler: (_) async {},
      );
      final result =
          await bridge.dispatch('req', {
                'url': 'https://example.test/videos',
                'method': 'GET',
                'headers': {'User-Agent': 'UA'},
              })
              as Map<String, dynamic>;
      expect(result['ok'], isTrue);
      expect(result['status'], 200);
      expect(result['body'], 'hello');
      expect(http.requests.single.method, 'get');
      expect(http.requests.single.headers['User-Agent'], 'UA');
    });

    test('req：POST form 自动补 Content-Type 并带 body', () async {
      final http = _FakeHttp();
      final bridge = ActressLibraryBridge(
        httpExecutor: http.call,
        playHandler: (_) async {},
      );
      await bridge.dispatch('req', {
        'url': 'https://example.test/login',
        'method': 'post',
        'data': 'a=1&b=2',
        'postType': 'form',
      });
      final request = http.requests.single;
      expect(request.body, 'a=1&b=2');
      expect(
        request.headers['Content-Type'],
        contains('application/x-www-form-urlencoded'),
      );
    });

    test('req：网络失败回 {ok:false,status:0} 不抛', () async {
      final http = _FakeHttp()..failure = Exception('socket closed');
      final bridge = ActressLibraryBridge(
        httpExecutor: http.call,
        playHandler: (_) async {},
      );
      final result =
          await bridge.dispatch('req', {'url': 'https://example.test/'})
              as Map<String, dynamic>;
      expect(result['ok'], isFalse);
      expect(result['status'], 0);
      expect(result['error'], contains('socket closed'));
    });

    test('req：Cookie 罐回收 set-cookie 并在同 host 续发', () async {
      final http = _FakeHttp();
      var first = true;
      http.responder = (request) {
        if (first) {
          first = false;
          return ActressLibHttpResult(
            status: 200,
            headers: const {'set-cookie': 'session=abc123; Path=/'},
            body: '',
            finalUrl: request.url.toString(),
          );
        }
        return ActressLibHttpResult(
          status: 200,
          headers: const {},
          body: '',
          finalUrl: request.url.toString(),
        );
      };
      final bridge = ActressLibraryBridge(
        httpExecutor: http.call,
        playHandler: (_) async {},
      );
      await bridge.dispatch('req', {'url': 'https://example.test/a'});
      await bridge.dispatch('req', {'url': 'https://example.test/b'});
      expect(http.requests[1].headers['Cookie'], 'session=abc123');
    });

    test('play：归一成单集播放请求', () async {
      ActressLibPlayRequest? played;
      final bridge = ActressLibraryBridge(
        playHandler: (request) async => played = request,
      );
      await bridge.dispatch('play', {
        'url': 'https://v.hersav.me/h/h.m3u8',
        'title': '作品一',
        'pic': 'https://x.test/p.jpg',
        'headers': {'Referer': 'https://whos.tv/'},
      });
      expect(played, isNotNull);
      expect(played!.title, '作品一');
      expect(played!.episodes.single.url, 'https://v.hersav.me/h/h.m3u8');
      expect(played!.headers['Referer'], 'https://whos.tv/');
    });

    test('vodInline：集表归一；无可播集抛桥异常', () async {
      ActressLibPlayRequest? played;
      final bridge = ActressLibraryBridge(
        playHandler: (request) async => played = request,
      );
      await bridge.dispatch('vodInline', {
        'vod_id': 'whos_mvsd-546',
        'vod_name': 'MVSD-546',
        'vod_pic': 'https://x.test/p.jpg',
        'episodes': [
          {'name': '线路1', 'url': 'https://v.hersav.me/a/a.m3u8'},
          {'name': '坏集', 'url': ''},
        ],
      });
      expect(played!.episodes, hasLength(1));
      expect(played!.vodId, 'whos_mvsd-546');
      await expectLater(
        bridge.dispatch('vodInline', {'episodes': const []}),
        throwsA(isA<ActressLibBridgeException>()),
      );
    });

    test('panPlay：正文里提到流地址才播，提不到抛错让网页兜底', () async {
      final http = _FakeHttp();
      http.responder = (request) => ActressLibHttpResult(
        status: 200,
        headers: const {},
        body: '<html><script>var u="https://cdn.test/v/1.m3u8?tok=1";</script>',
        finalUrl: request.url.toString(),
      );
      ActressLibPlayRequest? played;
      final bridge = ActressLibraryBridge(
        httpExecutor: http.call,
        playHandler: (request) async => played = request,
      );
      await bridge.dispatch('panPlay', {
        'url': 'https://embed.test/watch/1',
        'title': '嗅探作品',
      });
      expect(played!.episodes.single.url, 'https://cdn.test/v/1.m3u8?tok=1');

      final http2 = _FakeHttp();
      http2.responder = (request) => ActressLibHttpResult(
        status: 200,
        headers: const {},
        body: '<html>no stream here</html>',
        finalUrl: request.url.toString(),
      );
      final bridge2 = ActressLibraryBridge(
        httpExecutor: http2.call,
        playHandler: (request) async => played = request,
      );
      await expectLater(
        bridge2.dispatch('panPlay', {'url': 'https://embed.test/watch/2'}),
        throwsA(isA<ActressLibBridgeException>()),
      );
    });

    test('libraryQuery：透传给库查询并原样回结果', () async {
      Map<String, dynamic>? seen;
      final bridge = ActressLibraryBridge(
        playHandler: (_) async {},
        libraryQuery: (params) async {
          seen = params;
          return {'ok': true, 'items': const []};
        },
      );
      final result =
          await bridge.dispatch('libraryQuery', {
                'op': 'list',
                'kind': 'latest',
              })
              as Map<String, dynamic>;
      expect(result['ok'], isTrue);
      expect(seen?['op'], 'list');
    });

    test('未知方法抛桥异常', () async {
      final bridge = ActressLibraryBridge(playHandler: (_) async {});
      await expectLater(
        bridge.dispatch('nope', {}),
        throwsA(isA<ActressLibBridgeException>()),
      );
    });
  });
}
