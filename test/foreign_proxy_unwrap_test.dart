import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/drama_site_play.dart';

void main() {
  const target = 'https://cdn.example.com/v.m3u8?token=abc&exp=1';

  test('url 参数解出上游（含自身查询串）', () {
    final proxy =
        "http://127.0.0.1:9978/proxy?url=${Uri.encodeComponent(target)}";
    final unwrapped = unwrapForeignProxyUrl(proxy);
    expect(unwrapped?.target, target);
    expect(unwrapped?.headers, isEmpty);
  });

  test('u 参数解出上游', () {
    final proxy =
        "http://127.0.0.1:9978/proxy?u=${Uri.encodeComponent(target)}";
    expect(unwrapForeignProxyUrl(proxy)?.target, target);
  });

  test('双重编码的 url 参数再解一次', () {
    final twice = Uri.encodeComponent(Uri.encodeComponent(target));
    final proxy = 'http://127.0.0.1:9978/proxy?url=$twice';
    expect(unwrapForeignProxyUrl(proxy)?.target, target);
  });

  test('整个查询串就是 urlencoded 上游地址', () {
    final proxy =
        'http://127.0.0.1:9978/proxy?${Uri.encodeComponent(target)}';
    expect(unwrapForeignProxyUrl(proxy)?.target, target);
  });

  test('不透明令牌解不出，回空', () {
    expect(
      unwrapForeignProxyUrl('http://127.0.0.1:9978/proxy?token=abc123'),
      isNull,
    );
  });

  test('url 参数为空，回空', () {
    expect(
      unwrapForeignProxyUrl('http://127.0.0.1:9978/proxy?url='),
      isNull,
    );
  });

  test('查询里的 header JSON 一并取出', () {
    const headers = '{"Referer":"https://site.example/"}';
    final proxy =
        "http://127.0.0.1:9978/proxy?url=${Uri.encodeComponent(target)}"
        '&header=${Uri.encodeComponent(headers)}';
    final unwrapped = unwrapForeignProxyUrl(proxy);
    expect(unwrapped?.target, target);
    expect(unwrapped?.headers['Referer'], 'https://site.example/');
  });

  test('header 不是 JSON 时忽略，不影响解包', () {
    final proxy =
        "http://127.0.0.1:9978/proxy?url=${Uri.encodeComponent(target)}"
        '&header=not-json';
    final unwrapped = unwrapForeignProxyUrl(proxy);
    expect(unwrapped?.target, target);
    expect(unwrapped?.headers, isEmpty);
  });

  test('外来代理判定：9978/proxy 为真，普通地址与非 proxy 路径为假', () {
    expect(isForeignProxyUrl('http://127.0.0.1:9978/proxy?url=x'), isTrue);
    expect(isForeignProxyUrl('https://cdn.example.com/v.m3u8'), isFalse);
    expect(isForeignProxyUrl('http://127.0.0.1:8080/video.m3u8'), isFalse);
  });
}
