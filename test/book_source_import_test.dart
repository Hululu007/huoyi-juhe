import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/source_registry.dart';

SourceEntry _entry(String id, {String? contentType, SourceKind? kind}) {
  final extra = <String, dynamic>{};
  if (contentType != null) extra['contentType'] = contentType;
  return SourceEntry(
    id: id,
    name: id,
    kind: kind ?? SourceKind.legadoImport,
    extra: extra,
  );
}

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

  test('书源与影视源只按内容类型分', () {
    expect(isBookSourceEntry(_entry('n', contentType: 'novel')), isTrue);
    expect(isBookSourceEntry(_entry('c', contentType: 'comic')), isTrue);
    expect(isBookSourceEntry(_entry('a', contentType: 'audio')), isTrue);
    expect(isBookSourceEntry(_entry('v', contentType: 'video')), isFalse);
    expect(isBookSourceEntry(_entry('m', contentType: 'mixed')), isFalse);
    expect(isBookSourceEntry(_entry('d')), isFalse);
    // 导入方式不影响分界：py 小说源归书源，Legado 视频源归影视源。
    expect(
      isBookSourceEntry(
        _entry('py-novel', contentType: 'novel', kind: SourceKind.pyImport),
      ),
      isTrue,
    );
    expect(
      isBookSourceEntry(
        _entry('legado-video', contentType: 'video'),
      ),
      isFalse,
    );
  });
}
