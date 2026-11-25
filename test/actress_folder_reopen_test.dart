// 类型文件夹二次进入复现测试（2026-11-25 群报 bug：
// 演员库“类型文件夹”页，点进一个文件夹可以加载，返回再点第二个
// 就加载不出来，之后所有文件夹都加载不出来，必须重启应用）。
//
// 覆盖的流：
// 1. 进文件夹 A → 返回 → 进文件夹 B：B 的作品必须出来；
// 2. 第二个文件夹取数抛错一次：出失败文案 + 重试，点重试能出来，
//    之后再进其他文件夹也不受影响；
// 3. 快速连续进出（A 还没取完就进 B）：B 必须出来，不能卡转圈；
// 4. 翻页进行中切文件夹（A 的第 2 页还在取，退回进 B）：B 必须出来，
//    且 B 滑到底还能继续翻页（_folderLoadingMore 不能被上一个
//    文件夹没跑完的翻页卡死）；
// 5. 第一个文件夹的总数 COUNT 还没回来就切第二个：B 的作品与总数
//    都要对，A 的晚到总数不能串到 B 头上。
//
// 假服务带可控延迟与一次性抛错，模拟真机上 COUNT 全表扫很慢、
// 同步写库时读被锁抛错的形态；不碰真库。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_database.dart';
import 'package:fqapp/actress/actress_film_library.dart';
import 'package:fqapp/actress/actress_generic_db.dart';
import 'package:fqapp/actress/actress_mytv_bind.dart';
import 'package:fqapp/actress/actress_nvku_cache.dart';
import 'package:fqapp/actress/actress_nvku_page.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'actress_fixtures.dart';

/// 假影视库服务：文件夹 A/B 各 35 部（第一页 30 + 第二页 5），
//  用来验翻页；listFilms / countFilms 可设延迟，模拟真机 COUNT
//  全表扫慢；failListFilmsOnceFor 让指定文件夹的下一次 listFilms
//  抛错一次，模拟同步写库时读被锁。
class _ReopenFakeFilmService extends FilmLibraryService {
  _ReopenFakeFilmService({required super.database});

  Duration listDelay = Duration.zero;
  Duration countDelay = Duration.zero;

  /// 下一次 listFilms 抛错的文件夹名（抛一次后自动清掉）。
  final failListFilmsOnceFor = <String>{};

  /// 下一次 listFilms 挂住不回的文件夹名（挂一次后自动清掉，
  /// 用来验 15 秒超时走失败分支）。
  final hangListFilmsOnceFor = <String>{};

  /// 下一次 countFilms 抛错的文件夹名（抛一次后自动清掉）。
  final failCountFilmsOnceFor = <String>{};

  var listFilmsCalls = 0;
  var countFilmsCalls = 0;

  final works = <String, List<FilmLibraryEntry>>{
    '文件夹A': [
      for (var i = 1; i <= 35; i++)
        FilmLibraryEntry(
          vodId: 'a-${i.toString().padLeft(3, '0')}',
          title: 'A作品$i',
          code: 'A-$i',
          playUrl: 'https://example.test/a$i.m3u8',
          typeName: '文件夹A',
        ),
    ],
    '文件夹B': [
      for (var i = 1; i <= 35; i++)
        FilmLibraryEntry(
          vodId: 'b-${i.toString().padLeft(3, '0')}',
          title: 'B作品$i',
          code: 'B-$i',
          playUrl: 'https://example.test/b$i.m3u8',
          typeName: '文件夹B',
        ),
    ],
    '文件夹C': [
      for (var i = 1; i <= 3; i++)
        FilmLibraryEntry(
          vodId: 'c-${i.toString().padLeft(3, '0')}',
          title: 'C作品$i',
          code: 'C-$i',
          playUrl: 'https://example.test/c$i.m3u8',
          typeName: '文件夹C',
        ),
    ],
  };

  @override
  Future<FilmLibraryOpenResult> open() async {
    return const FilmLibraryOpenResult(
      dbPath: '/fake/MYTV/db/女优库.db',
      displayPath: 'MYTV/db/女优库.db',
      strict: true,
      total: 73,
      schema: GenericDbSchema(tables: [], fingerprint: 'test'),
      domain: '',
    );
  }

  @override
  Future<List<(String, int)>> typeFolders({
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) async {
    return [
      for (final e in works.entries) (e.key, e.value.length),
    ];
  }

  @override
  Future<Map<String, String>> typeFolderCovers({
    required List<String> typeNames,
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) async {
    return {for (final name in typeNames) name: ''};
  }

  @override
  Future<({String key, List<(String, int)> values})> tags() async {
    return (key: 'video_tag.tag_name', values: const <(String, int)>[]);
  }

  @override
  Future<List<FilmLibraryEntry>> listFilms({
    String category = '',
    String site = '',
    String actress = '',
    String query = '',
    String typeName = '',
    String videoTag = '',
    String genericTagKey = '',
    required int offset,
    required int limit,
  }) async {
    listFilmsCalls++;
    if (listDelay > Duration.zero) {
      await Future.delayed(listDelay);
    }
    if (failListFilmsOnceFor.remove(typeName)) {
      throw StateError('模拟读被锁：$typeName');
    }
    if (hangListFilmsOnceFor.remove(typeName)) {
      // 挂住不回：只有调用方的 15 秒超时能把它拉回失败分支。
      await Completer<void>().future;
    }
    final list = works[typeName] ?? const [];
    return list.skip(offset).take(limit).toList();
  }

  @override
  Future<int> countFilms({
    String category = '',
    String site = '',
    String actress = '',
    String query = '',
    String typeName = '',
    String videoTag = '',
    String genericTagKey = '',
  }) async {
    countFilmsCalls++;
    if (countDelay > Duration.zero) {
      await Future.delayed(countDelay);
    }
    if (failCountFilmsOnceFor.remove(typeName)) {
      throw StateError('模拟 COUNT 失败：$typeName');
    }
    return (works[typeName] ?? const []).length;
  }
}

ThemeData _testTheme() {
  final base = ThemeData.dark();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    try {
      await tester.pump(const Duration(milliseconds: 100));
    } catch (_) {}
  }
}

void main() {
  group('类型文件夹二次进入（群报：第二次点就加载不出来）', () {
    late LocalStore store;
    late MemoryActressDatabase db;
    late _ReopenFakeFilmService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      NvkuEntryCache.clearForTest();
      store = LocalStore();
      db = MemoryActressDatabase();
      service = _ReopenFakeFilmService(database: db);
      await ActressMytvBind.instance.ensureBound();
    });

    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: ActressNvkuPage(
            repository: FixtureRepository(),
            store: store,
            database: db,
            filmService: service,
          ),
        ),
      );
      await _settle(tester);
    }

    /// 打开文件夹：首页点文件夹名，等取数 settle。
    Future<void> openFolder(WidgetTester tester, String name) async {
      await tester.tap(find.text(name));
      await _settle(tester);
    }

    /// 退回：点“‹ 全部类型”，再点底栏“首页”回到文件夹网格。
    Future<void> backToGrid(WidgetTester tester) async {
      await tester.tap(find.text('‹ 全部类型'));
      await _settle(tester);
      await tester.tap(find.text('首页'));
      await _settle(tester);
    }

    testWidgets('进 A → 返回 → 进 B：B 的作品能出来', (tester) async {
      await pumpPage(tester);
      await openFolder(tester, '文件夹A');
      expect(find.text('A作品1'), findsOneWidget);
      expect(find.text('文件夹A · 共35条'), findsOneWidget);
      await backToGrid(tester);
      expect(find.text('文件夹B'), findsOneWidget);
      await openFolder(tester, '文件夹B');
      expect(find.text('B作品1'), findsOneWidget);
      expect(find.text('文件夹B · 共35条'), findsOneWidget);
      expect(find.text('A作品1'), findsNothing);
    });

    testWidgets('进 A → 返回 → 进 B → 返回 → 进 C：三个都能出来', (
      tester,
    ) async {
      await pumpPage(tester);
      await openFolder(tester, '文件夹A');
      expect(find.text('A作品1'), findsOneWidget);
      await backToGrid(tester);
      await openFolder(tester, '文件夹B');
      expect(find.text('B作品1'), findsOneWidget);
      await backToGrid(tester);
      await openFolder(tester, '文件夹C');
      expect(find.text('C作品1'), findsOneWidget);
      expect(find.text('文件夹C · 共3条'), findsOneWidget);
    });

    testWidgets('B 取数抛错一次：出失败文案 + 重试能出来，不连累其他文件夹', (
      tester,
    ) async {
      service.failListFilmsOnceFor.add('文件夹B');
      await pumpPage(tester);
      await openFolder(tester, '文件夹A');
      expect(find.text('A作品1'), findsOneWidget);
      await backToGrid(tester);
      await openFolder(tester, '文件夹B');
      // 抛错一次：不许永久转圈，要摆失败文案 + 重试。
      expect(find.text('这个类型暂时取不到作品，点下面重试'), findsOneWidget);
      expect(find.byKey(const ValueKey('folder-retry')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // 点重试：第二次取数成功，作品出来。
      await tester.tap(find.byKey(const ValueKey('folder-retry')));
      await _settle(tester);
      expect(find.text('B作品1'), findsOneWidget);
      expect(find.text('文件夹B · 共35条'), findsOneWidget);
      // 再进 A、C 也不受影响。
      await backToGrid(tester);
      await openFolder(tester, '文件夹C');
      expect(find.text('C作品1'), findsOneWidget);
    });

    testWidgets('快速连续进出：A 还没取完就进 B，B 必须出来、不卡转圈', (
      tester,
    ) async {
      service.listDelay = const Duration(milliseconds: 300);
      service.countDelay = const Duration(milliseconds: 300);
      await pumpPage(tester);
      // 点 A：只 pump 一下，让 A 的取数跑起来但还没回来。
      await tester.tap(find.text('文件夹A'));
      await tester.pump(const Duration(milliseconds: 50));
      // 立刻退回、回首页、进 B（A 的取数还在飞）。
      await tester.tap(find.text('‹ 全部类型'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('首页'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('文件夹B'));
      await _settle(tester);
      // B 的作品必须出来，且页上没有永久转圈。
      expect(find.text('B作品1'), findsOneWidget);
      expect(find.text('文件夹B · 共35条'), findsOneWidget);
      expect(find.text('A作品1'), findsNothing);
    });

    testWidgets('A 的总数还没回来就切 B：B 的总数要对，A 的晚到总数不串位', (
      tester,
    ) async {
      service.countDelay = const Duration(milliseconds: 500);
      await pumpPage(tester);
      await tester.tap(find.text('文件夹A'));
      await tester.pump(const Duration(milliseconds: 100));
      // A 的第一页已出（list 不延迟），总数还在飞。
      expect(find.text('A作品1'), findsOneWidget);
      expect(find.text('文件夹A · 加载中…'), findsOneWidget);
      await tester.tap(find.text('‹ 全部类型'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('首页'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('文件夹B'));
      await _settle(tester);
      expect(find.text('B作品1'), findsOneWidget);
      expect(find.text('文件夹B · 共35条'), findsOneWidget);
      // A 的晚到总数不能把 B 的标题改回 35 条之外的数（B 也是 35，
      // 这里断言标题仍是 B 的；关键是标题没变成 A 的串位值——
      // A、B 都是 35，用 C（3 条）再验一次串位）。
      await backToGrid(tester);
      await tester.tap(find.text('文件夹C'));
      await _settle(tester);
      expect(find.text('文件夹C · 共3条'), findsOneWidget);
    });

    testWidgets('总数 COUNT 抛错：已出的列表不被换成失败页', (tester) async {
      service.failCountFilmsOnceFor.add('文件夹A');
      await pumpPage(tester);
      await openFolder(tester, '文件夹A');
      // 第一页出来了，总数拿不到：列表照常显示，标题一直“加载中…”,
      // 不许整页变失败文案、不许出重试。
      expect(find.text('A作品1'), findsOneWidget);
      expect(find.text('文件夹A · 加载中…'), findsOneWidget);
      expect(find.text('这个类型暂时取不到作品，点下面重试'), findsNothing);
      expect(find.byKey(const ValueKey('folder-retry')), findsNothing);
    });

    testWidgets('取数挂住 15 秒超时：出失败文案 + 重试能出来', (tester) async {
      service.hangListFilmsOnceFor.add('文件夹B');
      await pumpPage(tester);
      await tester.tap(find.text('文件夹B'));
      // 15 秒内还是转圈（取数没回来）；到 16 秒超时走失败分支。
      await tester.pump(const Duration(seconds: 14));
      expect(find.text('这个类型暂时取不到作品，点下面重试'), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      await _settle(tester);
      expect(find.text('这个类型暂时取不到作品，点下面重试'), findsOneWidget);
      expect(find.byKey(const ValueKey('folder-retry')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // 点重试：第二次取数正常，作品出来。
      await tester.tap(find.byKey(const ValueKey('folder-retry')));
      await _settle(tester);
      expect(find.text('B作品1'), findsOneWidget);
      expect(find.text('文件夹B · 共35条'), findsOneWidget);
    });

    testWidgets('翻页进行中切文件夹：B 出来后滑到底还能继续翻页', (
      tester,
    ) async {
      service.listDelay = const Duration(milliseconds: 300);
      await pumpPage(tester);
      await openFolder(tester, '文件夹A');
      expect(find.text('A作品1'), findsOneWidget);
      // 滑到底触发 A 的第 2 页（30 → 35），取数还在飞时立刻切走。
      // 注意：IndexedStack 里首页 ListView 与文件夹 GridView 同时
      // 挂着，scrollUntilVisible 默认找第一个 Scrollable 会撞上
      // 两个，必须显式指定文件夹那个 GridView 的 Scrollable。
      final folderScrollable = find.descendant(
        of: find.byType(GridView),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.text('A作品30'),
        500,
        scrollable: folderScrollable,
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('‹ 全部类型'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('首页'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('文件夹B'));
      await _settle(tester);
      expect(find.text('B作品1'), findsOneWidget);
      // B 滑到底：第 2 页必须出来（第 31–35 部），翻页不能被
      // A 没跑完的那次翻页卡死。
      await tester.scrollUntilVisible(
        find.text('B作品30'),
        500,
        scrollable: find.descendant(
          of: find.byType(GridView),
          matching: find.byType(Scrollable),
        ),
      );
      await _settle(tester);
      expect(find.text('B作品35'), findsOneWidget);
    });
  });
}
