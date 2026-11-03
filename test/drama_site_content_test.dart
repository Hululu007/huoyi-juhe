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
