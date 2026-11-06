import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fqapp/services/drama_site_content.dart';

http.Response _playJson({String? key}) {
  final data = <String, dynamic>{
    'm3u8': 'https://cdn.example.com/play.m3u8',
    'preview_m3u8': 'https://cdn.example.com/preview.m3u8',
    'preview_seconds': 60,
    'name': '剧名',
    'seq': 1,
  };
  if (key != null) data['hls_key'] = key;
  return http.Response.bytes(
    utf8.encode(jsonEncode({'data': data})),
    200,
  );
}

MockClient _mockPlayClient({String? key}) {
  return MockClient((request) async {
    if (request.url.toString().contains('/api/drama/play')) {
      return _playJson(key: key);
    }
    return http.Response('not found', 404);
  });
}

void main() {
  test('黄豆：实测返回的 32 位十六进制密钥不再报无效', () {
    expect(
      huangdouHlsKeyHex('5dcb7ed7d6e3b0c3499f76929de34b03'),
      '5dcb7ed7d6e3b0c3499f76929de34b03',
    );
  });

  test('黄豆：空密钥放行（无加密正片走空密钥）', () {
    expect(huangdouHlsKeyHex(''), '');
  });

  test('黄豆：大写十六进制密钥也接受', () {
    expect(
      huangdouHlsKeyHex('5DCB7ED7D6E3B0C3499F76929DE34B03'),
      '5DCB7ED7D6E3B0C3499F76929DE34B03',
    );
  });

  test('黄豆：长度不对或含非十六进制字符仍判无效', () {
    expect(() => huangdouHlsKeyHex('5dcb7ed7d6e3b0c3499f76929de34b0'),
        throwsStateError);
    expect(() => huangdouHlsKeyHex('gdcb7ed7d6e3b0c3499f76929de34b03'),
        throwsStateError);
    expect(
        () => huangdouHlsKeyHex('5dcb7ed7d6e3b0c3499f76929de34b03ff'),
        throwsStateError);
  });

  test('黄豆：取流带合法密钥时返回地址与密钥', () async {
    final client = HuangdouContentClient(
      _mockPlayClient(key: '5dcb7ed7d6e3b0c3499f76929de34b03'),
    );
    final source = await client.playSource(
      const DramaSiteEpisode(
        videoId: '1',
        title: '第 1 集',
        seriesId: 'abc123',
      ),
    );
    expect(source.url, 'https://cdn.example.com/play.m3u8');
    expect(source.keyHex, '5dcb7ed7d6e3b0c3499f76929de34b03');
  });

  test('黄豆：取流无密钥时返回空密钥不抛错', () async {
    final client = HuangdouContentClient(_mockPlayClient());
    final source = await client.playSource(
      const DramaSiteEpisode(
        videoId: '1',
        title: '第 1 集',
        seriesId: 'abc123',
      ),
    );
    expect(source.url, 'https://cdn.example.com/play.m3u8');
    expect(source.keyHex, '');
  });

  test('黄豆：取流密钥格式不对时仍抛无效密钥', () async {
    final client = HuangdouContentClient(
      _mockPlayClient(key: 'not-a-hex-key'),
    );
    expect(
      () => client.playSource(
        const DramaSiteEpisode(
          videoId: '1',
          title: '第 1 集',
          seriesId: 'abc123',
        ),
      ),
      throwsStateError,
    );
  });
}
