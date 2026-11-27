import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/bottom_nav_manage_page.dart';
import 'package:fqapp/services/bottom_nav_prefs.dart';
import 'package:fqapp/widgets/editable_bottom_nav_bar.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/series_detail/moyi_detail_theme.dart';

import 'preview_test_support.dart';

// 本批（xiuxian_bottomnav_20261127）预览：真渲染本批的底栏控件与
// 管理页，截图落本批 previews/ 目录。底栏外层 dock 按 main.dart
// 移动壳的静态底变体复刻（实色 moyiSheetFill + 圆角 28 + 边框 +
// 阴影），编辑工具条按 main.dart 里的同款文案与按钮复刻；底栏
// 本体与管理页都是产品真控件，不是仿画。
const _previewDir = '/home/hatch/workspace/xiuxian_bottomnav_20261127/previews';
const _boundaryKey = ValueKey<String>('bottom-nav-preview-boundary');

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundaryKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$_previewDir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

Widget _dockScene({
  required List<BottomNavTabDef> tabs,
  required String? selectedId,
  required bool editing,
  bool showToolbar = false,
  void Function(String, int)? onMove,
}) {
  final bar = EditableBottomNavBar(
    tabs: tabs,
    selectedId: selectedId,
    editing: editing,
    selectedColor: HomePalette.accent,
    selectedIconColor: HomePalette.accent,
    selectedLabelColor: HomePalette.accent,
    unselectedColor: Colors.white.withValues(alpha: 0.65),
    indicatorColor: HomePalette.accent.withValues(alpha: 0.20),
    onSelect: (_) {},
    onEnterEdit: () {},
    onHide: (_) {},
    onMove: onMove ?? (_, _) {},
  );
  // RepaintBoundary 包住整个 Overlay：拖动反馈小片挂在 Overlay 里，
  // 只包 dock 的话截图截不到反馈（首轮实测教训）。
  return MaterialApp(
    theme: ThemeData(brightness: Brightness.dark, fontFamily: 'NotoSansCJK'),
    home: RepaintBoundary(
      key: _boundaryKey,
      child: Overlay(
        initialEntries: [
          OverlayEntry(
            builder: (_) => Scaffold(
              backgroundColor: moyiSheetFill,
              body: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showToolbar) ...[
                  Container(
                    decoration: BoxDecoration(
                      color: moyiSheetFill,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.16),
                        width: 0.8,
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '拖动排序 · 点 － 隐藏',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () {},
                          child: const Text('管理'),
                        ),
                        TextButton(
                          onPressed: () {},
                          child: const Text('完成'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                Container(
                  decoration: BoxDecoration(
                    color: moyiSheetFill,
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.16),
                      width: 0.8,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.38),
                        blurRadius: 22,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: bar,
                ),
                  ],
                ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void barViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 460);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('预览1：默认态（7 页签，演员库未解锁显锁）', (tester) async {
    barViewport(tester);
    await loadPreviewFonts(tester, lucide: true);
    await tester.pumpWidget(
      _dockScene(
        tabs: bottomNavTabDefs(
          kBottomNavDefaultOrder,
          actressUnlocked: false,
        ),
        selectedId: 'home',
        editing: false,
      ),
    );
    await tester.pump();
    expect(find.text('演员库'), findsOneWidget);
    await _capture(tester, 'preview_nav_default');
  });

  testWidgets('预览2：编辑态（工具条 + 减号角标）', (tester) async {
    barViewport(tester);
    await loadPreviewFonts(tester, lucide: true);
    await tester.pumpWidget(
      _dockScene(
        tabs: bottomNavTabDefs(
          kBottomNavDefaultOrder,
          actressUnlocked: false,
        ),
        selectedId: 'home',
        editing: true,
        showToolbar: true,
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('bottom-nav-hide-mine')), findsOneWidget);
    await _capture(tester, 'preview_nav_editing');
  });

  testWidgets('预览3：拖动中（长按拖短剧向右）', (tester) async {
    barViewport(tester);
    await loadPreviewFonts(tester, lucide: true);
    final order = List<String>.of(kBottomNavDefaultOrder);
    await tester.pumpWidget(
      _dockScene(
        tabs: bottomNavTabDefs(order, actressUnlocked: true),
        selectedId: 'home',
        editing: true,
        showToolbar: true,
        onMove: (id, target) {
          final from = order.indexOf(id);
          if (from < 0 || from == target) return;
          order
            ..removeAt(from)
            ..insert(target, id);
        },
      ),
    );
    await tester.pump();
    final center = tester.getCenter(
      find.byKey(const Key('bottom-nav-tab-drama')),
    );
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 800));
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await _capture(tester, 'preview_nav_dragging');
    await gesture.up();
    await tester.pump();
  });

  testWidgets('预览4：只剩 4 个页签的补位态', (tester) async {
    barViewport(tester);
    await loadPreviewFonts(tester, lucide: true);
    await tester.pumpWidget(
      _dockScene(
        tabs: bottomNavTabDefs(
          const ['home', 'live', 'library', 'mine'],
          actressUnlocked: true,
        ),
        selectedId: 'live',
        editing: false,
      ),
    );
    await tester.pump();
    await _capture(tester, 'preview_nav_few_tabs');
  });

  testWidgets('预览5：底部导航管理页（真页）', (tester) async {
    tester.view.physicalSize = const Size(800, 1568);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await loadPreviewFonts(tester, lucide: true);
    SharedPreferences.setMockInitialValues(<String, Object>{
      kBottomNavHiddenKey: ['game', 'drama'],
    });
    final prefs = BottomNavPrefs();
    await prefs.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, fontFamily: 'NotoSansCJK'),
        home: RepaintBoundary(
          key: _boundaryKey,
          child: BottomNavManagePage(prefs: prefs, actressUnlocked: false),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('当前显示'), findsOneWidget);
    expect(find.text('已隐藏'), findsOneWidget);
    await _capture(tester, 'preview_nav_manage');
  });
}
