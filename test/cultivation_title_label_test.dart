import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/widgets/cultivation_title_label.dart';

void main() {
  testWidgets('每种称号特效都能构建并跑动画', (tester) async {
    for (final effect in CultivationTitleEffect.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: CultivationTitleLabel(
                title: '黄枫谷精英',
                effect: effect,
              ),
            ),
          ),
        ),
      );
      // 金色流光用两层同字 Text 叠加（底字 + 亮带），其余一层。
      expect(find.text('黄枫谷精英'), findsWidgets);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 1500));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('未达成称号半透明显示', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: CultivationTitleLabel(
              title: '仙界接引',
              effect: CultivationTitleEffect.rainbowGlowDots,
              dimmed: true,
            ),
          ),
        ),
      ),
    );
    expect(find.text('仙界接引'), findsOneWidget);
    expect(find.byType(Opacity), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
