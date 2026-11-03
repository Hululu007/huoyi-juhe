import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/huangju_content.dart';

http.Response _json(Object value, [int status = 200]) {
  return http.Response.bytes(utf8.encode(jsonEncode(value)), status);
}

MockClient _mockClient({bool expireFirst = false}) {
  var guestCalls = 0;
  return MockClient((request) async {
    final url = request.url.toString();
    if (url == 'https://api.huangju.net/auth/guest') {
      guestCalls++;
      return _json({'token': 'guest-token-1'});
    }
    if (url.startsWith('https://api.huangju.net/categories')) {
      return _json([
        {'slug': 'hot', 'name': '热门'},
        {'slug': 'city', 'name': '都市'},
      ]);
    }
    if (url.startsWith('https://api.huangju.net/dramas') &&
        !url.contains('/dramas/')) {
      if (expireFirst && guestCalls == 1) {
        return http.Response('{"error":"unauthorized"}', 401);
      }
      return _json({
        'items': [
          {
            'id': '11',
            'slug': 'drama-a',
            'title': '剧A',
            'totalEpisodes': 80,
            'coverUrl': '/c/a.jpg',
          },
        ],
        'pageSize': 20,
        'page': 1,
        'total': 40,
      });
    }
    if (url.startsWith('https://api.huangju.net/dramas/')) {
      return _json({
        'id': '22',
        'slug': 'drama-a',
        'title': '剧A',
        'coverUrl': '/c/a.jpg',
        'episodes': [
          {'id': 'e2', 'epNo': 2, 'playable': true},
          {'id': 'e1', 'epNo': 1, 'playable': true},
          {'id': 'e3', 'epNo': 3, 'playable': false},
        ],
      });
    }
    if (url.startsWith('https://api.huangju.net/play/')) {
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'url': 'https://cdn.example.com/v.m3u8',
            'expiresAt': 4102444800,
          }),
        ),
        200,
        headers: {
          'set-cookie':
              'CloudFront-Policy=POL; Path=/, CloudFront-Signature=SIG; Path=/, CloudFront-Key-Pair-Id=KEY; Path=/',
        },
      );
    }
    return http.Response('not found', 404);
  });
}

void main() {
  test('剧果：访客令牌、分类跳过 hot、最新置顶', () async {
    final client = HuangjuContentClient(client: _mockClient());
    final categories = await client.categories();
    expect(categories.map((c) => c.id), ['@new', 'city']);
    expect(categories.first.name, '最新');
  });

  test('剧果：目录分页、搜索同路、详情跳过不可播并按集号排', () async {
    final client = HuangjuContentClient(client: _mockClient());
    final page = await client.catalog('@new', 1);
    expect(page.items.single.id, 'drama-a-11');
    expect(page.items.single.title, '剧A');
    expect(page.hasMore, isTrue);
    final detail = await client.detail('drama-a-11');
    expect(detail.episodes.map((e) => e.videoId), ['e1', 'e2']);
    expect(detail.episodes.map((e) => e.title), ['第 1 集', '第 2 集']);
  });

  test('剧果：401 刷新令牌一次后成功', () async {
    final client = HuangjuContentClient(client: _mockClient(expireFirst: true));
    final page = await client.catalog('city', 1);
    expect(page.items.single.id, 'drama-a-11');
  });

  test('剧果：签名 Cookie 提取与播放走本地代理', () async {
    expect(
      huangjuSignedCookies(
        'CloudFront-Policy=POL; Path=/, CloudFront-Signature=SIG; Path=/, CloudFront-Key-Pair-Id=KEY; Path=/',
      ),
      {
        'CloudFront-Policy': 'POL',
        'CloudFront-Signature': 'SIG',
        'CloudFront-Key-Pair-Id': 'KEY',
      },
    );
    final client = HuangjuContentClient(client: _mockClient());
    final source = await client.playSource(
      const DramaSiteEpisode(
        videoId: 'e1',
        title: '第 1 集',
        seriesId: 'drama-a-11',
      ),
    );
    expect(source.url, startsWith('http://127.0.0.1:'));
    expect(source.url, contains('/r/'));
  });
}
