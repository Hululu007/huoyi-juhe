import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/tgdrama_login_page.dart';
import 'package:fqapp/services/tgdrama_account.dart';
import 'package:fqapp/services/tgdrama_service.dart';
import 'package:fqapp/widgets/mine/tgdrama_account_row.dart';

/// 假的本地服务：不联网、不启动真进程，只按脚本回登录状态。
class FakeTgdramaService extends TgdramaService {
  bool running = true;
  bool authorized = false;

  @override
  Future<bool> ensureRunning() async => running;

  @override
  Future<TgdramaAuthStatus> authStatus() async {
    return TgdramaAuthStatus(
      authorized: authorized,
      needPassword: false,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTgdramaService fakeService;
  late TgdramaAccountStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    store = TgdramaAccountStore(prefs: prefs);
    fakeService = FakeTgdramaService();
  });

  tearDown(() {
    fakeService.dispose();
  });

  Future<void> pumpRow(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TgdramaAccountRow(
            service: fakeService,
            accountStore: store,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('未登录时显示“未登录”', (tester) async {
    fakeService.authorized = false;
    await pumpRow(tester);
    expect(find.text('Telegram'), findsOneWidget);
    expect(find.text('未登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已登录且有存下的标签时显示脱敏手机号', (tester) async {
    fakeService.authorized = true;
    await store.saveLabel('+86 138****5678');
    await pumpRow(tester);
    expect(find.text('+86 138****5678'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已登录但没有标签时显示“已登录”', (tester) async {
    fakeService.authorized = true;
    await pumpRow(tester);
    expect(find.text('已登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('服务起不来但有存下的标签时按已登录显示', (tester) async {
    fakeService.running = false;
    await store.saveLabel('+86 138****5678');
    await pumpRow(tester);
    expect(find.text('+86 138****5678'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点一行进登录页', timeout: const Timeout(Duration(seconds: 90)), (
    tester,
  ) async {
    fakeService.authorized = false;
    await pumpRow(tester);
    await tester.tap(find.text('Telegram'));
    // 只泵固定帧数验导航，不用 pumpAndSettle：登录页用的是真实服务，
    // 初始化会调 path_provider 等平台通道，pumpAndSettle 会被它拖住。
    // 注意别给 path_provider 加 mock——加了它登录页会继续往下走，
    // 去 rootBundle 里读 18MB 的 tgphone 助手，测试里会挂住。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(TgdramaLoginPage), findsOneWidget);
    expect(find.text('扫码登录'), findsOneWidget);
    // 登录页真实服务在测试里会报 MissingPluginException（path_provider
    // 未 mock），这里只验导航到页，不验它内部状态。
    expect(tester.takeException(), isNull);
  });
}
