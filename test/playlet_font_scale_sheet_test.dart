import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/short_series_font_scale.dart';
import 'package:fqapp/widgets/player/playlet_font_scale_sheet.dart';
import 'package:fqapp/widgets/series_detail/moyi_detail_theme.dart';

void main() {
  testWidgets('深色下字号弹层取浮层底与浅色字', (tester) async {
    // 弹层原来固定 #FAFAFA 底 + 黑字：深色主题下从深色播放器弹出来是一块
    // 白板。这里断言改为浮层色（surface）+ 色板字色。
    ShortSeriesFontScale.instance = 0;
    addTearDown(() => ShortSeriesFontScale.instance = 0);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPlayletFontScaleSheet(context),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(sheet.backgroundColor, moyiSheetFill);
    expect(
      tester.widget<Text>(find.text('字体大小')).style?.color,
      Colors.white,
    );
    // 选中档（标准）用白字，未选中档（大号）用魔蚁次级白。
    expect(
      tester.widget<Text>(find.text('标准')).style?.color,
      Colors.white,
    );
    expect(
      tester.widget<Text>(find.text('大号')).style?.color,
      moyiMutedOnDark,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('player-font-scale-preview')))
          .style
          ?.color,
      Colors.white,
    );
    expect(tester.takeException(), isNull);
  });
}
