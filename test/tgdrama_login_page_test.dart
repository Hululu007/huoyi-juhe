import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/tgdrama_login_page.dart';
import 'package:fqapp/services/tdlib_service.dart';
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

/// 假的 TDLib 服务：不碰通道，只按脚本回状态。
class FakeTdlibService extends TdlibService {
  final _controller = StreamController<TdlibAuthState>.broadcast();
  TdlibAuthState initialState =
      const TdlibAuthState(status: TdlibAuthStatus.waitPhoneNumber);
  String? initializeError;
  String? lastPhone;
  String? submittedCode;
  String? submittedPassword;
  int requestQrCalls = 0;
  int resendCalls = 0;
  int restartCalls = 0;
  int logOutCalls = 0;
  String? registeredFirstName;
  String? registeredLastName;
  TdlibUser userToReturn = const TdlibUser(
    id: 1,
    firstName: '张',
    lastName: '三',
    username: 'zhangsan',
  );

  static final Uint8List tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );

  void emit(TdlibAuthState state) => _controller.add(state);

  void dispose() => _controller.close();

  @override
  Stream<TdlibAuthState> get stateStream => _controller.stream;

  @override
  Future<TdlibAuthState> initialize() async {
    if (initializeError != null) throw StateError(initializeError!);
    _controller.add(initialState);
    return initialState;
  }

  @override
  Future<TdlibAuthState> restart() async {
    restartCalls++;
    const state = TdlibAuthState(status: TdlibAuthStatus.waitPhoneNumber);
    _controller.add(state);
    return state;
  }

  @override
  Future<String> sendPhoneCode(String phone) async {
    lastPhone = phone;
    return 'sent';
  }

  @override
  Future<void> checkCode(String code) async {
    submittedCode = code;
  }

  @override
  Future<void> resendCode() async {
    resendCalls++;
  }

  @override
  Future<void> register({required String firstName, String lastName = ''}) async {
    registeredFirstName = firstName;
    registeredLastName = lastName;
  }

  @override
  Future<TdlibAuthState> requestQrCode() async {
    requestQrCalls++;
    return initialState;
  }

  @override
  Future<void> submitPassword(String password) async {
    submittedPassword = password;
  }

  @override
  Future<void> logOut() async {
    logOutCalls++;
  }

  @override
  Future<TdlibUser> getMe() async => userToReturn;
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

  Future<void> pumpPageWithTdlib(
    WidgetTester tester,
    FakeTdlibService fakeTdlib,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TgdramaLoginPage(
          service: fakeService,
          phoneLoginService: fakePhone,
          tdlibService: fakeTdlib,
        ),
      ),
    );
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

  group('TDLib 应用内扫码登录', () {
    late FakeTdlibService fakeTdlib;

    setUp(() {
      fakeTdlib = FakeTdlibService();
    });

    tearDown(() {
      fakeTdlib.dispose();
    });

    testWidgets('TDLib 区可见，点开始扫码弹二维码大图，取消后可再查看',
        (tester) async {
      fakeTdlib.initialState = TdlibAuthState(
        status: TdlibAuthStatus.showQr,
        link: 'tg://login?token=abc',
        qrPngBytes: FakeTdlibService.tinyPng,
      );
      await pumpPageWithTdlib(tester, fakeTdlib);

      expect(find.text('手机号登录（TDLib 应用内）'), findsOneWidget);
      expect(find.text('开始扫码（TDLib）'), findsOneWidget);

      await tester.tap(find.text('开始扫码（TDLib）'));
      await tester.pump();
      await tester.pump();

      // 二维码弹窗大图（标题是弹窗的，页面标题带“应用内”后缀）。
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('扫码登录（TDLib）'),
        ),
        findsOneWidget,
      );
      expect(find.byType(Image), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('取消'),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('查看二维码'), findsOneWidget);
    });

    testWidgets('已登录过：初始化直接 Ready，显示当前用户名', (tester) async {
      fakeTdlib.initialState =
          const TdlibAuthState(status: TdlibAuthStatus.ready);
      await pumpPageWithTdlib(tester, fakeTdlib);

      await tester.tap(find.text('开始扫码（TDLib）'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('TDLib 已登录：张 三'), findsOneWidget);

      await tester.tap(find.text('退出登录'));
      await tester.pump();
      expect(fakeTdlib.logOutCalls, 1);
    });

    testWidgets('TDLib 二步验证：弹密码框，错一次显示错误，成功后关框显示已登录',
        (tester) async {
      fakeTdlib.initialState = const TdlibAuthState(
        status: TdlibAuthStatus.waitPassword,
        hint: '我家猫的名字',
      );
      await pumpPageWithTdlib(tester, fakeTdlib);

      await tester.tap(find.text('开始扫码（TDLib）'));
      await tester.pump();
      await tester.pump();

      expect(find.text('二步验证'), findsOneWidget);
      expect(find.text('密码提示：我家猫的名字'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('tdlib_password_field')),
        'pw123',
      );
      await tester.tap(find.text('提交'));
      await tester.pump();
      await tester.pump();

      expect(fakeTdlib.submittedPassword, 'pw123');

      // 密码错了：状态流重发带错误的 WaitPassword，错误更新在弹窗里。
      fakeTdlib.emit(const TdlibAuthState(
        status: TdlibAuthStatus.waitPassword,
        error: '密码不正确',
      ));
      await tester.pump();
      await tester.pump();
      expect(find.text('密码不正确'), findsOneWidget);
      expect(find.text('二步验证'), findsOneWidget);

      // 密码对了：状态流走到 Ready，弹窗关掉，显示已登录。
      fakeTdlib.emit(const TdlibAuthState(status: TdlibAuthStatus.ready));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('二步验证'), findsNothing);
      expect(find.text('TDLib 已登录：张 三'), findsOneWidget);
    });

    testWidgets('凭证缺失：初始化抛错，TDLib 区原样显示原因', (tester) async {
      fakeTdlib.initializeError = '缺少 Telegram 凭证，TDLib 扫码登录不可用';
      await pumpPageWithTdlib(tester, fakeTdlib);

      await tester.tap(find.text('开始扫码（TDLib）'));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('缺少 Telegram 凭证，TDLib 扫码登录不可用'),
        findsOneWidget,
      );
    });

    testWidgets('手机号主路：输号发码，弹窗输码，登上显示用户名', (tester) async {
      await pumpPageWithTdlib(tester, fakeTdlib);

      expect(find.text('手机号登录（TDLib 应用内）'), findsOneWidget);
      expect(find.text('发送验证码（TDLib）'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('tdlib_phone_field')),
        '13800000000',
      );
      await tester.tap(find.text('发送验证码（TDLib）'));
      await tester.pump();
      await tester.pump();

      expect(fakeTdlib.lastPhone, '+8613800000000');
      expect(find.text('输入验证码'), findsOneWidget);

      // 短信到了：状态流推 WaitCode，码框自动弹。
      fakeTdlib.emit(const TdlibAuthState(
        status: TdlibAuthStatus.waitCode,
        phoneNumber: '+8613800000000',
        timeout: 60,
      ));
      await tester.pump();
      await tester.pump();

      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('输入验证码'),
        ),
        findsOneWidget,
      );
      expect(find.text('验证码已发送到 +8613800000000，请在下方输入。'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('tdlib_code_field')),
        '123456',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('登录'),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(fakeTdlib.submittedCode, '123456');

      fakeTdlib.emit(const TdlibAuthState(status: TdlibAuthStatus.ready));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('TDLib 已登录：张 三'), findsOneWidget);
    });

    testWidgets('手机号输码错了：在弹窗里显示错误，可重输', (tester) async {
      await pumpPageWithTdlib(tester, fakeTdlib);

      await tester.enterText(
        find.byKey(const ValueKey('tdlib_phone_field')),
        '13800000000',
      );
      await tester.tap(find.text('发送验证码（TDLib）'));
      await tester.pump();
      await tester.pump();

      fakeTdlib.emit(const TdlibAuthState(
        status: TdlibAuthStatus.waitCode,
        phoneNumber: '+8613800000000',
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(
        find.byKey(const ValueKey('tdlib_code_field')),
        '000000',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('登录'),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(fakeTdlib.submittedCode, '000000');

      fakeTdlib.emit(const TdlibAuthState(
        status: TdlibAuthStatus.waitCode,
        phoneNumber: '+8613800000000',
        error: '验证码不正确，请重新输入',
      ));
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

      // 重发按钮调重发接口。
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('重新发送'),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(fakeTdlib.resendCalls, 1);
    });

    testWidgets('手机号换号：点“换个手机号”重建客户端', (tester) async {
      await pumpPageWithTdlib(tester, fakeTdlib);

      await tester.enterText(
        find.byKey(const ValueKey('tdlib_phone_field')),
        '13800000000',
      );
      await tester.tap(find.text('发送验证码（TDLib）'));
      await tester.pump();
      await tester.pump();

      expect(find.text('换个手机号'), findsOneWidget);
      await tester.tap(find.text('换个手机号'));
      await tester.pump();
      await tester.pump();

      expect(fakeTdlib.restartCalls, 1);
      expect(find.text('换个手机号'), findsNothing);
    });

    testWidgets('未注册号：输码后弹完善资料，填名完成注册', (tester) async {
      await pumpPageWithTdlib(tester, fakeTdlib);

      await tester.enterText(
        find.byKey(const ValueKey('tdlib_phone_field')),
        '13800000000',
      );
      await tester.tap(find.text('发送验证码（TDLib）'));
      await tester.pump();
      await tester.pump();

      fakeTdlib.emit(const TdlibAuthState(
        status: TdlibAuthStatus.waitCode,
        phoneNumber: '+8613800000000',
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(
        find.byKey(const ValueKey('tdlib_code_field')),
        '123456',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('登录'),
        ),
      );
      await tester.pump();
      await tester.pump();

      fakeTdlib.emit(
        const TdlibAuthState(status: TdlibAuthStatus.waitRegistration),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('完善资料'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('tdlib_first_name_field')),
        '张',
      );
      await tester.enterText(
        find.byKey(const ValueKey('tdlib_last_name_field')),
        '三',
      );
      await tester.tap(find.text('完成注册'));
      await tester.pump();
      await tester.pump();

      expect(fakeTdlib.registeredFirstName, '张');
      expect(fakeTdlib.registeredLastName, '三');

      fakeTdlib.emit(const TdlibAuthState(status: TdlibAuthStatus.ready));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('完善资料'), findsNothing);
      expect(find.text('TDLib 已登录：张 三'), findsOneWidget);
    });
  });
}
