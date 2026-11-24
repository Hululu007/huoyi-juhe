// 女优 tab 第二排分类 + 男优列表预览截图（2026-11-24 合树批）。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、超时杀掉只取 PNG；不要把多张放进同一个
// 测试体，也不要批量跑。
// 人是合成数据；男优头像是真图：黒田悠斗的真实头像
// https://c0.jdbstatic.com/avatars/mm/MmXaX.jpg（新库里的值，
// 走代理下回来的 preview/male_avatar_sample.jpg 预埋进图片缓存，
// 测试环境离线也能画出来；图注里如实写明）。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_database.dart';
import 'package:fqapp/actress/actress_list_page.dart';
import 'package:fqapp/actress/actress_models.dart';
import 'package:fqapp/actress/actress_roster_sources.dart';
import 'package:fqapp/actress/actress_sync.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'actress_fixtures.dart';

const _previewDir = '/home/hatch/workspace/xiuxian_actress_port_20261124/preview';

/// 新库里男优头像的真地址（2026-11-24 实查：258 位男优全有头像，
/// 都是 c0.jdbstatic.com 这个域名，与女优同一路）。
const _maleAvatarUrl = 'https://c0.jdbstatic.com/avatars/mm/MmXaX.jpg';

Future<ActressHttpResponse> _unusedFetch(
  String url, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 20),
}) async => throw UnimplementedError('fake source must not fetch');

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

Widget _labelBar(String label) => Container(
  color: Colors.black,
  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
  child: Text(
    label,
    style: const TextStyle(color: Colors.white, fontSize: 13),
  ),
);

/// 首屏 _bootstrap 里有真异步文件 IO，FakeAsync 定步 pump 等不到它
/// 完成（见 AGENTS.md 2026-11-18 条）；必须在 runAsync 里用真
/// 时间轮询、块内 pump，否则截出来的是转圈。
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 30; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}

Future<ui.Image> _captureImage(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  return image;
}

Future<void> _savePng(ui.Image image, String name) async {
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  Directory(_previewDir).createSync(recursive: true);
  File('$_previewDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    try {
      final bytes = File(
        '/home/hatch/workspace/nexhub_ref/assets/fonts/SourceHanSansCN-Regular.otf',
      ).readAsBytesSync();
      final loader = FontLoader('PreviewCJK')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
    try {
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore();
    db = MemoryActressDatabase();
    // 男优 3 位（新库前 3 的真名 + 真作品数 + 真头像地址格式；
    // 头像只预埋黒田悠斗一张真图，其余两张回落首字圆圈，图注写明）。
    // 女优 2 位作对照。
    for (final (name, sex, works, avatar) in [
      ('ピエール剣', 'male', 214, ''),
      ('今井勇太', 'male', 210, ''),
      (
        '黒田悠斗',
        'male',
        138,
        _maleAvatarUrl,
      ),
      ('波多野結衣', 'female', 2636, ''),
      ('八木奈奈', 'female', 120, ''),
    ]) {
      final person = (await db.upsertRosterPerson(
        RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'id-$name',
          name: name,
          sex: sex,
          avatarUrl: avatar,
          worksHint: works,
        ),
      ))!;
      await db.upsertWorks(person.localId, [
        for (var i = 0; i < works; i++) RosterFilm(code: 'TST-$name-$i'),
      ], site: ActressRosterSourceId.chaoliu.name);
    }
  });

  Future<GlobalKey> pumpPage(WidgetTester tester, String label) async {
    // 头像预埋：黒田悠斗的真头像样本按库里的真地址预埋进图片缓存。
    final bytes = File(
      '$_previewDir/male_avatar_sample.jpg',
    ).readAsBytesSync();
    final sample = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    });
    PaintingBinding.instance.imageCache.putIfAbsent(
      NetworkImage(_maleAvatarUrl),
      () => OneFrameImageStreamCompleter(
        Future.value(ImageInfo(image: sample!)),
      ),
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(store.dispose);
    final sync = ActressSyncService(
      db: db,
      sources: const [],
      fetch: _unusedFetch,
    );
    addTearDown(sync.dispose);
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
                    child: ActressListPage(
                      repository: FixtureRepository(),
                      store: store,
                      database: db,
                      syncService: sync,
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
    return key;
  }

  testWidgets('preview actress tab tag row', (tester) async {
    final key = await pumpPage(
      tester,
      '预览 · 女优 tab：只有两排筛选（性别排 + 分类排三册全部/有码/无码/欧美/国产/4K/动漫/三级/其他）· 库名那排已删 · 人是合成数据',
    );
    await _savePng(await _captureImage(tester, key), 'nvku_tag_row');
  });

  testWidgets('preview actress tab male list', (tester) async {
    final key = await pumpPage(
      tester,
      '预览 · 点男优后只剩男优（新库真名+真作品数：ピエール剣 214、今井勇太 210、黒田悠斗 138）· 黒田悠斗头像是真图样本，其余回落首字圆圈',
    );
    await tester.tap(find.text('男优'));
    await _settle(tester);
    await _savePng(await _captureImage(tester, key), 'nvku_male_list');
  });
}
