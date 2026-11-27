// 磁力播放＋115 会员播放新测（2026-11-27）：
// - pan115IsVip 纯判定（永久/在期/过期/没拿到四态）；
// - 离线任务 failed 态解析（状态 -1）；
// - pickBestMagnetPlayLink：磁力优先、退回直链、不假提交；
// - MagnetPlayWaiter 状态机全结局：未登入/盘里已有直接播/
//   秒下/轮询进度/任务失败/提交失败/超时/取消/已交过不重交；
// - 页面层：主入口+行播放钮+会员标、等待态实显与取消、
//   秒下就绪页内起播网盘那一份。
// 全部注入假件，不碰真库真网真 115。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_http.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_javdb_api.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_still_capture.dart';
import 'package:fqapp/actress/actress_work_detail_page.dart';
import 'package:fqapp/cloud_drive/auto_offline.dart';
import 'package:fqapp/cloud_drive/cloud_115_offline.dart';
import 'package:fqapp/cloud_drive/cloud_providers.dart';
import 'package:fqapp/cloud_drive/magnet_offline.dart';
import 'package:fqapp/cloud_drive/magnet_play.dart';

import 'support/controlled_player.dart';

const _magnetA =
    'magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _magnetB =
    'magnet:?xt=urn:btih:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _hashA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Pan115OfflineTask _task({
  String hash = '',
  String name = 'SIGL-020.mp4',
  double percent = 0,
  bool done = false,
  bool failed = false,
}) => Pan115OfflineTask(
  infoHash: hash,
  name: name,
  percent: percent,
  done: done,
  failed: failed,
);

/// 磁力播放假件一组：计数 + 可配结局。
class _PlayDeps {
  bool loggedIn = true;
  int driveHitOnCall = -1; // 第几次 findInDrive 起返回 hit；-1 永不
  var findCalls = 0;
  bool wasSubmittedResult = false;
  bool taskExistsResult = false;
  Pan115SubmitResult submitResult = const Pan115SubmitResult(ok: true);
  Object? submitError;
  final submittedUrls = <String>[];
  List<Pan115OfflineTask> Function(int call) tasksFor = (_) => const [];
  var listCalls = 0;

  static const hit = (
    url: 'https://cdn115.test/sigl-020.m3u8',
    headers: <String, String>{},
  );

  MagnetPlayWaiter build({
    Duration pollInterval = const Duration(milliseconds: 1),
    Duration maxWait = const Duration(seconds: 30),
    Future<void> Function(Duration)? delay,
  }) {
    return MagnetPlayWaiter(
      isLoggedIn: () async => loggedIn,
      findInDrive: (code) async {
        findCalls++;
        if (driveHitOnCall >= 0 && findCalls >= driveHitOnCall) return hit;
        return null;
      },
      wasSubmitted: (fp) async => wasSubmittedResult,
      markSubmitted: (fp) async {},
      taskExists: (code, hash) async => taskExistsResult,
      submit: (url) async {
        if (submitError != null) throw submitError!;
        submittedUrls.add(url);
        return submitResult;
      },
      listTasks: () async => tasksFor(++listCalls),
      pollInterval: pollInterval,
      maxWait: maxWait,
      delay: delay ?? (_) async {},
    );
  }
}

void main() {
  group('pan115IsVip 会员判定', () {
    const now = 1700000000;
    test('永久 VIP 恒真', () {
      expect(
        pan115IsVip(
          const Pan115AccountInfo(userId: '1', vipForever: true),
          nowSeconds: now,
        ),
        isTrue,
      );
    });
    test('到期在未来是在期会员', () {
      expect(
        pan115IsVip(
          const Pan115AccountInfo(userId: '1', vipExpireSeconds: now + 100),
          nowSeconds: now,
        ),
        isTrue,
      );
    });
    test('到期已过不是会员', () {
      expect(
        pan115IsVip(
          const Pan115AccountInfo(userId: '1', vipExpireSeconds: now - 100),
          nowSeconds: now,
        ),
        isFalse,
      );
    });
    test('到期为 0（没拿到/不是 VIP）不臆造', () {
      expect(
        pan115IsVip(const Pan115AccountInfo(userId: '1'), nowSeconds: now),
        isFalse,
      );
    });
  });

  group('离线任务 failed 态解析', () {
    test('status -1 是失败、status 2 是完成', () {
      final tasks = pan115TasksOf(
        jsonEncode({
          'tasks': [
            {'info_hash': 'ABC', 'name': 'X-1.mp4', 'percentDone': 0, 'status': -1},
            {'info_hash': 'DEF', 'name': 'X-2.mp4', 'percentDone': 100, 'status': 2},
          ],
        }),
      );
      expect(tasks.length, 2);
      expect(tasks[0].failed, isTrue);
      expect(tasks[0].done, isFalse);
      expect(tasks[1].done, isTrue);
      expect(tasks[1].failed, isFalse);
    });
  });

  group('pickBestMagnetPlayLink 优选', () {
    test('磁力优先于直链（与自动离线的直链优先相反）', () {
      final best = pickBestMagnetPlayLink([
        (name: 'X-001.mp4', url: 'https://dl.test/X-001.mp4'),
        (name: 'X-001.mp4', url: _magnetA),
      ]);
      expect(best?.url, _magnetA);
    });
    test('磁力之间：正片文件名优先', () {
      final best = pickBestMagnetPlayLink([
        (name: 'SIGL-020.torrent', url: _magnetA),
        (name: 'SIGL-020.mp4', url: _magnetB),
      ]);
      expect(best?.url, _magnetB);
    });
    test('没有磁力时退回直链优选', () {
      final best = pickBestMagnetPlayLink([
        (name: 'X-001.mp4', url: 'https://dl.test/X-001.mp4'),
      ]);
      expect(best?.url, 'https://dl.test/X-001.mp4');
    });
    test('只有 .torrent 文件地址回 null（不假提交）', () {
      expect(
        pickBestMagnetPlayLink([
          (name: 'X-001.torrent', url: 'https://dl.test/X-001.torrent'),
        ]),
        isNull,
      );
      expect(pickBestMagnetPlayLink(const []), isNull);
    });
  });

  group('MagnetPlayWaiter 状态机', () {
    test('未登入：notLoggedIn、零提交零轮询', () async {
      final deps = _PlayDeps()..loggedIn = false;
      final result = await deps.build().run(code: 'SIGL-020', url: _magnetA);
      expect(result.phase, MagnetPlayPhase.notLoggedIn);
      expect(deps.submittedUrls, isEmpty);
      expect(deps.listCalls, 0);
    });

    test('盘里已有：直接 ready（instant）、零提交', () async {
      final deps = _PlayDeps()..driveHitOnCall = 1;
      final result = await deps.build().run(code: 'SIGL-020', url: _magnetA);
      expect(result.phase, MagnetPlayPhase.ready);
      expect(result.instant, isTrue);
      expect(result.hit?.url, _PlayDeps.hit.url);
      expect(result.message, contains('已有'));
      expect(deps.submittedUrls, isEmpty);
    });

    test('秒下：提交后首轮任务即完成 → ready 且 instant', () async {
      final deps = _PlayDeps()
        ..driveHitOnCall = 2
        ..submitResult = const Pan115SubmitResult(ok: true, infoHash: _hashA)
        ..tasksFor = (_) => [_task(hash: _hashA, percent: 1, done: true)];
      final result = await deps.build().run(code: 'SIGL-020', url: _magnetA);
      expect(result.phase, MagnetPlayPhase.ready);
      expect(result.instant, isTrue);
      expect(result.message, contains('秒下'));
      expect(deps.submittedUrls, [_magnetA]);
    });

    test('轮询进度：40% → 85% → 完成，ready 非 instant', () async {
      final deps = _PlayDeps()
        ..driveHitOnCall = 2
        ..tasksFor = (call) => switch (call) {
          1 => [_task(percent: 0.4)],
          2 => [_task(percent: 0.85)],
          _ => [_task(percent: 1, done: true)],
        };
      final seen = <MagnetPlayProgress>[];
      final result = await deps.build().run(
        code: 'SIGL-020',
        url: _magnetA,
        onProgress: seen.add,
      );
      expect(result.phase, MagnetPlayPhase.ready);
      expect(result.instant, isFalse);
      expect(result.message, contains('离线完成'));
      expect(
        seen.any((p) => p.message == '离线中 40%' && p.percent == 0.4),
        isTrue,
      );
      expect(seen.any((p) => p.message == '离线中 85%'), isTrue);
    });

    test('任务失败（状态 -1）：立刻 failed 收尾，不干等', () async {
      final deps = _PlayDeps()
        ..tasksFor = (_) => [_task(failed: true)];
      final result = await deps.build().run(code: 'SIGL-020', url: _magnetA);
      expect(result.phase, MagnetPlayPhase.failed);
      expect(result.message, contains('失败'));
      expect(deps.listCalls, 1);
    });

    test('提交回失败：failed + 通用中文文案', () async {
      final deps = _PlayDeps()
        ..submitResult = const Pan115SubmitResult(ok: false);
      final result = await deps.build().run(code: 'SIGL-020', url: _magnetA);
      expect(result.phase, MagnetPlayPhase.failed);
      expect(result.message, MagnetOfflineSubmitter.genericFailureMessage);
      expect(deps.listCalls, 0);
    });

    test('提交抛中文异常：失败文案带原因', () async {
      final deps = _PlayDeps()
        ..submitError = CloudDriveException('离线配额已用完');
      final result = await deps.build().run(code: 'SIGL-020', url: _magnetA);
      expect(result.phase, MagnetPlayPhase.failed);
      expect(result.message, '提交失败：离线配额已用完');
    });

    test('超时：任务一直下不到完 → timedOut', () async {
      final deps = _PlayDeps()
        ..tasksFor = (_) => [_task(percent: 0.2)];
      final result = await deps
          .build(maxWait: const Duration(milliseconds: 40))
          .run(code: 'SIGL-020', url: _magnetA);
      expect(result.phase, MagnetPlayPhase.timedOut);
      expect(result.message, contains('超时'));
    });

    test('取消：等待中 cancel → cancelled 收尾', () async {
      final deps = _PlayDeps()
        ..tasksFor = (_) => [_task(percent: 0.5)];
      final waiter = deps.build(
        delay: (d) => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      final waitingSeen = Completer<void>();
      final future = waiter.run(
        code: 'SIGL-020',
        url: _magnetA,
        onProgress: (p) {
          if (p.phase == MagnetPlayPhase.waiting && !waitingSeen.isCompleted) {
            waitingSeen.complete();
          }
        },
      );
      await waitingSeen.future;
      waiter.cancel();
      final result = await future;
      expect(result.phase, MagnetPlayPhase.cancelled);
    });

    test('已交过（指纹命中）：不重交、直接轮询到完成', () async {
      final deps = _PlayDeps()
        ..wasSubmittedResult = true
        ..driveHitOnCall = 2
        ..tasksFor = (_) => [_task(percent: 1, done: true)];
      final result = await deps.build().run(code: 'SIGL-020', url: _magnetA);
      expect(result.phase, MagnetPlayPhase.ready);
      expect(deps.submittedUrls, isEmpty);
    });

    test('任务靠番号名匹配（提交没回 infoHash 也认）', () async {
      final deps = _PlayDeps()
        ..driveHitOnCall = 2
        ..tasksFor = (_) => [_task(name: 'SIGL-020.mp4', percent: 1, done: true)];
      final result = await deps.build().run(code: 'SIGL-020', url: _magnetA);
      expect(result.phase, MagnetPlayPhase.ready);
    });
  });

  group('详情页（widget）', () {
    late LocalStore store;
    late Directory cacheDir;

    setUp(() {
      store = LocalStore();
      cacheDir = Directory.systemTemp.createTempSync('actress_magnet_test_');
    });
    tearDown(() {
      store.dispose();
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    });

    void tallView(WidgetTester tester) {
      tester.view.physicalSize = const Size(420, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    ActressWorkDetailPage page({
      MagnetPlayWaiter? magnetPlay,
      Future<bool?> Function()? vipProbe,
      ControlledNativePlayer? player,
      Key? key,
    }) {
      return ActressWorkDetailPage.local(
        key: key,
        vodId: 'sigl-020',
        fallback: ActressLibraryDbFallback(
          pathResolver: () async => '/fake/女优库.db',
          opener: (path) async => _FakeDb().query,
        ),
        repository: _FakeRepository(),
        javdbClient: JavdbApiClient(fetch: _javdbFetchMagnets),
        onlineFetch: _fetchDead,
        // 自动离线关掉：本组只验磁力播放，不让它抢提交计数。
        autoOffline: ActressAutoOffline(
          isEnabled: () async => false,
          isLoggedIn: () async => true,
          wasSubmitted: (fp) async => false,
          markSubmitted: (fp) async {},
          taskExists: (code, hash) async => false,
          driveHasFile: (code) async => false,
          submit: (url) async => const Pan115SubmitResult(ok: true),
        ),
        magnetOffline: MagnetOfflineSubmitter(
          isLoggedIn: () async => true,
          submit: (url) async => const Pan115SubmitResult(ok: true),
        ),
        magnetPlay: magnetPlay,
        pan115VipProbe: vipProbe,
        stillCache: ActressStillCache(directoryOf: () async => cacheDir),
        probeFetch: _probeOk,
        playerFactory: () => player ?? ControlledNativePlayer(),
        playUrlPrep: (url, headers) async => url,
      );
    }

    testWidgets('下载区有磁力播放主入口 + 每行播放钮', (tester) async {
      tallView(tester);
      await tester.pumpWidget(
        MaterialApp(home: page(magnetPlay: _PlayDeps().build())),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('work-detail-magnet-play'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text('磁力播放'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('work-detail-magnet-play-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('work-detail-magnet-play-1')),
        findsOneWidget,
      );
    });

    testWidgets('会员标：探针确认会员才贴，非会员不贴', (tester) async {
      tallView(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: page(
            magnetPlay: _PlayDeps().build(),
            vipProbe: () async => true,
          ),
        ),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('work-detail-pan115-vip'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text('115 网盘 · 会员'), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          home: page(
            key: const ValueKey('vip-false-page'),
            magnetPlay: _PlayDeps().build(),
            vipProbe: () async => false,
          ),
        ),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('work-detail-magnet-play'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const ValueKey('work-detail-pan115-vip')),
        findsNothing,
      );
    });

    testWidgets('秒下直接播：点主入口 → 就绪后页内起播网盘那一份', (
      tester,
    ) async {
      tallView(tester);
      final player = ControlledNativePlayer();
      final deps = _PlayDeps()
        ..driveHitOnCall = 2
        ..tasksFor = (_) => [_task(percent: 1, done: true)];
      await tester.pumpWidget(
        MaterialApp(home: page(magnetPlay: deps.build(), player: player)),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('work-detail-magnet-play'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('work-detail-magnet-play')));
      await _until(
        tester,
        () => player.calls.any(
          (c) => c == 'create:https://cdn115.test/sigl-020.m3u8',
        ),
      );
      expect(deps.submittedUrls.length, 1);
      expect(deps.submittedUrls.single, startsWith(_magnetB)); // 优选 .mp4 名那条
      expect(
        find.byKey(const ValueKey('work-detail-magnet-wait')),
        findsNothing,
      );
    });

    testWidgets('行播放钮播指定那条磁力', (tester) async {
      tallView(tester);
      final player = ControlledNativePlayer();
      final deps = _PlayDeps()
        ..driveHitOnCall = 2
        ..tasksFor = (_) => [_task(percent: 1, done: true)];
      await tester.pumpWidget(
        MaterialApp(home: page(magnetPlay: deps.build(), player: player)),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('work-detail-magnet-play-0'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(
        find.byKey(const ValueKey('work-detail-magnet-play-0')),
      );
      await _until(
        tester,
        () => player.calls.any((c) => c.startsWith('create:')),
      );
      expect(deps.submittedUrls.length, 1);
      expect(deps.submittedUrls.single, startsWith(_magnetA)); // 第 0 行是 aaaa… 那条
    });

    testWidgets('等待态实显 + 取消等待回原样', (tester) async {
      tallView(tester);
      final deps = _PlayDeps()
        ..tasksFor = (_) => [_task(percent: 0.3)];
      await tester.pumpWidget(
        MaterialApp(
          home: page(
            magnetPlay: deps.build(
              delay: (d) => Future<void>.delayed(d),
            ),
          ),
        ),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('work-detail-magnet-play'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('work-detail-magnet-play')));
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('work-detail-magnet-wait'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text('离线中 30%'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('work-detail-magnet-play-cancel')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('work-detail-magnet-play-cancel')),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const ValueKey('work-detail-magnet-wait')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('work-detail-poster-play')),
        findsOneWidget,
      );
      // 放行被取消轮询的挂起延时，别让假时钟留尾。
      await tester.pump(const Duration(seconds: 5));
    });
  });
}

// ---------------------------------------------------------------------------
// 假件（与 actress_drive_race_test 同形）
// ---------------------------------------------------------------------------

class _FakeDb {
  final tables = {
    'videos',
    'video_play_urls',
    'video_actress',
    'actresses',
    'video_tag',
    'video_ranking',
    'index_categories',
  };

  Map<String, Object?> _row(String id, String title) => {
    'vodId': id,
    'title': title,
    'pic': 'https://img.test/poster.jpg',
    'play': 'https://v.hersav.me/abc/abc.m3u8',
    'playAlt': '',
    'date': '2024-05-06',
    'typeName': '剧情',
    'actress': '演员甲',
  };

  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? args,
  ]) async {
    if (sql.contains('sqlite_master')) {
      return [for (final t in tables) {'name': t}];
    }
    if (sql.contains('PRAGMA table_info(actresses)')) {
      return [
        {'name': 'name'},
        {'name': 'avatar'},
      ];
    }
    if (sql.contains('PRAGMA table_info(videos)')) {
      return [
        {'name': 'content'},
      ];
    }
    if (sql.contains('PRAGMA')) return [];
    if (sql.contains('a.avatar AS avatar')) {
      return [
        {'name': '演员甲', 'avatar': 'https://img.test/av-a.jpg'},
        {'name': '男演员乙', 'avatar': ''},
      ];
    }
    if (sql.contains('content AS content')) {
      return [
        {'content': '这是 SIGL-020 的简介内容。'},
      ];
    }
    if (sql.contains('FROM video_play_urls')) {
      return [
        {'play_url': 'https://v.hersav.me/abc/abc.m3u8'},
      ];
    }
    if (sql.contains('SELECT a.name AS name FROM video_actress')) {
      return [
        {'name': '演员甲'},
        {'name': '男演员乙'},
      ];
    }
    if (sql.contains('SELECT tag_name AS name FROM video_tag')) {
      return [
        {'name': '剧情'},
      ];
    }
    if (sql.contains('FROM videos v')) {
      if (sql.contains('WHERE v.vod_id = ?')) {
        return [_row('sigl-020', 'SIGL-020 样本标题')];
      }
      return [_row('mida-002', 'MIDA-002 相关作品')];
    }
    return [];
  }
}

class _FakeRepository extends AppRepository {
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
  Future<CatalogPage> searchAcross(List<String> sources, String query) async =>
      CatalogPage(const []);

  @override
  Future<void> searchAcrossProgressive(
    List<String> sources,
    String query, {
    required void Function(String source, List<Drama> items) onSite,
    bool Function()? shouldStop,
  }) async {}

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => drama.cover;

  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail(drama, [
    Episode({'id': 'https://example.test/whos.m3u8', 'title': '正片'}, 1),
  ]);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async => const PlaybackPlan(url: 'https://example.test/whos.m3u8');
}

Future<String> _javdbFetchMagnets(String url) async {
  if (url.contains('/magnets')) {
    return jsonEncode({
      'success': true,
      'data': {
        'magnets': [
          {
            'hash': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            'name': 'SIGL-020.torrent',
            'size': 5390,
            'created_at': '2026-11-26',
            'hd': true,
          },
          {
            'hash': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            'name': 'SIGL-020.mp4',
            'size': 5390,
            'created_at': '2026-11-26',
            'hd': true,
          },
        ],
      },
    });
  }
  if (url.contains('api/v4/movies/')) {
    return jsonEncode({
      'success': true,
      'data': {
        'movie': {
          'id': 'm1',
          'number': 'SIGL-020',
          'score': '8.6',
          'score_count': 321,
          'preview_images': [
            {'large_url': 'https://img.test/jdb-still.jpg'},
          ],
        },
      },
    });
  }
  return jsonEncode({
    'success': true,
    'data': {
      'movies': [
        {
          'id': 'm1',
          'number': 'SIGL-020',
          'title': 'SIGL-020 样本标题',
          'cover_url': 'https://img.test/poster.jpg',
        },
      ],
    },
  });
}

Future<FeedProbeResponse> _probeOk(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async {
  return FeedProbeResponse(
    statusCode: 200,
    headers: const {},
    headBytes: utf8.encode('#EXTM3U\n#EXT-X-VERSION:3\n'),
  );
}

Future<String> _fetchDead(String url, Map<String, String> headers) async =>
    throw StateError('no network in test');

Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  int rounds = 50,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}
