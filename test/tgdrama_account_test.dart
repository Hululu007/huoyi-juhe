import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/tgdrama_account.dart';

void main() {
  group('maskPhone', () {
    test('+86 全号脱敏', () {
      expect(
        TgdramaAccountStore.maskPhone('+8613812345678'),
        '+86 138****5678',
      );
    });

    test('11 位号脱敏', () {
      expect(TgdramaAccountStore.maskPhone('13812345678'), '138****5678');
    });

    test('带空格横杠的号先去符号再脱敏', () {
      expect(
        TgdramaAccountStore.maskPhone('138-1234-5678'),
        '138****5678',
      );
    });

    test('太短原样返回，不遮成空', () {
      expect(TgdramaAccountStore.maskPhone('123'), '123');
      expect(TgdramaAccountStore.maskPhone(''), '');
    });
  });

  group('store', () {
    test('存取与清除', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = TgdramaAccountStore(prefs: prefs);
      expect(await store.readLabel(), isNull);
      await store.saveLabel('+86 138****5678');
      expect(await store.readLabel(), '+86 138****5678');
      await store.clearLabel();
      expect(await store.readLabel(), isNull);
    });

    test('空标签不存', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = TgdramaAccountStore(prefs: prefs);
      await store.saveLabel('');
      expect(await store.readLabel(), isNull);
    });
  });
}
