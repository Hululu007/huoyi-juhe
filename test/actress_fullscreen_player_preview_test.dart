// 全屏态预览（单独一测，避免与详情页导航同进程时收尾卡死
// 的既有环境脆弱性）：直接渲染整页 PlayerPage 的
// openFullScreen 形态——演员库点全屏推起的就是这张页、
// 同一参数。横屏视口，纹理区在测试里是占位黑屏，真机手感
// 待验。导航往返与进度保持由 actress_fullscreen_test 覆盖。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/player_page.dart';

import 'preview_test_support.dart';
import 'support/controlled_player.dart';

const _previewDir =
    '/home/hatch/workspace/xiuxian_actress_fullscreen_20261127/previews';

Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  int rounds = 60,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          (call) async => null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          null,
        );
  });

  testWidgets('预览：整页播放器横屏全屏态', (tester) async {
    await loadPreviewFonts(tester);
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final player = ControlledNativePlayer();
    await tester.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'NotoSansCJK',
            ),
          ),
          home: PlayerPage(
            bookId: 'actress:work:sigl-020',
            kind: 'video',
            title: 'SIGL-020 样本标题',
            cover: '',
            eps: [
              Chapter(
                itemId: 'actress:work:sigl-020',
                title: 'SIGL-020 样本标题',
                volumeName: '',
              ),
            ],
            startIndex: 0,
            startPosition: const Duration(minutes: 6, seconds: 12),
            openFullScreen: true,
            shortSeries: false,
            contentLoader: (_) async => {
              'video_url': 'https://v.hersav.me/abc/abc.m3u8',
              'key_hex': '',
            },
            playerFactory: () => player,
          ),
        ),
      ),
    );
    await _until(tester, () => player.calls.contains('created'));
    player.emitFirstFrame();
    player.emitDuration(const Duration(minutes: 118));
    player.emitPosition(const Duration(minutes: 6, seconds: 12));
    await tester.pump(const Duration(milliseconds: 400));

    final boundary = tester
        .element(find.byType(RepaintBoundary).first)
        .findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    Directory(_previewDir).createSync(recursive: true);
    File('$_previewDir/preview_fullscreen_player.png').writeAsBytesSync(bytes);
    expect(find.byType(PlayerPage), findsOneWidget);
  });
}
