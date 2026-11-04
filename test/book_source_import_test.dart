import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/source_registry.dart';

void main() {
  test('空输入不认', () {
    expect(classifyBookSourceInput(''), BookSourceImportKind.invalid);
    expect(classifyBookSourceInput('   \n '), BookSourceImportKind.invalid);
  });

  test('http(s) 链接走远程', () {
    expect(
      classifyBookSourceInput('https://example.com/sources.json'),
      BookSourceImportKind.remote,
    );
    expect(
      classifyBookSourceInput('http://example.com/x'),
      BookSourceImportKind.remote,
    );
    expect(
      classifyBookSourceInput('HTTPS://example.com/x'),
      BookSourceImportKind.remote,
    );
    expect(
      classifyBookSourceInput('  https://example.com/x \n'),
      BookSourceImportKind.remote,
    );
  });

  test('JSON 对象与数组走直接导入', () {
    expect(
      classifyBookSourceInput('{"bookSourceName":"x"}'),
      BookSourceImportKind.json,
    );
    expect(
      classifyBookSourceInput('[{"bookSourceName":"x"}]'),
      BookSourceImportKind.json,
    );
    expect(
      classifyBookSourceInput('  [{"a":1}]  '),
      BookSourceImportKind.json,
    );
  });

  test('既非链接又非 JSON 不认', () {
    expect(classifyBookSourceInput('notaurl'), BookSourceImportKind.invalid);
    expect(
      classifyBookSourceInput('ftp://example.com/x'),
      BookSourceImportKind.invalid,
    );
    expect(
      classifyBookSourceInput('legado://import'),
      BookSourceImportKind.invalid,
    );
  });
}
