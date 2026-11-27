// 演员库四站接入（工人 D）界面测试：详情页竞速组线
// （MJV 后补线不阻塞主竞速、主线全灭时不提前定死
// 「暂无可播线路」、后补线到后接上起播）与原生页顶部
// 源条（六段页签 + 横向可滑动 + who's 不在 + MissAV
// 页签能列卡）。全部假件，不碰真库真网。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_http.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_javdb_api.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_library_native_page.dart';
import 'package:fqapp/actress/actress_py_lines.dart';
import 'package:fqapp/actress/actress_work_detail_page.dart';

import 'support/controlled_player.dart';

Future<FeedProbeResponse> _probeOk(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async => FeedProbeResponse(
  statusCode: 200,
  headers: const {},
  headBytes: utf8.encode('#EXTM3U\n#EXT-X-VERSION:3\n'),
);

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

/// 详情页假仓储：Dart 线路由页面 onlineFetch 假取数回空、
/// MissAV 无命中、潮流索引拿到地址但探针判死（桥内落现拉
/// 也要慢搜）；MJV 现拉（经 seed_chaoliu 搜索）一律慢回
/// （1.2 秒）一张本体卡——主竞速总闸（300ms）内无任何线
/// 能验活，胜负只能由后补线窗口决定。
class _RaceRepo extends AppRepository {

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory('all', '全部')];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async => CatalogPage(const [], page: page);

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    if (sources.contains(ActressPyBridge.chaoliuSiteId)) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      return CatalogPage(const [
        Drama(
          id: 'chinese#255461#SSIS-001',
          source: ActressPyBridge.chaoliuSiteId,
          title: 'SSIS-001 现拉标题',
        ),
      ]);
    }
    return CatalogPage(const []);
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => drama.cover;

  @override
  Future<DramaDetail> detail(Drama drama) async {
    if (drama.id.startsWith('code_')) {
      return DramaDetail(drama, [
        Episode({'id': 'jpcode:SSIS-001', 'title': '正片'}, 1),
      ]);
    }
    return DramaDetail(drama, [
      Episode({'id': 'mjv|720', 'title': '720P'}, 1),
    ]);
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async {
    if (episode.id.startsWith('jpcode:')) {
      // 索引地址：探针判死（见 _raceProbe），桥内落现拉。
      return const PlaybackPlan(url: 'https://index.test/dead.m3u8');
    }
    return const PlaybackPlan(url: 'https://live.test/mjv/720.m3u8');
  }
}

/// 竞速探针：索引地址判死、现拉地址判活。
Future<FeedProbeResponse> _raceProbe(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async {
  if (url.contains('index.test')) {
    return const FeedProbeResponse(statusCode: 404, headers: {}, headBytes: []);
  }
  return _probeOk(url, headers, timeout);
}

ActressLibraryDbFallback _noDbFallback() => ActressLibraryDbFallback(
  pathResolver: () async => null,
  opener: (path) async => null,
);

Future<String> _emptyFetch(String url, Map<String, String> headers) async => '';

Future<String> _javdbEmpty(String url) async =>
    jsonEncode({'success': false, 'data': <String, Object?>{}});

void main() {
  testWidgets('详情页竞速：主线全灭不提前定死，MJV 后补线到后接上起播', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final player = ControlledNativePlayer();
    await tester.pumpWidget(
      MaterialApp(
        home: ActressWorkDetailPage.byCode(
          code: 'SSIS-001',
          title: 'SSIS-001 样本',
          fallback: _noDbFallback(),
          repository: _RaceRepo(),
          onlineFetch: _emptyFetch,
          javdbClient: JavdbApiClient(fetch: _javdbEmpty),
          probeFetch: _raceProbe,
          playerFactory: () => player,
          playUrlPrep: (url, headers) async => url,
          raceGate: const Duration(milliseconds: 300),
          lateLineWindow: const Duration(seconds: 10),
        ),
      ),
    );
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('work-detail-poster-play'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('work-detail-poster-play')));
    // 主竞速总闸（300ms）已过、MJV 现拉（约 1.2 秒）未到：
    // 不许提前把「暂无可播线路」定死。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 700)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('暂无可播线路'), findsNothing);
    // 后补线到后验活接上：播放器被创建（页内起播）。
    await _until(
      tester,
      () => player.calls.any((c) => c.startsWith('create:')),
    );
    expect(player.calls.any((c) => c.startsWith('create:')), isTrue);
    expect(find.text('暂无可播线路'), findsNothing);
  });

  testWidgets('原生页源条：六段页签横滑、who\'s 不在、MissAV 页签能列卡', (
    tester,
  ) async {
    final store = LocalStore();
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ActressLibraryNativePage(
          repository: _BarRepo(),
          store: store,
          fallback: _noDbFallback(),
          onlineFetch: _emptyFetch,
        ),
      ),
    );
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // 六段都在源条里（横滑列表懒建：先断言已建的，再滑出后面的）。
    expect(find.byKey(const ValueKey('native-source-local')), findsOneWidget);
    expect(find.byKey(const ValueKey('native-source-123av')), findsOneWidget);
    expect(find.byKey(const ValueKey('native-source-pornhub')), findsOneWidget);
    expect(find.byKey(const ValueKey('native-source-whos')), findsNothing);
    expect(find.text("who's"), findsNothing);
    // 源条是横向可滑动列表。
    final barList = tester.widget<ListView>(
      find.byKey(const ValueKey('native-source-bar-scroll')),
    );
    expect(barList.scrollDirection, Axis.horizontal);
    await tester.drag(
      find.byKey(const ValueKey('native-source-bar-scroll')),
      const Offset(-300, 0),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const ValueKey('native-source-missav')), findsOneWidget);
    expect(find.byKey(const ValueKey('native-source-chaoliu')), findsOneWidget);
    expect(find.byKey(const ValueKey('native-source-av18')), findsOneWidget);
    // 在线段都带「未验」小标（与 123AV/PH 现行口径一致）；
    // 2026-11-27 桥接批后源条尾段平铺 110 个桥接站、同带
    // 未验标，横滑懒建出的段数随滑动位置变——断言至少五段
    // 在位（原断言的五段口径不变）。
    expect(find.text('未验'), findsAtLeastNWidgets(5));
    // 切到 MissAV 页签：py 桥经仓储 catalog 列出卡片。
    await tester.tap(find.byKey(const ValueKey('native-source-missav')));
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('native-work-missav-seed_missav-1'))
          .evaluate()
          .isNotEmpty,
      rounds: 30,
    );
    expect(
      find.byKey(const ValueKey('native-work-missav-seed_missav-1')),
      findsOneWidget,
    );
  });
}

/// 原生页假仓储：catalog 按站回一张卡（py 页签列卡用），
/// 其余方法回空/直链。
class _BarRepo extends AppRepository {
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory('all', '全部')];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async => CatalogPage([
    Drama(id: '$source-1', source: source, title: '$source 作品一'),
  ], page: page);

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async =>
      CatalogPage(const []);

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => drama.cover;

  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail(drama, [
    Episode({'id': 'https://example.test/a.m3u8', 'title': '正片'}, 1),
  ]);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async => const PlaybackPlan(url: 'https://example.test/a.m3u8');
}
