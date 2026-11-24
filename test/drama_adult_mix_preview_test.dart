import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/pages/drama_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/digg_store.dart';
import 'package:fqapp/services/drama_channel_preferences.dart';
import 'package:fqapp/services/drama_feed_adult_mix.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/swipe_guide_store.dart';

import 'support/controlled_player.dart';

/// 修仙版短剧首页随机成人视频：混入卡预览图（测试渲染出 PNG，不构建整包）。
///
/// 挂载骨架复用 drama_inline_playback_test.dart 的 _Session（假后端 + 假
/// 播放器，不碰网络）：推荐 feed 每 4 条短剧插 1 条混入卡。
/// 4 张图：
///   feed_drama_card_playing.png   短剧卡全屏播放态（对照，药丸「观看全集·12集」）
///   feed_mix_card_cover.png       混入卡上屏前封面态（首帧未到，只见封面占位）
///   feed_mix_card_playing.png     混入卡全屏内联起播（站名 chip「测试站」+「观看全片」药丸）
///   feed_compare_drama_vs_mix.png 短剧卡与混入卡左右并排对照
/// 视频区在测试里是假播放器纹理（黑块），每张图底部都画了占位说明字条；
/// 封面也是空 cover 的占位色块，不是真实图片。

const _outDir = '/home/hatch/workspace/xiuxian_random_adult_20261124/previews';

Future<void> _loadFonts() async {
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
}

MediaItem _item(String label) => MediaItem(
  id: label,
  title: '$label 作品',
  cover: '',
  author: '演员',
  badge: '',
  ep: '12',
  kind: 'video',
);

class _Session {
  _Session({this.hasFirstFrame = true});

  final bool hasFirstFrame;
  final players = <ControlledNativePlayer>[];
  final store = ControlledReaderStore();
  int itemsPerTab = 8;
  List<AdultMixEntry> adultMixEntries = const [];

  late final HomeNotifier home = _notifierFor(this);
  late final HomeNotifier drama = _notifierFor(this);

  static HomeNotifier _notifierFor(_Session session) => HomeNotifier(
    initialTabIndex: dramaTabIndex,
    homepageLoader:
        ({int tabType = 2, int offset = 0, String? sessionId}) async {
          return HomepagePage(
            items: [
              for (var index = 0; index < session.itemsPerTab; index++)
                _item('$tabType-$index'),
            ],
            nextOffset: null,
            sessionId: null,
          );
        },
    searchLoader: (query, {int page = 1}) async => const [],
  );

  Widget app() => ProviderScope(
    overrides: [
      homeProvider.overrideWith(() => home),
      dramaProvider.overrideWith(() => drama),
    ],
    child: MaterialApp(
      theme: ThemeData(fontFamily: 'NotoSansCJK'),
      home: RepaintBoundary(
        key: const ValueKey<String>('adult-mix-preview'),
        child: TickerMode(
          enabled: true,
          child: DramaPage(
            directoryLoader: (id, tab) async {
              return [
                [Chapter(itemId: '$id-1', title: '第 1 集', volumeName: '剧集')],
              ];
            },
            contentLoader: (itemId, tab) async => <String, dynamic>{
              'video_url': 'https://example.invalid/$itemId.mp4',
            },
            historyStore: store,
            adultMixLoader: ({required int xp}) async => adultMixEntries,
            hotCommentsLoader: (seriesId) async => const <PlayletComment>[],
            playerFactory: () {
              final player = ControlledNativePlayer(
                hasFirstFrame: hasFirstFrame,
              )
                ..width = 1920
                ..height = 1080;
              players.add(player);
              return player;
            },
          ),
        ),
      ),
    ),
  );
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _mount(WidgetTester tester, _Session session) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(session.app());
  await _flush(tester);
}

Future<void> _swipeUp(WidgetTester tester) async {
  await tester.drag(
    find.byKey(const Key('drama_feed')),
    const Offset(0, -600),
  );
  await tester.pumpAndSettle();
  await _flush(tester);
}

AdultMixEntry _mixEntry() => AdultMixEntry(
  item: MediaItem(
    id: 'adultmix:test:v0',
    title: '混入片',
    cover: '',
    author: '',
    badge: '',
    ep: '',
    kind: 'film',
    categories: ['测试站'],
  ),
  siteId: 'test',
  siteItem: const DramaSiteItem(id: 'v0', title: '混入片', cover: ''),
  playUrl: 'https://example.invalid/mix.mp4',
);

/// 在 PNG 下方接一条黑色说明字条（视频区/封面占位如实标注），返回新 PNG。
/// 字条接在图下方，不遮卡片内容（标题行、站名 chip、进度条都在原图里）。
Future<Uint8List> _captionPng(Uint8List raw, String caption) async {
  final codec = await ui.instantiateImageCodec(raw);
  final frame = await codec.getNextFrame();
  final src = frame.image;
  const barH = 72.0;
  final outHeight = (src.height + barH).toInt();
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawImage(src, ui.Offset.zero, ui.Paint());
  canvas.drawRect(
    ui.Rect.fromLTWH(0, src.height.toDouble(), src.width.toDouble(), barH),
    ui.Paint()..color = const Color(0xE6000000),
  );
  final builder = ui.ParagraphBuilder(
    ui.ParagraphStyle(
      fontFamily: 'NotoSansCJK',
      fontSize: 24,
      textAlign: TextAlign.center,
    ),
  )
    ..pushStyle(ui.TextStyle(color: const Color(0xFFFFFFFF)))
    ..addText(caption);
  final para = builder.build()
    ..layout(
      ui.ParagraphConstraints(width: src.width.toDouble() - 32),
    );
  canvas.drawParagraph(
    para,
    ui.Offset(16, src.height + (barH - para.height) / 2),
  );
  final out = await recorder.endRecording().toImage(src.width, outHeight);
  final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
  src.dispose();
  out.dispose();
  return bytes!.buffer.asUint8List();
}

Future<void> _capture(WidgetTester tester, String name, String caption) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey<String>('adult-mix-preview')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final captioned = await _captionPng(
        bytes!.buffer.asUint8List(),
        caption,
      );
      final file = File('$_outDir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(captioned);
    } finally {
      image.dispose();
    }
  });
}

late Directory _hiveDir;

void main() {
  setUpAll(_loadFonts);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    DramaChannelPreferences.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          (call) async => null,
        );
    _hiveDir = await Directory.systemTemp.createTemp('fqapp-drama-mix-prev-');
    Hive.init(_hiveDir.path);
    await ShelfStore.instance.init();
    await DiggStore.instance.init();
    await SwipeGuideStore.instance.init();
    await SwipeGuideStore.instance.markShown();
    await SwipeGuideStore.instance.markSeekHintShown();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          null,
        );
    await Hive.close().timeout(
      const Duration(seconds: 10),
      onTimeout: () => const <void>[],
    );
    try {
      await _hiveDir.delete(recursive: true);
    } catch (_) {}
  });

  testWidgets('预览：短剧卡全屏播放态（对照）', (tester) async {
    final session = _Session()..adultMixEntries = [_mixEntry()];
    await _mount(tester, session);
    expect(find.text('观看全集·12集'), findsOneWidget);
    // 假播放器报时长 + 位置，卡片底部的官方进度条才画出轨道。
    session.players.single.emitDuration(const Duration(minutes: 2));
    session.players.single.emitPosition(const Duration(seconds: 20));
    await tester.pump();
    expect(find.byKey(const Key('drama_seek_bar')), findsOneWidget);
    await _capture(
      tester,
      'feed_drama_card_playing',
      '短剧卡对照 · 视频区为测试占位（假播放器纹理，无真实画面）',
    );
  });

  testWidgets('预览：混入卡上屏前封面态', (tester) async {
    final session = _Session(hasFirstFrame: false)
      ..adultMixEntries = [_mixEntry()];
    await _mount(tester, session);
    for (var i = 0; i < 4; i++) {
      await _swipeUp(tester);
    }
    expect(find.text('混入片'), findsWidgets);
    expect(find.text('测试站'), findsOneWidget);
    expect(find.text('观看全片'), findsOneWidget);
    await _capture(
      tester,
      'feed_mix_card_cover',
      '混入卡 · 上屏前封面态（首帧未到，只见封面占位）· 视频区为测试占位',
    );
  });

  testWidgets('预览：混入卡全屏内联起播', (tester) async {
    final session = _Session()..adultMixEntries = [_mixEntry()];
    await _mount(tester, session);
    for (var i = 0; i < 4; i++) {
      await _swipeUp(tester);
    }
    expect(find.text('混入片'), findsWidgets);
    expect(find.text('测试站'), findsOneWidget);
    expect(find.text('观看全片'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('drama_inline_texture_film_adultmix:test:v0')),
      findsOneWidget,
    );
    expect(session.players.last.isPlaying, isTrue);
    // 假播放器报时长 + 位置，卡片底部的官方进度条才画出轨道。
    session.players.last.emitDuration(const Duration(minutes: 2));
    session.players.last.emitPosition(const Duration(seconds: 20));
    await tester.pump();
    expect(find.byKey(const Key('drama_seek_bar')), findsOneWidget);
    await _capture(
      tester,
      'feed_mix_card_playing',
      '混入卡 · 上屏后播放态 · 视频区为测试占位（假播放器纹理，无真实画面）',
    );
  });

  testWidgets('预览：短剧卡与混入卡同屏对比', (tester) async {
    await tester.runAsync(() async {
      final leftBytes = File(
        '$_outDir/feed_drama_card_playing.png',
      ).readAsBytesSync();
      final rightBytes = File(
        '$_outDir/feed_mix_card_playing.png',
      ).readAsBytesSync();
      final leftCodec = await ui.instantiateImageCodec(leftBytes);
      final rightCodec = await ui.instantiateImageCodec(rightBytes);
      final left = (await leftCodec.getNextFrame()).image;
      final right = (await rightCodec.getNextFrame()).image;
      const labelH = 64.0;
      final width = left.width + right.width;
      final height = (left.height + labelH).toInt();
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        ui.Rect.fromLTWH(0, 0, width.toDouble(), labelH),
        ui.Paint()..color = const Color(0xFF1A1A2E),
      );
      for (final (index, label) in ['短剧卡', '混入卡 · 测试站'].indexed) {
        final builder = ui.ParagraphBuilder(
          ui.ParagraphStyle(
            fontFamily: 'NotoSansCJK',
            fontSize: 28,
            textAlign: TextAlign.center,
          ),
        )
          ..pushStyle(ui.TextStyle(color: const Color(0xFFFFFFFF)))
          ..addText(label);
        final para = builder.build()
          ..layout(
            ui.ParagraphConstraints(width: left.width.toDouble()),
          );
        canvas.drawParagraph(
          para,
          ui.Offset(index * left.width + 0.0, (labelH - para.height) / 2),
        );
      }
      canvas.drawImage(left, ui.Offset(0, labelH), ui.Paint());
      canvas.drawImage(right, ui.Offset(left.width.toDouble(), labelH), ui.Paint());
      canvas.drawRect(
        ui.Rect.fromLTWH(left.width - 2.0, 0, 4, height.toDouble()),
        ui.Paint()..color = const Color(0xFFFFFFFF),
      );
      final out = await recorder.endRecording().toImage(width, height);
      final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
      left.dispose();
      right.dispose();
      out.dispose();
      final file = File('$_outDir/feed_compare_drama_vs_mix.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    });
  });
}
