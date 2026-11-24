// 类型文件夹视图预览截图（2026-11-24 文件夹视图）。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、超时杀掉只取 PNG；不要把多张放进同一个
// 测试体，也不要批量跑。
// 文件夹是真数据：2026-11-24 从女优库.db 实查的 26 个 type_name
// 全量分组计数（总和 449,068）；文件夹里的视频行是假数据（封面
// 为空显示番号占位），每张图顶栏都写明。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_database.dart';
import 'package:fqapp/actress/actress_film_library.dart';
import 'package:fqapp/actress/actress_generic_db.dart';
import 'package:fqapp/actress/actress_mytv_bind.dart';
import 'package:fqapp/actress/actress_nvku_page.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'actress_fixtures.dart';

const _previewDir = '/home/hatch/workspace/xiuxian_actress_port_20261124/preview';

// 真文件夹数据：女优库.db type_name 全量分组计数（2026-11-24 实查）。
const _realFolders = <(String, int)>[
  ('成人影片', 339840),
  ('国产精品', 31555),
  ('无码专区', 11847),
  ('卡通动漫', 11110),
  ('伦理三级', 10418),
  ('巨乳美乳', 6234),
  ('群交淫乱', 5587),
  ('欧美性爱', 4950),
  ('亚洲有码', 4176),
  ('制服丝袜', 4159),
  ('中文字幕', 4120),
  ('国产传媒', 3810),
  ('角色扮演', 3222),
  ('少女萝莉', 3115),
  ('黑料吃瓜', 2823),
  ('人妖伪娘', 1678),
  ('日本AV', 51),
  ('无码', 51),
  ('国产自拍', 48),
  ('H有码动画', 48),
  ('H无码动画', 48),
  ('H_3D动画', 48),
  ('H动画', 41),
  ('素人', 38),
  ('有码', 28),
  ('无码破解', 23),
];

// 各类型第一条视频的真实 pic_url（2026-11-24 从女优库.db 实查，
// ORDER BY vod_id 第一行；26 个全有封面，见
// verify/replay_folder_cover_sql.py）。测试环境离线拿不到真图，
// 下面的 pumpPage 把 preview/cover_sample.jpg（成人影片首条
// 003t28-262 的真实封面）预埋进图片缓存，26 张卡共用这一张
// 样本示意裁剪与版式——图注里如实写明，不说成各卡真图。
const _realFirstCovers = <String, String>{
  '成人影片': 'https://v.hersav.me/images/av/b523a6856db194ce24db61c5716c6838.jpg',
  '国产精品': 'https://fm.fhpicpic.com/upload/vod/20241205-1/309c8bd51fbdceaecb4e3c8a309f8b7f.jpg',
  '无码专区': 'https://sbzytpimg1.com:3519/upload/vod/20231013-1/8c48f6a560dd1e30908526fae4a414b8.jpg',
  '卡通动漫': 'https://fh.lbfh2025.com/upload/vod/20250830-1/f553df8abc3b1661f32498d483b65b5a.jpg',
  '伦理三级': 'https://z.fpabc2025.net/upload/vod/20250430-1/50368957bea9b31ceb4b8d56178d5db3.jpg',
  '巨乳美乳': 'https://z.fpabc2025.net/upload/vod/20200810/200GANA-2200.jpg',
  '群交淫乱': 'https://z.fpabc2025.net/upload/vod/2023/02/ybncukpa1qk.jpg',
  '欧美性爱': 'https://z.fpabc2025.net/upload/vod/20250503-1/93fc0865b7cfe311f67564e05082541b.jpg',
  '亚洲有码': 'https://sbzytpimg2.com:3519/upload/vod/20241111-1/02742a589398ef8a403d618f03c40746.jpg',
  '制服丝袜': 'https://sbzytpimg1.com:3519/upload/vod/20231003-1/c0789da8b11ccc4afbb546506be2e34c.jpg',
  '中文字幕': 'https://fchost1.eemmhh01.com/b/ei/CH65564.jpg',
  '国产传媒': 'https://sbzytpimg1.com:3519/upload/vod/20231025-34/b7ab07e14d883a5df774166ae827d5e4.jpg',
  '角色扮演': 'https://sbzytpimg2.com:3519/upload/vod/20241111-1/78ea5cb6c3fd3dbe1eb9b3c5e1220363.jpg',
  '少女萝莉': 'https://z.fpabc2025.net/upload/vod/20200715/200GANA-2195.jpg',
  '黑料吃瓜': 'https://sbzytpimg1.com:3519/upload/vod/20240508-1/e9c30cf866acf284b04ee1e1ea2d1bdf.jpg',
  '人妖伪娘': 'https://z.fpabc2025.net/upload/vod/2022/07/ihfvifmsx4j.jpg',
  '日本AV': 'https://v.hersav.me/images/av/9ccfe55d19edb98fd8eced62e450dd41.jpg',
  '无码': 'https://fbhost1.eemmhh01.com/b/uncensored/112643_060626_100.jpg',
  '国产自拍': 'https://fbhost1.eemmhh01.com/b/mic/pa233469.jpg',
  'H有码动画': 'https://fbhost1.eemmhh01.com/b/ei/HH07190.jpg',
  'H无码动画': 'https://fbhost1.eemmhh01.com/b/ei/HH06781.jpg',
  'H_3D动画': 'https://fchost1.eemmhh01.com/b/ei/TD01430.jpg',
  'H动画': 'https://fchost1.eemmhh01.com/b/ei/HH07197.jpg',
  '素人': 'https://v.hersav.me/images/av/6475f8686a041e3850a746ffd4f34e5f.jpg',
  '有码': 'https://v.hersav.me/images/av/bcde1fbce6743aea2c52c2fd695c39ba.jpg',
  '无码破解': 'https://v.hersav.me/images/av/a2bbd03cab3d997d0796dd64bc31c1c0.jpg',
};

/// 假影视库服务：文件夹用上面 26 个真计数；视频行是假数据。
/// 文件夹封面用各类型第一条视频的真实 pic_url（2026-11-24 从
/// 女优库.db 实查，ORDER BY vod_id 第一行；重放见
/// verify/replay_folder_cover_sql.py）。
class _PreviewFilmService extends FilmLibraryService {
  _PreviewFilmService({required super.database});

  @override
  Future<FilmLibraryOpenResult> open() async {
    return const FilmLibraryOpenResult(
      dbPath: '/fake/MYTV/db/女优库.db',
      displayPath: 'MYTV/db/女优库.db',
      strict: true,
      total: 449068,
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
    return _realFolders;
  }

  @override
  Future<Map<String, String>> typeFolderCovers({
    required List<String> typeNames,
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) async {
    return {
      for (final name in typeNames)
        if (_realFirstCovers[name] != null) name: _realFirstCovers[name]!,
    };
  }

  @override
  Future<({String key, List<(String, int)> values})> tags() async {
    return (
      key: 'video_tag.tag_name',
      values: const [('中文字幕', 21080), ('ハイビジョン', 183579)],
    );
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
    final all = [
      for (var i = 1; i <= 12; i++)
        FilmLibraryEntry(
          vodId: 'fake-$i',
          title: '假数据视频 $i（封面占位）',
          code: 'FAKE-$i',
          playUrl: 'https://example.test/fake$i.m3u8',
          typeName: typeName,
        ),
    ];
    return all.skip(offset).take(limit).toList();
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
    return 12;
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
  // 首屏加载里有真异步文件 IO，FakeAsync 定步 pump 等不到它完成
  // （见 AGENTS.md 2026-11-18 条）；runAsync 里用真时间轮询、块
  // 内 pump，否则截出来的是转圈。
  await tester.runAsync(() async {
    for (var i = 0; i < 30; i++) {
      try {
        await Future.delayed(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 100));
      } catch (_) {}
    }
  });
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
      // 思源黑体 CN：覆盖假名，文件夹/标签里的日文才能显示；
      // cjk_subset.ttf 是子集字库，假名会显示为空白。
      final bytes = File(
        '/home/hatch/workspace/nexhub_ref/assets/fonts/SourceHanSansCN-Regular.otf',
      ).readAsBytesSync();
      final loader = FontLoader('PreviewCJK')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
    try {
      // Material 图标字库：不加载时图标在预览图里是空方框
      // （文件夹图标、搜索/刷新/底部页签图标都看不见）。
      final bytes = File(
        '/home/hatch/workspace/tools/flutter-3.50.0/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ).readAsBytesSync();
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
  });

  late LocalStore store;
  late MemoryActressDatabase db;
  late _PreviewFilmService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore();
    db = MemoryActressDatabase();
    service = _PreviewFilmService(database: db);
    await ActressMytvBind.instance.ensureBound();
  });

  Future<void> pumpPage(WidgetTester tester, String label) async {
    // 封面预埋：把真实封面样本（cover_sample.jpg）按 26 个真实
    // pic_url 预埋进图片缓存，Image.network 在测试环境里不用走
    // 网络就能画出来；26 张卡共用这一张样本，图注里如实写明。
    final bytes = File(
      '$_previewDir/cover_sample.jpg',
    ).readAsBytesSync();
    final sample = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    });
    for (final url in _realFirstCovers.values) {
      PaintingBinding.instance.imageCache.putIfAbsent(
        NetworkImage(url),
        () => OneFrameImageStreamCompleter(
          Future.value(ImageInfo(image: sample!)),
        ),
      );
    }
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(store.dispose);
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
                  _labelBar(label),
                  Expanded(
                    child: ActressNvkuPage(
                      repository: FixtureRepository(),
                      store: store,
                      database: db,
                      filmService: service,
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
  }

  testWidgets('preview nvku folders home', (tester) async {
    await pumpPage(
      tester,
      '预览 · 文件夹封面为真实 pic_url（测试环境离线，26 张卡共用同一张真实封面样本示意裁剪）· 首页：顶栏库名 + 类型文件夹 + 最新上架',
    );
    expect(find.text('女优库.db'), findsOneWidget);
    expect(find.text('成人影片'), findsOneWidget);
    expect(find.text('共339840条'), findsOneWidget);
    // 26 张卡都有封面图（夹具作品没封面，首页的 Image 全是文件夹卡）。
    expect(find.byType(Image), findsNWidgets(26));
    final boundary = tester
        .element(find.byType(RepaintBoundary).first)
        .findRenderObject() as RenderRepaintBoundary;
    await _savePng(await boundary.toImage(pixelRatio: 2.0), 'nvku_home_folders');
  });

  testWidgets('preview nvku folders category', (tester) async {
    // 修仙版结构与魔蚁不同：分类 tab 仍是站点分类 + 作品网格
    // （不是文件夹网格页），点“分类”看到的是假站源的作品，
    // 文件夹网格只在首页；文件夹的钻取视图在下面那张 folder open 里。
    await pumpPage(
      tester,
      '预览 · 分类 tab（修仙版结构：站点分类 + 作品网格，文件夹网格在首页）· 假站源作品',
    );
    await tester.tap(find.text('分类'));
    await _settle(tester);
    expect(find.text('测试短剧'), findsOneWidget);
    expect(find.text('成人影片'), findsNothing);
    final boundary = tester
        .element(find.byType(RepaintBoundary).first)
        .findRenderObject() as RenderRepaintBoundary;
    await _savePng(
      await boundary.toImage(pixelRatio: 2.0),
      'nvku_category_works',
    );
  });

  testWidgets('preview nvku folder open', (tester) async {
    await pumpPage(tester, '预览 · 视频行假数据 · 点“成人影片”文件夹后的视频列表');
    await tester.tap(find.text('成人影片'));
    await _settle(tester);
    expect(find.text('成人影片 · 共12条'), findsOneWidget);
    expect(find.text('假数据视频 1（封面占位）'), findsOneWidget);
    final boundary = tester
        .element(find.byType(RepaintBoundary).first)
        .findRenderObject() as RenderRepaintBoundary;
    await _savePng(await boundary.toImage(pixelRatio: 2.0), 'nvku_folder_open');
  });
}
