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

  test('河果列表与详情解析：NEXT_DATA 的书单与章节成卡片选集', () {
    const body =
        '<script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"bookList":[{"bookId":"111","bookName":"河果测试剧","coverWap":"https://example.test/heguo.jpg","totalChapterNum":60}],"bookInfoVo":{"bookId":"111","bookName":"河果测试剧","coverWap":"https://example.test/heguo.jpg"},"chapterList":[{"chapterId":"c1","chapterName":"第1集","chapterNum":1},{"chapterId":"c2","chapterName":"第2集","chapterNum":2}]}}}</script>';
    final props = HeguoContentClient.parsePageProps(body)!;
    expect(HeguoContentClient.parseCatalog(props).first.title, '河果测试剧');
    final detail = HeguoContentClient.parseDetail(props, '111');
    expect(detail.episodes.map((e) => e.videoId).toList(), ['c1', 'c2']);
    expect(
      HeguoContentClient.parseEpisodeUrls(
        '<video src="https://example.test/h1.mp4"></video>',
      ),
      ['https://example.test/h1.mp4'],
    );
  });

  test('星果列表与详情解析：资源编号取卡片，章节嵌套直链成选集', () {
    final items = XingguoContentClient.parseCatalog({
      'data': {
        'datalist': [
          {
            'id': '555',
            'name': '星果测试剧',
            'icon': 'https://example.test/xingguo.jpg',
            'chapterCount': 40,
            'introduction': '简介',
          },
        ],
      },
    });
    expect(items.first.id, '555@简介');
    expect(items.first.remark, '共40集');
    final detail = XingguoContentClient.parseDetail({
      'data': [
        {
          'chapterNum': 1,
          'shortPlayList': [
            {'playUrl': 'https://example.test/x1.mp4'},
          ],
        },
      ],
    }, '555@简介');
    expect(detail.episodes.first.videoId, 'https://example.test/x1.mp4');
  });

  test('猫果列表与详情解析：data.list 成卡片，play_list 直链成选集', () {
    final items = MaoguoContentClient.parseCatalog({
      'data': {
        'list': [
          {
            'playlet_id': '888',
            'title': '猫果测试剧',
            'image_link': 'https://example.test/maoguo.jpg',
            'total_episode_num': 70,
          },
        ],
      },
    });
    expect(items.first.id, '888');
    expect(items.first.remark, '共70集');
    final detail = MaoguoContentClient.parseDetail({
      'data': {
        'title': '猫果测试剧',
        'image_link': 'https://example.test/maoguo.jpg',
        'play_list': [
          {'sort': 1, 'video_url': 'https://example.test/m1.mp4'},
        ],
      },
    }, '888');
    expect(detail.episodes.first.videoId, 'https://example.test/m1.mp4');
  });

  test('芽果列表与详情解析：theater 成卡片，theaters 直链成选集', () {
    final items = YaguoContentClient.parseCatalog({
      'data': {
        'list': [
          {
            'theater': {
              'id': '666',
              'title': '芽果测试剧',
              'cover_url': 'https://example.test/yaguo.jpg',
              'total': 30,
            },
          },
        ],
      },
    });
    expect(items.first.id, '666');
    expect(items.first.remark, '共30集');
    final detail = YaguoContentClient.parseDetail({
      'data': {
        'title': '芽果测试剧',
        'cover_url': 'https://example.test/yaguo.jpg',
        'theaters': [
          {'num': 1, 'son_video_url': 'https://example.test/y1.mp4'},
        ],
      },
    }, '666');
    expect(detail.episodes.first.videoId, 'https://example.test/y1.mp4');
  });

  test('苹果 CMS 列表与详情与播放解析：卡片、选集、player_aaaa 直链', () {
    final items = MaccmsContentClient.parseCatalog(
      '<div class="module-item"><a href="/voddetail/123.html" title="花果测试剧"><img src="/pic.jpg" alt="花果测试剧"></a><span>共40集</span></div>',
      'https://example.test',
    );
    expect(items.length, 1);
    expect(items.first.id, '123');
    expect(items.first.cover, 'https://example.test/pic.jpg');
    final detail = MaccmsContentClient.parseDetail(
      '<h1 class="detail-title">花果测试剧</h1><div class="content__playlist"><a href="/vodplay/123-1-1.html">第1集</a><a href="/vodplay/123-1-2.html">第2集</a></div>',
      '123',
    );
    expect(detail.title, '花果测试剧');
    expect(detail.episodes.length, 2);
    final play = MaccmsContentClient.parsePlayerUrl(
      '<script>var player_aaaa={"url":"aHR0cHM6Ly9leGFtcGxlLnRlc3QvdjEubTN1OA==","from":"x","encrypt":"2"}</script>',
    );
    expect(play, 'https://example.test/v1.m3u8');
  });

  test('牛果列表与详情解析：解密后 JSON 的卡片与分集链接', () {
    final items = NiuguoContentClient.parseCatalog({
      'data': [
        {
          'vod_id': 575258,
          'vod_name': '牛果样本',
          'vod_pic': 'https://pic.example.cn/a.jpg',
          'vod_remarks': '已完结',
        },
      ],
    });
    expect(items.first.id, '575258');
    expect(items.first.title, '牛果样本');
    final detail = NiuguoContentClient.parseDetail({
      'vod_name': '牛果样本',
      'vod_pic': 'https://pic.example.cn/a.jpg',
      'sources': [
        {
          'episodes': [
            {'name': '第1集', 'url': 'https://example.test/n1'},
          ],
        },
      ],
    }, '575258');
    expect(detail.episodes.first.videoId, 'https://example.test/n1');
    final decrypted = NiuguoContentClient.decryptResponse(
      'd/I5TwIMGn7d1tvbqM7QrLYiBgMkVJQl3Uj3tUEF9dkHfgvV/ZfFVuE/NLhAd/b1XsugnbdQT62TYZ1g2mFMxuXPF1lzAJpoY95A/6hdqSeGpHDrqLnWElFVu7L6e5whh5MKc7AGE7zcLb2WbQS9aXRaTXhzKkNU9JN7lBcmMqmnmeht+inJDlIATllbfw7BY65kYjTkgADlFRZPiRMFBT5h6Zs3DwxyACR2a+KtU8w=',
      '/list?class=&ord',
    );
    expect(decrypted['status'], 0);
  });

  test('黄豆列表与详情解析：rp_ 前缀去后成剧集与按序号分集', () {
    final items = HuangdouContentClient.parseCatalog({
      'data': [
        {
          'id': 'rp_12345',
          'name': '黄豆样本',
          'img_y': 'https://pic.example.cn/y.jpg',
          'episode_count': '30',
        },
      ],
    });
    expect(items.first.id, '12345');
    expect(items.first.remark, '全30集');
    final detail = HuangdouContentClient.parseDetail({
      'data': {
        'name': '黄豆样本',
        'img_y': 'https://pic.example.cn/y.jpg',
        'episodes': [
          {'seq': 2, 'name': '第2集'},
          {'seq': 1, 'name': '第1集'},
        ],
      },
    }, '12345');
    expect(detail.episodes.length, 2);
    expect(detail.episodes.first.videoId, '1');
    expect(detail.episodes.first.seriesId, '12345');
  });

  test('红果搜索解析：search 页的 searchList 成卡片', () {
    const body = '''
<script>window.__ROUTER_DATA__ = {"loaderData":{"search_abc/page":{"isSuccess":true,"query":"样本","searchList":[{"video_data":{"series_id_str":"12345","series_title":"搜索样本剧","series_cover":"https://pic.example.cn/s.jpg","episode_cnt":"20"}}]}}}</script>
''';
    final items = HongguoContentClient.parseSearch(body);
    expect(items.length, 1);
    expect(items.first.id, '12345');
    expect(items.first.title, '搜索样本剧');
    expect(items.first.remark, '共20集');
  });

  test('河果搜索解析：data.bookList 成卡片', () {
    final items = HeguoContentClient.parseSearch({
      'data': {
        'bookList': [
          {
            'bookId': '9988',
            'bookName': '河果搜索样本',
            'coverWap': 'https://pic.example.cn/h.jpg',
            'totalChapterNum': 42,
            'statusDesc': '已完结',
          },
        ],
      },
    });
    expect(items.first.id, '9988');
    expect(items.first.remark, '已完结 共42集');
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

  test('红果镜像详情解析：通用列之外的标量原字段进扩展列', () {
    final detail = HgtvMirrorContentClient.parseDetail(
      '<html><script>window._ROUTER_DATA = {"loaderData":{"detail_page":{"seriesDetail":{"series_id":"123","series_title":"测试剧","series_cover":"https://example.test/cover.jpg","series_desc":"简介文字","episode_cnt":42,"series_area":"内地","vid_list":["111"]}}}};</script></html>',
      '123',
    );
    expect(detail.synopsis, '简介文字');
    expect(detail.extra['episode_cnt'], '42');
    expect(detail.extra['series_area'], '内地');
    expect(detail.extra.containsKey('series_desc'), isFalse);
    expect(detail.extra.containsKey('vid_list'), isFalse);
    expect(detail.extra.containsKey('series_title'), isFalse);
  });
}
