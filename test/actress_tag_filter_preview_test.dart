// 女优库标签筛选预览截图（2026-11-24 用户令）。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、超时杀掉只取 PNG；不要把两张放进同一个
// 测试体，也不要批量跑。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_database.dart';
import 'package:fqapp/actress/actress_json_fallback.dart';
import 'package:fqapp/actress/actress_list_page.dart';
import 'package:fqapp/actress/actress_models.dart';
import 'package:fqapp/actress/actress_mytv_bind.dart';
import 'package:fqapp/actress/actress_site_crawl.dart';
import 'package:fqapp/actress/actress_tag_sheet.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'actress_fixtures.dart';

const _previewDir = '/home/hatch/workspace/xiuxian_actress_port_20261124/preview';

// 真标签数据：2026-11-24 从女优库.db（roster_json_fix 版）实查
// SELECT tag_name, COUNT(*) FROM video_tag GROUP BY tag_name
// ORDER BY c DESC LIMIT 30 的结果，原样写进弹窗预览。
// 真标签数据：2026-11-24 从重合并后的 女优库.db
// （~/workspace/roster_remrge_20261124/女优库.db）实查的 top 30，
// tags 1,190 个、video_tag 2,727,008 行、覆盖 272,994 部；
// 中出已并进中出し（94,652）、单体作品已并进単体作品（180,503），
// 两者新库里 0 行，不再单独列出。
const _realTopTags = <(String, int)>[
  ('ハイビジョン', 183579),
  ('単体作品', 180503),
  ('独占配信', 125204),
  ('高清', 98694),
  ('中出し', 94652),
  ('大乳房', 88651),
  ('独家', 68513),
  ('無修正リーク', 53205),
  ('人妻・主婦', 51033),
  ('成熟的女人', 46841),
  ('无码流出', 39579),
  ('デジモ', 36489),
  ('已婚妇女', 34906),
  ('美丽的女孩', 34896),
  ('荡妇', 32265),
  ('3P・4P', 30158),
  ('颜射', 24532),
  ('4K', 24013),
  ('スレンダー', 22880),
  ('角色剧情', 22503),
  ('フェラ', 22327),
  ('业余', 22213),
  ('潮吹き', 21562),
  ('中文字幕', 21080),
  ('騎乗位', 20854),
  ('寝取り・寝取られ・NTR', 20837),
  ('少女', 19418),
  ('パイズリ', 19080),
  ('ドラマ', 17750),
  ('口交', 17050),
];

late LocalStore _previewStore;
late MemoryActressDatabase _previewDb;
late ActressJsonFallback _previewFallback;
late _NoopCrawl _previewCrawl;

/// 不真爬：只记下触发的站。
class _NoopCrawl extends ActressSiteCrawlService {
  _NoopCrawl({required super.repository, required super.db});

  String? startedSite;

  @override
  Future<void> start({
    String site = 'mjv',
    int maxPagesPerCategory =
        ActressSiteCrawlService.defaultMaxPagesPerCategory,
    int enrichPerCategory =
        ActressSiteCrawlService.defaultEnrichPerCategory,
    int categoryConcurrency =
        ActressSiteCrawlService.defaultCategoryConcurrency,
  }) async {
    startedSite = site;
  }
}

ThemeData _previewTheme() {
  final base = ThemeData.dark();
  TextStyle? cjk(TextStyle? style) => style?.copyWith(fontFamily: 'PreviewCJK');
  // ChoiceChip/TextButton 这类控件会把主题里的 labelStyle/textStyle
  // 当整套 DefaultTextStyle 装上去（不继承外层的 PreviewCJK），
  // 主题里那些样式又没写 fontFamily，测试环境没有系统字体兜底，
  // 中文就变方框；真机上有系统字体兜底不会这样。这里只改预览
  // 主题，给这些样式也补上 PreviewCJK，产品代码不动。
  ButtonStyle cjkButton(ButtonStyle? style) {
    final s = style ?? const ButtonStyle();
    final resolved = s.textStyle?.resolve({}) ?? const TextStyle();
    return s.copyWith(
      textStyle: WidgetStatePropertyAll(
        resolved.copyWith(fontFamily: 'PreviewCJK'),
      ),
    );
  }

  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: cjk(base.appBarTheme.titleTextStyle),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: cjk(base.chipTheme.labelStyle),
      secondaryLabelStyle: cjk(base.chipTheme.secondaryLabelStyle),
    ),
    textButtonTheme: TextButtonThemeData(
      style: cjkButton(base.textButtonTheme.style),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: cjkButton(base.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: cjkButton(base.outlinedButtonTheme.style),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  // 首屏 _bootstrap 里有真异步文件 IO，FakeAsync 定步 pump 等不到它
  // 完成（见 AGENTS.md 2026-11-18 条）；runAsync 里用真时间轮询、
  // 块内 pump，否则截出来的是转圈。
  await tester.runAsync(() async {
    for (var i = 0; i < 30; i++) {
      try {
        await Future.delayed(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 100));
      } catch (_) {}
    }
  });
  for (var i = 0; i < 10; i++) {
    try {
      if (tester.takeException() == null) break;
    } catch (_) {
      break;
    }
  }
}

/// 列表页种子：A 八木奈奈（MIDA-619/SSIS-123，有码）、B 测试二号
///（IPX-707，无码）；标签：MIDA-619 挂中文字幕+ハイビジョン，
/// SSIS-123 挂ハイビジョン，IPX-707 挂中文字幕。
/// 名册检查点全记完成，不自动跑同步。
Future<
    ({
      LocalStore store,
      MemoryActressDatabase db,
      ActressJsonFallback fallback,
      _NoopCrawl crawl,
    })> _seed() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore();
  final db = MemoryActressDatabase();
  final a = await db.upsertRosterPerson(
    const RosterPerson(
      source: ActressRosterSourceId.chaoliu,
      sourceId: 'a1',
      name: '八木奈奈',
      sex: 'female',
    ),
  );
  await db.upsertWorks(a!.localId, [
    const RosterFilm(code: 'MIDA-619', title: '测试作品一', category: '有码'),
    const RosterFilm(code: 'SSIS-123', title: '测试作品二', category: '有码'),
  ]);
  final b = await db.upsertRosterPerson(
    const RosterPerson(
      source: ActressRosterSourceId.whos,
      sourceId: 'b1',
      name: '测试二号',
      sex: 'female',
    ),
  );
  await db.upsertWorks(b!.localId, [
    const RosterFilm(code: 'IPX-707', title: '测试作品三', category: '无码'),
  ]);
  db.setWorkTagsForCode('mida-619', ['中文字幕', 'ハイビジョン']);
  db.setWorkTagsForCode('ssis-123', ['ハイビジョン']);
  db.setWorkTagsForCode('ipx-707', ['中文字幕']);
  for (final source in ActressRosterSourceId.values) {
    for (final phase in const ['roster', 'films']) {
      await db.saveCheckpoint(
        ActressSyncCheckpoint(
          source: source.name,
          phase: phase,
          finished: true,
        ),
      );
    }
  }
  final temp = Directory.systemTemp.createTempSync();
  final jsonDir = Directory('${temp.path}/actress_json')
    ..createSync(recursive: true);
  File('${jsonDir.path}/mjv011.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'list': [
        {
          'vod_id': 'mjv-mida-619',
          'vod_name': 'MIDA-619 测试作品',
          'vod_pic': '',
          'vod_actor': '八木奈奈',
          'vod_director': '',
          'vod_remarks': '高清',
          'vod_pubdate': '2026-01-01',
          'vod_area': '日本',
          'vod_year': '2026',
          'vod_content': '',
          'vod_play_from': 'mjv011',
          'vod_play_url': r'正片$https://example.test/mida619.m3u8',
          'type_name': '有码',
          'vod_code': 'MIDA-619',
          'vod_actress_pic': '',
        },
      ],
      'parse': 0,
      'jx': 0,
      'last_update': '2026-11-20T00:00:00',
    }),
  );
  final fallback = ActressJsonFallback(localJsonDir: jsonDir);
  await fallback.load();
  final crawl = _NoopCrawl(repository: FixtureRepository(), db: db);
  return (store: store, db: db, fallback: fallback, crawl: crawl);
}

Future<ui.Image> _captureImage(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  return image;
}

Future<void> _savePng(ui.Image image, String name) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes = data!.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  );
  Directory(_previewDir).createSync(recursive: true);
  File('$_previewDir/$name.png').writeAsBytesSync(bytes);
}

Widget _labelBar(String label) {
  return Container(
    width: double.infinity,
    color: Colors.black87,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    child: Text(
      label,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 10,
        fontFamily: 'PreviewCJK',
      ),
    ),
  );
}

void main() {
  setUpAll(() async {
    try {
      // 思源黑体 CN（nexhub_ref 资产）：覆盖假名，标签里的日文假名
      // 才能在预览图里显示；cjk_subset.ttf 是子集字库，假名会显示为空白。
      final bytes = File(
        '/home/hatch/workspace/nexhub_ref/assets/fonts/SourceHanSansCN-Regular.otf',
      ).readAsBytesSync();
      final loader = FontLoader('PreviewCJK')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
    try {
      // Material 图标字库：不加载时图标在预览图里是空方框。
      final bytes = File(
        '/home/hatch/workspace/tools/flutter-3.50.0/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ).readAsBytesSync();
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
  });

  setUp(() async {
    final seed = await _seed();
    _previewStore = seed.store;
    _previewDb = seed.db;
    _previewFallback = seed.fallback;
    _previewCrawl = seed.crawl;
    await ActressMytvBind.instance.ensureBound();
  });

  testWidgets('preview tag sheet with real tags', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(_previewStore.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _previewTheme(),
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'PreviewCJK'),
            child: Scaffold(
              body: Column(
                children: [
                  _labelBar('预览 · 标签弹窗 · 真标签前 30 名（数据库实查数）'),
                  Expanded(
                    child: ActressTagSheet(
                      tags: _realTopTags,
                      selected: '中文字幕',
                      onSelected: (_) {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('ハイビジョン（183579）'), findsOneWidget);
    expect(find.text('30 个'), findsOneWidget);
    await _savePng(await _captureImage(tester, key), 'tag_sheet');
  });

  testWidgets('preview list with tag selected', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(_previewStore.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _previewTheme(),
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'PreviewCJK'),
            child: Scaffold(
              body: Column(
                children: [
                  _labelBar('预览 · 假数据 · 选标签“ハイビジョン”后只留八木奈奈'),
                  Expanded(
                    child: ActressListPage(
                      repository: FixtureRepository(),
                      store: _previewStore,
                      database: _previewDb,
                      fallback: _previewFallback,
                      crawlService: _previewCrawl,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('八木奈奈'), findsOneWidget);
    expect(find.text('测试二号'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('actress-tag-open')));
    await _settle(tester);
    expect(find.text('ハイビジョン（2）'), findsOneWidget);
    await tester.tap(find.text('ハイビジョン（2）'));
    await _settle(tester);
    expect(find.text('标签：ハイビジョン'), findsOneWidget);
    expect(find.text('八木奈奈'), findsOneWidget);
    expect(find.text('测试二号'), findsNothing);
    await _savePng(await _captureImage(tester, key), 'list_tagged');
  });
}
