import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/live_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/live_epg.dart';
import 'package:fqapp/services/live_platform.dart';
import 'package:fqapp/services/live_sources.dart';
import 'package:fqapp/services/platform_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _previewDir = '/home/hatch/workspace/xiuxian_live_port_20261126';

Future<void> _capture(
  WidgetTester tester,
  ValueKey<String> boundaryKey,
  String name,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(boundaryKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
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

Future<void> _loadCjkFont() async {
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
    '/home/hatch/workspace/tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ).readAsBytesSync();
  final iconLoader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.view(iconBytes.buffer)));
  await iconLoader.load();
}

void main() {
  late StreamController<dynamic> playerEvents;
  var nextPlayerId = 0;
  var sendFirstFrame = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CultivationService.instance.resetForTest();
    await CultivationService.instance.ensureInitialized();
    sendFirstFrame = true;
    playerEvents = StreamController<dynamic>.broadcast();
    PlatformChannels.invoke = (channel, method, args) async {
      if (method == 'create') {
        final id = ++nextPlayerId;
        scheduleMicrotask(() {
          playerEvents.add({'playerId': id, 'type': 'created', 'value': 1});
          playerEvents.add({
            'playerId': id,
            'type': 'videoSize',
            'width': 1280,
            'height': 720,
          });
          if (sendFirstFrame) {
            playerEvents.add({'playerId': id, 'type': 'firstFrame'});
          } else {
            playerEvents.add({'playerId': id, 'type': 'buffering', 'value': true});
          }
        });
        return <String, dynamic>{'playerId': id};
      }
      return null;
    };
    PlatformChannels.events = (_) => playerEvents.stream;
    livePlatformsFetcherForTest = (_) async => const [
      LivePlatform(id: 'p1', name: '央视卫视', count: 3),
    ];
    liveChannelsFetcherForTest = (_, _) async => [
      LiveChannel(
        title: '综合频道',
        url: 'https://example.test/one.m3u8',
        urls: const [
          'https://example.test/one.m3u8',
          'https://example.test/one-alt.m3u8',
        ],
        group: '央视卫视',
        sourceId: 'xiuguo',
        number: '001',
        tvgId: 'ch1',
      ),
      LiveChannel(
        title: '新闻频道',
        url: 'https://example.test/two.m3u8',
        group: '央视卫视',
        sourceId: 'xiuguo',
        number: '002',
        tvgId: 'ch2',
      ),
      LiveChannel(
        title: '体育频道',
        url: 'https://example.test/three.m3u8',
        group: '央视卫视',
        sourceId: 'xiuguo',
        number: '003',
        tvgId: 'ch3',
      ),
    ];
    final now = DateTime.now();
    String stamp(DateTime t) {
      String two(int v) => v.toString().padLeft(2, '0');
      final u = t.toUtc();
      return '${u.year}${two(u.month)}${two(u.day)}'
          '${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
    }

    final xml =
        '<tv>'
        '<channel id="ch1"><display-name>综合频道</display-name></channel>'
        '<programme channel="ch1" start="${stamp(now.subtract(const Duration(minutes: 30)))}" '
        'stop="${stamp(now.add(const Duration(minutes: 30)))}">'
        '<title>晚间新闻联播</title></programme>'
        '<programme channel="ch1" start="${stamp(now.add(const Duration(minutes: 30)))}" '
        'stop="${stamp(now.add(const Duration(minutes: 90)))}">'
        '<title>黄金剧场：山海情</title></programme>'
        '</tv>';
    liveEpgLoaderForTest = (_) async => parseXmltvGuide(xml);
  });

  tearDown(() async {
    livePlatformsFetcherForTest = null;
    liveChannelsFetcherForTest = null;
    liveEpgLoaderForTest = null;
    await playerEvents.close();
    PlatformChannels.invoke = null;
    PlatformChannels.events = null;
    await CultivationService.instance.resetForTest();
  });

  Future<bool> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    int maxPumps = 120,
  }) async {
    for (var i = 0; i < maxPumps; i++) {
      if (finder.evaluate().isNotEmpty) return true;
      await tester.pump(const Duration(milliseconds: 100));
    }
    return finder.evaluate().isNotEmpty;
  }

  Future<void> pumpUnlocked(
    WidgetTester tester,
    ValueKey<String> boundaryKey,
  ) async {
    await _loadCjkFont();
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          theme: ThemeData(fontFamily: 'NotoSansCJK'),
          home: const LivePage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    CultivationService.instance.snapshotNotifier.value =
        const CultivationSnapshot(
          seconds: {CultivationCategory.novel: 6000.0},
        );
  }

  Future<void> drainRetireTimer(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 31));
  }

  testWidgets('preview normal', (tester) async {
    const boundaryKey = ValueKey<String>('live-final-preview-normal');
    await pumpUnlocked(tester, boundaryKey);
    expect(
      await pumpUntil(tester, find.byKey(const ValueKey('live-channel-0'))),
      true,
    );
    expect(await pumpUntil(tester, find.text('正在播放：晚间新闻联播')), true);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump();
    await _capture(tester, boundaryKey, 'preview_normal');
    await drainRetireTimer(tester);
  });

  testWidgets('preview buffering', (tester) async {
    sendFirstFrame = false;
    const boundaryKey = ValueKey<String>('live-final-preview-buffering');
    await pumpUnlocked(tester, boundaryKey);
    expect(
      await pumpUntil(tester, find.byKey(const ValueKey('live-channel-0'))),
      true,
    );
    expect(await pumpUntil(tester, find.byType(CircularProgressIndicator)), true);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    await _capture(tester, boundaryKey, 'preview_buffering');
    await drainRetireTimer(tester);
  });
}
