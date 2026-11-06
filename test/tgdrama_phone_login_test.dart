import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/tgdrama_account.dart';
import 'package:fqapp/services/tgdrama_phone_login.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tgdrama_phone_login_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// 默认 assetLoader 抛错（模拟构建期未打助手进包），这样已有测试
  /// 只验文件在不在，不依赖真实 asset 包。
  TgdramaPhoneLoginService serviceWith({
    Future<ByteData> Function(String assetPath)? assetLoader,
    String? bundledApiId,
    String? bundledApiHash,
    Future<ProcessResult> Function(String executable, List<String> args)?
        runProcess,
    TgdramaAccountStore? accountStore,
  }) {
    return TgdramaPhoneLoginService(
      supportDir: tempDir,
      assetLoader:
          assetLoader ?? (_) async => throw StateError('no asset in test'),
      bundledApiId: bundledApiId,
      bundledApiHash: bundledApiHash,
      runProcess: runProcess,
      accountStore: accountStore,
    );
  }

  Future<void> putHelper() async {
    final file = File('${tempDir.path}/tgdrama/tgphone');
    await file.create(recursive: true);
    await file.writeAsString('fake-helper');
  }

  Future<void> putConfig(String content) async {
    final file = File('${tempDir.path}/tgdrama/config.yaml');
    await file.create(recursive: true);
    await file.writeAsString(content);
  }

  Future<void> putConfigWithCreds() async {
    await putConfig(
      'telegram:\n  api_id: 123456\n  api_hash: 0123456789abcdef0123456789abcdef\n',
    );
  }

  Future<TgdramaAccountStore> mockStore() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    return TgdramaAccountStore(prefs: prefs);
  }

  group('checkAvailability', () {
    test('助手不存在时不可用，reason 非空且让人先用扫码登录', () async {
      final service = serviceWith();
      final result = await service.checkAvailability();
      expect(result.available, isFalse);
      expect(result.reason, isNotEmpty);
      expect(result.reason, contains('扫码登录'));
    });

    test('助手在但 config 不存在时不可用', () async {
      await putHelper();
      final service = serviceWith();
      final result = await service.checkAvailability();
      expect(result.available, isFalse);
      expect(result.reason, contains('Telegram API 凭证'));
    });

    test('config 里没有 api_id/api_hash 时不可用', () async {
      await putHelper();
      await putConfig('telegram:\n  api_id: ""\n  api_hash: ""\n');
      final service = serviceWith();
      final result = await service.checkAvailability();
      expect(result.available, isFalse);
      expect(result.reason, contains('api_id'));
    });

    test('助手在且 config 里有凭证时可用', () async {
      await putHelper();
      await putConfig(
        'telegram:\n  api_id: 123456\n  api_hash: 0123456789abcdef0123456789abcdef\n',
      );
      final service = serviceWith();
      final result = await service.checkAvailability();
      expect(result.available, isTrue);
    });
  });

  group('ensureReady', () {
    test('asset 里有助手 + 注入凭证时，解出助手、写好 config，变可用', () async {
      final service = serviceWith(
        assetLoader: (_) async =>
            ByteData.view(Uint8List.fromList([1, 2, 3, 4]).buffer),
        bundledApiId: '123456',
        bundledApiHash: 'abcdef0123456789abcdef0123456789',
      );
      final ready = await service.ensureReady();
      expect(ready, isTrue);
      final helper = File('${tempDir.path}/tgdrama/tgphone');
      expect(await helper.exists(), isTrue);
      expect(await helper.readAsBytes(), [1, 2, 3, 4]);
      final config = File('${tempDir.path}/tgdrama/config.yaml');
      expect(await config.exists(), isTrue);
      final text = await config.readAsString();
      expect(text, contains('api_id: 123456'));
      expect(text, contains('api_hash: abcdef0123456789abcdef0123456789'));
      final availability = await service.checkAvailability();
      expect(availability.available, isTrue);
    });

    test('助手解出来了但没有凭证时，仍不可用', () async {
      final service = serviceWith(
        assetLoader: (_) async =>
            ByteData.view(Uint8List.fromList([9, 9, 9]).buffer),
      );
      final ready = await service.ensureReady();
      expect(ready, isFalse);
      final availability = await service.checkAvailability();
      expect(availability.available, isFalse);
      expect(availability.reason, contains('Telegram API 凭证'));
    });

    test('已有 config 带凭证时不覆盖，助手仍解', () async {
      await putConfig(
        'telegram:\n  api_id: 777\n  api_hash: deadbeef\n',
      );
      final service = serviceWith(
        assetLoader: (_) async =>
            ByteData.view(Uint8List.fromList([5, 6]).buffer),
        bundledApiId: '123456',
        bundledApiHash: 'abcdef',
      );
      final ready = await service.ensureReady();
      expect(ready, isTrue);
      final config = File('${tempDir.path}/tgdrama/config.yaml');
      expect(await config.readAsString(), contains('api_id: 777'));
    });
  });

  group('sendCode', () {
    test('助手不存在时直接抛 StateError，不跑进程', () async {
      final service = serviceWith();
      await expectLater(
        service.sendCode('13800000000'),
        throwsA(isA<StateError>()),
      );
    });

    test('config 无凭证时直接抛 StateError', () async {
      await putHelper();
      await putConfig('telegram:\n  api_id: 123\n');
      final service = serviceWith();
      await expectLater(
        service.sendCode('13800000000'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('api_hash'),
          ),
        ),
      );
    });
  });

  group('linker fallback', () {
    test('直接跑助手被拒时改走链接器兜底，发码成功', () async {
      await putHelper();
      await putConfigWithCreds();
      final calls = <String>[];
      final service = serviceWith(
        runProcess: (executable, args) async {
          calls.add(executable);
          if (executable == TgdramaPhoneLoginService.linker64Path) {
            // 模拟助手写出 state 文件。
            final state = File(
              '${tempDir.path}/tgdrama/phone_login_state.json',
            );
            await state.writeAsString('{"phone_code_hash": "abc123"}');
            return ProcessResult(0, 0, '', '');
          }
          throw ProcessException(executable, args, 'Permission denied', 13);
        },
      );
      await service.sendCode('13800000000');
      expect(calls.length, 2);
      expect(calls[1], TgdramaPhoneLoginService.linker64Path);
    });

    test('直接跑助手报非权限错时不走链接器，直接抛', () async {
      await putHelper();
      await putConfigWithCreds();
      final calls = <String>[];
      final service = serviceWith(
        runProcess: (executable, args) async {
          calls.add(executable);
          throw ProcessException(
            executable,
            args,
            'No such file or directory',
            2,
          );
        },
      );
      await expectLater(
        service.sendCode('13800000000'),
        throwsA(isA<ProcessException>()),
      );
      expect(calls.length, 1);
    });

    test('直接与链接器都被拒时抛错', () async {
      await putHelper();
      await putConfigWithCreds();
      final service = serviceWith(
        runProcess: (executable, args) async {
          throw ProcessException(executable, args, 'Permission denied', 13);
        },
      );
      await expectLater(
        service.sendCode('13800000000'),
        throwsA(isA<ProcessException>()),
      );
    });
  });

  group('verifyCode saves account label', () {
    test('验证码登录成功后存下脱敏手机号', () async {
      final store = await mockStore();
      await putHelper();
      await putConfigWithCreds();
      final state = File('${tempDir.path}/tgdrama/phone_login_state.json');
      await state.writeAsString('{"phone_code_hash": "abc123"}');
      final service = serviceWith(
        runProcess: (_, _) async => ProcessResult(0, 0, '', ''),
        accountStore: store,
      );
      await service.verifyCode(phone: '13812345678', code: '123456');
      expect(await store.readLabel(), '+86 138****5678');
    });

    test('验证码登录失败时不存标签', () async {
      final store = await mockStore();
      await putHelper();
      await putConfigWithCreds();
      final state = File('${tempDir.path}/tgdrama/phone_login_state.json');
      await state.writeAsString('{"phone_code_hash": "abc123"}');
      final service = serviceWith(
        runProcess: (_, _) async => ProcessResult(1, 1, 'error', ''),
        accountStore: store,
      );
      await expectLater(
        service.verifyCode(phone: '13812345678', code: '000000'),
        throwsA(isA<StateError>()),
      );
      expect(await store.readLabel(), isNull);
    });
  });

  group('parseTelegramCredentials', () {
    test('只取 telegram 小节下的两键，值去引号', () {
      final (apiId, apiHash) =
          TgdramaPhoneLoginService.parseTelegramCredentials(
        'other:\n  api_id: 999\ntelegram:\n  api_id: "123456"\n  api_hash: \'abcdef\'\n',
      );
      expect(apiId, '123456');
      expect(apiHash, 'abcdef');
    });

    test('没有 telegram 小节时返回空', () {
      final (apiId, apiHash) =
          TgdramaPhoneLoginService.parseTelegramCredentials(
        'foo: bar\n',
      );
      expect(apiId, isNull);
      expect(apiHash, isNull);
    });
  });

  group('normalizePhone', () {
    test('11 位手机号默认补 +86', () {
      expect(
        TgdramaPhoneLoginService.normalizePhone('13800000000'),
        '+8613800000000',
      );
    });

    test('带 +86 的全号原样保留', () {
      expect(
        TgdramaPhoneLoginService.normalizePhone('+8613800000000'),
        '+8613800000000',
      );
    });

    test('空格与横杠去掉', () {
      expect(
        TgdramaPhoneLoginService.normalizePhone('138-0000-0000'),
        '+8613800000000',
      );
    });
  });
}
