import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/tgdrama_login_page.dart';
import 'package:fqapp/services/tgdrama_phone_login.dart';
import 'package:fqapp/services/tgdrama_service.dart';

/// 假的本地服务：不联网、不启动真进程，只按脚本回登录状态。
class FakeTgdramaService extends TgdramaService {
  bool running = true;
  String? errorOverride;
  bool authorized = false;
  bool needPassword = false;
  bool qrStarted = false;
  String? submittedPassword;
  int authStatusCalls = 0;

  @override
  Future<bool> ensureRunning() async => running;

  @override
  String? get lastError => errorOverride;

  @override
  Future<TgdramaAuthStatus> authStatus() async {
    authStatusCalls++;
    return TgdramaAuthStatus(
      authorized: authorized,
      needPassword: needPassword,
    );
  }

  @override
  Future<void> startQrLogin() async {
    qrStarted = true;
  }

  @override
  String get qrImageUrl => 'http://127.0.0.1:5278/api/auth/qr.png';

  @override
  Future<void> submitPassword(String password) async {
    submittedPassword = password;
  }
}

/// 假的手机号登录服务：不跑进程，只按脚本回可用性与成败。
class FakePhoneLoginService extends TgdramaPhoneLoginService {
  bool available = false;
  String reason = '手机号登录暂不可用：缺少 Telegram API 凭证，请先用扫码登录';
  int sendCodeCalls = 0;
  int verifyCodeCalls = 0;
  String? lastCode;
  String? lastPassword;
  String? verifyError;
  bool verifyNeedsPassword = false;

  @override
  Future<PhoneLoginAvailability> checkAvailability() async {
    return PhoneLoginAvailability(available: available, reason: reason);
  }

  @override
  Future<void> sendCode(String phone) async {
    sendCodeCalls++;
    if (!available) throw StateError(reason);
  }

  @override
  Future<void> verifyCode({
    required String phone,
    required String code,
    String? password,
  }) async {
    verifyCodeCalls++;
    lastCode = code;
    lastPassword = password;
    if (verifyError != null) throw StateError(verifyError!);
    if (verifyNeedsPassword && (password == null || password.isEmpty)) {
      throw StateError('SESSION_PASSWORD_NEEDED：该账号开了二步验证');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTgdramaService fakeService;
  late FakePhoneLoginService fakePhone;

  setUp(() {
    fakeService = FakeTgdramaService();
    fakePhone = FakePhoneLoginService();
  });

  tearDown(() {
    fakeService.dispose();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TgdramaLoginPage(
          service: fakeService,
          phoneLoginService: fakePhone,
        ),
      ),
    );
    // 初始 ensureRunning + authStatus + checkAvailability 三个异步调用。
    await tester.pump();
    await tester.pump();
  }

  testWidgets('未登录时显示状态与两种登录区，手机号不可用原因原样显示',
      (tester) async {
    await pumpPage(tester);

    expect(find.text('未登录'), findsOneWidget);
    expect(find.text('扫码登录'), findsOneWidget);
    expect(find.text('手机号登录'), findsOneWidget);
    expect(find.text('开始扫码'), findsOneWidget);
    expect(find.text('发送验证码'), findsOneWidget);
    expect(find.text(fakePhone.reason), findsOneWidget);
    // 验证码/密码输入框不在页面里：只在弹窗里出现。
    expect(find.byKey(const ValueKey('tgdrama_code_field')), findsNothing);
    expect(
      find.byKey(const ValueKey('tgdrama_password_field')),
      findsNothing,
    );
  });

  testWidgets('服务未启动时显示未启动与重试', (tester) async {
    fakeService.running = false;
    fakeService.errorOverride = '本地服务未启动：测试原因';
    await pumpPage(tester);

    expect(find.text('本地服务未启动'), findsWidgets);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('扫码流程：点开始扫码出二维码，轮询成功显示登录成功', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('开始扫码'));
    await tester.pump();
    await tester.pump();

    expect(fakeService.qrStarted, isTrue);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('等待扫码…（最多 5 分钟）'), findsOneWidget);

    fakeService.authorized = true;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(find.text('登录成功'), findsOneWidget);
    expect(find.text('已登录'), findsOneWidget);
  });

  testWidgets('扫码二步验证：轮询到 needPassword 弹密码框，提交后继续轮询',
      (tester) async {
    fakeService.needPassword = true;
    await pumpPage(tester);

    await tester.tap(find.text('开始扫码'));
    await tester.pump();
    await tester.pump();

    // 轮询一轮，needPassword 为真即弹密码框。
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(find.text('二步验证'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('tgdrama_password_field')),
      'pw123',
    );
    await tester.tap(find.text('提交'));
    await tester.pump();
    await tester.pump();

    expect(fakeService.submittedPassword, 'pw123');
    expect(find.text('二步验证'), findsNothing);

    fakeService.needPassword = false;
    fakeService.authorized = true;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(find.text('登录成功'), findsOneWidget);
  });

  testWidgets('扫码密码框点取消：停轮询、回登录页状态', (tester) async {
    fakeService.needPassword = true;
    await pumpPage(tester);

    await tester.tap(find.text('开始扫码'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(find.text('二步验证'), findsOneWidget);
    // 密码框里的“取消”（页面扫码区也有一个“取消”，要限定在弹窗内）。
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('取消'),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('二步验证'), findsNothing);
    expect(find.text('开始扫码'), findsOneWidget);
    final callsAfterCancel = fakeService.authStatusCalls;
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(fakeService.authStatusCalls, callsAfterCancel);
  });

  testWidgets('手机号区点发送时服务不可用，页内原样显示中文原因', (tester) async {
    await pumpPage(tester);

    await tester.enterText(
      find.byKey(const ValueKey('tgdrama_phone_field')),
      '13800000000',
    );
    await tester.tap(find.text('发送验证码'));
    await tester.pump();
    await tester.pump();

    expect(fakePhone.sendCodeCalls, 1);
    expect(find.text(fakePhone.reason), findsWidgets);
    // 没弹验证码框：不可用时不假装发了码。
    expect(find.text('输入验证码'), findsNothing);
  });

  testWidgets('手机号可用：发码成功弹验证码框，输码登录成功', (tester) async {
    fakePhone.available = true;
    fakePhone.reason = '可用';
    fakeService.authorized = true;
    await pumpPage(tester);

    await tester.enterText(
      find.byKey(const ValueKey('tgdrama_phone_field')),
      '13800000000',
    );
    await tester.tap(find.text('发送验证码'));
    await tester.pump();
    await tester.pump();

    expect(fakePhone.sendCodeCalls, 1);
    // 验证码弹窗已弹（标题在弹窗内；页面里“输入验证码”按钮是另一个）。
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('输入验证码'),
      ),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('tgdrama_code_field')),
      '12345',
    );
    await tester.tap(find.text('登录'));
    await tester.pump();
    await tester.pump();

    expect(fakePhone.verifyCodeCalls, 1);
    expect(fakePhone.lastCode, '12345');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('登录成功'), findsOneWidget);
  });

  testWidgets('验证码输错：在弹窗里显示错误，可重输，不闪退', (tester) async {
    fakePhone.available = true;
    fakePhone.reason = '可用';
    fakePhone.verifyError = '验证码不正确，请重新输入';
    await pumpPage(tester);

    await tester.enterText(
      find.byKey(const ValueKey('tgdrama_phone_field')),
      '13800000000',
    );
    await tester.tap(find.text('发送验证码'));
    await tester.pump();
    await tester.pump();

    await tester.enterText(
      find.byKey(const ValueKey('tgdrama_code_field')),
      '00000',
    );
    await tester.tap(find.text('登录'));
    await tester.pump();
    await tester.pump();

    expect(find.text('验证码不正确，请重新输入'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('输入验证码'),
      ),
      findsOneWidget,
    );

    fakePhone.verifyError = null;
    await tester.enterText(
      find.byKey(const ValueKey('tgdrama_code_field')),
      '12345',
    );
    await tester.tap(find.text('登录'));
    await tester.pump();
    await tester.pump();

    expect(fakePhone.verifyCodeCalls, 2);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('手机号二步验证：验证码框提交后改弹密码框', (tester) async {
    fakePhone.available = true;
    fakePhone.reason = '可用';
    fakePhone.verifyNeedsPassword = true;
    fakeService.authorized = true;
    await pumpPage(tester);

    await tester.enterText(
      find.byKey(const ValueKey('tgdrama_phone_field')),
      '13800000000',
    );
    await tester.tap(find.text('发送验证码'));
    await tester.pump();
    await tester.pump();

    await tester.enterText(
      find.byKey(const ValueKey('tgdrama_code_field')),
      '12345',
    );
    await tester.tap(find.text('登录'));
    await tester.pump();
    await tester.pump();

    // 验证码框关了，密码框弹出来（页面里“输入验证码”按钮还在，
    // 所以只断言弹窗内没有“输入验证码”标题）。
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('输入验证码'),
      ),
      findsNothing,
    );
    expect(find.text('二步验证'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('tgdrama_password_field')),
      'pw123',
    );
    await tester.tap(find.text('提交'));
    await tester.pump();
    await tester.pump();

    expect(fakePhone.lastPassword, 'pw123');
    expect(find.text('二步验证'), findsNothing);
  });
}
