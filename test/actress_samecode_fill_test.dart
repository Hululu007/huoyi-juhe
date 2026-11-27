// 同番号互补测试（2026-11-27 用户令）：详情页简介、演员头
// 像从本地库其他相同番号行里补——
// - 候选 slug 生成：分隔符（-/_/无）× 数字尾零填充宽度的有
//   限集（≤24），走 vod_id 主键 IN 命中，不全表扫；
// - 兜底 sameCode 操作：简介取同番号最长的一份非空、头像回
//   同番号行演员头像，本行排除、别番号不串、硬线排除在位；
// - 头像链第三级：本行没头像/占位/死址 → 同番号互补 → 才
//   轮到 JavDB 按名；同番号地址迟到能补跑、已出图不降级；
// - 详情页：本行简介为空才借、已有不覆盖；头像按归一化名
//   对人（带空格的同名也认）、异名不串。
// 全部假件：假查询函数（按参数集模拟 IN 过滤）/假取图/临
// 时目录缓存，不碰真库真网。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_http.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_avatar.dart';
import 'package:fqapp/actress/actress_javdb_api.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_still_capture.dart';
import 'package:fqapp/actress/actress_work_detail_page.dart';

import 'support/controlled_player.dart';

/// 1x1 PNG（解码得动的真图字节）。
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

/// 1x1 GIF（与 _png 字节不同，验「已出图不被迟到的同番号
/// 地址降级替换」时靠字节区分两张图）。
final _gif = base64Decode(
  'R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw==',
);

Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  int rounds = 50,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  group('候选 slug 生成', () {
    test('ssis-001：分隔符三式 × 填充宽度一族都在、上限 24', () {
      final ids = actressSameCodeCandidateIds(
        vodId: 'ssis-001',
        code: 'SSIS-001',
      );
      expect(ids, contains('ssis-001'));
      expect(ids, contains('ssis-01'));
      expect(ids, contains('ssis-1'));
      expect(ids, contains('ssis-0001'));
      expect(ids, contains('ssis_001'));
      expect(ids, contains('ssis001'));
      expect(ids.length, lessThanOrEqualTo(24));
      expect(ids.toSet().length, ids.length);
      expect(ids.every((id) => id == id.toLowerCase()), isTrue);
    });

    test('fc2-ppv 长番号：原拼法在候选里', () {
      final ids = actressSameCodeCandidateIds(
        vodId: 'fc2-ppv-1234567',
        code: '',
      );
      expect(ids, contains('fc2-ppv-1234567'));
    });

    test('只有番号没 vodId 也能生成；全空回空集', () {
      final ids = actressSameCodeCandidateIds(vodId: '', code: 'ABW-123');
      expect(ids, contains('abw-123'));
      expect(ids, contains('abw-0123'));
      expect(actressSameCodeCandidateIds(vodId: '', code: ''), isEmpty);
    });
  });

  group('兜底 sameCode 操作', () {
    test('简介取同番号最长一份、头像跨行回收、本行与别番号不串', () async {
      final db = _SameCodeFakeDb();
      final service = _service(db);
      final result = await service.handle({
        'op': 'sameCode',
        'vodId': 'ssis-001',
        'code': 'SSIS-001',
      });
      expect(result['ok'], isTrue);
      // ssis-01 的长简介胜出（ssis-0001 的短简介、ssis-002 与
      // mida-002 的别番号简介都不许混进来）。
      expect(result['content'], '这是一份更长的同番号简介，用来验证取最长的一份。');
      final avatars = (result['avatars'] as List).cast<Map>();
      final byName = {
        for (final row in avatars)
          row['name']?.toString() ?? '': row['avatar']?.toString() ?? '',
      };
      expect(byName['演员甲'], 'https://img.test/same-a.jpg');
      expect(byName['演员乙'], 'https://img.test/same-b.jpg');
      // 查询形态：主键 IN 命中、硬线排除在位、没有前缀 LIKE。
      final contentCall = db.calls.firstWhere(
        (c) => c.$1.contains('content AS content'),
      );
      expect(contentCall.$1, contains('IN ('));
      expect(contentCall.$1, contains('type_name NOT IN'));
      expect(contentCall.$1, isNot(contains('LIKE')));
      expect(contentCall.$2, contains('ssis-0001'));
    });

    test('只有番号（无本行 id）：照样借到同番号数据', () async {
      final db = _SameCodeFakeDb()..selfId = '';
      final service = _service(db);
      final result = await service.handle({
        'op': 'sameCode',
        'code': 'SSIS-001',
      });
      expect(result['ok'], isTrue);
      expect(result['content'], contains('更长的同番号简介'));
    });

    test('番号与 vodId 都缺 → ok:false 中文错误', () async {
      final service = _service(_SameCodeFakeDb());
      final result = await service.handle({'op': 'sameCode'});
      expect(result['ok'], isFalse);
    });

    test('库没有 content 列：简介留空、头像照常回', () async {
      final db = _SameCodeFakeDb()..hasContentColumn = false;
      final service = _service(db);
      final result = await service.handle({
        'op': 'sameCode',
        'vodId': 'ssis-001',
        'code': 'SSIS-001',
      });
      expect(result['ok'], isTrue);
      expect(result['content'], '');
      expect((result['avatars'] as List), isNotEmpty);
    });
  });

  group('头像链第三级（同番号互补）', () {
    Future<ActressAvatarCache> tempCache() async {
      final dir = Directory.systemTemp.createTempSync('samecode_avatar_');
      addTearDown(() => dir.delete(recursive: true));
      return ActressAvatarCache(directoryOf: () async => dir);
    }

    Widget host(ActressAvatar avatar) {
      return MaterialApp(
        home: SizedBox(width: 76, height: 76, child: avatar),
      );
    }

    testWidgets('本行是占位地址 → 同番号补到出图，JavDB 不被调用、落缓存', (
      tester,
    ) async {
      final cache = await tempCache();
      var javdbCalls = 0;
      await tester.pumpWidget(
        host(
          ActressAvatar(
            name: '演员甲',
            avatarUrl: 'https://v.hersav.me/',
            sameCodeAvatarUrl: 'https://img.test/same-a.jpg',
            cache: cache,
            remoteLoader: (url) async =>
                url == 'https://img.test/same-a.jpg' ? _png : null,
            avatarFetcher: (name) async {
              javdbCalls++;
              return (bytes: _gif, actorId: 'j1');
            },
          ),
        ),
      );
      await _until(tester, () => find.byType(Image).evaluate().isNotEmpty);
      expect(find.byType(Image), findsOneWidget);
      expect(javdbCalls, 0);
      expect(await cache.read('演员甲'), isNotNull);
    });

    testWidgets('本行地址已死（取不到图）→ 落同番号互补出图', (tester) async {
      final cache = await tempCache();
      var javdbCalls = 0;
      await tester.pumpWidget(
        host(
          ActressAvatar(
            name: '演员甲',
            avatarUrl: 'https://img.test/dead.jpg',
            sameCodeAvatarUrl: 'https://img.test/same-a.jpg',
            cache: cache,
            remoteLoader: (url) async =>
                url == 'https://img.test/same-a.jpg' ? _png : null,
            avatarFetcher: (name) async {
              javdbCalls++;
              return (bytes: _gif, actorId: 'j1');
            },
          ),
        ),
      );
      await _until(tester, () => find.byType(Image).evaluate().isNotEmpty);
      expect(find.byType(Image), findsOneWidget);
      expect(javdbCalls, 0);
    });

    testWidgets('同番号地址是占位形态 → 本地跳过、落 JavDB 按名补', (
      tester,
    ) async {
      final cache = await tempCache();
      var javdbCalls = 0;
      await tester.pumpWidget(
        host(
          ActressAvatar(
            name: '演员甲',
            sameCodeAvatarUrl:
                'https://c0.jdbstatic.com/images/actor_unknow.jpg',
            cache: cache,
            remoteLoader: (url) async => null,
            avatarFetcher: (name) async {
              javdbCalls++;
              return (bytes: _png, actorId: 'j1');
            },
          ),
        ),
      );
      await _until(tester, () => find.byType(Image).evaluate().isNotEmpty);
      expect(find.byType(Image), findsOneWidget);
      expect(javdbCalls, 1);
    });

    testWidgets('同番号地址迟到（开页后才查回）→ 占位自动换成图', (
      tester,
    ) async {
      final cache = await tempCache();
      ActressAvatar build(String sameCodeUrl) => ActressAvatar(
        name: '演员甲',
        sameCodeAvatarUrl: sameCodeUrl,
        cache: cache,
        remoteLoader: (url) async =>
            url == 'https://img.test/same-a.jpg' ? _png : null,
        avatarFetcher: (name) async => null,
      );
      await tester.pumpWidget(host(build('')));
      await _until(tester, () => find.text('演').evaluate().isNotEmpty);
      expect(find.byType(Image), findsNothing);
      // 详情页后台查回同番号数据，重建时带上地址。
      await tester.pumpWidget(host(build('https://img.test/same-a.jpg')));
      await _until(tester, () => find.byType(Image).evaluate().isNotEmpty);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('已靠 JavDB 出图后同番号地址才到 → 不降级替换', (
      tester,
    ) async {
      final cache = await tempCache();
      ActressAvatar build(String sameCodeUrl) => ActressAvatar(
        name: '演员甲',
        sameCodeAvatarUrl: sameCodeUrl,
        cache: cache,
        remoteLoader: (url) async =>
            url == 'https://img.test/same-a.jpg' ? _gif : null,
        avatarFetcher: (name) async => (bytes: _png, actorId: 'j1'),
      );
      await tester.pumpWidget(host(build('')));
      await _until(tester, () => find.byType(Image).evaluate().isNotEmpty);
      await tester.pumpWidget(host(build('https://img.test/same-a.jpg')));
      await tester.pump(const Duration(milliseconds: 100));
      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as MemoryImage).bytes, _png);
    });
  });

  group('详情页同番号互补', () {
    late LocalStore store;
    late Directory cacheDir;

    setUp(() {
      store = LocalStore();
      cacheDir = Directory.systemTemp.createTempSync('samecode_detail_');
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

    ActressWorkDetailPage page(_PageFakeDb db) {
      return ActressWorkDetailPage.local(
        vodId: 'ssis-001',
        fallback: ActressLibraryDbFallback(
          pathResolver: () async => '/fake/女优库.db',
          opener: (path) async => db.query,
        ),
        repository: _FakeRepository(),
        javdbClient: JavdbApiClient(fetch: _javdbEmptyFetch),
        stillCapturer: _EmptyCapturer(),
        stillCache: ActressStillCache(directoryOf: () async => cacheDir),
        probeFetch: _probeOk,
        playerFactory: () => ControlledNativePlayer(),
        playUrlPrep: (url, headers) async => url,
      );
    }

    testWidgets('本行简介为空 → 借同番号简介；头像按归一化名对人、异名不串', (
      tester,
    ) async {
      tallView(tester);
      await tester.pumpWidget(
        MaterialApp(home: page(_PageFakeDb(selfContent: ''))),
      );
      await _until(
        tester,
        () => find.text('同番号借来的简介。').evaluate().isNotEmpty,
      );
      expect(find.text('同番号借来的简介。'), findsOneWidget);
      // 头像：兜底回的同番号行演员名带空格（'演员 甲'），归
      // 一化后仍对上本页的'演员甲'；'路人丙'的头像不许串给
      // '演员乙'。
      final avatars = tester
          .widgetList<ActressAvatar>(find.byType(ActressAvatar))
          .toList();
      final byName = {for (final a in avatars) a.name: a.sameCodeAvatarUrl};
      expect(byName['演员甲'], 'https://img.test/same-a.jpg');
      expect(byName['演员乙'], '');
    });

    testWidgets('本行已有简介 → 不被同番号简介覆盖', (tester) async {
      tallView(tester);
      await tester.pumpWidget(
        MaterialApp(home: page(_PageFakeDb(selfContent: '本行自己的简介。'))),
      );
      await _until(
        tester,
        () => find.text('本行自己的简介。').evaluate().isNotEmpty,
      );
      // 给同番号补充足够的时间落地后再断言没被换掉。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('本行自己的简介。'), findsOneWidget);
      expect(find.text('同番号借来的简介。'), findsNothing);
    });
  });
}

/// sameCode 操作的内存假库：按参数集模拟主键 IN 过滤（候选
/// 集外的行天然进不来），本行排除靠 selfId 显式模拟 SQL 的
/// `<> ?`。
class _SameCodeFakeDb {
  final tables = {
    'videos',
    'video_play_urls',
    'video_actress',
    'actresses',
    'video_tag',
    'video_ranking',
    'index_categories',
  };
  final calls = <(String, List<Object?>?)>[];
  var hasContentColumn = true;
  String selfId = 'ssis-001';

  /// vodId → 简介（'' = 本行没有）。
  static const contents = {
    'ssis-001': '',
    'ssis-0001': '短。',
    'ssis-01': '这是一份更长的同番号简介，用来验证取最长的一份。',
    'ssis-002': '同厂牌别番号的简介，不许混进来。',
    'mida-002': '别番号的简介，不许混进来。',
  };

  /// vodId → [(演员名, 头像)]。
  static const links = {
    'ssis-001': [('演员甲', ''), ('演员乙', '')],
    'ssis-0001': [('演员甲', 'https://img.test/same-a.jpg')],
    'ssis-01': [('演员乙', 'https://img.test/same-b.jpg')],
    'mida-002': [('演员甲', 'https://img.test/wrong.jpg')],
  };

  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? args,
  ]) async {
    calls.add((sql, args));
    if (sql.contains('sqlite_master')) {
      return [for (final t in tables) {'name': t}];
    }
    if (sql.contains('PRAGMA table_info(videos)')) {
      return [if (hasContentColumn) {'name': 'content'}];
    }
    if (sql.contains('PRAGMA table_info(actresses)')) {
      return [
        {'name': 'avatar'},
      ];
    }
    if (sql.contains('PRAGMA')) return [];
    final argSet = {for (final a in args ?? const []) a?.toString() ?? ''};
    if (sql.contains('content AS content') && sql.contains('vod_id IN (')) {
      final found = [
        for (final e in contents.entries)
          if (argSet.contains(e.key) &&
              e.key != selfId &&
              e.value.trim().isNotEmpty)
            e.value.trim(),
      ]..sort((a, b) => b.length.compareTo(a.length));
      return [if (found.isNotEmpty) {'content': found.first}];
    }
    if (sql.contains('a.avatar AS avatar') && sql.contains('vod_id IN (')) {
      return [
        for (final e in links.entries)
          if (argSet.contains(e.key) && e.key != selfId)
            for (final link in e.value)
              if (link.$2.trim().isNotEmpty)
                {'name': link.$1, 'avatar': link.$2},
      ];
    }
    return [];
  }
}

ActressLibraryDbFallback _service(_SameCodeFakeDb db) {
  return ActressLibraryDbFallback(
    pathResolver: () async => '/fake/女优库.db',
    opener: (path) async => db.query,
  );
}

/// 详情页的内存假库（原始查询级）：detail 回本行（简介可
/// 配）、sameCode 两条查询按 IN 特征分流回同番号数据。
class _PageFakeDb {
  _PageFakeDb({required this.selfContent});

  final String selfContent;
  static const borrowedContent = '同番号借来的简介。';
  final tables = {
    'videos',
    'video_play_urls',
    'video_actress',
    'actresses',
    'video_tag',
    'video_ranking',
    'index_categories',
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
    // sameCode 的两条查询（vod_id IN）先于 detail 的同名查
    // 询分流——detail 主查询的硬线排除是 NOT IN (?)，不能用
    // 裸 'IN (' 当特征，会误吞详情。
    if (sql.contains('vod_id IN (')) {
      if (sql.contains('content AS content')) {
        return [
          {'content': borrowedContent},
        ];
      }
      if (sql.contains('a.avatar AS avatar')) {
        return [
          // 名字带空格：验归一化名匹配。
          {'name': '演员 甲', 'avatar': 'https://img.test/same-a.jpg'},
          // 异名演员：不许串给本页演员。
          {'name': '路人丙', 'avatar': 'https://img.test/other.jpg'},
        ];
      }
      return [];
    }
    if (sql.contains('a.avatar AS avatar')) {
      return [
        {'name': '演员甲', 'avatar': ''},
        {'name': '演员乙', 'avatar': ''},
      ];
    }
    if (sql.contains('content AS content')) {
      return [
        {'content': selfContent},
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
        {'name': '演员乙'},
      ];
    }
    if (sql.contains('SELECT tag_name AS name FROM video_tag')) return [];
    if (sql.contains('FROM videos v')) {
      if (sql.contains('WHERE v.vod_id = ?')) {
        return [
          {
            'vodId': 'ssis-001',
            'title': 'SSIS-001 样本标题',
            'pic': 'https://img.test/poster.jpg',
            'play': 'https://v.hersav.me/abc/abc.m3u8',
            'playAlt': '',
            'date': '2024-05-06',
            'typeName': '剧情',
            'actress': '演员甲',
          },
        ];
      }
      return [];
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

class _EmptyCapturer implements ActressStillCapturer {
  @override
  Future<List<Uint8List>> captureFrames({
    required String url,
    Map<String, String> headers = const {},
    int count = 5,
  }) async => const [];
}

/// JavDB 假取数：搜索恒空（补充回 null，不干扰同番号断言）。
Future<String> _javdbEmptyFetch(String url) async {
  return jsonEncode({
    'success': true,
    'data': {'movies': <Object?>[]},
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
