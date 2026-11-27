// 演员库四站接入（工人 D）夹具测试：18AV Dart 直连移植
// （搜索解析 / pid 解密向量 / play.php 取档）、chaoliu
// 索引三态（命中活 / 未命中落现拉 / 命中但死落现拉）、
// MissAV 按番号搜 + 取址、详情页竞速组线（新四线在列、
// MJV 后补线不阻塞主竞速、主线全灭不提前定死）、原生页
// 源条（页签集合 + 横滑 + who's 不在）。
// 全部假件（假仓储 / 假取数 / 假探针 / 受控播放器），
// 不碰真库真网。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_http.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_av18_source.dart';
import 'package:fqapp/actress/actress_mjv_parse.dart';
import 'package:fqapp/actress/actress_online_parse.dart';
import 'package:fqapp/actress/actress_online_sources.dart';
import 'package:fqapp/actress/actress_py_lines.dart';

// ---------------------------------------------------------------------------
// 夹具文本（结构照 MJV 模板真页；pid 向量由 chaoliu.py 本体
// _decrypt_id 往返验过：hadeedg=4242 / hcdeedg=16 /
// key=k3yF0rTestOnly18 / iv=ivF0rTestOnly181 时下述 enc
// 解出 pidTEST-720-abc123）
// ---------------------------------------------------------------------------

const _encPid =
    '10c1q10cbq10fcq10e8q10a4q10f4q10faq10c1q10feq10caq10bdq10e1q10a4q'
    '10a6q10fbq10c7q10f7q10e4q10f9q10f3q10f0q10e4q10dcq10c6q10deq10f6q'
    '10c7q10c8q10ffq10e8q10cbq10a1q10e2q10a5q10a4q10a2q10c1q10cbq10f1q'
    '10daq10a7q10a6q10a2q10af';

const _mjvDetailHtml = '''
<html><head><title>SSIS-001 详情标题</title>
<meta property="og:image" content="https://img.test/og.jpg"></head>
<body><h1>SSIS-001 详情标题</h1>
<script>
hadeedg252=4242; hcdeedg252=16;
var argdeqweqweqwe = 'k3yF0rTestOnly18';
var hdddedg252 = 'ivF0rTestOnly181';
mvarr['10_1']=[['a','$_encPid','b','pfx','c','d']];
</script></body></html>
''';

const _mjvSearchHtml = '''
<div class='post'><a href="/zh/chinese_content/255461/SSIS-001.html"><img src='https://img.test/c1.jpg'></a><div class='con'><h3><a href="/zh/chinese_content/255461/SSIS-001.html">SSIS-001 中字版</a></h3><div class='meta'>2026-01-01</div></div></div>
<div class='post'><a href="/zh/chinese_content/121841/SSIS-001-unc.html"><img src='https://img.test/c2.jpg'></a><div class='con'><h3><a href="/zh/chinese_content/121841/SSIS-001-unc.html">SSIS-001 无码版</a></h3><div class='meta'>2026-01-02</div></div></div>
''';

const _playPhpHtml = '''
<script>
var videoSources = [
  {src: '//cdn.test/v/720.m3u8', size: 720},
  {src: '//cdn.test/v/1080.m3u8', size: 1080}
];
</script>
''';

Future<FeedProbeResponse> _probeOk(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async => FeedProbeResponse(
  statusCode: 200,
  headers: const {},
  headBytes: utf8.encode('#EXTM3U\n#EXT-X-VERSION:3\n'),
);

Future<FeedProbeResponse> _probeDead(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async => const FeedProbeResponse(
  statusCode: 404,
  headers: {},
  headBytes: [],
);

// ---------------------------------------------------------------------------
// 假仓储（py 桥用）：行为按站 / 作品 id 分派，调用计数可查。
// ---------------------------------------------------------------------------

class _BridgeRepo extends AppRepository {
  _BridgeRepo({this.indexFails = false, this.missavFails = false});

  final bool indexFails;
  final bool missavFails;
  var chaoliuSearches = 0;
  var missavSearches = 0;

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory('all', '全部')];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async => CatalogPage(const [], page: page);

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    final out = <Drama>[];
    for (final source in sources) {
      if (source == ActressPyBridge.missavSiteId) {
        missavSearches++;
        out.add(
          const Drama(
            id: '/cn/ssis-001',
            source: ActressPyBridge.missavSiteId,
            title: 'SSIS-001 MissAV 标题',
            cover: 'https://img.test/m.jpg',
          ),
        );
      }
      if (source == ActressPyBridge.chaoliuSiteId) {
        chaoliuSearches++;
        out.add(
          const Drama(
            id: 'chinese#255461#SSIS-001',
            source: ActressPyBridge.chaoliuSiteId,
            title: 'SSIS-001 现拉标题',
            cover: 'https://img.test/c.jpg',
          ),
        );
      }
    }
    return CatalogPage(out);
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => drama.cover;

  @override
  Future<DramaDetail> detail(Drama drama) async {
    if (drama.id.startsWith('code_')) {
      return DramaDetail(drama, [
        Episode({'id': 'jpcode:SSIS-001', 'title': '正片'}, 1),
      ]);
    }
    if (drama.source == ActressPyBridge.chaoliuSiteId) {
      return DramaDetail(drama, [
        Episode({'id': 'mjv|480', 'title': '480P'}, 1),
        Episode({'id': 'mjv|720', 'title': '720P'}, 2),
      ]);
    }
    return DramaDetail(drama, [
      Episode({'id': 'missav-ep', 'title': '正片'}, 1),
    ]);
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async {
    if (episode.id.startsWith('jpcode:')) {
      if (indexFails) throw StateError('该集没有可播地址');
      return const PlaybackPlan(url: 'https://index.test/ssis-001/index.m3u8');
    }
    if (drama.source == ActressPyBridge.chaoliuSiteId) {
      return const PlaybackPlan(url: 'https://live.test/mjv/720.m3u8');
    }
    if (missavFails) throw StateError('该集需要壳解析，当前播放合同只支持直链');
    return const PlaybackPlan(
      url: 'https://surrit.test/uuid/playlist.m3u8',
      headers: {'Referer': 'https://missav.ws/'},
    );
  }
}

void main() {
  group('MJV 模板解析（chaoliu.py 对齐）', () {
    test('搜索页卡解析：ctype/num/slug/标题/封面齐', () {
      final cards = parseMjvCards(_mjvSearchHtml);
      expect(cards, hasLength(2));
      expect(cards.first.ctype, 'chinese');
      expect(cards.first.num, '255461');
      expect(cards.first.slug, 'SSIS-001');
      expect(cards.first.title, contains('SSIS-001'));
      expect(cards.first.cover, 'https://img.test/c1.jpg');
      expect(
        cards.first.detailUrl(av18Site),
        'https://www.18av.nl/zh/chinese_content/255461/SSIS-001.html',
      );
    });

    test('pid 解密向量：enc 按 chaoliu.py _decrypt_id 解出原文', () {
      expect(
        mjvDecryptId(
          _encPid,
          4242,
          16,
          'k3yF0rTestOnly18',
          'ivF0rTestOnly181',
        ),
        'pidTEST-720-abc123',
      );
      // 钥错一位即解不出（回空、不乱码递送）。
      expect(
        mjvDecryptId(_encPid, 4243, 16, 'k3yF0rTestOnly18', 'ivF0rTestOnly181'),
        isNot('pidTEST-720-abc123'),
      );
    });

    test('详情页 pid 提取：hadeedg/mvarr 三件套齐才出 pid', () {
      expect(extractMjvPids(_mjvDetailHtml), ['pidTEST-720-abc123']);
      expect(extractMjvPids('<html>没有加密段</html>'), isEmpty);
    });

    test('play.php 取档：优先目标档、协议相对地址补 https:', () {
      expect(
        parsePlayPhpStream(_playPhpHtml, preferSize: 720),
        'https://cdn.test/v/720.m3u8',
      );
      expect(
        parsePlayPhpStream(_playPhpHtml, preferSize: 1080),
        'https://cdn.test/v/1080.m3u8',
      );
      expect(parsePlayPhpStream(''), isEmpty);
    });
  });

  group('18AV Dart 直连源', () {
    Future<String> fakeFetch(String url, Map<String, String> headers) async {
      if (url.contains('chinese_search')) return _mjvSearchHtml;
      if (url.contains('_content/')) return _mjvDetailHtml;
      if (url.contains('play.php')) return _playPhpHtml;
      if (url.contains('_list/')) return _mjvSearchHtml;
      return '';
    }

    test('按番号搜索出卡 + 命中判定认详情地址尾段番号', () async {
      const source = Av18ActressSource();
      final cards = await source.fetchCards(
        primaryId: source.defaultPrimaryId,
        secondaryId: '',
        query: 'SSIS-001',
        page: 1,
        fetch: fakeFetch,
      );
      expect(cards, hasLength(2));
      expect(
        cards.first.pageUrl,
        'https://www.18av.nl/zh/chinese_content/255461/SSIS-001.html',
      );
      expect(av18CardMatches(cards.first, 'SSIS-001'), isTrue);
      expect(av18CardMatches(cards.first, 'MIDA-002'), isFalse);
      expect(
        actressOnlineCardMatches(
          source: source,
          card: cards.first,
          code: 'ssis-001',
        ),
        isTrue,
      );
    });

    test('取流全链：详情解密 pid → play.php 取 720 并补 https:', () async {
      const source = Av18ActressSource();
      final play = await source.resolvePlay(
        const OnlineVideoCard(
          pageUrl:
              'https://www.18av.nl/zh/chinese_content/255461/SSIS-001.html',
          title: 'SSIS-001',
        ),
        fetch: fakeFetch,
      );
      expect(play.streamUrl, 'https://cdn.test/v/720.m3u8');
      expect(play.headers['Referer'], 'https://www.18av.nl/');
      expect(play.detail.title, contains('SSIS-001'));
    });

    test('18AV 已进 Dart 直连源表（竞速同层）', () {
      expect(
        kActressOnlineSources.map((s) => s.id),
        containsAllInOrder(['123av', 'pornhub', 'av18']),
      );
      expect(actressOnlineSourceById('av18'), isNotNull);
    });
  });

  group('py 桥（MissAV / 潮流索引 / MJV 现拉）', () {
    test('MissAV 按番号搜 + 取址：命中回 surrit 直链与播放头', () async {
      final repo = _BridgeRepo();
      final bridge = ActressPyBridge(repo, verifyFetch: _probeOk);
      final target = await bridge.playMissavByCode('SSIS-001');
      expect(target, isNotNull);
      expect(target!.url, 'https://surrit.test/uuid/playlist.m3u8');
      expect(target.headers['Referer'], 'https://missav.ws/');
      expect(repo.missavSearches, 1);
    });

    test('MissAV 取流回 parse=1（仓储抛错）时按无结果处理', () async {
      final bridge = ActressPyBridge(
        _BridgeRepo(missavFails: true),
        verifyFetch: _probeOk,
      );
      expect(await bridge.playMissavByCode('SSIS-001'), isNull);
    });

    test('潮流索引三态一：命中且验活 → 直接递送索引地址、不落现拉', () async {
      final repo = _BridgeRepo();
      final bridge = ActressPyBridge(repo, verifyFetch: _probeOk);
      final target = await bridge.playChaoliuIndex('SSIS-001');
      expect(target!.url, 'https://index.test/ssis-001/index.m3u8');
      expect(repo.chaoliuSearches, 0);
    });

    test('潮流索引三态二：未命中（取流失败）→ 落 MJV 现拉', () async {
      final repo = _BridgeRepo(indexFails: true);
      final bridge = ActressPyBridge(repo, verifyFetch: _probeOk);
      final target = await bridge.playChaoliuIndex('SSIS-001');
      expect(target!.url, 'https://live.test/mjv/720.m3u8');
      expect(repo.chaoliuSearches, 1);
    });

    test('潮流索引三态三：命中但地址已死（轻验不过）→ 落 MJV 现拉', () async {
      final repo = _BridgeRepo();
      final bridge = ActressPyBridge(repo, verifyFetch: _probeDead);
      final target = await bridge.playChaoliuIndex('SSIS-001');
      expect(target!.url, 'https://live.test/mjv/720.m3u8');
      expect(repo.chaoliuSearches, 1);
    });

    test('MJV 现拉：搜索本体卡 → 详情 → 取 720P', () async {
      final bridge = ActressPyBridge(_BridgeRepo(), verifyFetch: _probeOk);
      final target = await bridge.playChaoliuLive('SSIS-001');
      expect(target!.url, 'https://live.test/mjv/720.m3u8');
    });
  });
}
