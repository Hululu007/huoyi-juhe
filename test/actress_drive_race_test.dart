// 详情页两活新测（2026-11-27）：
// 活一改令——打开详情页自动离线：链接形态分类/优选一条/
// 查重三道闸（指纹/任务/网盘成品）/未登入静默/开关关不
// 跑/失败给中文原因；页面层：开页自动交、小字状态行、已
// 提交行标、不弹窗。
// 活二——网盘加入竞速成三池：找片器番号匹配变体/未登入
// 弃池/超时弃池；页面层：网盘命中且本地线死时网盘线赢、
// 网盘未命中时本地线照旧赢。
// 全部注入假件，不碰真库真网真 115。
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
import 'package:fqapp/cloud_drive/cloud_drive_types.dart';
import 'package:fqapp/cloud_drive/cloud_providers.dart';
import 'package:fqapp/cloud_drive/drive_code_play.dart';

import 'support/controlled_player.dart';

// ---------------------------------------------------------------------------
// 假件（与 actress_work_detail_page_test 同形）
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

/// JavDB 假取数：磁力两条——一条 .torrent 名、一条 .mp4 名
/// （优选应挑 .mp4 名那条）。
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

/// 只认 115 CDN 的验活：本地线与在线线全死、网盘线活。
Future<FeedProbeResponse> _probeDriveOnly(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async {
  if (url.contains('cdn115.test')) return _probeOk(url, headers, timeout);
  return const FeedProbeResponse(
    statusCode: 404,
    headers: {},
    headBytes: [],
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

/// 自动离线假件一组：计数 + 可配结局。
class _FakeAutoDeps {
  bool enabled = true;
  bool loggedIn = true;
  bool taskExistsResult = false;
  bool driveHasResult = false;
  Object? submitError;
  bool submitOk = true;
  final submittedFingerprints = <String>{};
  final submittedUrls = <String>[];
  var wasSubmittedCalls = 0;

  ActressAutoOffline build() {
    return ActressAutoOffline(
      isEnabled: () async => enabled,
      isLoggedIn: () async => loggedIn,
      wasSubmitted: (fp) async {
        wasSubmittedCalls++;
        return submittedFingerprints.contains(fp);
      },
      markSubmitted: (fp) async => submittedFingerprints.add(fp),
      taskExists: (code, hash) async => taskExistsResult,
      driveHasFile: (code) async => driveHasResult,
      submit: (url) async {
        if (submitError != null) throw submitError!;
        submittedUrls.add(url);
        return Pan115SubmitResult(ok: submitOk);
      },
    );
  }
}

const _magnetA =
    'magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _magnetB =
    'magnet:?xt=urn:btih:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  group('链接形态分类', () {
    test('磁力/电驴/直链/.torrent/其它各归其类', () {
      expect(offlineLinkKindOf(_magnetA), OfflineLinkKind.magnet);
      expect(
        offlineLinkKindOf('ed2k://|file|x.mp4|123|ABC|/'),
        OfflineLinkKind.ed2k,
      );
      expect(
        offlineLinkKindOf('https://dl.test/NACT-125.mp4'),
        OfflineLinkKind.direct,
      );
      expect(
        offlineLinkKindOf('https://dl.test/NACT-125.torrent'),
        OfflineLinkKind.torrent,
      );
      expect(
        offlineLinkKindOf('https://dl.test/get?f=NACT-125.torrent'),
        OfflineLinkKind.direct,
        reason: '查询串里的 .torrent 不算种子文件地址，看路径',
      );
      expect(offlineLinkKindOf('thunder://QUJD'), OfflineLinkKind.other);
      expect(offlineLinkKindOf(''), OfflineLinkKind.other);
    });

    test('可提交形态只有直链/磁力/电驴', () {
      expect(offlineLinkSubmittable(OfflineLinkKind.direct), isTrue);
      expect(offlineLinkSubmittable(OfflineLinkKind.magnet), isTrue);
      expect(offlineLinkSubmittable(OfflineLinkKind.ed2k), isTrue);
      expect(offlineLinkSubmittable(OfflineLinkKind.torrent), isFalse);
      expect(offlineLinkSubmittable(OfflineLinkKind.other), isFalse);
    });
  });

  group('优选一条', () {
    test('直链优先于磁力', () {
      final best = pickBestOfflineLink([
        (name: 'X-001.mp4', url: _magnetA),
        (name: 'X-001.mp4', url: 'https://dl.test/X-001.mp4'),
      ]);
      expect(best?.url, 'https://dl.test/X-001.mp4');
    });

    test('磁力之间：正片文件名优先于 .torrent 名', () {
      final best = pickBestOfflineLink([
        (name: 'SIGL-020.torrent', url: _magnetA),
        (name: 'SIGL-020.mp4', url: _magnetB),
      ]);
      expect(best?.url, _magnetB);
    });

    test('只有 .torrent 文件地址时无可交（回 null，不假提交）', () {
      final best = pickBestOfflineLink([
        (name: 'X-001.torrent', url: 'https://dl.test/X-001.torrent'),
      ]);
      expect(best, isNull);
    });

    test('空列表回 null', () {
      expect(pickBestOfflineLink(const []), isNull);
    });
  });

  group('ActressAutoOffline 编排', () {
    const links = [
      (name: 'SIGL-020.torrent', url: _magnetA),
      (name: 'SIGL-020.mp4', url: _magnetB),
    ];

    test('正常路：只交一条最优（.mp4 名磁力），并记指纹', () async {
      final deps = _FakeAutoDeps();
      final result = await deps.build().run(code: 'SIGL-020', links: links);
      expect(result.outcome, AutoOfflineOutcome.submitted);
      expect(result.message, '已自动提交到 115 离线下载');
      expect(deps.submittedUrls, [_magnetB]);
      expect(
        deps.submittedFingerprints,
        contains(offlineLinkFingerprint(_magnetB)),
      );
    });

    test('重复打开不重交：指纹命中直接跳过、零提交', () async {
      final deps = _FakeAutoDeps();
      final runner = deps.build();
      final first = await runner.run(code: 'SIGL-020', links: links);
      expect(first.outcome, AutoOfflineOutcome.submitted);
      final second = await runner.run(code: 'SIGL-020', links: links);
      expect(second.outcome, AutoOfflineOutcome.alreadySubmitted);
      expect(second.message, '已提交过离线下载');
      expect(deps.submittedUrls.length, 1);
    });

    test('离线任务里已有：跳过不交', () async {
      final deps = _FakeAutoDeps()..taskExistsResult = true;
      final result = await deps.build().run(code: 'SIGL-020', links: links);
      expect(result.outcome, AutoOfflineOutcome.alreadyInTasks);
      expect(result.message, '115 离线任务里已有这部片');
      expect(deps.submittedUrls, isEmpty);
    });

    test('网盘里已有成品：跳过不交', () async {
      final deps = _FakeAutoDeps()..driveHasResult = true;
      final result = await deps.build().run(code: 'SIGL-020', links: links);
      expect(result.outcome, AutoOfflineOutcome.alreadyInDrive);
      expect(result.message, '115 网盘里已有这部片');
      expect(deps.submittedUrls, isEmpty);
    });

    test('未登入：静默跳过（只回小字文案）、零提交', () async {
      final deps = _FakeAutoDeps()..loggedIn = false;
      final result = await deps.build().run(code: 'SIGL-020', links: links);
      expect(result.outcome, AutoOfflineOutcome.notLoggedIn);
      expect(result.message, '未登录 115 网盘，自动离线已跳过');
      expect(deps.submittedUrls, isEmpty);
    });

    test('开关关：不跑后续任何一步', () async {
      final deps = _FakeAutoDeps()..enabled = false;
      final result = await deps.build().run(code: 'SIGL-020', links: links);
      expect(result.outcome, AutoOfflineOutcome.disabled);
      expect(result.message, isEmpty);
      expect(deps.submittedUrls, isEmpty);
      expect(deps.wasSubmittedCalls, 0);
    });

    test('只有 .torrent 地址：回 unsupported + 中文说明、零提交', () async {
      final deps = _FakeAutoDeps();
      final result = await deps.build().run(
        code: 'X-001',
        links: const [
          (name: 'X-001.torrent', url: 'https://dl.test/X-001.torrent'),
        ],
      );
      expect(result.outcome, AutoOfflineOutcome.unsupported);
      expect(result.message, '这类下载链接暂不支持自动离线');
      expect(deps.submittedUrls, isEmpty);
    });

    test('提交抛中文异常：失败文案带原因，不糊原文', () async {
      final deps = _FakeAutoDeps()
        ..submitError = CloudDriveException('离线配额已用完');
      final result = await deps.build().run(code: 'SIGL-020', links: links);
      expect(result.outcome, AutoOfflineOutcome.failed);
      expect(result.message, '提交失败：离线配额已用完');
    });

    test('查重抛错不挡路：当没有、照常提交', () async {
      final runner = ActressAutoOffline(
        isEnabled: () async => true,
        isLoggedIn: () async => true,
        wasSubmitted: (fp) async => false,
        markSubmitted: (fp) async {},
        taskExists: (code, hash) async => throw StateError('boom'),
        driveHasFile: (code) async => throw StateError('boom'),
        submit: (url) async => const Pan115SubmitResult(ok: true),
      );
      final result = await runner.run(code: 'SIGL-020', links: links);
      expect(result.outcome, AutoOfflineOutcome.submitted);
    });

    test('没链接：noLinks、零提交', () async {
      final deps = _FakeAutoDeps();
      final result = await deps.build().run(code: 'SIGL-020', links: const []);
      expect(result.outcome, AutoOfflineOutcome.noLinks);
      expect(deps.submittedUrls, isEmpty);
    });
  });

  group('DriveCodePlayFinder 找片', () {
    DriveCodePlayFinder finder({
      bool loggedIn = true,
      List<CloudDriveFile> files = const [],
      Duration timeout = const Duration(seconds: 12),
      Future<List<CloudDriveFile>> Function(String)? searchFn,
    }) {
      return DriveCodePlayFinder(
        isLoggedIn: () async => loggedIn,
        search: searchFn ?? (keyword) async => files,
        directLink: (file) async => CloudDirectLink(
          url: 'https://cdn115.test/${file.id}.m3u8',
          headers: const {'User-Agent': '115'},
        ),
        searchTimeout: timeout,
      );
    }

    CloudDriveFile video(String id, String name) => CloudDriveFile(
      id: id,
      name: name,
      isFolder: false,
      kind: CloudFileKind.video,
    );

    test('番号命名变体都命中：无连字符/方括号前缀/下划线', () async {
      for (final name in [
        'nact125.mp4',
        '[javdb.com] NACT-125.mkv',
        'NACT_125.mp4',
        'NACT-125.mp4',
      ]) {
        final hit = await finder(files: [video('f1', name)]).find('NACT-125');
        expect(hit?.url, 'https://cdn115.test/f1.m3u8', reason: name);
        expect(hit?.headers, {'User-Agent': '115'});
      }
    });

    test('离线任务刚下完的命名（带发布组前后缀）命中', () async {
      final hit = await finder(
        files: [video('f9', '[FHD] nact-125-C.mp4')],
      ).find('NACT-125');
      // 提码档命中 NACT-125 本体（-C 是分段后缀，提码取主番号）。
      expect(hit?.url, 'https://cdn115.test/f9.m3u8');
    });

    test('别的番号不冒充：搜到异番号文件回 null', () async {
      final hit = await finder(
        files: [video('f2', 'MIDA-002.mp4')],
      ).find('NACT-125');
      expect(hit, isNull);
    });

    test('文件夹与非视频不算命中', () async {
      final hit = await finder(
        files: [
          const CloudDriveFile(
            id: 'd1',
            name: 'NACT-125',
            isFolder: true,
            kind: CloudFileKind.folder,
          ),
          const CloudDriveFile(
            id: 'f3',
            name: 'NACT-125.srt',
            isFolder: false,
            kind: CloudFileKind.other,
          ),
        ],
      ).find('NACT-125');
      expect(hit, isNull);
    });

    test('未登入弃池：不搜、回 null', () async {
      var searchCalls = 0;
      final hit = await finder(
        loggedIn: false,
        searchFn: (keyword) async {
          searchCalls++;
          return [video('f1', 'NACT-125.mp4')];
        },
      ).find('NACT-125');
      expect(hit, isNull);
      expect(searchCalls, 0);
    });

    test('搜索超时弃池：回 null 不挂住', () async {
      final hit = await finder(
        timeout: const Duration(milliseconds: 100),
        searchFn: (keyword) => Future<List<CloudDriveFile>>.delayed(
          const Duration(milliseconds: 600),
          () => [video('f1', 'NACT-125.mp4')],
        ),
      ).find('NACT-125');
      expect(hit, isNull);
    });

    test('搜索抛错弃池：回 null', () async {
      final hit = await finder(
        searchFn: (keyword) async => throw StateError('boom'),
      ).find('NACT-125');
      expect(hit, isNull);
    });
  });

  group('详情页（widget）', () {
    late LocalStore store;
    late Directory cacheDir;

    setUp(() {
      store = LocalStore();
      cacheDir = Directory.systemTemp.createTempSync('actress_race_test_');
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
      ActressAutoOffline? autoOffline,
      DriveCodePlayFinder? drivePlayFinder,
      FeedProbeFetch? probeFetch,
      ControlledNativePlayer? player,
    }) {
      return ActressWorkDetailPage.local(
        vodId: 'sigl-020',
        fallback: ActressLibraryDbFallback(
          pathResolver: () async => '/fake/女优库.db',
          opener: (path) async => _FakeDb().query,
        ),
        repository: _FakeRepository(),
        javdbClient: JavdbApiClient(fetch: _javdbFetchMagnets),
        onlineFetch: _fetchDead,
        autoOffline: autoOffline,
        drivePlayFinder: drivePlayFinder,
        stillCache: ActressStillCache(directoryOf: () async => cacheDir),
        probeFetch: probeFetch ?? _probeOk,
        playerFactory: () => player ?? ControlledNativePlayer(),
        playUrlPrep: (url, headers) async => url,
      );
    }

    testWidgets('开页自动离线：只交最优一条、小字状态行 + 行上已提交标', (
      tester,
    ) async {
      tallView(tester);
      final deps = _FakeAutoDeps();
      await tester.pumpWidget(
        MaterialApp(home: page(autoOffline: deps.build())),
      );
      await _until(
        tester,
        () => find.text('已自动提交到 115 离线下载').evaluate().isNotEmpty,
      );
      // 只交一条：优选 .mp4 名磁力（bbbb…），不交 .torrent 名那条。
      expect(deps.submittedUrls.length, 1);
      expect(
        deps.submittedUrls.single,
        startsWith('magnet:?xt=urn:btih:bbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
      );
      // 状态小字在下载区里（key 定位），不是弹窗/SnackBar。
      expect(
        find.byKey(const ValueKey('work-detail-auto-offline-note')),
        findsOneWidget,
      );
      // 交的那行（下标 1）打「已提交」标，另一行不打。
      expect(
        find.byKey(const ValueKey('work-detail-magnet-submitted-1')),
        findsOneWidget,
      );
      expect(find.text('已提交'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('work-detail-magnet-submitted-0')),
        findsNothing,
      );
      // 不弹窗打断看页。
      expect(find.text('去登录'), findsNothing);
    });

    testWidgets('未登入：静默跳过只留小字，不弹引导窗', (tester) async {
      tallView(tester);
      final deps = _FakeAutoDeps()..loggedIn = false;
      await tester.pumpWidget(
        MaterialApp(home: page(autoOffline: deps.build())),
      );
      await _until(
        tester,
        () => find.text('未登录 115 网盘，自动离线已跳过').evaluate().isNotEmpty,
      );
      expect(deps.submittedUrls, isEmpty);
      expect(find.text('未登录 115 网盘'), findsNothing); // 弹窗标题不出
      expect(find.text('去登录'), findsNothing);
    });

    testWidgets('开关关：开页不自动交、无状态小字', (tester) async {
      tallView(tester);
      final deps = _FakeAutoDeps()..enabled = false;
      await tester.pumpWidget(
        MaterialApp(home: page(autoOffline: deps.build())),
      );
      // 等下载区出现并稳定一轮，确认自动离线没跑。
      await _until(tester, () => find.text('下载链接').evaluate().isNotEmpty);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(deps.submittedUrls, isEmpty);
      expect(
        find.byKey(const ValueKey('work-detail-auto-offline-note')),
        findsNothing,
      );
    });

    testWidgets('指纹已有：不重交、小字报已提交过', (tester) async {
      tallView(tester);
      final deps = _FakeAutoDeps();
      deps.submittedFingerprints.add(offlineLinkFingerprint(_magnetB));
      await tester.pumpWidget(
        MaterialApp(home: page(autoOffline: deps.build())),
      );
      await _until(
        tester,
        () => find.text('已提交过离线下载').evaluate().isNotEmpty,
      );
      expect(deps.submittedUrls, isEmpty);
    });

    testWidgets('三池竞速：本地线死、网盘命中 → 网盘线赢', (tester) async {
      tallView(tester);
      final player = ControlledNativePlayer();
      final driveFinder = DriveCodePlayFinder(
        isLoggedIn: () async => true,
        search: (keyword) async => [
          const CloudDriveFile(
            id: 'f1',
            name: 'SIGL-020.mp4',
            isFolder: false,
            kind: CloudFileKind.video,
          ),
        ],
        directLink: (file) async =>
            const CloudDirectLink(url: 'https://cdn115.test/sigl-020.m3u8'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: page(
            drivePlayFinder: driveFinder,
            probeFetch: _probeDriveOnly,
            player: player,
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
      await _until(
        tester,
        () => player.calls.any(
          (c) => c == 'create:https://cdn115.test/sigl-020.m3u8',
        ),
      );
      expect(player.calls, contains('create:https://cdn115.test/sigl-020.m3u8'));
    });

    testWidgets('三池竞速：网盘未命中 → 本地线照旧赢（不拖慢）', (tester) async {
      tallView(tester);
      final player = ControlledNativePlayer();
      final driveFinder = DriveCodePlayFinder(
        isLoggedIn: () async => true,
        search: (keyword) async => const [],
        directLink: (file) async =>
            const CloudDirectLink(url: 'https://cdn115.test/none.m3u8'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: page(
            drivePlayFinder: driveFinder,
            probeFetch: _probeOk,
            player: player,
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
      await _until(
        tester,
        () => player.calls.any(
          (c) => c == 'create:https://v.hersav.me/abc/abc.m3u8',
        ),
      );
      expect(player.calls, contains('create:https://v.hersav.me/abc/abc.m3u8'));
    });
  });
}
