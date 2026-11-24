// 封面加载失败重试（2026-11-24 加载侧加固）。
//
// StoryCover 失败后按退避重试，最多 3 次尝试。测试用本地 HTTP 服务器
// 编排失败/成功剧本（404 / 真 PNG 字节），走真实的 CachedNetworkImage +
// PosterCache 链路，不 mock 图片组件本身。
//
// 注意：dart:io 的真实网络 IO 在 testWidgets 的 FakeAsync 区里等不到回包，
// 所以 pumpWidget 与等待都在 tester.runAsync 里做真时间轮询（见 AGENTS.md
// 2026-11-18 条）；重试间隔用 StoryCover.retryDelays 缩短到毫秒级，
// 产品默认值（2 秒、6 秒）不受影响。
import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/poster_cache.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';

late HttpServer _server;
late Uint8List _png;
late Directory _tempDir;

/// 每条 path 的剧本：按请求顺序消耗，true 回真 PNG，false 回 404；
/// 耗尽后重复最后一项。
final _scripts = <String, List<bool>>{};
final _counts = <String, int>{};

String _coverUrl(String path) =>
    'http://127.0.0.1:${_server.port}$path';

Future<void> _handle(HttpRequest request) async {
  final path = request.uri.path;
  _counts[path] = (_counts[path] ?? 0) + 1;
  final script = _scripts[path] ?? const [true];
  final outcome = script[(_counts[path]! - 1).clamp(0, script.length - 1)];
  if (outcome) {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType('image', 'png');
    request.response.contentLength = _png.length;
    request.response.add(_png);
  } else {
    request.response.statusCode = HttpStatus.notFound;
    request.response.contentLength = 0;
  }
  await request.response.close();
}

MediaItem _item(String path) => MediaItem(
      id: 'retry-test',
      title: '重试测试',
      cover: _coverUrl(path),
      author: '',
      badge: '',
      ep: '',
      kind: 'manju',
    );

Widget _cover(
  String path, {
  List<Duration> retryDelays = const [
    Duration(milliseconds: 100),
    Duration(milliseconds: 200),
  ],
}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 120,
            height: 168,
            child: StoryCover(
              item: _item(path),
              cacheWidth: 240,
              // 测试缩短等待：产品默认是 2 秒、6 秒。
              retryDelays: retryDelays,
            ),
          ),
        ),
      ),
    );

/// 真时间轮询直到条件成立：runAsync 里等真 IO 回包，块外 pump 刷帧。
/// pump 必须在 runAsync 外——runAsync 里调 tester.pump() 刷不动帧，
/// 图片字节到了也画不出来（见 AGENTS.md 2026-11-18 条）。
/// 上限约 30 秒真时间（60 轮 × 500 毫秒），超时即失败。
Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxRounds = 60,
}) async {
  for (var i = 0; i < maxRounds; i++) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(condition(), isTrue, reason: '条件在约 ${maxRounds ~/ 2} 秒内未达成');
}

/// 真 HTTP 连接回池后会挂一个 15 秒空闲定时器（dart:_http），留在
/// FakeAsync 区里会导致收尾断言“仍有待处理定时器”失败。
/// 注意这个定时器是 FakeTimer（假时钟区里建的），必须拨假时钟
/// 才能让它熄掉——真等 16 秒（runAsync）反而熄不掉它，收尾照样报错。
/// 所以这里用 pump(16 秒) 拨假时钟。
/// 另：拨掉它只解决收尾断言；“首次成功”在整文件跑时仍不出图，
/// 是另一个跨测试共享状态问题（前一个测试成功下载过后，下一个
/// 测试的 getFileStream 40 秒无事件；新 HttpClient 裸读同一地址
/// 38266 字节正常），见 REPORT.md，App 代码本身无问题。
Future<void> _drainIdleConnections(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 16));
}

/// 封面是否已显示：占位图标消失、Image 出现。
bool _coverShown() =>
    find.byType(Image).evaluate().isNotEmpty &&
    find.byIcon(LucideIcons.film).evaluate().isEmpty;

void main() {
  setUpAll(() async {
    _tempDir = await Directory.systemTemp.createTemp(
      'story-cover-retry-test-',
    );
    _png = File(
      'test/fixtures/moyi_style_preview/still_mock.png',
    ).readAsBytesSync();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
    // CachedNetworkImage 的缓存要写临时目录，测试里 path_provider 没有
    // 真实现，这里把 getTemporaryDirectory 指到本测试的临时目录。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall methodCall) async {
            if (methodCall.method == 'getTemporaryDirectory' ||
                methodCall.method == 'getApplicationSupportDirectory' ||
                methodCall.method == 'getApplicationDocumentsDirectory') {
              return _tempDir.path;
            }
            return null;
          },
        );
  });

  tearDownAll(() async {
    await _server.close(force: true);
    await _tempDir.delete(recursive: true);
  });

  late HttpOverrides? savedOverrides;

  setUp(() {
    _scripts.clear();
    _counts.clear();
    // 测试绑定默认拦掉一切 HTTP（回 400）；本地服务器要走真网，先摘掉。
    savedOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
  });

  tearDown(() {
    HttpOverrides.global = savedOverrides;
  });

  testWidgets('失败两次后第三次成功：共请求 3 次，封面显示', (tester) async {
    _scripts['/retry-then-ok.png'] = [false, false, true];
    await tester.runAsync(() async {
      await tester.pumpWidget(_cover('/retry-then-ok.png'));
    });
    await _waitUntil(tester, () => (_counts['/retry-then-ok.png'] ?? 0) >= 3);
    await _waitUntil(tester, _coverShown);
    expect(_counts['/retry-then-ok.png'], 3);
    expect(find.byIcon(LucideIcons.film), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    await _drainIdleConnections(tester);
  });

  testWidgets('一直失败：最多请求 3 次，不再重试', (tester) async {
    _scripts['/always-fail.png'] = [false];
    await tester.runAsync(() async {
      await tester.pumpWidget(_cover('/always-fail.png'));
    });
    await _waitUntil(tester, () => (_counts['/always-fail.png'] ?? 0) >= 3);
    // 再等 2 秒，确认没有第 4 次请求。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 2));
      await tester.pump();
    });
    expect(_counts['/always-fail.png'], 3);
    expect(find.byIcon(LucideIcons.film), findsOneWidget);
    // 注意：不能再断言 find.byType(Image) 为空——cached_network_image 4.x
    // 的 OctoImage 内部始终含一个 Image（占位也经它的 frameBuilder 画），
    // 占位是否在显示只看胶片图标即可。
    await _drainIdleConnections(tester);
  });

  testWidgets('首次成功：只请求 1 次', (tester) async {
    _scripts['/first-ok.png'] = [true];
    await tester.runAsync(() async {
      await tester.pumpWidget(_cover('/first-ok.png'));
    });
    await _waitUntil(tester, _coverShown);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
      await tester.pump();
    });
    expect(_counts['/first-ok.png'], 1);
    expect(find.byType(Image), findsOneWidget);
    await _drainIdleConnections(tester);
  });

  testWidgets('空封面地址：不发请求，只显示占位', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              height: 168,
              child: StoryCover(
                item: MediaItem(
                  id: 'empty',
                  title: '空封面',
                  cover: '',
                  author: '',
                  badge: '',
                  ep: '',
                  kind: 'manju',
                ),
                cacheWidth: 240,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_counts, isEmpty);
    expect(find.byIcon(LucideIcons.film), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('dispose 取消待重试：卸载后不再请求', (tester) async {
    _scripts['/disposed.png'] = [false];
    await tester.runAsync(() async {
      // 重试间隔 1 秒：轮询发现第 1 次失败后有足够窗口卸载，
      // 再等 2.5 秒（超过间隔）确认没有第 2 次请求。
      await tester.pumpWidget(
        _cover(
          '/disposed.png',
          retryDelays: const [Duration(seconds: 1), Duration(seconds: 1)],
        ),
      );
    });
    // 等到第 1 次失败、重试 Timer 已排上，再卸载。
    await _waitUntil(tester, () => (_counts['/disposed.png'] ?? 0) >= 1);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      await tester.pump();
    });
    expect(_counts['/disposed.png'], 1);
  });

  test('TimeoutFileService：30 秒无响应头即抛 TimeoutException', () {
    fakeAsync((async) {
      final service = TimeoutFileService(httpClient: _NeverHttpClient());
      Object? error;
      unawaited(
        service.get('https://example.com/cover.png').then(
          (_) {},
          onError: (Object e) {
            error = e;
          },
        ),
      );
      async.elapse(const Duration(seconds: 29));
      expect(error, isNull);
      async.elapse(const Duration(seconds: 2));
      expect(error, isA<TimeoutException>());
    });
  });
}

/// 发出请求后永远不回包的 http 客户端：模拟卡住的封面请求。
class _NeverHttpClient extends Fake implements http.Client {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}
