// 演员库在线源（123AV / PH）解析层测试（2026-11-27 随解析层
// 从魔蚁侧移植，样本与断言与魔蚁侧同一套）：样本按
// 两站真实页面结构造（与合并网页适配器当时的取数口径一致），
// 只验解析与拼址，不碰真网络。在线链的真站验播结论见
// 本批 REPORT.md（本机出口不可达时按未验写）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_online_parse.dart';

void main() {
  group('PH 拼址', () {
    test('浏览：分类 + 排序 + 页码', () {
      expect(
        phListUrl(sortValue: 'o=ht', catValue: 'c=111', query: '', page: 2),
        'https://cn.pornhub.com/video?c=111&o=ht&page=2',
      );
      expect(
        phListUrl(sortValue: 'o=mr', catValue: '', query: '', page: 1),
        'https://cn.pornhub.com/video?o=mr',
      );
    });

    test('搜索：走 /video/search，翻页带 page', () {
      expect(
        phListUrl(sortValue: 'o=ht', catValue: '', query: 'abc def', page: 1),
        'https://cn.pornhub.com/video/search?search=abc+def',
      );
      expect(
        phListUrl(sortValue: '', catValue: '', query: 'abc', page: 3),
        'https://cn.pornhub.com/video/search?search=abc&page=3',
      );
    });
  });

  group('PH 列表解析', () {
    const html = '''
<div class="wrap">
  <a href="/view_video.php?viewkey=abc123" data-poster="https://ci.phncdn.com/p1.jpg"><img src="https://ci.phncdn.com/t1.jpg" alt="标题一"></a>
  <span class="duration">12:34</span>
</div>
<div class="wrap">
  <a href="/view_video.php?viewkey=abc123"><img src="https://ci.phncdn.com/t1b.jpg" alt="重复卡"></a>
</div>
<div class="wrap">
  <a href="/view_video.php?viewkey=noimg">无图链接不算卡</a>
</div>
<div class="wrap">
  <a href="https://cn.pornhub.com/view_video.php?viewkey=def456"><img data-path="https://ci.phncdn.com/t2.jpg" alt="标题二"></a>
  <span class="duration"><span class="time">3:05</span></span>
</div>
''';

    test('只收带图卡、按地址去重、时长与封面取对', () {
      final cards = parsePhCards(html);
      expect(cards, hasLength(2));
      expect(
        cards[0].pageUrl,
        'https://cn.pornhub.com/view_video.php?viewkey=abc123',
      );
      expect(cards[0].title, '标题一');
      expect(cards[0].cover, 'https://ci.phncdn.com/p1.jpg');
      expect(cards[0].duration, '12:34');
      expect(cards[1].title, '标题二');
      expect(cards[1].cover, 'https://ci.phncdn.com/t2.jpg');
      expect(cards[1].duration, '3:05');
    });
  });

  group('PH 详情与取流', () {
    const detailHtml = '''
<html><head>
<meta property="og:title" content="示例标题 - Pornhub.com">
<meta property="og:image" content="https://ci.phncdn.com/poster.jpg">
</head><body>
<a href="/pornstar/some-star">明星甲</a>
<a href="/model/some-model">模特乙</a>
<a href="/video?c=111">日本人</a>
</body></html>
''';

    test('og 标题去站名尾巴、演员与标签取对', () {
      final detail = parsePhDetail(detailHtml);
      expect(detail.title, '示例标题');
      expect(detail.poster, 'https://ci.phncdn.com/poster.jpg');
      expect(detail.actresses, ['明星甲', '模特乙']);
      expect(detail.tags, ['日本人']);
    });

    test('剧照只取剧照容器，日期时长取页内字段', () {
      const html = '''
<html><head>
<meta property="og:title" content="剧照样本 - Pornhub.com">
<meta property="og:image" content="https://ci.phncdn.com/poster.jpg">
<script type="application/ld+json">{"datePublished":"2024-03-15"}</script>
<script>var flashvars = {"video_duration":"1830"};</script>
</head><body>
<div class="screenshots"><img src="https://img.example.com/s1.jpg"><img data-src="https://img.example.com/s2.jpg"></div>
<a href="/model/star-one">明星甲</a>
</body></html>
''';
      final detail = parsePhDetail(html);
      expect(detail.stills, [
        'https://img.example.com/s1.jpg',
        'https://img.example.com/s2.jpg',
      ]);
      expect(detail.date, '2024-03-15');
      expect(detail.duration, '31 分钟');
      expect(detail.maker, isEmpty);
    });

    test('没有剧照容器时剧照为空（不拿别处图冒充）', () {
      final detail = parsePhDetail(detailHtml);
      expect(detail.stills, isEmpty);
      expect(detail.date, isEmpty);
      expect(detail.duration, isEmpty);
    });

    test('flashvars：quality 数组那条是 master 播放列表', () {
      final raw =
          'var flashvars_987 = {"mediaDefinitions":['
          '{"quality":720,"videoUrl":"https://cdn.example.com/720.m3u8"},'
          '{"quality":["1080","720"],"videoUrl":"https://cdn.example.com/master.m3u8"},'
          '{"quality":480,"videoUrl":"https://cdn.example.com/480.mp4"}]};\n';
      expect(extractPhStream(raw), 'https://cdn.example.com/master.m3u8');
    });

    test('flashvars 解不出时全文兜底找 m3u8', () {
      expect(
        extractPhStream('xx https://cdn.example.com/a/b.m3u8?tok=1 yy'),
        'https://cdn.example.com/a/b.m3u8?tok=1',
      );
      expect(extractPhStream('什么都没有'), '');
    });
  });

  group('123AV 拼址与番号', () {
    test('浏览与搜索', () {
      expect(
        av123ListUrl(path: '/cn/recent', query: '', page: 1),
        'https://123av.com/cn/recent',
      );
      expect(
        av123ListUrl(path: '/cn/hot', query: '', page: 2),
        'https://123av.com/cn/hot?page=2',
      );
      expect(
        av123ListUrl(path: '/cn/recent', query: 'ssis', page: 2),
        'https://123av.com/cn/search?q=ssis&page=2',
      );
    });

    test('番号规整', () {
      expect(av123CodeOf('https://123av.com/cn/v/ssis-001'), 'SSIS-001');
      expect(av123CodeOf('/cn/v/madv-647-uncensored-leaked'), 'MADV-647');
    });
  });

  group('123AV 列表解析', () {
    const html = '''
<div class="card">
  <a class="card__cover" href="/cn/v/ssis-001"><img class="card__img" data-src="https://icdn.123av.com/p1.jpg" alt=""></a>
  <div class="card__title">测试标题一</div>
  <span class="card__dur">120分钟</span>
</div>
<div class="card">
  <a href="/cn/v/madv-647"><img src="data:image/gif;base64,xx" data-original="https://icdn.123av.com/p2.jpg"></a>
</div>
<div class="card">
  <a class="card__cover" href="/cn/v/ssis-001"><img class="card__img" data-src="https://icdn.123av.com/pdup.jpg"></a>
  <div class="card__title">重复卡</div>
</div>
''';

    test('卡片/标题/时长/封面懒加载序、去重、无标题用番号顶', () {
      final cards = parseAv123Cards(html);
      expect(cards, hasLength(2));
      expect(cards[0].pageUrl, 'https://123av.com/cn/v/ssis-001');
      expect(cards[0].title, '测试标题一');
      expect(cards[0].cover, 'https://icdn.123av.com/p1.jpg');
      expect(cards[0].duration, '120分钟');
      expect(cards[1].title, 'MADV-647');
      expect(cards[1].cover, 'https://icdn.123av.com/p2.jpg');
    });
  });

  group('123AV 详情与取流', () {
    const detailHtml = '''
<html><body>
<h1>SSIS-001 示例标题</h1>
<script>var posterUrl = "player?poster=https%3A%2F%2Ficdn.123av.com%2Fposter.jpg&x=1";</script>
<a href="/cn/actresses/star-a">演员甲</a>
<a href="/cn/genres/drama">剧情</a>
<a href="/cn/tag/hd">高清</a>
</body></html>
''';

    test('标题/海报解码/演员/标签', () {
      final detail = parseAv123Detail(detailHtml);
      expect(detail.title, 'SSIS-001 示例标题');
      expect(detail.poster, 'https://icdn.123av.com/poster.jpg');
      expect(detail.actresses, ['演员甲']);
      expect(detail.tags, ['剧情', '高清']);
    });

    test('剧照取预览图区，日期/时长/制作商取正文标签行', () {
      const html = '''
<html><body>
<h1>MADV-647 样本标题</h1>
<img class="card-img-top" src="https://img.example.com/cover.jpg">
<div class="preview-images"><img src="https://img.example.com/p1.jpg"><img src="https://img.example.com/p2.jpg"></div>
<div class="detail"><p>发布日期：2025-01-20</p><p>长度：150 分钟</p><p>制作商：示例片商</p></div>
</body></html>
''';
      final detail = parseAv123Detail(html);
      expect(detail.stills, [
        'https://img.example.com/p1.jpg',
        'https://img.example.com/p2.jpg',
      ]);
      expect(detail.date, '2025-01-20');
      expect(detail.duration, '150 分钟');
      expect(detail.maker, '示例片商');
    });

    test('没有预览图区与标签行时全为空', () {
      final detail = parseAv123Detail(detailHtml);
      expect(detail.stills, isEmpty);
      expect(detail.date, isEmpty);
      expect(detail.duration, isEmpty);
      expect(detail.maker, isEmpty);
    });

    test('集数 JSON：真页内联 player 样本解出嵌入地址（域名现读）', () {
      // 样本逐字摘自出口补验批实拉的 123av 详情页（番号
      // c-2582-uncensored-leaked）：集数在内联 player 的转义
      // JSON 里，嵌入域名是轮换后的 sadie-shop.site。
      final raw = '<script>' + r'''player(JSON.parse('[{\u0022number\u0022:1,\u0022name\u0022:\u00221\u0022,\u0022url\u0022:\u0022https:\\\/\\\/sadie-shop.site\\\/e\\\/1RWL3E?poster=https%3A%2F%2Ficdn.123av.me%2Fimg2%2Fs500%2Fcd%2Fc-2582-uncensored-leaked%2Fcover.jpg%3F6b081042\u0022}]')''' + '</script>';
      final episodes = av123EpisodesOf(raw);
      expect(episodes, hasLength(1));
      expect(episodes.single.number, 1);
      expect(
        episodes.single.url,
        'https://sadie-shop.site/e/1RWL3E?poster=https%3A%2F%2Ficdn.123av.me%2Fimg2%2Fs500%2Fcd%2Fc-2582-uncensored-leaked%2Fcover.jpg%3F6b081042',
      );
      expect(av123EmbedOf(raw), episodes.single.url);
    });

    test('嵌入地址兜底：任意域名的 /e/ 地址（转义形）也认', () {
      final raw =
          r'<script>embed("https:\/\/player.example.net\/e\/AbC123?token=xyz")</script>';
      expect(
        av123EmbedOf(raw),
        'https://player.example.net/e/AbC123?token=xyz',
      );
    });

    test('取流接口拼址：嵌入源 /stream + 原查询串 + id', () {
      final request = av123StreamRequest(
        'https://sadie-shop.site/e/1RWL3E?poster=abc',
      );
      expect(request, isNotNull);
      expect(request!.origin, 'https://sadie-shop.site');
      expect(
        request.apiUrl,
        'https://sadie-shop.site/stream?poster=abc&id=1RWL3E',
      );
      expect(av123StreamRequest('https://example.com/watch/1'), isNull);
    });

    test('取流回包：真回包形状 media.stream 优先', () {
      expect(
        extractAv123Stream(
          '{"status":"ok","media":{"stream":"https://jd50.example.com/oo5/video.m3u8","vtt":"https://jd50.example.com/preview.vtt"}}',
        ),
        'https://jd50.example.com/oo5/video.m3u8',
      );
      expect(extractAv123Stream('{"status":"error"}'), '');
    });

    test('取流回包：stream 字段优先，其次全文 m3u8', () {
      expect(
        extractAv123Stream('{"stream":"https://cdn.example.com/x.m3u8"}'),
        'https://cdn.example.com/x.m3u8',
      );
      expect(
        extractAv123Stream('{"file":"https://cdn.example.com/y.mp4"}'),
        'https://cdn.example.com/y.mp4',
      );
      expect(
        extractAv123Stream('prefix https://cdn.example.com/z.m3u8 suffix'),
        'https://cdn.example.com/z.m3u8',
      );
      expect(extractAv123Stream('{}'), '');
    });
  });
}
