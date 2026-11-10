import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FontLoader, MethodCall, MethodChannel;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/services/shelf_store.dart';

import 'support/fakes.dart';
import 'support/series_detail_fixtures.dart';

/// 魔蚁主题影视区详情页预览图：测试渲染出 PNG，不构建整包。
///
/// 渲染手机版 SeriesDetailPage（影视区入口），数据全部注入；剧照与海报
/// 是 [HttpOverrides] 喂的同一张模拟剧照（`moyi_style_preview/` 下的
/// still_mock.png），不是真联网。背景必须是剧照原图整幅显示、不模糊，
/// 所以这里断言页里没有任何 [ImageFiltered]，再截图供手机上对照。
Future<void> _capture(
  WidgetTester tester,
  ValueKey<String> boundaryKey,
  String path,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(boundaryKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

/// 测试里 HttpClient 一律回 400（见 TestWidgetsFlutterBinding 的警告），
/// 所以用 [HttpOverrides] 把所有图片请求拦下来，直接回模拟剧照的字节。
class MockStillHttpOverrides extends HttpOverrides {
  final Uint8List bytes;
  MockStillHttpOverrides(this.bytes);

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      MockStillHttpClient(bytes);
}

class MockStillHttpClient implements HttpClient {
  final Uint8List _bytes;
  MockStillHttpClient(this._bytes);

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      MockStillHttpRequest(_bytes);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      MockStillHttpRequest(_bytes);

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      getUrl(Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      getUrl(Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      getUrl(Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      getUrl(Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      getUrl(Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      getUrl(Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) => getUrl(Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockStillHttpRequest implements HttpClientRequest {
  final Uint8List _bytes;
  MockStillHttpRequest(this._bytes);

  final _headers = MockStillHttpHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<HttpClientResponse> close() async => MockStillHttpResponse(_bytes);

  @override
  Future<HttpClientResponse> get done => close();

  @override
  String get method => 'GET';

  @override
  Uri get uri => Uri.parse('http://127.0.0.1/still.png');

  // HttpClientRequest 没有 requestedUri：这是造假类自带成员，不加 @override。
  Uri get requestedUri => uri;

  @override
  int get contentLength => 0;

  @override
  set contentLength(int value) {}

  @override
  List<Cookie> get cookies => const [];

  @override
  bool get followRedirects => true;

  @override
  set followRedirects(bool value) {}

  @override
  int get maxRedirects => 5;

  @override
  set maxRedirects(int value) {}

  @override
  bool get persistentConnection => false;

  @override
  set persistentConnection(bool value) {}

  @override
  Encoding get encoding => utf8;

  @override
  set encoding(Encoding value) {}

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}

  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  Future<void> flush() async {}

  @override
  void write(Object? object) {}

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {}

  @override
  void writeCharCode(int charCode) {}

  @override
  void writeln([Object? object = '']) {}

  @override
  HttpConnectionInfo? get connectionInfo => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockStillHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  final Uint8List _bytes;
  MockStillHttpResponse(this._bytes);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(_bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength => _bytes.length;

  @override
  HttpHeaders get headers {
    final result = MockStillHttpHeaders();
    result.contentType = ContentType('image', 'png');
    return result;
  }

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  List<Cookie> get cookies => const [];

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase => 'OK';

  @override
  X509Certificate? get certificate => null;

  @override
  HttpConnectionInfo? get connectionInfo => null;

  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) => throw UnsupportedError('redirect is not supported in this mock');

  @override
  Future<Socket> detachSocket() =>
      throw UnsupportedError('detachSocket is not supported in this mock');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockStillHttpHeaders implements HttpHeaders {
  final _values = <String, List<String>>{};

  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _values.putIfAbsent(name.toLowerCase(), () => []).add(value.toString());
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = [value.toString()];
  }

  @override
  String? value(String name) => _values[name.toLowerCase()]?.firstOrNull;

  @override
  void remove(String name, Object value) {
    _values[name.toLowerCase()]?.remove(value.toString());
  }

  @override
  void removeAll(String name) {
    _values.remove(name.toLowerCase());
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach(action);
  }

  @override
  void clear() => _values.clear();

  @override
  void noFolding(String name) {}

  ContentType? _contentType;

  @override
  ContentType? get contentType => _contentType;

  @override
  set contentType(ContentType? value) => _contentType = value;

  @override
  int get contentLength => -1;

  @override
  set contentLength(int value) {}

  @override
  DateTime? get date => null;

  @override
  set date(DateTime? value) {}

  @override
  DateTime? get expires => null;

  @override
  set expires(DateTime? value) {}

  @override
  String? get host => null;

  @override
  set host(String? value) {}

  @override
  DateTime? get ifModifiedSince => null;

  @override
  set ifModifiedSince(DateTime? value) {}

  // HttpClientRequest 没有 lastModified/transferEncoding：造假类自带成员。
  DateTime? get lastModified => null;

  set lastModified(DateTime? value) {}

  @override
  bool get persistentConnection => false;

  @override
  set persistentConnection(bool value) {}

  @override
  int? get port => null;

  @override
  set port(int? value) {}

  String? get transferEncoding => null;

  set transferEncoding(String? value) {}

  @override
  bool get chunkedTransferEncoding => false;

  @override
  set chunkedTransferEncoding(bool value) {}
}

void main() {
  late Directory directory;
  late Uint8List stillBytes;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'moyi-detail-preview-test-',
    );
    Hive.init(directory.path);
    await ShelfStore.instance.init();
    stillBytes = File(
      '../moyi_style_preview/still_mock.png',
    ).readAsBytesSync();
    HttpOverrides.global = MockStillHttpOverrides(stillBytes);
    // CachedNetworkImage 的缓存要写临时目录，测试里 path_provider 没有
    // 真实现，这里把 getTemporaryDirectory 指到本测试的临时目录。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall methodCall) async {
            if (methodCall.method == 'getTemporaryDirectory' ||
                methodCall.method == 'getApplicationSupportDirectory' ||
                methodCall.method == 'getApplicationDocumentsDirectory') {
              return directory.path;
            }
            return null;
          },
        );
  });
  tearDownAll(() async {
    HttpOverrides.global = null;
    await Hive.close();
    await directory.delete(recursive: true);
  });
  setUp(() async => ShelfStore.instance.clear());

  testWidgets('预览：影视区详情页（魔蚁主题）', (tester) async {
    // 见上：框架的 400-mock 在 setUp 后才生效，这里重设才盖得住。
    HttpOverrides.global = MockStillHttpOverrides(stillBytes);
    // 载入系统里的 Noto Sans CJK SC（简体中文），否则中文全是方框。
    // 与 detail_page_preview_test.dart 同款做法。
    final regularBytes = File(
      '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    ).readAsBytesSync();
    final boldBytes = File(
      '/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc',
    ).readAsBytesSync();
    final loader = FontLoader('NotoSansCJK')
      ..addFont(Future.value(ByteData.view(regularBytes.buffer)));
    await loader.load();
    final boldLoader = FontLoader('NotoSansCJK')
      ..addFont(Future.value(ByteData.view(boldBytes.buffer)));
    await boldLoader.load();
    // 图标字体：不载入则顶部返回/操作图标与「加入追剧」两侧图标变方框
    //（频道分类预览同款做法）。
    final iconBytes = File(
      '/home/hatch/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).readAsBytesSync();
    final iconLoader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.view(iconBytes.buffer)));
    await iconLoader.load();
    final lucideBytes = File(
      '/home/hatch/.pub-cache/hosted/pub.dev/flutter_lucide-1.59.0/lib/fonts/lucide.ttf',
    ).readAsBytesSync();
    final lucideLoader = FontLoader('packages/flutter_lucide/lucide')
      ..addFont(Future.value(ByteData.view(lucideBytes.buffer)));
    await lucideLoader.load();
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 1600);
    addTearDown(tester.view.reset);

    const base = 'https://example.com';
    final chapters = <Chapter>[for (var i = 0; i < 8; i++) chapterAt(i)];
    // 图片要走缓存文件 IO（真异步）+ 解码，假时钟 pump 转不动：
    // 整个挂载 + 等帧都放在 runAsync 里（上一轮已证实：挂住的不是
    // pump-in-runAsync，而是图标字体加载），让真实 IO 跑完；
    // 末尾再推 11 秒，把缓存管理器那个 10 秒清理定时器跑掉。
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: 'NotoSansCJK',
          ),
          home: RepaintBoundary(
            key: const ValueKey<String>('moyi-detail-preview'),
            child: SeriesDetailPage(
              seriesId: 'film-1',
              historyStore: MemoryReaderStore(),
              title: '抽象三国第一季',
              cover: '$base/cover.jpg',
              episodes: chapters,
              seriesLoader: (_) async => seriesDetailFixture(
                episodeCount: chapters.length,
                episodeLabel: '共${chapters.length}集',
              ),
              siteDetailLoader: (_) async => FilmSiteDetail(
                synopsis:
                    '东汉末年分三国，烽火连天不休。刘备、关羽、张飞桃园结义，'
                    '立志匡扶汉室；曹操挟天子以令诸侯，孙权坐断东南。'
                    '这是一段用搞笑口吻重讲的三国故事。',
                extra: const {
                  'play_from': '在线播放',
                  'actor': '张三，李四',
                  'year': '2026',
                  'area': '大陆',
                  'category': '历史，搞笑',
                },
                stills: ['$base/still1.jpg', '$base/still2.jpg'],
              ),
              commentLoader: (_) async => const PlayletCommentPage(),
            ),
          ),
        ),
      );
      try {
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 20),
        );
      } on TimeoutException {
        // 图片流未收敛不致命，继续截图；断言会校验关键元素在不在。
      }
    });
    await tester.pump(const Duration(seconds: 11));
    // 图片走缓存文件 IO + 解码是真异步：上面那次 pump 只推假时钟，
    // 缓存写盘与解码跑不完，海报与剧照会留在深紫占位上。runAsync 里
    // 等真时间、再各推一帧，让解码结果落到界面上再截图。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 3));
    });
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pump();

    // 标题 / 海报 / 集数 / 站源 / 追剧 / 选集 / 简介 / 剧照，一个不少。
    expect(find.text('抽象三国第一季'), findsWidgets);
    expect(find.byKey(const ValueKey('film-detail-poster')), findsOneWidget);
    expect(find.byKey(const ValueKey('film-detail-title')), findsOneWidget);
    expect(find.text('共 8 集 · 当前第 1 集'), findsOneWidget);
    expect(find.text('站源： 在线播放'), findsOneWidget);
    expect(find.byKey(const ValueKey('film-detail-follow')), findsOneWidget);
    expect(find.text('加入追剧'), findsOneWidget);
    expect(find.text('选集'), findsOneWidget);
    expect(find.text('简介'), findsOneWidget);
    expect(find.text('本片剧照'), findsOneWidget);
    // 背景是剧照原图（不是海报回落）：剧照地址进了背景图，且页里
    // 没有任何模糊组件。
    expect(
      find.byKey(const ValueKey('moyi-detail-background-image')),
      findsOneWidget,
    );
    expect(find.byType(ImageFiltered), findsNothing);

    await _capture(
      tester,
      const ValueKey<String>('moyi-detail-preview'),
      '../moyi_style_preview/detail.png',
    );
  });
}
