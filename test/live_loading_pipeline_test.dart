import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/whos_local_library.dart';
import 'package:fqapp/pages/live_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/live_platform.dart';
import 'package:fqapp/services/live_sources.dart';
import 'package:fqapp/services/whos_live_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 加载管线修复批（2026-11-26）的钉子：
/// 1) 默认源不是内置片库（登记表本身不动，片库仍是第 1 项）；
/// 2) ensureLoaded 失败不缓存、下次可重试成功（魔蚁 5523531 状态机）；
/// 3) 慢源/挂死源下首屏看门狗 20 秒结束加载并落报错态，刷新可自救；
/// 4) 内置片库首屏分类只有最新/排行榜，厂牌聚合异步补、不进首屏链；
/// 5) 片库读不出来时透出真实原因，不再是「退出直播重进一次看看」。

/// 站点库批（2026-11-27）适配：直播 26 源（3 平台＋23 清单）已改由站点库
/// 供数（LiveSources.sqlSources），未导入时 builtin 只剩原生 2 源。
/// 本文件验的是「导入后」的完整源表行为，故在 setUp 注入与生产站点库
/// 等值的 26 源夹具（id/名/协议与生成器 ACCOUNT 对账一致），tearDown 清空。
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
  setUp(injectSqlLiveFixture);
  tearDown(() {
    LiveSources.sqlSources = <LiveSource>[];
    livePlatformsFetcherForTest = null;
    whosLibTestLibrary = null;
  });

  group('默认源', () {
    test('默认源是登记表第一个真正的直播源，不是内置片库', () {
      expect(LiveSources.builtin.first.id, whosLibSourceId);
      expect(LiveSources.builtin.length, 28);
      expect(LiveSources.defaultSource.id, isNot(whosLibSourceId));
      expect(LiveSources.defaultSource.id, 'xiuguo');
      // 片库仍在登记表里可选，没被删。
      expect(LiveSources.byId(whosLibSourceId), isNotNull);
    });
  });

  group('ensureLoaded 加载状态机', () {
    test('失败后不缓存失败：下一次调用重新真加载', () async {
      final lib = WhosLocalLibrary.fromWorks(const []);
      var attempts = 0;
      lib.loadOverrideForTest = () async {
        attempts++;
        return attempts >= 2;
      };
      expect(await lib.ensureLoaded(), isFalse);
      expect(await lib.ensureLoaded(), isTrue);
      expect(attempts, 2);
    });

    test('成功后走缓存：不再重复加载', () async {
      final lib = WhosLocalLibrary.fromWorks(const []);
      var attempts = 0;
      lib.loadOverrideForTest = () async {
        attempts++;
        return true;
      };
      expect(await lib.ensureLoaded(), isTrue);
      expect(await lib.ensureLoaded(), isTrue);
      expect(attempts, 1);
    });

    test('抛错同样不缓存：下一次调用重试', () async {
      final lib = WhosLocalLibrary.fromWorks(const []);
      var attempts = 0;
      lib.loadOverrideForTest = () async {
        attempts++;
        if (attempts < 2) throw StateError('boom');
        return true;
      };
      expect(await lib.ensureLoaded(), isFalse);
      expect(await lib.ensureLoaded(), isTrue);
      expect(attempts, 2);
    });
  });

  group('内置片库首屏分类', () {
    test('首屏只有最新/排行榜，厂牌走异步补', () async {
      WhosLocalWork work(String code) => WhosLocalWork(
        id: code.toLowerCase(),
        title: '标题$code',
        cover: 'https://example.test/$code.jpg',
        playUrl: 'https://example.test/$code.m3u8',
        code: code,
        brand: WhosLocalWork.brandOfCode(code),
      );
      whosLibTestLibrary = WhosLocalLibrary.fromWorks([
        work('SSIS-001'),
        work('SSIS-002'),
        work('SSIS-003'),
        work('IPX-001'),
        work('IPX-002'),
      ]);
      final first = await fetchWhosLibPlatforms();
      expect(first.map((p) => p.id), ['new', 'rank']);
      final brands = await fetchWhosLibBrandPlatforms();
      expect(brands.map((p) => p.id), ['brand:ssis', 'brand:ipx']);
    });

    test('读不出来时透出真实原因，没有误导文案', () async {
      whosLibTestLibrary = null;
      Object? caught;
      try {
        await fetchWhosLibPlatforms();
      } catch (error) {
        caught = error;
      }
      expect(caught, isA<StateError>());
      final message = (caught! as StateError).message;
      expect(message, isNot(contains('退出直播重进')));
      expect(message, contains('女优库.db'));
    });
  });

  group('首屏看门狗', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await CultivationService.instance.resetForTest();
      await CultivationService.instance.ensureInitialized();
    });

    tearDown(() async {
      await CultivationService.instance.resetForTest();
    });

    testWidgets('挂死源：20 秒看门狗结束加载并落报错态', (tester) async {
      // 分类拉取永远不返回（模拟链上某一步挂死）。
      livePlatformsFetcherForTest = (_) => Completer<List<LivePlatform>>().future;
      await tester.pumpWidget(const MaterialApp(home: LivePage()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      CultivationService.instance.snapshotNotifier.value =
          const CultivationSnapshot(
            seconds: {CultivationCategory.novel: 6000.0},
          );
      await tester.pump();
      // 加载中：转圈在；手动刷新钮已按用户 2026-11-27 令删除，
      // 挂死只能等看门狗落报错态后用面板「重试」。
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(
        find.byKey(const ValueKey('live-refresh-button')),
        findsNothing,
      );

      // 推进到看门狗上限之后：加载结束、落报错态并给出真实原因。
      await tester.pump(const Duration(seconds: 21));
      await tester.pump();
      expect(find.text('秀果 直播源暂时不可用'), findsOneWidget);
      expect(find.textContaining('直播加载超时'), findsOneWidget);
      expect(find.text('载入中…'), findsNothing);
    });
  });
}
