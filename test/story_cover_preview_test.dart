// 改后漫剧/小说/听书三页封面预览（2026-11-24 加载侧加固）。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），单个测单独跑、加超时，PNG 落地后即可杀掉，不要等它
// 自然收尾，也不要把三张拼在一个命令里跑。
//
// 封面是本地服务器回的真图片字节，走真实的 CachedNetworkImage +
// PosterCache 链路（不是画上去的假图）；标题是预览占位标题，不是
// 真实作品名——本测只证加载链路与卡片形态，不证具体作品数据。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';

import 'preview_test_support.dart';

const _previewDir = '/home/hatch/workspace/xiuxian_manju_covers_20261124/preview';

late HttpServer _server;
late List<int> _png;
late Directory _tempDir;

MediaItem _item(String path, String title, String kind, {String author = ''}) =>
    MediaItem(
      id: 'preview-$kind-$title',
      title: title,
      cover: 'http://127.0.0.1:${_server.port}$path',
      author: author,
      badge: '',
      ep: kind == 'manju' ? '共153集' : '',
      kind: kind,
    );

Widget _page(String label, List<MediaItem> items) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(),
    home: Scaffold(
      backgroundColor: const Color(0xFF1B1030),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            color: Colors.black87,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 10),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final item in items)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: HomeMediaCard(
                        item: item,
                        onTap: () {},
                        coverWidth: 112,
                        showLength: true,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2.0);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$_previewDir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

/// 真时间轮询直到封面全部显示：runAsync 里等真 IO 回包，块外 pump 刷帧。
/// 条件必须是“占位图标全部消失”——占位是 _CoverArtwork 几何画 +
/// 按 kind 区分的图标（漫剧 film、小说 book_open、听书 headphones），
/// 只等 film 图标的话，小说/听书页一开始就没有 film 图标、会立刻
/// 返回，截出来的是占位画不是真图。
/// 另：cached_network_image 4.x 的 OctoImage 占位态内部也有一个 Image，
/// find.byType(Image) 在建树后立刻就满足，同样等不到加载完成。
/// 上限约 30 秒真时间（60 轮 × 500 毫秒）。
Future<void> _waitForCovers(WidgetTester tester) async {
  bool placeholderShown() =>
      find.byIcon(LucideIcons.film).evaluate().isNotEmpty ||
      find.byIcon(LucideIcons.book_open).evaluate().isNotEmpty ||
      find.byIcon(LucideIcons.headphones).evaluate().isNotEmpty ||
      find.byIcon(LucideIcons.clapperboard).evaluate().isNotEmpty ||
      find.byIcon(LucideIcons.image).evaluate().isNotEmpty;
  for (var i = 0; i < 60; i++) {
    if (!placeholderShown()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(placeholderShown(), isFalse);
}

void main() {
  setUpAll(() async {
    _tempDir = await Directory.systemTemp.createTemp(
      'story-cover-preview-test-',
    );
    _png = File(
      'test/fixtures/moyi_style_preview/still_mock.png',
    ).readAsBytesSync();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.contentLength = _png.length;
      request.response.add(_png);
      await request.response.close();
    });
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
    savedOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
  });

  tearDown(() {
    HttpOverrides.global = savedOverrides;
  });

  testWidgets('预览：漫剧页卡片封面', (tester) async {
    await loadPreviewFonts(tester);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: _page('预览 · 漫剧页 · 封面经真实加载链路拉取（本地模拟图）', [
            _item('/manju-1.png', '漫剧预览一', 'manju'),
            _item('/manju-2.png', '漫剧预览二', 'manju'),
            _item('/manju-3.png', '漫剧预览三', 'manju'),
          ]),
        ),
      );
    });
    await _waitForCovers(tester);
    await _capture(tester, key, 'manju');
  });

  testWidgets('预览：小说页卡片封面', (tester) async {
    await loadPreviewFonts(tester);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: _page('预览 · 小说页 · 封面经真实加载链路拉取（本地模拟图）', [
            _item('/novel-1.png', '小说预览一', 'book', author: '预览作者'),
            _item('/novel-2.png', '小说预览二', 'book', author: '预览作者'),
            _item('/novel-3.png', '小说预览三', 'book', author: '预览作者'),
          ]),
        ),
      );
    });
    await _waitForCovers(tester);
    await _capture(tester, key, 'novel');
  });

  testWidgets('预览：听书页卡片封面', (tester) async {
    await loadPreviewFonts(tester);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: _page('预览 · 听书页 · 封面经真实加载链路拉取（本地模拟图）', [
            _item('/audio-1.png', '听书预览一', 'audio', author: '预览作者'),
            _item('/audio-2.png', '听书预览二', 'audio', author: '预览作者'),
            _item('/audio-3.png', '听书预览三', 'audio', author: '预览作者'),
          ]),
        ),
      );
    });
    await _waitForCovers(tester);
    await _capture(tester, key, 'audio');
  });
}
