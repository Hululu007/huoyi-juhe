import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/tgdrama_phone_login.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tgdrama_phone_login_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  TgdramaPhoneLoginService serviceWith() {
    return TgdramaPhoneLoginService(docsDir: tempDir);
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
