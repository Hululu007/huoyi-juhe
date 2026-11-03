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
