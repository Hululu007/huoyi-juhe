import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/library_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/widgets/shelf/shelf_empty.dart';

/// 书架视觉对齐回归：三种空态同一套尺度、今日已读胶囊与筛选 chip 同款描边。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-shelf-visual-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
  });

  tearDown(() async {
    await Hive.close().timeout(
      const Duration(seconds: 10),
      onTimeout: () => const <void>[],
    );
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      // 临时目录清理失败只是噪音。
    }
  });

  testWidgets('三种书架空态统一 48dp 图标砖、20dp 内边距与 16sp 标题', (tester) async {
    final cases = <(Widget, String)>[
      (const ShelfEmptyState(), '书架暂无书籍'),
      (const ShelfEmptyHint(text: '暂无漫画'), '暂无漫画'),
      (const ShelfEmptyHint(text: '暂无听书'), '暂无听书'),
    ];
    // 每个空态的图标砖都是 build 里的第一个 Icon。
    for (final (state, title) in cases) {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: state)));
      await tester.pumpAndSettle();
      final iconFinder = find.byType(Icon).first;
      expect(tester.widget<Icon>(iconFinder).size, 48);
      final brick = tester.widget<Container>(
        find.ancestor(of: iconFinder, matching: find.byType(Container)).first,
      );
      expect(brick.padding, const EdgeInsets.all(20));
      final text = tester.widget<Text>(find.text(title));
      expect(text.style?.fontSize, 16);
      expect(text.style?.fontWeight, FontWeight.w600);
    }
  });

  testWidgets('浅色下今日已读胶囊不描边，与未选中 HomeChip 同款', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LibraryPage()));
    await tester.pumpAndSettle();
    final pill = tester.widget<Container>(
      find
          .ancestor(of: find.text('今日已读0分钟'), matching: find.byType(Container))
          .first,
    );
    expect((pill.decoration! as BoxDecoration).border, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('墨水屏下今日已读胶囊有黑描边，点漫画 tab 切到漫画空态', (tester) async {
    final original = einkModeNotifier.value;
    einkModeNotifier.value = true;
    addTearDown(() => einkModeNotifier.value = original);

    await tester.pumpWidget(const MaterialApp(home: LibraryPage()));
    await tester.pumpAndSettle();

    final pill = tester.widget<Container>(
      find
          .ancestor(of: find.text('今日已读0分钟'), matching: find.byType(Container))
          .first,
    );
    final pillBorder = (pill.decoration! as BoxDecoration).border;
    expect(pillBorder, isNotNull, reason: '白底胶囊需要黑描边才可见');
    expect((pillBorder! as Border).top.color, Colors.black);

    await tester.tap(find.text('漫画'));
    await tester.pumpAndSettle();
    expect(find.text('暂无漫画'), findsOneWidget);
    expect(find.text('书架暂无书籍'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
