// 网盘页 115 区「详情页自动离线」开关（活一关闸，
// 2026-11-27）：默认开、点关即落盘。
// 单独成文件：网盘主体与设置单例带静态状态，与详情页
// 套件同文件互扰（单跑稳过），按本仓惯例隔离单跑。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/cloud_drive/cloud_drive_screen.dart';
import 'package:fqapp/cloud_drive/cloud_drive_settings.dart';
import 'package:fqapp/cloud_drive/cloud_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('115 卡内「详情页自动离线」默认开，点关落盘', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // 偏好/设置都是真异步期约：假时钟区里直接 await 会
    // 死锁，走 runAsync 真区取（本仓通行做法）。
    final prefs = await tester.runAsync(() => SharedPreferences.getInstance());
    final settings = await tester.runAsync(() => CloudDriveSettings.load());
    expect(settings!.actressAutoOffline, isTrue);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CloudDriveBody(
            settings: settings,
            providers: [Pan115Provider()],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final switchFinder = find.byKey(
      const ValueKey('cloud-drive-auto-offline-switch'),
    );
    expect(switchFinder, findsOneWidget);
    expect(find.text('详情页自动离线'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
    await tester.tap(switchFinder);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
    expect(settings.actressAutoOffline, isFalse);
    expect(prefs!.getBool(CloudDriveSettings.actressAutoOfflineKey), isFalse);
  });
}
