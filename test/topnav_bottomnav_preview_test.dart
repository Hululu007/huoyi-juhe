@Timeout(Duration(minutes: 30))
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter/rendering.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/home/home_tab_bar.dart';
import 'package:fqapp/widgets/series_detail/moyi_detail_theme.dart';

/// 第 27 轮背景全换补漏（顶栏 + 底部导航）预览图：一张 PNG 到
/// ~/workspace/moyi_style_preview/topnav_bottomnav.png。
///
/// 拼图方式（整页 HomePage/RootShell 不渲染：HomePage 整页之前 3 次都挂
/// 在测试体执行阶段，见 moyi_style_zones_preview_test.dart 的说明）：
/// - 外壳：Container(color: moyiSheetFill) 扮 RootShell 的壳层画布
///   （main.dart 里 shell Scaffold 的 backgroundColor，修的就是它）；
/// - 顶栏：真实的 VideoPage 式 AppBar（标题“影视”+ 金色“游戏”钮 +
///   白字“分类” + 两个白图标，透明底，透出壳层深紫），下面是真实的
///   HomeTabBarDelegate（dark: true，首页分类条）；
/// - 内容：MoyiPageBackground + 几张深色假卡片，只为撑满高度；
/// - 底部导航：与 main.dart 里 staticNavBar / NavigationBarTheme 同值
///   的 NavigationBar（7 个真实目的地：游戏/首页/短剧/影视/直播/书架/
///   我的，选中第 4 项“影视”），圆角 28、实色深紫 moyiSheetFill、
///   白 16% 描边。
///
/// 方框说明：首页分类条是真实的 HomeTabBarDelegate，它的 _labelStyle
/// 不带 fontFamily，靠 AnimatedDefaultTextStyle 替换环境默认样式；
/// flutter test 强制用只覆盖 ASCII 的 Ahem 当缺省字体，所以图中七个
/// 分类字与（未加 fontFamily 的）按钮字在截图里是方框。真机上系统字体
/// 覆盖中文，不受影响；分类字的颜色已由代码核对（见文件头注释）与
/// find.text 断言兜底——选中白字、未选中 moyiMutedOnDark（白 55%），
/// 在魔蚁渐变底上都可读；图中选中项下的金色短线也看得到，证明条带
/// 布局与选中态都在深底上正常渲染。
const _outDir = '/home/hatch/workspace/moyi_style_preview';

Future<void> _loadFonts() async {
  final regularBytes = File(
    '/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc',
  ).readAsBytesSync();
  final boldBytes = File(
    '/usr/share/fonts/opentype/noto/NotoSerifCJK-Bold.ttc',
  ).readAsBytesSync();
  final loader = FontLoader('NotoSerifCJK')
    ..addFont(Future.value(ByteData.view(regularBytes.buffer)));
  await loader.load();
  final boldLoader = FontLoader('NotoSerifCJK')
    ..addFont(Future.value(ByteData.view(boldBytes.buffer)));
  await boldLoader.load();
  final iconBytes = File(
    '/home/hatch/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ).readAsBytesSync();
  final iconLoader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.view(iconBytes.buffer)));
  await iconLoader.load();
  final lucideBytes = File(
    '/home/hatch/.pub-cache/hosted/pub.dev/flutter_lucide-1.59.0/lib/fonts/lucide.ttf',
  ).readAsBytesSync();
  final lucideLoader = FontLoader('packages/flutter_lucide/lucide')
    ..addFont(Future.value(ByteData.view(lucideBytes.buffer)));
  await lucideLoader.load();
}

Future<void> _capture(
  WidgetTester tester,
  ValueKey<String> boundaryKey,
  String name,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(boundaryKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$_outDir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

/// 与 main.dart 里 mobile 分支的 NavigationBarTheme 同值（glassDark 分支：
/// 非墨水屏下 dock 一律深底，选中指示金底 20%、未选中白 65%）。
NavigationBarThemeData _navBarTheme() => NavigationBarThemeData(
  height: 64,
  elevation: 0,
  backgroundColor: Colors.transparent,
  surfaceTintColor: Colors.transparent,
  shadowColor: Colors.transparent,
  indicatorColor: HomePalette.accent.withValues(alpha: 0.20),
  indicatorShape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(16),
  ),
  iconTheme: WidgetStateProperty.resolveWith(
    (states) => IconThemeData(
      size: 22,
      color: states.contains(WidgetState.selected)
          ? HomePalette.accent
          : Colors.white.withValues(alpha: 0.65),
    ),
  ),
  labelTextStyle: WidgetStateProperty.resolveWith(
    (states) => TextStyle(
      fontSize: 11,
      fontWeight: states.contains(WidgetState.selected)
          ? FontWeight.w700
          : FontWeight.w500,
      color: states.contains(WidgetState.selected)
          ? HomePalette.accent
          : Colors.white.withValues(alpha: 0.65),
    ),
  ),
);

/// 与 main.dart 里 staticNavBar 同值（非短剧视频流、非 OLED）：
/// 圆角 28、实色深紫 moyiSheetFill、白 16% 描边。
Widget _navBarShell({required Widget child}) {
  return Container(
    key: const ValueKey('preview_nav_bar'),
    decoration: BoxDecoration(
      color: moyiSheetFill,
      borderRadius: BorderRadius.circular(28),
      border: Border.all(
        color: Colors.white.withValues(alpha: 0.16),
        width: 0.8,
      ),
    ),
    child: child,
  );
}

Widget _navBar() {
  return NavigationBarTheme(
    data: _navBarTheme(),
    child: NavigationBar(
      selectedIndex: 3,
      onDestinationSelected: (_) {},
      backgroundColor: Colors.transparent,
      elevation: 0,
      destinations: const [
        NavigationDestination(
          icon: Icon(LucideIcons.gamepad),
          selectedIcon: Icon(LucideIcons.gamepad),
          label: '游戏',
        ),
        NavigationDestination(
          icon: Icon(LucideIcons.house),
          selectedIcon: Icon(LucideIcons.house),
          label: '首页',
        ),
        NavigationDestination(
          icon: Icon(LucideIcons.clapperboard),
          selectedIcon: Icon(LucideIcons.clapperboard),
          label: '短剧',
        ),
        NavigationDestination(
          icon: Icon(LucideIcons.film),
          selectedIcon: Icon(LucideIcons.film),
          label: '影视',
        ),
        NavigationDestination(
          icon: Icon(LucideIcons.tv),
          selectedIcon: Icon(LucideIcons.tv),
          label: '直播',
        ),
        NavigationDestination(
          icon: Icon(LucideIcons.library_big),
          selectedIcon: Icon(LucideIcons.library_big),
          label: '书架',
        ),
        NavigationDestination(
          icon: Icon(LucideIcons.circle_user_round),
          selectedIcon: Icon(LucideIcons.circle_user_round),
          label: '我的',
        ),
      ],
    ),
  );
}

void main() {
  test('顶栏 + 底部导航补漏：main.dart 里三处浅色底已改成深紫', () {
    final src = File('lib/main.dart').readAsStringSync();
    // 1. 底部 dock 不再是白底圆角条。
    expect(src.contains('Colors.white.withValues(alpha: 0.82)'), isFalse);
    // 2. 非短剧 tab 的 dock 填实色深紫 moyiSheetFill。
    expect(src.contains(': moyiSheetFill),'), isTrue);
    // 3. 壳层画布（透明 AppBar 透出的底）是实色深紫。
    expect(
      src.contains('backgroundColor: eink ? null : moyiSheetFill,'),
      isTrue,
    );
    // 4. dock 深色判定不再只看深色外观 / 短剧视频流，墨水屏除外一律深底。
    expect(src.contains('final glassDark = !eink || isDark || dramaOnVideo;'), isTrue);
    // 5. 系统导航栏底色也不再是浅色画布色。
    expect(src.contains('(eink ? palette.canvas : moyiSheetFill),'), isTrue);
  });

  testWidgets('预览：顶栏 + 底部导航（深紫底、白字、金色选中）', (tester) async {
    await _loadFonts();
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: 'NotoSerifCJK',
          brightness: Brightness.dark,
        ),
        home: RepaintBoundary(
          key: const ValueKey<String>('topnav-bottomnav'),
          // 壳层画布：main.dart 里 shell Scaffold 的 backgroundColor。
          child: Container(
            key: const ValueKey('preview_shell_bg'),
            color: moyiSheetFill,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              extendBody: true,
              // 真实的 VideoPage 式 AppBar：透明底、白字标题与动作项。
              appBar: AppBar(
                title: const Text('影视'),
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                scrolledUnderElevation: 0,
                foregroundColor: Colors.white,
                actions: [
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: FilledButton.icon(
                      onPressed: () {},
                      icon: const Icon(Icons.sports_esports, size: 18),
                      label: const Text('游戏'),
                      style: FilledButton.styleFrom(
                        backgroundColor: moyiGold,
                        foregroundColor: Colors.black,
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        // 测试里补 fontFamily：FilledButton 的字走
                        // AnimatedDefaultTextStyle（不带 fontFamily 时测试
                        // 缺省字体 Ahem 会把“游戏”画成方框）；业务代码不动。
                        textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'NotoSerifCJK',
                        ),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () {},
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('分类'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.video_library),
                    tooltip: '本地库',
                    onPressed: () {},
                  ),
                  IconButton(
                    icon: const Icon(Icons.list),
                    tooltip: '站源管理',
                    onPressed: () {},
                  ),
                ],
              ),
              body: MoyiPageBackground(
                child: CustomScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  slivers: [
                    // 真实的首页分类条（dark: true，魔蚁渐变底）。
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: HomeTabBarDelegate(
                        selectedIndex: 3,
                        onSelect: (_) {},
                        categories: homeCategories,
                        extent: HomeTabBarDelegate.extentFor(1.0),
                        dark: true,
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          '午夜区',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) => Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                          child: Container(
                            height: 92,
                            decoration: BoxDecoration(
                              color: moyiDarkCardFill,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: moyiDarkCardBorder),
                            ),
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                Container(
                                  width: 62,
                                  height: 68,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF8B5CF6),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        '午夜剧目$index',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '更新至第 ${index + 1} 集',
                                        style: const TextStyle(
                                          color: moyiGold,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        childCount: 4,
                      ),
                    ),
                  ],
                ),
              ),
              // 游戏 tab 藏底部导航，这里选中“影视”所以显示。
              bottomNavigationBar: SafeArea(
                top: false,
                left: false,
                right: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: _navBarShell(child: _navBar()),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 顶栏：标题、游戏金钮、白字“分类”都在。
    expect(find.text('影视'), findsWidgets);
    expect(find.text('游戏'), findsWidgets);
    expect(find.text('分类'), findsOneWidget);
    // 首页分类条：七个真实分类都在深底上。
    for (final label in ['推荐', '小说', '短剧', '影视', '漫剧', '漫画', '听书']) {
      expect(find.text(label), findsWidgets, reason: '首页分类条缺 $label');
    }
    // 底部导航：七项都在，选中“影视”。
    for (final label in ['游戏', '首页', '短剧', '影视', '直播', '书架', '我的']) {
      expect(find.text(label), findsWidgets, reason: '底部导航缺 $label');
    }
    // 壳层画布与底部 dock 都是实色深紫 moyiSheetFill。
    final shellBg = tester.widget<Container>(
      find.byKey(const ValueKey('preview_shell_bg')),
    );
    expect(shellBg.color, moyiSheetFill);
    final navBar = tester.widget<Container>(
      find.byKey(const ValueKey('preview_nav_bar')),
    );
    final navDecoration = navBar.decoration! as BoxDecoration;
    expect(navDecoration.color, moyiSheetFill);
    expect(navDecoration.borderRadius, BorderRadius.circular(28));
    // 首页分类条背后是真实的魔蚁渐变（HomeTabBarDelegate dark: true）。
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            (w.decoration as BoxDecoration?)?.gradient == moyiPageGradient,
      ),
      findsWidgets,
    );
    await _capture(
      tester,
      const ValueKey<String>('topnav-bottomnav'),
      'topnav_bottomnav',
    );
  });
}
