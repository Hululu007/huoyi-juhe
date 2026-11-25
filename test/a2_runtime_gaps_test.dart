import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/engine_site_content.dart';
import 'package:fqapp/services/js_bridge.dart';

/// 同步批 A2 六条运行时缺口的核查证据测试：
/// #2 JS 驱动 pg 字符串化（已补）、#4 播放 url 数组多候选（已补）、
/// #5 详情 vod_year/vod_area 经 extra 透传（本就具备，锁行为）。
void main() {
  group('#2 JS 驱动 pg 字符串化', () {
    test('search 调用：pg 是 JSON 字符串而非数字', () {
      final driver = buildJsDriverScript(
        script: '',
        operation: 'search',
        query: '片',
        page: 2,
      );
      expect(driver, contains('fn("片", false, "2")'));
    });

    test('category 调用：pg 同样字符串化', () {
      final driver = buildJsDriverScript(
        script: '',
        operation: 'category',
        tid: 'movie',
        page: 3,
      );
      expect(driver, contains('fn("movie", "3", false, {})'));
    });
  });

  group('#4 播放 url 数组多候选 playUrlCandidates / parseTvboxPlay', () {
    test('成对 [名, 址] 数组：第一条主址、其余变体', () {
      final source = parseTvboxPlay(<String, dynamic>{
        'parse': '0',
        'url': <String>[
          '标清',
          'https://cdn.example.com/low.m3u8',
          '高清',
          'https://cdn.example.com/high.m3u8',
        ],
      });
      expect(source.url, 'https://cdn.example.com/low.m3u8');
      expect(source.variants.length, 1);
      expect(source.variants.single.name, '高清');
      expect(source.variants.single.url, 'https://cdn.example.com/high.m3u8');
    });

    test('纯地址列表：全部成候选，名字按线路序号', () {
      final candidates = playUrlCandidates(<String>[
        'https://a.example.com/1.m3u8',
        'https://b.example.com/2.m3u8',
      ]);
      expect(candidates.length, 2);
      expect(candidates[0].name, '线路1');
      expect(candidates[1].name, '线路2');
    });

    test('对象列表：认 url/name，别名 v/n 也认', () {
      final candidates = playUrlCandidates(<Object?>[
        <String, dynamic>{'name': '主线', 'url': 'https://a.example.com/x.m3u8'},
        <String, dynamic>{'n': '备线', 'v': 'https://b.example.com/y.m3u8'},
      ]);
      expect(candidates.length, 2);
      expect(candidates[0].name, '主线');
      expect(candidates[1].url, 'https://b.example.com/y.m3u8');
    });

    test('字符串 url 行为不变；空数组抛「没有可播地址」', () {
      final source = parseTvboxPlay(<String, dynamic>{
        'parse': '0',
        'url': 'https://cdn.example.com/one.m3u8',
      });
      expect(source.url, 'https://cdn.example.com/one.m3u8');
      expect(source.variants, isEmpty);
      expect(
        () => parseTvboxPlay(<String, dynamic>{
          'parse': '0',
          'url': <String>[],
        }),
        throwsStateError,
      );
    });
  });

  group('#5 详情字段透传 parseTvboxDetail', () {
    test('vod_year / vod_area 进 extra（本就具备，锁住防回归）', () {
      final detail = parseTvboxDetail(<String, dynamic>{
        'list': <Map<String, dynamic>>[
          <String, dynamic>{
            'vod_id': '42',
            'vod_name': '某剧',
            'vod_pic': 'https://img.example.com/p.jpg',
            'vod_content': '简介',
            'vod_year': '2024',
            'vod_area': '大陆',
            'vod_play_from': 'line1',
            'vod_play_url': '第1集\$ep1',
          },
        ],
      });
      expect(detail.extra['vod_year'], '2024');
      expect(detail.extra['vod_area'], '大陆');
      expect(detail.episodes.length, 1);
    });
  });
}
