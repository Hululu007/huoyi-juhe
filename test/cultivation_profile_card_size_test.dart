import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/widgets/mine/cultivation_profile_card.dart';

/// 道友档案卡回归：宽高比约 2:1（参考图），男女切换显示对应立绘。
Future<void> _seed(CultivationGender gender) async {
  SharedPreferences.setMockInitialValues({});
  final service = CultivationService.instance;
  await service.resetForTest();
  await service.ensureInitialized();
  await service.createProfile(
    gender: gender,
    sect: '黄枫谷',
    profession: '天道',
    costumeId: 'qing',
  );
  await service.addSeconds(CultivationCategory.novel, 1200);
  await service.addSeconds(CultivationCategory.comic, 600);
  await service.addSeconds(CultivationCategory.audio, 300);
  await service.addSeconds(CultivationCategory.video, 600);
  await service.addDramaEpisodeCompleted();
  await service.addDramaEpisodeCompleted();
}

Future<void> _pumpCard(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF0F0F14),
        body: SingleChildScrollView(
          child: CultivationProfileCard(totalTitles: 12, onOpenTitles: () {}),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('档案卡宽高比约 2:1（女）', (tester) async {
    await _seed(CultivationGender.female);
    await _pumpCard(tester);
    final size = tester.getSize(find.byType(CultivationProfileCard));
    final ratio = size.width / size.height;
    // ignore: avoid_print
    print('CARD_SIZE female w=${size.width} h=${size.height} ratio=${ratio.toStringAsFixed(3)}');
    expect(ratio, greaterThan(1.8));
    expect(ratio, lessThan(2.15));
    final image = tester.widget<Image>(find.byType(Image).first);
    expect((image.image as AssetImage).assetName,
        'assets/images/cultivation/profile_female.png');
  });

  testWidgets('档案卡宽高比约 2:1（男）', (tester) async {
    await _seed(CultivationGender.male);
    await _pumpCard(tester);
    final size = tester.getSize(find.byType(CultivationProfileCard));
    final ratio = size.width / size.height;
    // ignore: avoid_print
    print('CARD_SIZE male w=${size.width} h=${size.height} ratio=${ratio.toStringAsFixed(3)}');
    expect(ratio, greaterThan(1.8));
    expect(ratio, lessThan(2.15));
    final image = tester.widget<Image>(find.byType(Image).first);
    expect((image.image as AssetImage).assetName,
        'assets/images/cultivation/profile_male.webp');
  });
}
