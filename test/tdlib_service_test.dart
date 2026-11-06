import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/tdlib_service.dart';

/// 1x1 透明 PNG（Kotlin 侧 ZXing 生成的二维码 PNG 的替身）。
const _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TdlibAuthState.fromMap：状态机各状态都解析', () {
    test('initializing', () {
      final state =
          TdlibAuthState.fromMap(<String, dynamic>{'state': 'initializing'});
      expect(state.status, TdlibAuthStatus.initializing);
      expect(state.isReady, isFalse);
    });

    test('waitPhoneNumber：等用户选手机号或扫码', () {
      final state = TdlibAuthState.fromMap(<String, dynamic>{
        'state': 'waitPhoneNumber',
      });
      expect(state.status, TdlibAuthStatus.waitPhoneNumber);
    });

    test('waitCode：收码号码、有效秒数、报错、提交中都带上', () {
      final state = TdlibAuthState.fromMap(<String, dynamic>{
        'state': 'waitCode',
        'phoneNumber': '+8613800000000',
        'timeout': 60,
        'error': '验证码不正确',
        'checking': true,
      });
      expect(state.status, TdlibAuthStatus.waitCode);
      expect(state.phoneNumber, '+8613800000000');
      expect(state.timeout, 60);
      expect(state.error, '验证码不正确');
      expect(state.checking, isTrue);
    });

    test('waitRegistration：未注册号填名字', () {
      final state = TdlibAuthState.fromMap(<String, dynamic>{
        'state': 'waitRegistration',
      });
      expect(state.status, TdlibAuthStatus.waitRegistration);
    });

    test('showQr：链接与二维码字节都带上', () {
      final state = TdlibAuthState.fromMap(<String, dynamic>{
        'state': 'showQr',
        'link': 'tg://login?token=abc',
        'qrPngBase64': _tinyPngBase64,
      });
      expect(state.status, TdlibAuthStatus.showQr);
      expect(state.link, 'tg://login?token=abc');
      expect(state.qrPngBytes, isNotNull);
      expect(state.qrPngBytes!.lengthInBytes, greaterThan(0));
    });

    test('showQr：二维码损坏时不炸，只丢图', () {
      final state = TdlibAuthState.fromMap(<String, dynamic>{
        'state': 'showQr',
        'link': 'tg://login?token=abc',
        'qrPngBase64': '!!!不是 base64!!!',
      });
      expect(state.status, TdlibAuthStatus.showQr);
      expect(state.qrPngBytes, isNull);
    });

    test('waitPassword：提示、报错、提交中都带上', () {
      final state = TdlibAuthState.fromMap(<String, dynamic>{
        'state': 'waitPassword',
        'hint': '我家猫的名字',
        'error': '密码不正确',
        'checking': true,
      });
      expect(state.status, TdlibAuthStatus.waitPassword);
      expect(state.hint, '我家猫的名字');
      expect(state.error, '密码不正确');
      expect(state.checking, isTrue);
    });

    test('ready', () {
      final state =
          TdlibAuthState.fromMap(<String, dynamic>{'state': 'ready'});
      expect(state.status, TdlibAuthStatus.ready);
      expect(state.isReady, isTrue);
    });

    test('error：message 字段', () {
      final state = TdlibAuthState.fromMap(<String, dynamic>{
        'state': 'error',
        'message': '缺少 Telegram 凭证',
      });
      expect(state.status, TdlibAuthStatus.error);
      expect(state.error, '缺少 Telegram 凭证');
    });

    test('signingOut 与 loggedOut', () {
      expect(
        TdlibAuthState.fromMap(<String, dynamic>{'state': 'signingOut'})
            .status,
        TdlibAuthStatus.signingOut,
      );
      expect(
        TdlibAuthState.fromMap(<String, dynamic>{'state': 'loggedOut'})
            .status,
        TdlibAuthStatus.loggedOut,
      );
    });

    test('未知状态回落到 initializing，不炸', () {
      final state = TdlibAuthState.fromMap(<String, dynamic>{
        'state': 'something_new',
      });
      expect(state.status, TdlibAuthStatus.initializing);
    });
  });

  group('TdlibUser.displayName', () {
    test('名 + 姓', () {
      const user = TdlibUser(id: 1, firstName: '张', lastName: '三');
      expect(user.displayName, '张 三');
    });

    test('没名字时退回 @用户名', () {
      const user = TdlibUser(id: 1, firstName: '', lastName: '', username: 'zhangsan');
      expect(user.displayName, '@zhangsan');
    });

    test('什么都没有时显示“已登录”', () {
      const user = TdlibUser(id: 1, firstName: '', lastName: '');
      expect(user.displayName, '已登录');
    });

    test('fromMap', () {
      final user = TdlibUser.fromMap(<String, dynamic>{
        'id': 123,
        'firstName': '李',
        'lastName': '四',
        'username': 'lisi',
        'phoneNumber': '+8613800000000',
      });
      expect(user.id, 123);
      expect(user.displayName, '李 四');
      expect(user.username, 'lisi');
      expect(user.phoneNumber, '+8613800000000');
    });
  });

  group('TdlibService 通道调用（假 MethodChannel + 假 EventChannel）', () {
    const methodChannel = MethodChannel('fqapp/tdlib');
    const eventChannelName = 'fqapp/tdlib/events';
    const codec = StandardMethodCodec();
    late Directory tempDir;
    late TdlibService service;
    late List<MethodCall> methodCalls;
    late Map<String, dynamic>? initializeArgs;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('tdlib_test_');
      methodCalls = <MethodCall>[];
      initializeArgs = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
        methodCalls.add(call);
        switch (call.method) {
          case 'initialize':
            initializeArgs =
                Map<String, dynamic>.from(call.arguments as Map);
            return <String, dynamic>{'state': 'initializing'};
          case 'getState':
            return <String, dynamic>{'state': 'ready'};
          case 'requestQrCode':
            return <String, dynamic>{
              'state': 'showQr',
              'link': 'tg://login?token=xyz',
              'qrPngBase64': _tinyPngBase64,
            };
          case 'submitPassword':
          case 'logOut':
            return null;
          case 'sendPhoneCode':
            return <String, dynamic>{
              'action': 'sent',
              'phoneNumber': (call.arguments as Map)['phone'],
            };
          case 'checkCode':
          case 'resendCode':
          case 'register':
            return null;
          case 'restart':
            return <String, dynamic>{'state': 'waitPhoneNumber'};
          case 'getMe':
            return <String, dynamic>{
              'id': 7,
              'firstName': '王',
              'lastName': '五',
              'username': 'wangwu',
              'phoneNumber': '+8613900000000',
            };
          default:
            throw MissingPluginException('unexpected ${call.method}');
        }
      });
      // EventChannel：listen/cancel 回空，事件由测试主动推。
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(eventChannelName, (ByteData? message) async {
        final call = codec.decodeMethodCall(message!);
        expect(
          call.method,
          anyOf('listen', 'cancel'),
        );
        return codec.encodeSuccessEnvelope(null);
      });
      service = TdlibService(supportDirProvider: () async => tempDir);
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(eventChannelName, null);
      await tempDir.delete(recursive: true);
    });

    Future<void> pushEvent(Map<String, dynamic> event) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        eventChannelName,
        codec.encodeSuccessEnvelope(event),
        (_) {},
      );
    }

    test('initialize：apiId 传 int、凭证不进日志、目录在应用支持目录下', () async {
      final state = await service.initialize();
      expect(state.status, TdlibAuthStatus.initializing);
      expect(initializeArgs, isNotNull);
      expect(initializeArgs!['apiId'], isA<int>());
      expect(initializeArgs!['apiId'], 12345);
      expect(initializeArgs!['apiHash'], 'testhash');
      expect(
        initializeArgs!['databaseDir'] as String,
        endsWith('/tdlib'),
      );
      expect(
        initializeArgs!['databaseDir'] as String,
        startsWith(tempDir.path),
      );
      expect(
        initializeArgs!['filesDir'] as String,
        endsWith('/tdlib-files'),
      );
    });

    test('getState / requestQrCode / submitPassword / logOut / getMe', () async {
      final state = await service.getState();
      expect(state.status, TdlibAuthStatus.ready);

      final qr = await service.requestQrCode();
      expect(qr.status, TdlibAuthStatus.showQr);
      expect(qr.link, 'tg://login?token=xyz');
      expect(qr.qrPngBytes, isNotNull);

      await service.submitPassword('pw123');
      final submit = methodCalls
          .firstWhere((call) => call.method == 'submitPassword');
      expect((submit.arguments as Map)['password'], 'pw123');

      await service.logOut();
      expect(
        methodCalls.any((call) => call.method == 'logOut'),
        isTrue,
      );

      final user = await service.getMe();
      expect(user.displayName, '王 五');
      expect(user.username, 'wangwu');
    });

    test('手机号登录：发码 / 输码 / 重发 / 注册 / 重启', () async {
      final action = await service.sendPhoneCode('+8613800000000');
      expect(action, 'sent');
      final sendCall = methodCalls
          .firstWhere((call) => call.method == 'sendPhoneCode');
      expect((sendCall.arguments as Map)['phone'], '+8613800000000');

      await service.checkCode('123456');
      final checkCall = methodCalls
          .firstWhere((call) => call.method == 'checkCode');
      expect((checkCall.arguments as Map)['code'], '123456');

      await service.resendCode();
      expect(
        methodCalls.any((call) => call.method == 'resendCode'),
        isTrue,
      );

      await service.register(firstName: '张', lastName: '三');
      final registerCall = methodCalls
          .firstWhere((call) => call.method == 'register');
      expect((registerCall.arguments as Map)['firstName'], '张');
      expect((registerCall.arguments as Map)['lastName'], '三');

      final restarted = await service.restart();
      expect(restarted.status, TdlibAuthStatus.waitPhoneNumber);
    });

    test('stateStream：WaitCode → WaitPassword → Ready 依次收到', () async {
      final received = <TdlibAuthState>[];
      final subscription = service.stateStream.listen(received.add);
      // 先让 listen 的握手走完。
      await Future<void>.delayed(Duration.zero);

      await pushEvent(<String, dynamic>{
        'state': 'waitCode',
        'phoneNumber': '+8613800000000',
        'timeout': 60,
      });
      await pushEvent(<String, dynamic>{
        'state': 'waitPassword',
        'hint': '提示',
      });
      await pushEvent(<String, dynamic>{'state': 'ready'});
      await Future<void>.delayed(Duration.zero);

      expect(
        received.map((state) => state.status).toList(),
        <TdlibAuthStatus>[
          TdlibAuthStatus.waitCode,
          TdlibAuthStatus.waitPassword,
          TdlibAuthStatus.ready,
        ],
      );
      expect(received[0].phoneNumber, '+8613800000000');
      expect(received[0].timeout, 60);
      expect(received[1].hint, '提示');
      expect(service.lastState.status, TdlibAuthStatus.ready);
      await subscription.cancel();
    });
  });
}
