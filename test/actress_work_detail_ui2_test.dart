// 作品详情页第二棒测试（2026-11-27）：AvPlay 版式补齐——
// 大标题旁「翻译」切换（有/无译名两态）、下载链接区（有磁
// 力才出、字段形态、点按复制；无数据整区不出）、剧照截帧
// 兜底（JavDB 无剧照 → 假截帧器回填 + 缓存命中不重截）。
// 全部注入假件，不碰真库真网。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_http.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_javdb_api.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_still_capture.dart';
import 'package:fqapp/actress/actress_work_detail_page.dart';
import 'package:fqapp/cloud_drive/cloud_115_offline.dart';
import 'package:fqapp/cloud_drive/cloud_providers.dart';
import 'package:fqapp/cloud_drive/magnet_offline.dart';

import 'support/controlled_player.dart';

/// 假库（与 actress_work_detail_page_test 同形）：detail 回
/// SIGL-020 完整样本；works 回一部同演员作品。
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
      ];
    }
    if (sql.contains('content AS content')) {
      return [
        {'content': '简介内容。'},
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

/// JavDB 假取数（v4 形状）：可配原名/磁力/剧照三样有无。
Future<String> Function(String) _javdbFetch({
  bool originTitle = false,
  bool magnets = false,
  bool stills = true,
}) {
  return (String url) async {
    if (url.contains('/magnets')) {
      return jsonEncode({
        'success': true,
        'data': {
          'magnets': magnets
              ? [
                  {
                    'hash': 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
                    'name': 'SIGL-020 高清版',
                    'size': 5390,
                    'created_at': '2026-11-26',
                    'hd': true,
                    'cnsub': true,
                    'seeders': 10,
                  },
                ]
              : <Object?>[],
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
            if (originTitle) 'origin_title': '原名タイトル',
            'score': '8.6',
            'score_count': 321,
            if (stills)
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
  };
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

/// 1x1 透明 PNG（截帧假帧用）。
final _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _FakeCapturer implements ActressStillCapturer {
  var calls = 0;
  String? lastUrl;

  @override
  Future<List<Uint8List>> captureFrames({
    required String url,
    Map<String, String> headers = const {},
    int count = 5,
  }) async {
    calls++;
    lastUrl = url;
    return [_tinyPng, _tinyPng, _tinyPng];
  }
}

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

void main() {
  late LocalStore store;
  late Directory cacheDir;

  setUp(() {
    store = LocalStore();
    cacheDir = Directory.systemTemp.createTempSync('actress_stills_test_');
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
    JavdbApiClient? javdbClient,
    ActressStillCapturer? capturer,
    MagnetOfflineSubmitter? magnetOffline,
  }) {
    return ActressWorkDetailPage.local(
      vodId: 'sigl-020',
      fallback: ActressLibraryDbFallback(
        pathResolver: () async => '/fake/女优库.db',
        opener: (path) async => _FakeDb().query,
      ),
      repository: _FakeRepository(),
      javdbClient: javdbClient,
      stillCapturer: capturer,
      magnetOffline: magnetOffline,
      stillCache: ActressStillCache(directoryOf: () async => cacheDir),
      probeFetch: _probeOk,
      playerFactory: () => ControlledNativePlayer(),
      playUrlPrep: (url, headers) async => url,
    );
  }

  testWidgets('翻译切换：有原名数据才出，点按在原名/现标题间切换', (tester) async {
    tallView(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: page(
          javdbClient: JavdbApiClient(fetch: _javdbFetch(originTitle: true)),
        ),
      ),
    );
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('work-detail-translate-toggle'))
          .evaluate()
          .isNotEmpty,
    );
    final titleFinder = find.byKey(const ValueKey('work-detail-title'));
    expect(tester.widget<Text>(titleFinder).data, 'SIGL-020 样本标题');
    await tester.tap(
      find.byKey(const ValueKey('work-detail-translate-toggle')),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.widget<Text>(titleFinder).data, '原名タイトル');
    await tester.tap(
      find.byKey(const ValueKey('work-detail-translate-toggle')),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.widget<Text>(titleFinder).data, 'SIGL-020 样本标题');
  });

  testWidgets('翻译切换：没原名/译名数据整件不出', (tester) async {
    tallView(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: page(javdbClient: JavdbApiClient(fetch: _javdbFetch())),
      ),
    );
    // 等 JavDB 补充落地（评分缎带出现即补充已回填）。
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('work-detail-score-ribbon'))
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey('work-detail-translate-toggle')),
      findsNothing,
    );
  });

  testWidgets('下载链接区：有磁力才出，字段形态齐，未登入点按弹引导、长按复制', (
    tester,
  ) async {
    tallView(tester);
    String? clipboardText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    var submitCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: page(
          javdbClient: JavdbApiClient(fetch: _javdbFetch(magnets: true)),
          magnetOffline: MagnetOfflineSubmitter(
            isLoggedIn: () async => false,
            submit: (url) async {
              submitCalls++;
              return const Pan115SubmitResult(ok: true);
            },
          ),
        ),
      ),
    );
    await _until(tester, () => find.text('下载链接').evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('work-detail-magnets')), findsOneWidget);
    expect(find.text('SIGL-020 高清版'), findsOneWidget);
    expect(find.text('高清'), findsOneWidget);
    expect(find.text('字幕'), findsOneWidget);
    expect(find.text('5.26 GB'), findsOneWidget);
    expect(find.text('2026-11-26'), findsOneWidget);
    // 裁决：在线平台行不摆（隐藏令优先）。
    expect(find.text('在线平台'), findsNothing);
    expect(find.text('播放线路'), findsNothing);
    // 区内提示文案与实情一致：点按提交离线 / 长按复制。
    expect(find.text('点按磁力提交到 115 离线下载，长按复制链接'), findsOneWidget);
    // 点按（未登入）→ 引导弹窗：不提交、不复制。
    await tester.tap(find.byKey(const ValueKey('work-detail-magnet-0')));
    await _until(
      tester,
      () => find.text('未登录 115 网盘').evaluate().isNotEmpty,
    );
    expect(find.text('未登录 115 网盘'), findsOneWidget);
    expect(find.text('去登录'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(submitCalls, 0);
    expect(clipboardText, isNull);
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('未登录 115 网盘'), findsNothing);
    // 长按条目 = 复制磁力链接 + 提示「已复制」。
    await tester.longPress(find.byKey(const ValueKey('work-detail-magnet-0')));
    await _until(tester, () => clipboardText != null);
    expect(
      clipboardText,
      startsWith(
        'magnet:?xt=urn:btih:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
      ),
    );
    await _until(tester, () => find.text('已复制').evaluate().isNotEmpty);
    expect(find.text('已复制'), findsOneWidget);
    // 行尾复制按钮同义：同样复制。
    clipboardText = null;
    await tester.tap(find.byKey(const ValueKey('work-detail-magnet-copy-0')));
    await _until(tester, () => clipboardText != null);
    expect(
      clipboardText,
      startsWith(
        'magnet:?xt=urn:btih:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
      ),
    );
  });

  testWidgets('下载链接区：已登入点按磁力走提交假件并提示成功', (tester) async {
    tallView(tester);
    String? submittedUrl;
    await tester.pumpWidget(
      MaterialApp(
        home: page(
          javdbClient: JavdbApiClient(fetch: _javdbFetch(magnets: true)),
          magnetOffline: MagnetOfflineSubmitter(
            isLoggedIn: () async => true,
            submit: (url) async {
              submittedUrl = url;
              return const Pan115SubmitResult(ok: true);
            },
          ),
        ),
      ),
    );
    await _until(tester, () => find.text('下载链接').evaluate().isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('work-detail-magnet-0')));
    await _until(tester, () => submittedUrl != null);
    expect(
      submittedUrl,
      startsWith(
        'magnet:?xt=urn:btih:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
      ),
    );
    await _until(
      tester,
      () => find.text('已提交到 115 离线下载').evaluate().isNotEmpty,
    );
    expect(find.text('已提交到 115 离线下载'), findsOneWidget);
    expect(find.text('未登录 115 网盘'), findsNothing);
  });

  testWidgets('下载链接区：提交失败弹原因（异常中文信息优先）', (tester) async {
    tallView(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: page(
          javdbClient: JavdbApiClient(fetch: _javdbFetch(magnets: true)),
          magnetOffline: MagnetOfflineSubmitter(
            isLoggedIn: () async => true,
            submit: (url) async =>
                throw CloudDriveException('离线配额已用完'),
          ),
        ),
      ),
    );
    await _until(tester, () => find.text('下载链接').evaluate().isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('work-detail-magnet-0')));
    await _until(
      tester,
      () => find.text('提交失败：离线配额已用完').evaluate().isNotEmpty,
    );
    expect(find.text('提交失败：离线配额已用完'), findsOneWidget);
  });

  group('MagnetOfflineSubmitter 判定', () {
    test('未登入不调提交、回 notLoggedIn', () async {
      var submitCalls = 0;
      final submitter = MagnetOfflineSubmitter(
        isLoggedIn: () async => false,
        submit: (url) async {
          submitCalls++;
          return const Pan115SubmitResult(ok: true);
        },
      );
      final result = await submitter.tap('magnet:?xt=urn:btih:x');
      expect(result.outcome, MagnetTapOutcome.notLoggedIn);
      expect(submitCalls, 0);
    });

    test('接口回失败（无原因）用通用兜底文案，不静默', () async {
      final submitter = MagnetOfflineSubmitter(
        isLoggedIn: () async => true,
        submit: (url) async => const Pan115SubmitResult(ok: false),
      );
      final result = await submitter.tap('magnet:?xt=urn:btih:x');
      expect(result.outcome, MagnetTapOutcome.failed);
      expect(result.message, '提交失败，请稍后重试');
    });

    test('非中文异常不糊原文、用通用兜底文案', () async {
      final submitter = MagnetOfflineSubmitter(
        isLoggedIn: () async => true,
        submit: (url) async => throw StateError('https://secret.example/x'),
      );
      final result = await submitter.tap('magnet:?xt=urn:btih:x');
      expect(result.outcome, MagnetTapOutcome.failed);
      expect(result.message, '提交失败，请稍后重试');
    });

    test('防重复点：提交在飞时第二次 tap 回 busy 且只提交一次', () async {
      final gate = Completer<Pan115SubmitResult>();
      var submitCalls = 0;
      final submitter = MagnetOfflineSubmitter(
        isLoggedIn: () async => true,
        submit: (url) {
          submitCalls++;
          return gate.future;
        },
      );
      final first = submitter.tap('magnet:?xt=urn:btih:x');
      // 等第一次 tap 走到 submit（登录判据是微任务，轮询 busy）。
      for (var i = 0; i < 50 && !submitter.busy; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(submitter.busy, isTrue);
      final second = await submitter.tap('magnet:?xt=urn:btih:x');
      expect(second.outcome, MagnetTapOutcome.busy);
      gate.complete(const Pan115SubmitResult(ok: true));
      final firstResult = await first;
      expect(firstResult.outcome, MagnetTapOutcome.submitted);
      expect(firstResult.message, '已提交到 115 离线下载');
      expect(submitCalls, 1);
      expect(submitter.busy, isFalse);
    });
  });

  testWidgets('下载链接区：没磁力数据整区不出', (tester) async {
    tallView(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: page(javdbClient: JavdbApiClient(fetch: _javdbFetch())),
      ),
    );
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('work-detail-score-ribbon'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.text('下载链接'), findsNothing);
    expect(find.byKey(const ValueKey('work-detail-magnets')), findsNothing);
  });

  testWidgets('剧照截帧兜底：JavDB 无剧照 → 截帧回填；重开命中缓存不重截', (
    tester,
  ) async {
    tallView(tester);
    final capturer = _FakeCapturer();
    await tester.pumpWidget(
      MaterialApp(
        home: page(
          javdbClient: JavdbApiClient(fetch: _javdbFetch(stills: false)),
          capturer: capturer,
        ),
      ),
    );
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('work-detail-still-2'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.byKey(const ValueKey('work-detail-still-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('work-detail-still-2')), findsOneWidget);
    expect(capturer.calls, 1);
    // 截的是验活过的本地库流。
    expect(capturer.lastUrl, 'https://v.hersav.me/abc/abc.m3u8');
    // 缓存已落盘（番号+来源键）。
    final cached = await ActressStillCache(
      directoryOf: () async => cacheDir,
    ).read('sigl-020', 'local-0');
    expect(cached, hasLength(3));

    // 关页重开：缓存命中、截帧器零调用。
    await tester.pumpWidget(const SizedBox.shrink());
    final capturer2 = _FakeCapturer();
    await tester.pumpWidget(
      MaterialApp(
        home: page(
          javdbClient: JavdbApiClient(fetch: _javdbFetch(stills: false)),
          capturer: capturer2,
        ),
      ),
    );
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('work-detail-still-2'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.byKey(const ValueKey('work-detail-still-0')), findsOneWidget);
    expect(capturer2.calls, 0);
  });

  testWidgets('剧照截帧兜底：JavDB 有剧照时不截帧', (tester) async {
    tallView(tester);
    final capturer = _FakeCapturer();
    await tester.pumpWidget(
      MaterialApp(
        home: page(
          javdbClient: JavdbApiClient(fetch: _javdbFetch(stills: true)),
          capturer: capturer,
        ),
      ),
    );
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('work-detail-still-0'))
          .evaluate()
          .isNotEmpty,
    );
    // 剧照来自 JavDB（网络图），截帧器不该被叫到。
    await _until(tester, () => capturer.calls > 0, rounds: 5);
    expect(capturer.calls, 0);
  });

  test('截帧缓存：写后按番号+来源读回、异来源不串', () async {
    final cache = ActressStillCache(directoryOf: () async => cacheDir);
    final paths = await cache.write('sigl-020', 'local-0', [
      _tinyPng,
      _tinyPng,
    ]);
    expect(paths, hasLength(2));
    expect(await cache.read('SIGL-020', 'local-0'), hasLength(2));
    expect(await cache.read('sigl-020', 'dart-123av'), isEmpty);
    expect(await cache.read('sigl-021', 'local-0'), isEmpty);
  });
}
