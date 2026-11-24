// 女优库列表头像修复预览（由魔蚁版移植，修仙版适配）：种子与真库一致
// （见 xiuxian_actress_avatar_20261124/REPORT.md 第四节真库表），
// 图里效果 = 真库里修完的效果，别再按旧种子理解。
//
// 种子（MemoryActressDatabase + upsertCrawledPerson，行序照真库 rowid）：
// - 波多野结衣（简体名）：真库里只有裸域名一行 → 存裸域名、加载失败
//   （首字圆圈正确；完整头像在繁体名“波多野結衣”名下，归并不做繁简
//   转换，不在本次范围）
// - 森沢かな：真库里完整头像行（2142）在前、裸域名行（3215）在后 →
//   应存完整头像（裸域名占不了坑）
// - 素人：真库里空行（23692）在前、裸域名行（23698）在后 → 留空
//   （首字圆圈正确；数据里无可用头像）
// - 川上ゆう：真库里两张完整头像（2136 jdbstatic、2323 hersav），
//   取行序第一张 → 应存完整头像（真照片）
// - 大槻ひびき：只有完整头像 → 应存完整头像（对照）
//
// 假图：完整头像地址按 URL 回彩色方块（测试假图，非真实头像）；
// 未知地址（含裸域名）回 404，Image.network 走 errorBuilder 画首字圆圈——
// 与真机行为一致。注意：fixtures 的 FakeNetworkImageOverrides 会把未知
// 地址回落到第一张假图，不适用这里，所以本文件自带严格版拦截器。
//
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、超时杀掉只取 PNG；不要批量跑。
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_database.dart';
import 'package:fqapp/actress/actress_list_page.dart';
import 'package:fqapp/actress/actress_models.dart';
import 'package:fqapp/actress/actress_roster_sources.dart';
import 'package:fqapp/actress/actress_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'actress_fixtures.dart';

const _previewDir = '/home/hatch/workspace/xiuxian_actress_avatar_20261124/preview';

const _bare = 'https://v.hersav.me/';
const _morisawa =
    'https://v.hersav.me/actress/avatar/morisawa_hd.jpg';
const _otsuki =
    'https://v.hersav.me/actress/avatar/otsuki_hd.jpg';
// 真库里川上ゆう行序第一张完整头像（rowid 2136）。
const _kawakami = 'https://c0.jdbstatic.com/avatars/46/46BR.jpg';

/// 严格版假图拦截：已知地址回假图字节，未知地址回 404（不回落到第一张）。
class _StrictFakeHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _StrictFakeHttpResponse(this._bytes, this.statusCode);
  final Uint8List _bytes;
  @override
  final int statusCode;
  @override
  int get contentLength => _bytes.length;
  @override
  bool get isRedirect => false;
  @override
  List<RedirectInfo> get redirects => const [];
  @override
  bool get persistentConnection => false;
  @override
  String get reasonPhrase => statusCode == 200 ? 'OK' : 'Not Found';
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  HttpHeaders get headers => _StrictFakeHttpHeaders();
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

class _StrictFakeHttpHeaders implements HttpHeaders {
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

class _StrictFakeHttpRequest implements HttpClientRequest {
  _StrictFakeHttpRequest(this._response);
  final HttpClientResponse _response;
  @override
  final HttpHeaders headers = _StrictFakeHttpHeaders();
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  Future<HttpClientResponse> close() async => _response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StrictFakeHttpClient implements HttpClient {
  _StrictFakeHttpClient(this._images);
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
  Future<HttpClientRequest> getUrl(Uri url) async {
    final bytes = _images[url.toString()];
    if (bytes == null) {
      return _StrictFakeHttpRequest(
        _StrictFakeHttpResponse(Uint8List(0), HttpStatus.notFound),
      );
    }
    return _StrictFakeHttpRequest(
      _StrictFakeHttpResponse(bytes, HttpStatus.ok),
    );
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StrictFakeImageOverrides extends HttpOverrides {
  _StrictFakeImageOverrides(this.images);
  final Map<String, Uint8List> images;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _StrictFakeHttpClient(images);
}

Future<ActressHttpResponse> _unusedFetch(
  String url, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 20),
}) async => throw UnimplementedError('fake source must not fetch');

ThemeData _previewTheme() {
  final base = ThemeData.dark();
  TextStyle? cjk(TextStyle? style) => style?.copyWith(fontFamily: 'PreviewCJK');
  ButtonStyle cjkButton(ButtonStyle? style) {
    final s = style ?? const ButtonStyle();
    final resolved = s.textStyle?.resolve({}) ?? const TextStyle();
    return s.copyWith(
      textStyle: WidgetStatePropertyAll(
        resolved.copyWith(fontFamily: 'PreviewCJK'),
      ),
    );
  }

  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: cjk(base.appBarTheme.titleTextStyle),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: cjk(base.chipTheme.labelStyle),
      secondaryLabelStyle: cjk(base.chipTheme.secondaryLabelStyle),
    ),
    textButtonTheme: TextButtonThemeData(
      style: cjkButton(base.textButtonTheme.style),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: cjkButton(base.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: cjkButton(base.outlinedButtonTheme.style),
    ),
  );
}

/// 首屏 _bootstrap 里有真异步文件 IO，FakeAsync 定步 pump 等不到它
/// 完成（见 AGENTS.md 2026-11-18 条）；必须在 runAsync 里用真
/// 时间轮询、块内 pump，否则截出来的是转圈。
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 30; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}

late LocalStore _previewStore;
late MemoryActressDatabase _previewDb;
late ActressSyncService _previewSync;
// 假图字节：toImage 要走真异步光栅，在 widget 测试的 FakeAsync 区里会
// 挂住；放 setUpAll（真实异步区）里现画，测试体内只取用。
late Map<String, Uint8List> _previewImages;

Future<void> _seed() async {
  SharedPreferences.setMockInitialValues({});
  _previewStore = LocalStore();
  _previewDb = MemoryActressDatabase();
  // 波多野结衣（简体名）：真库里只有裸域名一行（rowid 2075）。
  await _previewDb.upsertCrawledPerson(name: '波多野结衣', avatarUrl: _bare);
  // 森沢かな：真库里完整头像行（2142）在前、裸域名行（3215）在后。
  await _previewDb.upsertCrawledPerson(
    name: '森沢かな',
    avatarUrl: _morisawa,
  );
  await _previewDb.upsertCrawledPerson(name: '森沢かな', avatarUrl: _bare);
  // 素人：真库里空行（23692）在前、裸域名行（23698）在后。
  await _previewDb.upsertCrawledPerson(name: '素人', avatarUrl: '');
  await _previewDb.upsertCrawledPerson(name: '素人', avatarUrl: _bare);
  // 川上ゆう：真库里两张完整头像（2136 jdbstatic、2323 hersav），
  // 取行序第一张。
  await _previewDb.upsertCrawledPerson(
    name: '川上ゆう',
    avatarUrl: _kawakami,
  );
  // 大槻ひびき：只有完整头像（对照）。
  await _previewDb.upsertCrawledPerson(
    name: '大槻ひびき',
    avatarUrl: _otsuki,
  );
  for (final source in ActressRosterSourceId.values) {
    for (final phase in const ['roster', 'films']) {
      await _previewDb.saveCheckpoint(
        ActressSyncCheckpoint(
          source: source.name,
          phase: phase,
          finished: true,
        ),
      );
    }
  }
  _previewSync = ActressSyncService(
    db: _previewDb,
    sources: const [],
    fetch: _unusedFetch,
  );
}

void main() {
  setUp(() async {
    await _seed();
  });

  setUpAll(() async {
    try {
      final bytes = File(
        '/home/hatch/workspace/nexhub_ref/assets/fonts/SourceHanSansCN-Regular.otf',
      ).readAsBytesSync();
      final loader = FontLoader('PreviewCJK')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
    try {
      final bytes = File(
        '/home/hatch/workspace/tools/flutter-3.50.0/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ).readAsBytesSync();
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
    _previewImages = <String, Uint8List>{
      _morisawa: await fakeComicPagePng(
        Colors.green,
        width: 120,
        height: 120,
      ),
      _kawakami: await fakeComicPagePng(
        Colors.pink,
        width: 120,
        height: 120,
      ),
      _otsuki: await fakeComicPagePng(Colors.blue, width: 120, height: 120),
    };
  });

  testWidgets('preview actress list avatars fixed', (tester) async {
    // 先断言存下来的头像：森沢かな/川上ゆう是完整地址，波多野结衣
    // （简体名）存裸域名、素人空——与真库修完效果一致。
    final persons = await _previewDb.listPersons(
      sex: ActressSexFilter.all,
      sort: ActressSort.nameAsc,
      query: '',
      offset: 0,
      limit: 100,
    );
    final byName = {for (final p in persons) p.displayName: p.avatarUrl};
    expect(byName['波多野结衣'], _bare);
    expect(byName['森沢かな'], _morisawa);
    expect(byName['素人'], '');
    expect(byName['川上ゆう'], _kawakami);
    expect(byName['大槻ひびき'], _otsuki);

    HttpOverrides.global = _StrictFakeImageOverrides(_previewImages);
    addTearDown(() {
      HttpOverrides.global = null;
      PaintingBinding.instance.imageCache.clear();
    });

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(_previewStore.dispose);
    addTearDown(_previewSync.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _previewTheme(),
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'PreviewCJK'),
            child: Scaffold(
              body: Column(
                children: [
                  Container(
                    width: double.infinity,
                    color: Colors.black87,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: const Text(
                      '预览 · 女优库列表头像修复 · 彩色方块为测试假图（非真实头像）· 素人/波多野结衣首字圆圈是正确的（无有效头像）· 川上ゆう/森沢かな方块为修复后真头像效果',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontFamily: 'PreviewCJK',
                      ),
                    ),
                  ),
                  Expanded(
                    child: ActressListPage(
                      repository: FixtureRepository(),
                      store: _previewStore,
                      database: _previewDb,
                      syncService: _previewSync,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    // 假图加载是真异步：再等几拍，让 Image.network 走完。
    // 假图走引擎解码，必须真等，否则截出来还是加载占位（首字圆圈）。
    // manwa_reader_preview_test 同款写法：runAsync 里真睡 600ms 再 pump。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await _settle(tester);
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    Directory(_previewDir).createSync(recursive: true);
    File('$_previewDir/actress_list_avatars.png').writeAsBytesSync(bytes);
  });
}
