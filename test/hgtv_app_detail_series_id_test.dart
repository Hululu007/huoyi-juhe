// 回归：App 详情出的分集必须带 seriesId，否则取流跳过播放页直落 360p。
//
// 2026-11-11 真接口复现：目录→详情都通，但分集 seriesId 为空，
// playSource 没请求播放页，直接回
// https://hongguoduanju.com/video/public/<vid>/360p.mp4。
// 修在 lib/services/hgtv_content.dart 的 parseHgtvAppDetail。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/hgtv_content.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _jsonResponse(Object decoded) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(decoded)),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  test('App 详情分集带 seriesId', () async {
    final client = HgtvContentClient(
      MockClient((_) async {
        return _jsonResponse({
          'code': '',
          'data': {
            'video_data': {
              'series_id_str': '123',
              'series_title': '测试剧',
              'series_cover': 'https://pic.test/123.jpg',
              'episode_cnt': '2',
              'video_list': [
                {'vid': '111', 'vid_index': '1'},
                {'vid': '222', 'vid_index': '2'},
              ],
            },
          },
        });
      }),
    );
    final detail = await client.detail('123');
    expect(detail.episodes.map((e) => e.videoId).toList(), ['111', '222']);
    expect(
      detail.episodes.map((e) => e.seriesId).toList(),
      ['123', '123'],
    );
  });

  test('带 seriesId 的分集取流会请求播放页', () async {
    final requested = <String>[];
    final client = HgtvContentClient(
      MockClient((request) async {
        requested.add(request.url.toString());
        if (request.url.host.contains('fqnovel')) {
          return _jsonResponse({
            'code': '',
            'data': {
              'video_data': {
                'series_id_str': '123',
                'series_title': '测试剧',
                'series_cover': 'https://pic.test/123.jpg',
                'episode_cnt': '1',
                'video_list': [
                  {'vid': '111', 'vid_index': '1'},
                ],
              },
            },
          });
        }
        if (request.url.path.contains('/player/')) {
          const html =
              '<html><body><script>window._ROUTER_DATA = '
              '{"loaderData":{"player_page":{"vid":"111","series_id":"123",'
              '"video_player_info":{"main_url":"https://cdn.test/a.m3u8",'
              '"backup_url":"https://cdn.test/b.m3u8"}}}}'
              '</script></body></html>';
          return http.Response(html, 200);
        }
        return http.Response('not found', 404);
      }),
    );
    final detail = await client.detail('123');
    final source = await client.playSource(detail.episodes.first);
    expect(source.url, 'https://cdn.test/a.m3u8');
    expect(
      requested.any((u) => u.contains('/player/123/111')),
      isTrue,
    );
  });
}
