import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/widgets/mine/cultivation_profile_card.dart';

/// 档案卡动效帧：与 mine_page_preview_test 同一套截图路子（先载 CJK 字体、
/// 整页 RepaintBoundary、等图 800ms），点人物放招后每 250ms 截一帧，
/// 存 `previews/anim_性别/frame_XX.png`，再由 PIL 拼成 GIF。
Future<void> _loadCjkFonts() async {
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
  final iconBytes = File(
    '/home/hatch/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ).readAsBytesSync();
  final iconLoader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.view(iconBytes.buffer)));
  await iconLoader.load();
}

Future<void> _seedProfile(CultivationGender gender) async {
  SharedPreferences.setMockInitialValues({});
  final service = CultivationService.instance;
  await service.resetForTest();
  await service.ensureInitialized();
  await service.createProfile(
    gender: gender,
    sect: '黄枫谷',
    profession: '天道',
    costumeId: 'qing',
  );
  await service.addSeconds(CultivationCategory.novel, 1200);
  await service.addSeconds(CultivationCategory.comic, 600);
  await service.addSeconds(CultivationCategory.audio, 300);
  await service.addSeconds(CultivationCategory.video, 600);
  await service.addDramaEpisodeCompleted();
  await service.addDramaEpisodeCompleted();
}

Future<void> _capture(
  WidgetTester tester,
  ValueKey<String> boundaryKey,
  String path,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(boundaryKey),
  );
  final sw = Stopwatch()..start();
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
  // ignore: avoid_print
  print('CAPTURE $path ${sw.elapsedMilliseconds}ms');
}

Future<void> _captureFrames(
  WidgetTester tester,
  CultivationGender gender,
) async {
  final tag = gender == CultivationGender.female ? 'female' : 'male';
  final boundaryKey = ValueKey<String>('anim-$tag');
  await _loadCjkFonts();
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
  await _seedProfile(gender);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'NotoSansCJK'),
      home: RepaintBoundary(
        key: boundaryKey,
        child: Scaffold(
          backgroundColor: const Color(0xFF0F0F14),
          body: SingleChildScrollView(
            child: CultivationProfileCard(
              totalTitles: 12,
              onOpenTitles: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 800));
  });
  await tester.pump();
  // 第 0 帧：放招前（待机态）。
  await _capture(tester, boundaryKey, 'previews/anim_$tag/frame_00.png');
  // 点人物放招。
  await tester.tap(find.byKey(const Key('profile-figure')));
  await tester.pump();
  for (var i = 1; i <= 5; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    await _capture(
      tester,
      boundaryKey,
      'previews/anim_$tag/frame_${i.toString().padLeft(2, '0')}.png',
    );
  }
  // ignore: avoid_print
  print('ANIM_FRAMES $tag done');
}

void main() {
  testWidgets('档案卡动效帧（女）', (tester) async {
    await _captureFrames(tester, CultivationGender.female);
  });

  testWidgets('档案卡动效帧（男）', (tester) async {
    await _captureFrames(tester, CultivationGender.male);
  });
}
