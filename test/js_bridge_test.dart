import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/js_bridge.dart';

void main() {
  test('JS 驱动脚本：按操作拼函数调用，参数做 JSON 编码', () {
    final driver = buildJsDriverScript(
      script: 'function homeContent(){return {class:[],list:[]};}',
      operation: 'category',
      tid: '1',
      page: 2,
    );
    expect(driver, contains('homeContent'));
    expect(driver, contains('fn("1", 2, false, {})'));
    expect(driver, contains('categoryContent'));
  });

  test('JS 驱动脚本：注入参数转义，不被引号打断', () {
    final driver = buildJsDriverScript(
      script: '',
      operation: 'search',
      query: 'a"b\\c',
      page: 1,
    );
    expect(driver, contains(r'fn("a\"b\\c", false, 1)'));
  });

  test('JS 结果解析：对象、列表与文本结果', () {
    expect(
      parseJsEvalResult('{"ok":true,"result":{"list":[]}}'),
      {'list': []},
    );
    expect(
      parseJsEvalResult('{"ok":true,"result":[{"vod_id":"1"}]}'),
      {
        'list': [
          {'vod_id': '1'},
        ],
      },
    );
    expect(
      parseJsEvalResult('{"ok":true,"result":"{\\"list\\":[]}"}'),
      {'list': []},
    );
    expect(
      () => parseJsEvalResult('{"ok":false,"error":"boom"}'),
      throwsStateError,
    );
    expect(
      () => parseJsEvalResult('{"ok":true,"result":"plain"}'),
      throwsStateError,
    );
  });

  test('JS 驱动脚本：不支持的操作抛错', () {
    expect(
      () => buildJsDriverScript(script: '', operation: 'bogus'),
      throwsStateError,
    );
  });

  test('JS 驱动脚本：本地代理操作调 localProxy，查询参数整包传过去', () {
    final driver = buildJsDriverScript(
      script: '',
      operation: 'proxy',
      params: {'do': 'play', 'id': '1'},
    );
    expect(driver, contains('localProxy'));
    expect(driver, contains('fn({"do":"play","id":"1"})'));
    expect(driver, contains("['proxy']"));
  });
}
