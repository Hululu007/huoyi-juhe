import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fqapp/services/xbpq_content.dart';

const _listHtml = '''
<ul class="list">
<li class="item"><a href="/voddetail/11.html"><img src="/up/11.jpg"><span class="t">第一部</span></a><em>更新至3集</em></li>
<li class="item"><a href="/voddetail/22.html"><img src="/up/22.jpg"><span class="t">第二部</span></a><em>全12集</em></li>
</ul>
''';

const _detailHtml = '''
<html><head><title>第一部在线观看</title>
<meta property="og:image" content="/up/11.jpg">
</head><body>
<div class="line"><b class="lname">线路A</b>
<a href="/vodplay/11-1-1.html">第1集</a>
<a href="/vodplay/11-1-2.html">第2集</a></div>
<div class="line"><b class="lname">线路B</b>
<a href="/vodplay/11-2-1.html">第1集</a></div>
</body></html>
''';

const _playHtml = '''
<html><script>var player_aaaa={"url":"https://cdn.example.com/11.m3u8","encrypt":"0"};</script></html>
''';

Map<String, dynamic> _rule() => {
  '主页url': 'https://demo.example.com',
  '分类': '电影\$1#电视剧\$2',
  '分类url': 'https://demo.example.com/vod/show/{cateId}----{catePg}---.html',
  '数组': '<li class="item">&&</li>',
  '图片': 'src="&&"',
  '标题': '<span class="t">&&</span>',
  '链接': 'href="&&"',
  '副标题': '<em>&&</em>',
  '线路数组': '<div class="line">&&</div>',
  '线路标题': '<b class="lname">&&</b>',
  '播放数组': '<a href="&&</a>',
  '播放标题': '">&&</a>',
  '播放链接': 'href="&&"',
  '搜索模式': '1',
  '搜索url': 'https://demo.example.com/index.php/vod/search/page/{pg}/wd/{wd}.html',
};

void main() {
  test('锚点截取：星号通配与替换清洗', () {
    expect(
      xbpqExtract(
        '<div class="detail-content" style="color:red;">剧情正文</span>后文',
        'detail-content" style=*>&&</span>',
      ),
      '剧情正文',
    );
    expect(
      xbpqExtract(
        '<b>线路A</span><small>注</small></b>',
        '<b>&&</b>[替换:</span><small>>>👉]',
      ),
      '线路A👉注</small>',
    );
    expect(
      xbpqStripTags('线路A👉注</small>'),
      '线路A👉注',
    );
    expect(xbpqExtract('无锚点文本', '左锚&&右锚'), '');
  });

  test('分类写法 A：名称\$值以 # 分条', () {
    final categories = xbpqParseCategories(_rule());
    expect(categories.map((c) => c.name), ['电影', '电视剧']);
    expect(categories.map((c) => c.id), ['1', '2']);
  });

  test('分类写法 B：名称串与分类值串按位对应', () {
    final categories = xbpqParseCategories({
      '分类': '电影&连续剧&动漫',
      '分类值': '/vodtype/1&/vodtype/2&/vodtype/4',
    });
    expect(categories.map((c) => c.id), ['/vodtype/1', '/vodtype/2', '/vodtype/4']);
    expect(categories.map((c) => c.name), ['电影', '连续剧', '动漫']);
  });

  test('筛选解析与模板填充：分类值取组、选中值进占位符', () {
    final rule = {
      '分类': '电影\$1#电视剧\$2',
      '分类url': '/show{area}{by}/id/{cateId}/page/{catePg}.html',
      '筛选': {
        '1': [
          {
            'key': 'area',
            'value': [
              {'n': '大陆', 'v': '/area/大陆'},
              {'n': '香港', 'v': '/area/香港'},
            ],
          },
          {
            'key': 'by',
            'value': [
              {'n': '最新', 'v': '/by/time'},
            ],
          },
        ],
      },
    };
    final groups = xbpqParseFilters(rule, '1');
    expect(groups.map((g) => g.key), ['area', 'by']);
    expect(groups.first.options.first.name, '全部');
    expect(groups.first.options[1].value, '/area/大陆');
    expect(xbpqParseFilters(rule, '2'), isEmpty);
    expect(
      xbpqFillTemplate(
        '/show{area}{by}/id/{cateId}/page/{catePg}.html',
        cateId: '1',
        page: 3,
        filters: {'area': '/area/大陆'},
      ),
      '/show/area/大陆/id/1/page/3.html',
    );
  });

  test('模板占位符填充', () {
    expect(
      xbpqFillTemplate(
        'https://demo.example.com/vod/show/{cateId}-{area}-{by}----{catePg}---{year}.html',
        cateId: '1',
        page: 3,
      ),
      'https://demo.example.com/vod/show/1------3---.html',
    );
  });

  test('客户端全链：分类、搜索、详情线路集数、播放页直链', () async {
    final client = MockClient((request) async {
      final url = request.url.toString();
      if (url.contains('/voddetail/')) {
        return http.Response.bytes(utf8.encode(_detailHtml), 200);
      }
      if (url.contains('/vodplay/')) {
        return http.Response.bytes(utf8.encode(_playHtml), 200);
      }
      return http.Response.bytes(utf8.encode(_listHtml), 200);
    });
    final xbpq = XbpqContentClient('xbpq-demo', _rule(), client: client);
    final categories = await xbpq.categories();
    expect(categories.first.name, '电影');
    final page = await xbpq.catalog('1', 1);
    expect(page.items.length, 2);
    expect(page.items.first.title, '第一部');
    expect(page.items.first.cover, 'https://demo.example.com/up/11.jpg');
    expect(page.items.first.remark, '更新至3集');
    final found = await xbpq.search('第一');
    expect(found.length, 2);
    final detail = await xbpq.detail('https://demo.example.com/voddetail/11.html');
    expect(detail.title, '第一部');
    expect(detail.cover, 'https://demo.example.com/up/11.jpg');
    expect(detail.episodes.length, 3);
    expect(detail.episodes.first.title, '线路A-第1集');
    expect(detail.episodes.last.title, '线路B-第1集');
    final source = await xbpq.playSource(detail.episodes.first);
    expect(source.url, 'https://cdn.example.com/11.m3u8');
  });
}
