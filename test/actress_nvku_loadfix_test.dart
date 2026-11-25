// 女优库修复批（2026-11-26）补测：
// 1. 名单抛错 → 失败文案 + 重试钮出现、转圈消失（永转圈绝迹）。
// 2. 名单永不返回 → 超时后出失败态（超时注入口压短到 300ms）。
// 3. 二次进库（页面 State 重建）→ 名单槽先上屏，listPersons 零调用。
// 4. 只读开库契约：夹具视频库经 sqlite3 只读回放名单 SQL，文件
//    mtime/大小不变、不新增表/索引；且数据库层源码里写 SQL 清零
//    （本机测试环境没有 sqflite_common_ffi、pub.dev 不可达，仓库
//    既定口径是测试不碰真库连接——真开库路径以源码断言 + CLI
//    只读回放双证，修前两条都必败）。
// 5. ⚙ 设置弹窗：同步/叠加/现爬/镜像四节消失，数据库节的重新
//    加载钮与多库勾选区仍在。
// 6. 无库时 JSON 顶首页：假库抛 ActressNoExternalDbException，
//    名单由内置 who's 索引顶上（真资源，真异步加载）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_database.dart';
import 'package:fqapp/actress/actress_generic_db.dart';
import 'package:fqapp/actress/actress_list_page.dart';
import 'package:fqapp/actress/actress_models.dart';
import 'package:fqapp/actress/actress_nvku_cache.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'actress_fixtures.dart';

/// 可编程假库：名单行为由测试注入（抛错/永不返回/正常计数）。
class _FakeDb implements ActressDatabase {
  _FakeDb({required this.onListPersons});

  final Future<List<ActressPerson>> Function() onListPersons;
  var listPersonsCalls = 0;
  var throwNoDbOnGenericReader = false;

  @override
  Future<ActressPerson?> personById(int localId) async => null;

  @override
  Future<List<ActressPerson>> listPersons({
    required ActressSexFilter sex,
    required ActressSort sort,
    required String query,
    required int offset,
    required int limit,
    String tag = '',
    String category = '',
    String videoTag = '',
  }) {
    listPersonsCalls++;
    return onListPersons();
  }

  @override
  Future<int> countPersons({
    required ActressSexFilter sex,
    required String query,
    String tag = '',
    String videoTag = '',
  }) async => 0;

  @override
  Future<List<ActressPerson>> allPersonsForRanking({
    required ActressSexFilter sex,
  }) async => const [];

  @override
  Future<List<ActressWork>> worksForPerson(
    int personId, {
    required int offset,
    required int limit,
    String? category,
    String? videoTag,
  }) async => const [];

  @override
  Future<int> countWorks(
    int personId, {
    String? category,
    String? videoTag,
  }) async => 0;

  @override
  Future<Set<String>> distinctWorkKeysForName(String name) async =>
      const <String>{};

  @override
  Future<List<(String, int)>> dbCategories() async => const [];

  @override
  Future<List<(String, int)>> dbTags() async => const [];

  @override
  Future<List<({String name, int count})>> workCategories(
    int personId,
  ) async => const [];

  @override
  Future<ActressSyncOverview> overview() async => const ActressSyncOverview(
    persons: 2,
    personsWithWorks: 2,
    works: 3,
    sources: {},
    lastUpdatedAt: 0,
  );

  @override
  Future<({bool reloaded, String? error})> reloadIfChanged({
    bool force = false,
  }) async => (reloaded: false, error: null);

  @override
  Future<GenericDbReader?> genericReader() async {
    if (throwNoDbOnGenericReader) {
      throw const ActressNoExternalDbException('未找到外置数据库');
    }
    return null;
  }

  @override
  bool get isVideoLibrary => false;

  @override
  String? get openFallbackNote => null;

  @override
  Future<void> close() async {}
}

Future<LocalStore> _makeStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore();
  addTearDown(store.dispose);
  return store;
}

/// 真异步沉降：bootstrap 有真文件 IO，FakeAsync 定步 pump 等不到，
/// 在 runAsync 里用真时间轮询到条件成立（见 AGENTS.md 2026-11-18 条）。
Future<void> _settleUntil(
  WidgetTester tester,
  bool Function() done, {
  int maxRounds = 60,
}) async {
  await tester.runAsync(() async {
    for (var i = 0; i < maxRounds; i++) {
      if (done()) return;
      await Future.delayed(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}

Widget _page(_FakeDb db, LocalStore store) => MaterialApp(
  home: ActressListPage(
    repository: FixtureRepository(),
    store: store,
    database: db,
  ),
);

void main() {
  setUp(() {
    NvkuEntryCache.clear();
    ActressListPage.listTimeoutOverride = null;
  });

  testWidgets('名单抛错：失败文案 + 重试钮出现、转圈消失', (tester) async {
    final store = await _makeStore();
    final db = _FakeDb(
      onListPersons: () async => throw StateError('database is locked'),
    );
    await tester.pumpWidget(_page(db, store));
    await _settleUntil(
      tester,
      () => find.byKey(const ValueKey('actress-list-retry')).evaluate().isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey('actress-list-retry')),
      findsOneWidget,
      reason: '名单抛错后必须出重试钮（修前 _loadPage 无守卫、永转圈）',
    );
    expect(find.textContaining('名单读不出来'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('名单永不返回：超时后出失败态', (tester) async {
    ActressListPage.listTimeoutOverride = const Duration(milliseconds: 300);
    addTearDown(() => ActressListPage.listTimeoutOverride = null);
    final store = await _makeStore();
    final db = _FakeDb(
      onListPersons: () => Completer<List<ActressPerson>>().future,
    );
    await tester.pumpWidget(_page(db, store));
    await _settleUntil(
      tester,
      () => find.byKey(const ValueKey('actress-list-retry')).evaluate().isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey('actress-list-retry')),
      findsOneWidget,
      reason: '名单超时（300ms 注入）后必须出失败态，不许无限转圈',
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('二次进库：名单槽先上屏，listPersons 零调用', (tester) async {
    final store = await _makeStore();
    final db = _FakeDb(
      onListPersons: () async => const [
        ActressPerson(
          localId: 1,
          displayName: '槽位女优甲',
          sex: 'female',
          worksCount: 5,
          exactWorks: 5,
        ),
        ActressPerson(
          localId: 2,
          displayName: '槽位女优乙',
          sex: 'female',
          worksCount: 3,
          exactWorks: 3,
        ),
      ],
    );
    await tester.pumpWidget(_page(db, store));
    await _settleUntil(
      tester,
      () => find.text('槽位女优甲').evaluate().isNotEmpty,
    );
    expect(find.text('槽位女优甲'), findsOneWidget);
    expect(db.listPersonsCalls, 1, reason: '第一次进库只查一次第一页');
    // 页面销毁重建（切区回来）：名单槽命中且新鲜，不再查库。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpWidget(_page(db, store));
    await _settleUntil(
      tester,
      () => find.text('槽位女优甲').evaluate().isNotEmpty,
      maxRounds: 10,
    );
    expect(find.text('槽位女优甲'), findsOneWidget);
    expect(
      db.listPersonsCalls,
      1,
      reason: '二次进库靠 NvkuEntryCache 名单槽上屏，listPersons 零新增调用',
    );
  });

  testWidgets('⚙ 弹窗：同步四节消失，重载钮与多库勾选仍在', (tester) async {
    final store = await _makeStore();
    final db = _FakeDb(
      onListPersons: () async => const [
        ActressPerson(
          localId: 1,
          displayName: '弹窗女优',
          sex: 'female',
          worksCount: 1,
          exactWorks: 1,
        ),
      ],
    );
    await tester.pumpWidget(_page(db, store));
    await _settleUntil(
      tester,
      () => find.text('弹窗女优').evaluate().isNotEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('open-actress-settings')));
    await tester.pumpAndSettle();
    // 被删的四节与可收起外壳全消失。
    for (final gone in [
      '名册 / 作品同步',
      '全站叠加',
      '任意站点爬取',
      '数据库镜像（其它 .db 追加）',
      '同步爬取',
    ]) {
      expect(find.text(gone), findsNothing, reason: '设置弹窗不应再有「$gone」');
    }
    expect(
      find.byKey(const ValueKey('toggle-actress-settings-body')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('actress-settings-summary')),
      findsNothing,
    );
    // 读功能仍在：重新加载数据库钮 + 多库勾选区（未绑定时是提示行）。
    expect(find.text('重新加载数据库'), findsWidgets);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is CheckboxListTile ||
            (w is Text &&
                (w.data?.contains('可勾的数据库') ?? false)),
      ),
      findsWidgets,
      reason: '多库勾选区（或未绑定提示）应在',
    );
  });

  test('只读开库契约：名单 SQL 只读回放不动库文件 + 源码写路径清零', () async {
    // 夹具视频库（sqlite3 CLI 造）：actresses/videos/video_actress/
    // video_category 四表 + 两行数据。
    final dir = Directory.systemTemp.createTempSync('nvku_ro_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dbFile = File('${dir.path}/女优库.db');
    void sql(String script, {bool readonly = false}) {
      final result = Process.runSync('sqlite3', [
        if (readonly) '-readonly',
        dbFile.path,
        script,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }

    sql('''
CREATE TABLE actresses (name TEXT, avatar TEXT, sex TEXT);
CREATE TABLE videos (vod_id TEXT PRIMARY KEY, vod_name TEXT, pic_url TEXT, m3u8_url TEXT, vod_play_url TEXT, vod_pubdate TEXT);
CREATE TABLE video_actress (vod_id TEXT, actress_name TEXT, cate_id TEXT);
CREATE TABLE video_category (vod_id TEXT, main_category TEXT, type_name TEXT);
CREATE TABLE per_cate (cate_id TEXT, actress_name TEXT);
INSERT INTO actresses VALUES ('甲', '', 'female'), ('乙', '', 'female');
INSERT INTO videos VALUES ('aaa-001', '作品一', '', 'https://x/1.m3u8', '', '2024-01-01'), ('bbb-002', '作品二', '', 'https://x/2.m3u8', '', '2024-02-01');
INSERT INTO video_actress VALUES ('aaa-001', '甲', 'c1'), ('bbb-002', '乙', 'c1');
INSERT INTO per_cate VALUES ('c1', '甲'), ('c1', '乙');
''');
    final sizeBefore = dbFile.lengthSync();
    final mtimeBefore = dbFile.lastModifiedSync();

    // 名单保留 SQL 的只读回放（与数据库层内存汇总的输入同形：
    // per_cate 计数 + actresses 全行扫 + worksForPerson）。
    sql(
      "SELECT cate_id, actress_name, COUNT(*) FROM per_cate GROUP BY cate_id, actress_name;",
      readonly: true,
    );
    sql("SELECT rowid, name, avatar, sex FROM actresses ORDER BY rowid;", readonly: true);
    sql(
      "SELECT v.vod_id FROM videos v JOIN video_actress va ON va.vod_id = v.vod_id WHERE va.actress_name = '甲';",
      readonly: true,
    );
    // 只读会话后：文件大小/mtime 不变，且没有 actress_rollup 表、
    // 没有 idx_moyi_* 索引（修前开库自写会建它们并顶变文件戳）。
    expect(dbFile.lengthSync(), sizeBefore);
    expect(dbFile.lastModifiedSync(), mtimeBefore);
    final master = Process.runSync('sqlite3', [
      '-readonly',
      dbFile.path,
      "SELECT name FROM sqlite_master WHERE name LIKE 'idx_moyi%' OR name = 'actress_rollup';",
    ]);
    expect((master.stdout as String).trim(), isEmpty);

    // 源码级断言：数据库层与影视库/兜底开库文件里不许再有写 SQL
    // 与读写开库（修前这些文件里全有：CREATE INDEX、ALTER TABLE、
    // INSERT、UPDATE、openDatabase 非只读）。
    const guardedFiles = [
      'lib/actress/actress_database.dart',
      'lib/actress/actress_generic_database.dart',
      'lib/actress/actress_film_library.dart',
      'lib/actress/whos_local_library.dart',
      'lib/actress/actress_multi_db_fallback.dart',
    ];
    final writePatterns = [
      RegExp(r'CREATE\s+(UNIQUE\s+)?INDEX', caseSensitive: false),
      RegExp(r'CREATE\s+TABLE', caseSensitive: false),
      RegExp(r'ALTER\s+TABLE', caseSensitive: false),
      RegExp(r'INSERT\s+INTO', caseSensitive: false),
      RegExp(r'DELETE\s+FROM', caseSensitive: false),
      RegExp(r'\bUPDATE\s+[\"`\[]?\w+[\"`\]]?\s+SET\b', caseSensitive: false),
      RegExp(r'rawInsert|rawUpdate|rawDelete'),
    ];
    for (final path in guardedFiles) {
      final text = File(path).readAsStringSync();
      for (final pattern in writePatterns) {
        expect(
          pattern.hasMatch(text),
          isFalse,
          reason: '$path 不应再含写路径 ${pattern.pattern}',
        );
      }
    }
    // 主库打开必须是只读姿势（openDatabase(readOnly: true) 或
    // openReadOnlyDatabase 均可），且带 query_only 兜底。
    final dbText = File('lib/actress/actress_database.dart').readAsStringSync();
    expect(
      dbText.contains('readOnly: true') ||
          dbText.contains('openReadOnlyDatabase'),
      isTrue,
    );
    expect(dbText.contains('PRAGMA query_only'), isTrue);
  });

  testWidgets(
    '无库时 JSON 顶首页：名单由内置 who\'s 索引顶上',
    (tester) async {
      final store = await _makeStore();
      final db = _FakeDb(onListPersons: () async => const [])
        ..throwNoDbOnGenericReader = true;
      await tester.pumpWidget(_page(db, store));
      // 索引是真资源（26MB 目录 gz）：真异步等第一张人物卡出现。
      await _settleUntil(
        tester,
        () => find
            .byKey(const ValueKey('actress-person-list'))
            .evaluate()
            .isNotEmpty,
        maxRounds: 300,
      );
      expect(
        find.byKey(const ValueKey('actress-person-list')),
        findsOneWidget,
        reason: '无库时演员库首页应由 who\'s JSON 名单顶上，不是空态',
      );
      expect(db.listPersonsCalls, 0, reason: 'JSON 顶首页不查数据库名单');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
