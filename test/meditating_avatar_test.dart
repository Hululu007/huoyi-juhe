import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/widgets/meditating_avatar.dart';

void main() {
  testWidgets('builds at the default size', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: MeditatingAvatar())),
      ),
    );

    expect(find.byType(MeditatingAvatar), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MeditatingAvatar),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byType(MeditatingAvatar)),
      const Size(120, 120),
    );
  });

  testWidgets('builds at a custom size and animates for several frames',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: MeditatingAvatar(size: 80))),
      ),
    );

    expect(find.byType(MeditatingAvatar), findsOneWidget);
    expect(
      tester.getSize(find.byType(MeditatingAvatar)),
      const Size(80, 80),
    );

    // Let the single looping controller run through several frames,
    // covering more than one full 4-second cycle.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(find.byType(MeditatingAvatar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('female variant builds and animates', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: MeditatingAvatar(isFemale: true))),
      ),
    );

    expect(find.byType(MeditatingAvatar), findsOneWidget);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.byType(MeditatingAvatar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new api: costume, profession, face, hairstyle and hair color',
      (tester) async {
    // 新 API（服饰/职业/脸型/发型/发色）全传非默认值：画出来不炸，
    // 逍遥职业放飞轮技能、紫袍 + 银白发 + 高马尾也能画。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: MeditatingAvatar(
              size: 100,
              isFemale: true,
              costume: cultivationCostumeById('zi'),
              profession: '逍遥',
              face: '圆脸',
              hairstyle: '高马尾',
              hairColor: cultivationHairColorById('silver'),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(MeditatingAvatar), findsOneWidget);
    expect(
      tester.getSize(find.byType(MeditatingAvatar)),
      const Size(100, 100),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.byType(MeditatingAvatar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('autoCastSkill off still casts on tap', (tester) async {
    // 自动放技能关掉后，隔 7 秒也不自动放；点一下仍能放技能。
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: MeditatingAvatar(profession: '金刚', autoCastSkill: false),
          ),
        ),
      ),
    );

    expect(find.byType(MeditatingAvatar), findsOneWidget);
    await tester.pump(const Duration(seconds: 8));
    expect(find.byType(MeditatingAvatar), findsOneWidget);
    await tester.tap(find.byType(MeditatingAvatar));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(MeditatingAvatar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
