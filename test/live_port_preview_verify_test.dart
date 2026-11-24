import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/whos_local_library.dart';
import 'package:fqapp/pages/live_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/platform_channel.dart';
import 'package:fqapp/services/whos_live_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 直播列表移植预览图（2026-11-25 收尾重出）：
///
/// 旧文件 live_port_preview_test.dart 跑不过——没有假播放器，
/// 原生事件通道报 MissingPluginException；日本有码那张还卡在
/// 4.4MB m3u 资产加载上（假时钟推不动）。本文件用假播放器 +
/// runAsync 真时间重出同一批 3 张图，旧文件不动。
/// 图存 ~/workspace/xiuxian_live_port_20261124/preview/。
///
/// ① 切换直播源弹窗全貌（28 项、分组可见）；
/// ② 新源（内置片库）频道列表——任务原定②是内置片库列表，
///    这里按任务②出内置片库，另加③日本有码 m3u 列表作对照
///    （旧文件②是日本有码；两张都在报告里列明）；
/// ③ 无源名列的频道行（内置片库行只剩频道名 + 播放图标）。
///
/// 视频区在测试里是假播放器：黑底画面 + 底部频道条，不是真机
/// 效果，图注与报告里如实标注；列表本身是真实数据（m3u 资产 /
/// 注入内存库）。
const _previewDir = '/home/hatch/workspace/xiuxian_live_port_20261124/preview';

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
  // 图标字体测试环境默认不加载，不加载图标全是方框。
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CultivationService.instance.resetForTest();
    await CultivationService.instance.ensureInitialized();
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
          playerEvents.add({'playerId': id, 'type': 'firstFrame'});
        });
        return <String, dynamic>{'playerId': id};
      }
      return null;
    };
    PlatformChannels.events = (_) => playerEvents.stream;
    whosLibTestLibrary = WhosLocalLibrary.fromWorks([
      for (var i = 1; i <= 5; i++)
        WhosLocalWork(
          id: 'ssis-${i.toString().padLeft(3, '0')}',
          title: '标题$i',
          cover: 'https://example.test/ssis-$i.jpg',
          playUrl: 'https://example.test/ssis-$i.m3u8',
          code: 'SSIS-${i.toString().padLeft(3, '0')}',
          brand: 'ssis',
        ),
    ]);
  });

  tearDown(() async {
    await playerEvents.close();
    PlatformChannels.invoke = null;
    PlatformChannels.events = null;
    whosLibTestLibrary = null;
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
    WidgetTester tester, {
    required Size size,
    required ValueKey<String> boundaryKey,
  }) async {
    await _loadCjkFont();
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        // 边界包在 MaterialApp 外面：弹窗走 Overlay，在 MaterialApp
        // 里；只包 LivePage 的话弹窗进不了图（旧文件同款漏）。
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
    expect(
      await pumpUntil(
        tester,
        find.byKey(const ValueKey('live-channel-0')),
      ),
      true,
    );
  }

  Future<void> drainRetireTimer(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 31));
  }

  testWidgets('预览①：切换直播源弹窗全貌（28 源全部可见）', (tester) async {
    const boundaryKey = ValueKey<String>('live-preview-picker');
    // 高屏：弹窗限高 70% 屏高，1400 高下 28 张卡一次放得下。
    await pumpUnlocked(
      tester,
      size: const Size(390, 1400),
      boundaryKey: boundaryKey,
    );
    await tester.tap(find.byTooltip('切换直播源'));
    expect(await pumpUntil(tester, find.text('切换直播源')), true);
    await tester.pumpAndSettle();
    expect(find.text('切换直播源'), findsOneWidget);
    await _capture(tester, boundaryKey, 'live_picker_all_sources');
    await drainRetireTimer(tester);
  });

  testWidgets('预览②：内置片库频道列表', (tester) async {
    const boundaryKey = ValueKey<String>('live-preview-whoslib');
    await pumpUnlocked(
      tester,
      size: const Size(390, 844),
      boundaryKey: boundaryKey,
    );
    // 默认源就是内置片库：解锁后已自动加载，左栏是分类、右列是频道。
    expect(find.text('最新作品 · 5'), findsOneWidget);
    expect(find.text('SSIS-001 标题1'), findsWidgets);
    await tester.pumpAndSettle();
    await _capture(tester, boundaryKey, 'live_whoslib_channels');
    await drainRetireTimer(tester);
  });

  testWidgets('预览③：无源名列的频道行 + 日本有码列表', (tester) async {
    const boundaryKey = ValueKey<String>('live-preview-riben');
    await pumpUnlocked(
      tester,
      size: const Size(390, 844),
      boundaryKey: boundaryKey,
    );
    await tester.tap(find.byTooltip('切换直播源'));
    expect(await pumpUntil(tester, find.text('切换直播源')), true);
    await tester.pumpAndSettle();
    for (var i = 0; i < 20; i++) {
      if (find
          .byKey(const ValueKey('site-picker-row-m3u_riben'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
      await tester.drag(
        find.byKey(const ValueKey('site-picker-list')),
        const Offset(0, -300),
      );
      await tester.pump();
    }
    await tester.tap(
      find.byKey(const ValueKey('site-picker-row-m3u_riben')),
    );
    // 4.4MB 资产加载 + 解析是普通 Future，先给真时间再轮询。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 8));
    });
    expect(
      await pumpUntil(tester, find.textContaining('CAWD-969')),
      true,
    );
    await tester.pumpAndSettle();
    expect(find.text('日本有码'), findsNothing);
    await _capture(tester, boundaryKey, 'live_riben_channels');
    await drainRetireTimer(tester);
  });
}
