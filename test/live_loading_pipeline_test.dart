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
void main() {
  tearDown(() {
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
