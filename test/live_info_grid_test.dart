import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/live_page.dart';
import 'package:fqapp/pages/live_player_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/live_epg.dart';
import 'package:fqapp/services/live_platform.dart';
import 'package:fqapp/services/live_sources.dart';
import 'package:fqapp/services/platform_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 直播版式 + 节目单/DRM 接线（第 3 包）新行为验证：
/// ① 80 高瘦信息行构成（左预览槽 / 正在-即将两行 / 56 宽切源钮）；
/// ② 假 EPG 喂入后信息行 now/next 显示真节目名；
/// ③ 分组/频道/线路三列同排渲染，点线路格切播到该线路地址；
/// ④ DRM 频道出明示卡且无「重新连接」入口（内嵌页与全屏页）；
/// ⑤ 节目单弹层里已结束节目点回看按模板生成地址起播；
/// ⑥ 顶栏整体撤除（频道名/分辨率/ⓘ 信息钮与信息单全无，
/// 魔蚁版式口径 2026-11-26），无节目单时点信息行中卡无反应。
/// 频道与节目单都走 live_page 的测试注入缝（生产路径为 null），
/// 播放器是 PlatformChannels 假原生播放器，create 的 cdnUrl 记
/// 下来断言实际起播地址。
/// 站点库批（2026-11-27）适配（组装 20261127+3 补）：直播 26 源
/// （3 平台＋23 清单）已改由站点库供数（LiveSources.sqlSources），
/// 未导入时 builtin 只剩原生 2 源。本文件验的是「导入后」的完整
/// 源表行为，故在 setUp 注入与生产站点库等值的 26 源夹具（id/名/
/// 协议与生成器 ACCOUNT 对账一致，与 live_port_verify_test 同款），
/// tearDown 清空。断言一字未动。
void injectSqlLiveFixture() {
  LiveSources.sqlSources = <LiveSource>[
    const LiveSource(
      id: 'xiuguo',
      name: '秀果',
      description: '主播直播 · 实时开播',
      protocol: LiveProtocol.pingtai,
      endpoints: ['http://api.vipmisss.com:81/xcdsw', 'http://api.hclyz.com:81/mf'],
      adult: true,
    ),
    const LiveSource(
      id: 'maiyoux',
      name: '欲火聚合',
      description: '欲火移植 · 平台动态聚合 · 实时开播',
      protocol: LiveProtocol.pingtai,
      endpoints: ['http://api.maiyoux.com:81/mf', 'http://api.vipmisss.com:81/xcdsw'],
      adult: true,
    ),
    const LiveSource(
      id: 'bnzb',
      name: '百年直播',
      description: '百年直播 · 多平台聚合 · 实时开播',
      protocol: LiveProtocol.pingtai,
      endpoints: ['http://api.vipmisss.com:81/xcdsw'],
      adult: true,
    ),
    for (final e in <String, String>{
      'user_m3u': '成人点播',
      'm3u_zhubo': '主播网红',
      'm3u_luanlun': '乱伦精品',
      'm3u_huayu': '华语精品',
      'm3u_guochan': '国产精品',
      'm3u_xuesheng': '学生合集',
      'm3u_tanhua': '探花约炮',
      'm3u_riben': '日本有码',
      'm3u_oumei': '欧美大屌',
      'm3u_heilian': '黑料吃瓜',
      'm3u_community10': '社区合集10',
      'm3u_community11': '社区合集11',
      'm3u_wuma': '無碼專區',
      'm3u_wanghong': '網紅頭條',
      'm3u_xingba': '杏吧原創',
      'm3u_chengtou': '成人頭條',
      'm3u_zhifu': '制服絲襪',
      'm3u_qunjiao': '群交淫亂',
      'm3u_mingxing': '明星換臉',
      'm3u_zipai': '自拍偷拍',
      'm3u_avxiongdi': 'AV兄弟无码',
      'm3u_guochanse': '国产色情',
      'm3u_riben2': '日本有码2',
    }.entries)
      LiveSource(
        id: e.key,
        name: e.value,
        description: '',
        protocol: LiveProtocol.list,
        endpoints: ['sql://${e.key}'],
        adult: true,
      ),
  ];
}

void main() {
  late StreamController<dynamic> playerEvents;
  var nextPlayerId = 0;
  final createdUrls = <String>[];

  setUp(() async {
    injectSqlLiveFixture();
    SharedPreferences.setMockInitialValues({});
    await CultivationService.instance.resetForTest();
    await CultivationService.instance.ensureInitialized();
    createdUrls.clear();
    playerEvents = StreamController<dynamic>.broadcast();
    PlatformChannels.invoke = (channel, method, args) async {
      if (method == 'create') {
        final id = ++nextPlayerId;
        final map = args as Map<dynamic, dynamic>?;
        createdUrls.add('${map?['cdnUrl'] ?? ''}');
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
    livePlatformsFetcherForTest = (_) async => const [
      LivePlatform(id: 'p1', name: '测试分组', count: 2),
    ];
  });

  tearDown(() async {
    LiveSources.sqlSources = <LiveSource>[];
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

  Future<void> pumpUnlocked(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: LivePage()));
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

  LiveChannel channelOne() => LiveChannel(
    title: '频道一',
    url: 'https://example.test/one.m3u8',
    urls: const [
      'https://example.test/one.m3u8',
      'https://example.test/one-alt.m3u8',
    ],
    group: '测试分组',
    sourceId: 'xiuguo',
    number: '001',
    tvgId: 'ch1',
  );

  LiveChannel channelTwo() => LiveChannel(
    title: '频道二',
    url: 'https://example.test/two.m3u8',
    group: '测试分组',
    sourceId: 'xiuguo',
    number: '002',
  );

  testWidgets('信息行：80 高、左预览槽、两行小字、56 宽切源钮', (tester) async {
    liveChannelsFetcherForTest = (_, _) async => [channelOne(), channelTwo()];
    await pumpUnlocked(tester);
    expect(
      await pumpUntil(tester, find.byKey(const ValueKey('live-channel-0'))),
      true,
    );
    // 整行钉死 80 高：量信息行三段共同的祖先 SizedBox 高度。
    final sourceCard = find.byKey(const ValueKey('live-source-card'));
    expect(sourceCard, findsOneWidget);
    expect(tester.getSize(sourceCard).width, 56);
    expect(tester.getSize(sourceCard).height, 80);
    final preview = find.byKey(const ValueKey('live-info-preview'));
    expect(preview, findsOneWidget);
    expect(tester.getSize(preview).height, 80);
    // 预览槽里是与主播放区同一个 textureId 的第二个 Texture。
    expect(
      find.byKey(const ValueKey('live-info-preview-texture')),
      findsOneWidget,
    );
    expect(find.byType(Texture), findsNWidgets(2));
    // 两行小字：无节目单时回落频道标题口径（正在=当前频道、
    // 即将=下一条频道），不编节目名。
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('live-epg-now')))
          .data,
      '正在播放：频道一',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('live-epg-next')))
          .data,
      '即将播放：频道二',
    );
    // 顶栏已整个撤掉（魔蚁版式口径 2026-11-26）：频道名、分辨率
    // 读数、ⓘ 信息钮都不存在，视频区顶部干净。
    expect(find.byKey(const ValueKey('live-video-title')), findsNothing);
    expect(
      find.byKey(const ValueKey('live-video-resolution')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('live-video-info')), findsNothing);
    expect(find.textContaining('帧/秒'), findsNothing);
    await drainRetireTimer(tester);
  });

  testWidgets('无节目单时点信息行中卡：不开任何弹层（信息单已撤）', (
    tester,
  ) async {
    liveChannelsFetcherForTest = (_, _) async => [channelOne(), channelTwo()];
    await pumpUnlocked(tester);
    expect(
      await pumpUntil(tester, find.byKey(const ValueKey('live-epg-card'))),
      true,
    );
    await tester.tap(find.byKey(const ValueKey('live-epg-card')));
    await tester.pump(const Duration(milliseconds: 400));
    // 没有节目单就不给假入口：节目单弹层不开，原频道信息弹层
    // 也已随顶栏一并撤掉，点按无反应。
    expect(find.byKey(const ValueKey('live-epg-list')), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    await drainRetireTimer(tester);
  });

  testWidgets('假 EPG 喂入后 now/next 显示真节目名', (tester) async {
    liveChannelsFetcherForTest = (_, _) async => [channelOne(), channelTwo()];
    final now = DateTime.now();
    String stamp(DateTime t) {
      String two(int v) => v.toString().padLeft(2, '0');
      final u = t.toUtc();
      return '${u.year}${two(u.month)}${two(u.day)}'
          '${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
    }

    final xml =
        '<tv>'
        '<channel id="ch1"><display-name>频道一</display-name></channel>'
        '<programme channel="ch1" start="${stamp(now.subtract(const Duration(minutes: 30)))}" '
        'stop="${stamp(now.add(const Duration(minutes: 30)))}">'
        '<title>正在播的真节目</title></programme>'
        '<programme channel="ch1" start="${stamp(now.add(const Duration(minutes: 30)))}" '
        'stop="${stamp(now.add(const Duration(minutes: 90)))}">'
        '<title>接下来真节目</title></programme>'
        '</tv>';
    liveEpgLoaderForTest = (_) async => parseXmltvGuide(xml);
    await pumpUnlocked(tester);
    expect(
      await pumpUntil(tester, find.text('正在播放：正在播的真节目')),
      true,
    );
    expect(find.text('即将播放：接下来真节目'), findsOneWidget);
    await drainRetireTimer(tester);
  });

  testWidgets('三列同排渲染，点线路格切播到该线路地址', (tester) async {
    liveChannelsFetcherForTest = (_, _) async => [channelOne(), channelTwo()];
    await pumpUnlocked(tester);
    expect(
      await pumpUntil(tester, find.byKey(const ValueKey('live-channel-0'))),
      true,
    );
    // 三列同排：分组格、频道格、线路格在同一行（纵坐标一致）。
    // 第 1 行分组是收藏（__favourites），与 live-channel-0 /
    // live-line-0 同行；测试分组 p1 在第 2 行。
    final groupY = tester
        .getTopLeft(find.byKey(const ValueKey('live-group-__favourites')))
        .dy;
    final channelY = tester
        .getTopLeft(find.byKey(const ValueKey('live-channel-0')))
        .dy;
    final lineY = tester
        .getTopLeft(find.byKey(const ValueKey('live-line-0')))
        .dy;
    expect(channelY, groupY);
    expect(lineY, groupY);
    expect(find.text('测试分组'), findsOneWidget);
    expect(find.text('线路1'), findsOneWidget);
    expect(find.text('线路2'), findsOneWidget);
    // 首播走线路 1 地址。
    expect(createdUrls, contains('https://example.test/one.m3u8'));
    // 点线路 2 格：同一频道按线路 2 地址重播。
    createdUrls.clear();
    await tester.tap(find.byKey(const ValueKey('live-line-1')));
    expect(
      await pumpUntil(
        tester,
        find.byWidgetPredicate(
          (_) => createdUrls.contains('https://example.test/one-alt.m3u8'),
        ),
      ),
      true,
    );
    await drainRetireTimer(tester);
  });

  testWidgets('DRM 频道：内嵌页出明示卡、无重新连接、不起播', (tester) async {
    final drmChannel = LiveChannel(
      title: '加密频道',
      url: 'https://example.test/drm.m3u8',
      group: '测试分组',
      sourceId: 'xiuguo',
      number: '009',
      licenseKey: 'https://license.example.test/wv',
      licenseType: 'com.widevine.alpha',
    );
    liveChannelsFetcherForTest = (_, _) async => [drmChannel, channelTwo()];
    await pumpUnlocked(tester);
    expect(await pumpUntil(tester, find.text('该频道带 DRM 加密')), true);
    expect(find.textContaining('当前播放器无法解密'), findsWidgets);
    expect(find.text('重新连接'), findsNothing);
    // 不起播：假播放器一次 create 都没收到。
    expect(createdUrls, isEmpty);
    await drainRetireTimer(tester);
  });

  testWidgets('DRM 频道：全屏页出明示卡、无重新连接', (tester) async {
    final drmChannel = LiveChannel(
      title: '加密频道',
      url: 'https://example.test/drm.m3u8',
      group: '测试分组',
      sourceId: 'xiuguo',
      licenseKey: 'https://license.example.test/wv',
      licenseType: 'com.widevine.alpha',
    );
    const source = LiveSource(
      id: 'xiuguo',
      name: '秀果',
      description: '',
      protocol: LiveProtocol.pingtai,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LivePlayerPage(
          channels: [drmChannel],
          startIndex: 0,
          source: source,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('该频道带 DRM 加密'), findsOneWidget);
    expect(find.textContaining('当前播放器无法解密'), findsOneWidget);
    expect(find.text('重新连接'), findsNothing);
    expect(createdUrls, isEmpty);
    await drainRetireTimer(tester);
  });

  testWidgets('节目单弹层：已结束节目点回看按模板生成地址起播', (tester) async {
    final catchupChannel = LiveChannel(
      title: '频道一',
      url: 'https://example.test/one.m3u8',
      group: '测试分组',
      sourceId: 'xiuguo',
      number: '001',
      tvgId: 'ch1',
      catchup: const LiveCatchup(
        type: 'append',
        source: '?playseek=\${(b)timestamp}-\${(e)timestamp}',
      ),
    );
    liveChannelsFetcherForTest = (_, _) async => [catchupChannel];
    final now = DateTime.now();
    final pastStart = now.subtract(const Duration(hours: 2));
    final pastEnd = now.subtract(const Duration(hours: 1));
    String stamp(DateTime t) {
      String two(int v) => v.toString().padLeft(2, '0');
      final u = t.toUtc();
      return '${u.year}${two(u.month)}${two(u.day)}'
          '${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
    }

    final xml =
        '<tv>'
        '<channel id="ch1"><display-name>频道一</display-name></channel>'
        '<programme channel="ch1" start="${stamp(pastStart)}" '
        'stop="${stamp(pastEnd)}">'
        '<title>已播完的节目</title></programme>'
        '<programme channel="ch1" start="${stamp(now.subtract(const Duration(minutes: 10)))}" '
        'stop="${stamp(now.add(const Duration(minutes: 50)))}">'
        '<title>正在播的节目</title></programme>'
        '</tv>';
    liveEpgLoaderForTest = (_) async => parseXmltvGuide(xml);
    await pumpUnlocked(tester);
    expect(await pumpUntil(tester, find.text('正在播放：正在播的节目')), true);
    // 点信息行中卡开节目单弹层。
    await tester.tap(find.byKey(const ValueKey('live-epg-card')));
    expect(
      await pumpUntil(tester, find.byKey(const ValueKey('live-epg-list'))),
      true,
    );
    expect(find.text('已播完的节目'), findsOneWidget);
    // 等弹层入场动画落定再点（动画中条目还在屏幕外）。
    await tester.pumpAndSettle();
    createdUrls.clear();
    await tester.tap(find.byKey(const ValueKey('live-epg-item-0')));
    final expected =
        'https://example.test/one.m3u8?playseek='
        '${pastStart.millisecondsSinceEpoch ~/ 1000}-'
        '${pastEnd.millisecondsSinceEpoch ~/ 1000}';
    expect(
      await pumpUntil(
        tester,
        find.byWidgetPredicate((_) => createdUrls.contains(expected)),
      ),
      true,
    );
    await drainRetireTimer(tester);
  });
}
