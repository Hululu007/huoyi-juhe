import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';

class FixtureRepository extends AppRepository {
  int detailCalls = 0;
  bool fail = false;
  final requests = <String>[];
  final pages = <int>[];
  final forced = <bool>[];
  final cachedPages = <String, CatalogPage>{};
  static const free = Drama(
    id: 'hongguo:100',
    source: 'hongguo',
    title: '测试短剧',
    episodes: 2,
    category: '合成数据',
  );
  static const vip = Drama(
    id: 'huangdou:200',
    source: 'huangdou',
    title: '会员测试剧',
    episodes: 4,
    vip: true,
  );
  // 适配层 AppRepository 没有 initialize / cached / fallback /
  // cancelPlayback / release（魔蚁 Go 核专属方法），移植时去掉。
  // categories 是适配层抽象方法，合成仓储回空表。
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [];
  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    final items = <Drama>[];
    for (final source in sources) {
      final page = await catalog(source, query: query);
      for (final drama in page.items) {
        if (drama.source != source) continue;
        items.add(drama);
      }
    }
    return CatalogPage(items);
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async =>
      throw AppFailure('合成剧集没有远程海报');
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    requests.add(source);
    pages.add(page);
    forced.add(force);
    if (fail) {
      throw AppFailure('合成网络错误');
    }
    return CatalogPage(
      [
        free,
        vip,
        Drama(
          id: '$source:auto-$page',
          source: source,
          title: '第$page页短剧',
          episodes: 1,
          category: '合成数据',
        ),
      ],
      page: page,
      hasMore: page < 5,
    );
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    detailCalls++;
    return DramaDetail(drama, [
      Episode({'id': '1', 'title': '第1集', 'currentEpisode': 1}, 1),
      Episode({'id': '2', 'title': '第2集', 'currentEpisode': 2}, 2),
    ]);
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    bool adBlock = true,
    int quality = 0,
    int route = 0,
  }) async => const PlaybackPlan(url: 'https://example.test/synthetic.mp4');
}

/// 生成一张纯色假漫画页 PNG（测试/预览用，绝不联网）。
Future<Uint8List> fakeComicPagePng(
  Color color, {
  int width = 390,
  int height = 520,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), 56),
    Paint()..color = Colors.black26,
  );
  canvas.drawRect(
    Rect.fromLTWH(24, 96, width - 48.0, height - 192.0),
    Paint()..color = Colors.white24,
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

class _FakeHttpHeaders implements HttpHeaders {
  final _values = <String, List<String>>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = [value.toString()];
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _values.putIfAbsent(name.toLowerCase(), () => []).add(value.toString());
  }

  @override
  void remove(String name, Object value) {
    _values[name.toLowerCase()]?.remove(value.toString());
  }

  @override
  String? value(String name) => _values[name.toLowerCase()]?.join(',');
  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach(action);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpResponse(this._bytes);
  final Uint8List _bytes;
  @override
  int get statusCode => HttpStatus.ok;
  @override
  int get contentLength => _bytes.length;
  @override
  bool get isRedirect => false;
  @override
  List<RedirectInfo> get redirects => const [];
  @override
  bool get persistentConnection => false;
  @override
  String get reasonPhrase => 'OK';
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  HttpHeaders get headers => _FakeHttpHeaders();
  @override
  List<Cookie> get cookies => const [];
  @override
  X509Certificate? get certificate => null;
  @override
  HttpConnectionInfo? get connectionInfo => null;
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpRequest implements HttpClientRequest {
  _FakeHttpRequest(this._bytes);
  final Uint8List _bytes;
  @override
  final HttpHeaders headers = _FakeHttpHeaders();
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  bool persistentConnection = true;
  @override
  int contentLength = -1;
  @override
  bool bufferOutput = true;
  @override
  String method = 'GET';
  @override
  Uri uri = Uri.parse('https://example.test/');
  @override
  Future<HttpClientResponse> close() async => _FakeHttpResponse(_bytes);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._images);
  final Map<String, Uint8List> _images;
  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  String? userAgent;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _FakeHttpRequest(_images[url.toString()] ?? _images.values.first);
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 拦截 Image.network：按 URL 回假图字节，测试里图片加载不走真网。
class FakeNetworkImageOverrides extends HttpOverrides {
  FakeNetworkImageOverrides(this.images);
  final Map<String, Uint8List> images;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeHttpClient(images);
}
