import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/drama_site_content.dart';

void main() {
  test('红果镜像分类解析：分类链接取 id 与名，空时用兜底三类', () {
    final parsed = HgtvMirrorContentClient.parseCategories(
      '<a href="/category/real-drama" class="pc-content-type"><span>真人剧</span></a>'
      '<a href="/category/comic-drama" class="pc-content-type"><span>漫剧</span></a>',
    );
    expect(parsed.map((c) => c.id).toList(), ['real-drama', 'comic-drama']);
    expect(parsed.map((c) => c.name).toList(), ['真人剧', '漫剧']);
    expect(
      HgtvMirrorContentClient.parseCategories('<html></html>')
          .map((c) => c.id)
          .toList(),
      ['real-drama', 'comic-drama', 'ai-drama'],
    );
  });

  test('红果镜像卡片解析：去重、有标题才算、封面与集数备注齐全', () {
    final items = HgtvMirrorContentClient.parseCards(
      '<a href="/detail?series_id=123"><p class="pc-title-x">测试剧</p>'
      '<img src="https://example.test/cover.jpg" alt="测试剧封面">'
      '<p class="pc-episode-x">102集</p></a>'
      '<a href="/detail?series_id=123"><p class="pc-title-x">测试剧</p></a>'
      '<a href="/detail?series_id=456"><p class="pc-title-x"></p></a>',
    );
    expect(items.length, 1);
    expect(items.first.id, '123');
    expect(items.first.title, '测试剧');
    expect(items.first.cover, 'https://example.test/cover.jpg');
    expect(items.first.remark, '102集');
  });

  test('红果分类解析：router 数据的 recommendList 成卡片', () {
    final items = HongguoContentClient.parseCatalog(
      '<html><script>window._ROUTER_DATA = {"loaderData":{"category_page":{"recommendList":[{"video_data":{"series_id_str":"123","series_title":"测试剧","series_cover":"https://example.test/cover.jpg","episode_right_text":"全102集"}}],"pagination":{"totalPages":"5"}}}};</script></html>',
    );
    expect(items.length, 1);
    expect(items.first.id, '123');
    expect(items.first.title, '测试剧');
    expect(items.first.remark, '全102集');
    expect(HongguoContentClient.routeForCategory('all'), 'real-drama');
  });

  test('红果播放页解析：video_player_info 的地址列表成线路', () {
    final addresses = HongguoContentClient.parsePlayerAddresses(
      '<html><script>window._ROUTER_DATA = {"loaderData":{"player_page":{"vid":"111","series_id":"123","video_player_info":{"main_url":"https://example.test/v1080.mp4","backup_url":"https://example.test/v720.mp4"}}}};</script></html>',
    );
    expect(addresses, [
      'https://example.test/v1080.mp4',
      'https://example.test/v720.mp4',
    ]);
  });

  test('饭果列表与详情解析：搜索结果成卡片，详情分集直链成播放地址', () {
    final items = FanguoContentClient.parseCatalog({
      'result': {
        'elements': [
          {
            'contents': [
              {
                'duanjuVo': {
                  'duanjuId': '999',
                  'title': '饭果测试剧',
                  'coverImageUrl': 'https://example.test/fanguo.jpg',
                  'total': 50,
                },
              },
            ],
          },
        ],
      },
    });
    expect(items.length, 1);
    expect(items.first.id, '999');
    expect(items.first.remark, '共50集');
    final detail = FanguoContentClient.parseDetail({
      'result': {
        'title': '饭果测试剧',
        'coverImageUrl': 'https://example.test/fanguo.jpg',
        'episodeList': [
          {'index': 2, 'playUrl': 'https://example.test/e2.mp4'},
          {'index': 1, 'playUrl': 'https://example.test/e1.mp4'},
        ],
      },
    }, '999');
    expect(detail.episodes.map((e) => e.videoId).toList(), [
      'https://example.test/e1.mp4',
      'https://example.test/e2.mp4',
    ]);
  });

  test('观果列表与详情解析：data 成卡片，清晰度最高那条成播放地址', () {
    final items = GuanguoContentClient.parseCatalog({
      'data': [
        {
          'oneId': '777',
          'title': '观果测试剧',
          'horzPoster': 'https://example.test/guanguo.jpg',
          'episodeCount': 80,
        },
      ],
    });
    expect(items.length, 1);
    expect(items.first.id, '777');
    expect(items.first.remark, '共80集');
    final detail = GuanguoContentClient.parseDetail({
      'title': '观果测试剧',
      'vertPoster': 'https://example.test/guanguo.jpg',
      'data': [
        {
          'playOrder': 1,
          'videoClarityList': [
            {'clarity': 720, 'playUrl': 'https://example.test/g720.mp4'},
            {'clarity': 1080, 'playUrl': 'https://example.test/g1080.mp4'},
          ],
        },
      ],
    }, '777');
    expect(detail.episodes.first.videoId, 'https://example.test/g1080.mp4');
  });

  test('红果镜像详情解析：router 数据里的 vid_list 成选集', () {
    final detail = HgtvMirrorContentClient.parseDetail(
      '<html><script>window._ROUTER_DATA = {"loaderData":{"detail_page":{"seriesDetail":{"series_id":"123","series_title":"测试剧","series_cover":"https://example.test/cover.jpg","vid_list":["111","222","111"]}}}};</script></html>',
      '123',
    );
    expect(detail.title, '测试剧');
    expect(detail.episodes.map((e) => e.videoId).toList(), ['111', '222']);
    expect(detail.episodes.map((e) => e.title).toList(), ['第1集', '第2集']);
    expect(
      () => HgtvMirrorContentClient.parseDetail('<html></html>', '123'),
      throwsStateError,
    );
  });
}
