import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/engine_site_content.dart';

void main() {
  test('TVBox 分类：class 列表转分类，空时退回全部', () {
    final categories = parseTvboxCategories({
      'class': [
        {'type_id': '1', 'type_name': '都市'},
        {'type_id': '', 'type_name': '无名'},
        {'type_id': '2', 'type_name': '古装'},
      ],
    });
    expect(categories.map((c) => c.id), ['1', '2']);
    expect(parseTvboxCategories({}).first.id, 'all');
  });

  test('TVBox 列表：页码与总数算 hasMore', () {
    final page = parseTvboxCatalog({
      'page': '1',
      'pagecount': 3,
      'list': [
        {
          'vod_id': 'v1',
          'vod_name': '剧一',
          'vod_pic': 'https://x/p.jpg',
          'vod_remarks': '全10集',
        },
      ],
    });
    expect(page.items.length, 1);
    expect(page.items.first.remark, '全10集');
    expect(page.hasMore, true);
    final last = parseTvboxCatalog({
      'page': 3,
      'pagecount': 3,
      'list': [],
    });
    expect(last.hasMore, false);
  });

  test('TVBox 详情：多线路多集拆成选集，线路名前缀防重名', () {
    final detail = parseTvboxDetail({
      'list': [
        {
          'vod_id': 'v1',
          'vod_name': '剧一',
          'vod_pic': 'https://x/p.jpg',
          'vod_play_from': '线路A\$\$\$线路B',
          'vod_play_url':
              '第1集\$id1#第2集\$id2\$\$\$第1集\$id3',
        },
      ],
    });
    expect(detail.episodes.length, 3);
    expect(detail.episodes[0].videoId, '线路A\u0001id1');
    expect(detail.episodes[0].title, '线路A-第1集');
    expect(detail.episodes[2].videoId, '线路B\u0001id3');
    expect(detail.episodes[2].seriesId, 'v1');
  });

  test('TVBox 详情：通用列之外的原字段进扩展列，通用列与选集源不重复存', () {
    final detail = parseTvboxDetail({
      'list': [
        {
          'vod_id': 'v1',
          'vod_name': '剧一',
          'vod_pic': 'https://x/p.jpg',
          'vod_content': '简介',
          'vod_actor': '演员A',
          'vod_director': '导演B',
          'vod_year': '2024',
          'vod_area': '内地',
          'vod_remarks': '已完结',
          'vod_play_from': '线路A',
          'vod_play_url': '第1集\$id1',
        },
      ],
    });
    expect(detail.synopsis, '简介');
    expect(detail.extra['vod_actor'], '演员A');
    expect(detail.extra['vod_director'], '导演B');
    expect(detail.extra['vod_year'], '2024');
    expect(detail.extra['vod_area'], '内地');
    expect(detail.extra['vod_remarks'], '已完结');
    expect(detail.extra['vod_play_from'], '线路A');
    expect(detail.extra.containsKey('vod_content'), isFalse);
    expect(detail.extra.containsKey('vod_play_url'), isFalse);
    expect(detail.extra.containsKey('vod_id'), isFalse);
  });

  test('TVBox 取流：直链放行，需壳解析与空地址抛错', () {
    expect(parseTvboxPlay({'url': 'https://x/play.m3u8'}).url,
        'https://x/play.m3u8');
    expect(
      () => parseTvboxPlay({'parse': '1', 'url': 'https://x/sniff'}),
      throwsStateError,
    );
    expect(() => parseTvboxPlay({}), throwsStateError);
  });
}
