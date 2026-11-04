import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/midnight_gate.dart';

void main() {
  test('午夜口令：888888 对，别的都不对', () {
    expect(MidnightGate.checkPasscode('888888'), isTrue);
    expect(MidnightGate.checkPasscode(' 888888 '), isTrue);
    expect(MidnightGate.checkPasscode('123456'), isFalse);
    expect(MidnightGate.checkPasscode(''), isFalse);
    expect(MidnightGate.checkPasscode('88888'), isFalse);
    expect(MidnightGate.checkPasscode('8888888'), isFalse);
  });

  test('进门密码：123456 对，别的都不对', () {
    expect(MidnightGate.checkEntryPassword('123456'), isTrue);
    expect(MidnightGate.checkEntryPassword(' 123456 '), isTrue);
    expect(MidnightGate.checkEntryPassword('888888'), isFalse);
    expect(MidnightGate.checkEntryPassword(''), isFalse);
    expect(MidnightGate.checkEntryPassword('12345'), isFalse);
    expect(MidnightGate.checkEntryPassword('1234567'), isFalse);
  });
}
