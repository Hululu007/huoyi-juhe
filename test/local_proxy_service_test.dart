import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/local_media_proxy.dart';
import 'package:fqapp/services/local_proxy_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LocalProxyPreferences.instance.resetForTest();
  });

  tearDown(() async {
    await LocalMediaProxy.instance.stop();
    LocalMediaProxy.instance.debugResetForTest();
    LocalProxyPreferences.instance.resetForTest();
  });

  test('本地代理偏好：默认开，关掉能落盘再读回', () async {
    await LocalProxyPreferences.instance.load();
    expect(LocalProxyPreferences.instance.enabled.value, isTrue);
    await LocalProxyPreferences.instance.setEnabled(false);
    expect(LocalProxyPreferences.instance.enabled.value, isFalse);
    LocalProxyPreferences.instance.resetForTest();
    await LocalProxyPreferences.instance.load();
    expect(LocalProxyPreferences.instance.enabled.value, isFalse);
  });

  test('本地代理：9978 起找空闲端口，全占顺延', () async {
    // 先占住 9978，再起服务：端口必须是 9978 之后的空闲端口。
    HttpServer? occupier;
    try {
      occupier = await HttpServer.bind(InternetAddress.loopbackIPv4, 9978);
    } catch (_) {
      // 测试机上 9978 已被占：只断言起在 9978–9998 段内。
      occupier = null;
    }
    try {
      final started = await LocalMediaProxy.instance.start();
      expect(started, isTrue);
      expect(LocalMediaProxy.instance.isRunning, isTrue);
      final port = LocalMediaProxy.instance.port!;
      expect(port, greaterThanOrEqualTo(9978));
      expect(port, lessThanOrEqualTo(9998));
      if (occupier != null) expect(port, isNot(9978));
      expect(
        LocalMediaProxy.instance.baseUrl,
        'http://127.0.0.1:$port',
      );
    } finally {
      await occupier?.close(force: true);
    }
  });

  test('本地代理：关着不起服务，register 回原地址、registerHandler 抛错',
      () async {
    await LocalProxyPreferences.instance.setEnabled(false);
    expect(LocalMediaProxy.instance.isRunning, isFalse);
    const target = 'http://127.0.0.1:9/none.m3u8';
    final direct = await LocalMediaProxy.instance.register(
      targetUrl: target,
      headers: const {},
    );
    expect(direct, target);
    expect(
      () => LocalMediaProxy.instance.registerHandler(
        handler: (_) async => null,
      ),
      throwsA(isA<StateError>()),
    );
    await LocalProxyPreferences.instance.setEnabled(true);
    final proxied = await LocalMediaProxy.instance.register(
      targetUrl: target,
      headers: const {},
    );
    expect(proxied, contains('/r/'));
  });

  test('本地代理：探活 / 回 200，/proxy 打包图片带 Referer 取回', () async {
    // 上游图床：没 Referer 就 406（仿 sex8 的图床），有就回假 JPEG。
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final imageBytes = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4];
    origin.listen((request) async {
      final referer = request.headers.value(HttpHeaders.refererHeader);
      if (referer != 'https://example.test/') {
        request.response.statusCode = HttpStatus.notAcceptable;
      } else {
        request.response.headers.contentType = ContentType('image', 'jpeg');
        request.response.add(imageBytes);
      }
      await request.response.close();
    });
    addTearDown(() => origin.close(force: true));

    final started = await LocalMediaProxy.instance.start();
    expect(started, isTrue);
    final base = LocalMediaProxy.instance.baseUrl;

    final probe = await http.get(Uri.parse('$base/'));
    expect(probe.statusCode, 200);
    expect(probe.body, 'local-proxy-ok');

    final payload = jsonEncode({
      's': 'sex8',
      'u': 'http://127.0.0.1:${origin.port}/pic.jpg',
      'r': 'https://example.test/',
    });
    final packed = base64Url.encode(utf8.encode(payload));
    final image = await http.get(
      Uri.parse('$base/proxy?type=img&site=sex8&p=$packed'),
    );
    expect(image.statusCode, 200);
    expect(image.bodyBytes, imageBytes);
    expect(image.headers['content-type'], contains('image/jpeg'));

    final ranged = await http.get(
      Uri.parse('$base/proxy?type=img&site=sex8&p=$packed'),
      headers: {HttpHeaders.rangeHeader: 'bytes=0-1'},
    );
    expect(ranged.statusCode, 206);
    expect(ranged.bodyBytes, [0xFF, 0xD8]);
  });

  test('本地代理：/proxy 解不开的载荷回 404，未接线 do/siteKey 回 404',
      () async {
    final started = await LocalMediaProxy.instance.start();
    expect(started, isTrue);
    final base = LocalMediaProxy.instance.baseUrl;

    final bad = await http.get(Uri.parse('$base/proxy?type=img&site=x&p=!!!'));
    expect(bad.statusCode, 404);

    final unbound = await http.get(
      Uri.parse('$base/proxy?do=py&siteKey=danai&u=http%3A%2F%2Fexample.test%2Fa.jpg'),
    );
    expect(unbound.statusCode, 404);

    LocalMediaProxy.instance.onProxyRequest = (_) async =>
        const LocalProxyResponse(status: 200, mime: 'image/jpeg', body: [9]);
    final bound = await http.get(
      Uri.parse('$base/proxy?do=py&siteKey=danai&u=http%3A%2F%2Fexample.test%2Fa.jpg'),
    );
    expect(bound.statusCode, 200);
    expect(bound.bodyBytes, [9]);
  });

}
