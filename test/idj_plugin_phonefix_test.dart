import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/idj_plugin_store.dart';
import 'package:fqapp/services/idj_runtime.dart';
import 'package:fqapp/services/shell_proxy_url.dart';

/// 插件手机实测五症状回归（20261127+2 装机反馈）：
/// ① MissAV 被「未声明 storage 权限」整站挡死——真根因是脚本组装
///    顺序（垫片在加载期读 __idjStorageAllowed，变量排在垫片后时
///    var 只提升声明不提升赋值，读到的恒是 undefined）＋未声明时
///    抛错整站死的处置过重；
/// ② 黄色仓库 manifest 的 media 里有公网 IP（23.225.11.173）被
///    域名校验整包拒装；
/// ③ 分类名读错字段（真包回 name，宿主只读 title）＋'all' 伪分类
///    原样喂插件 category op（18AV 整页「分类加载失败」的一环）；
/// ④ 封面：协议相对地址（黄果）发不出请求、图床查 Referer 时
///    直取无头被拒（321AV）；附带 321AV 详情的 MacCMS 字段形态
///    （vod_*）宿主不认、详情全空；
/// ⑤ 报错页点重试连环失败把插件计数停用（感知为「点重试关站」）：
///    契约类错误码永不计数（store 套件另测冷却窗连发只计一次）。
/// 夹具形态全部照远程仓库真包（MissAV/321AV/18AV/rouAV/黄果/
/// 黄色仓库）的 manifest 与回包实测形状。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory rootDir;
  late Directory supportDir;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    rootDir = await Directory.systemTemp.createTemp('idj_fix_root');
    supportDir = await Directory.systemTemp.createTemp('idj_fix_support');
  });

  tearDown(() async {
    if (await rootDir.exists()) await rootDir.delete(recursive: true);
    if (await supportDir.exists()) await supportDir.delete(recursive: true);
  });

  IdjPluginManifest manifestOf(Map<String, dynamic> json) =>
      IdjPluginManifest.fromJson(json);

  Map<String, dynamic> baseManifest({
    required String id,
    required List<String> http,
    List<String> media = const [],
    bool storage = false,
  }) => {
    'schema': 1,
    'id': id,
    'name': '夹具插件',
    'version': '1.0.0',
    'entry': 'main.js',
    'type': 'video',
    'adult': true,
    'capabilities': ['home', 'category', 'search', 'detail', 'play'],
    'permissions': {
      'http': http,
      'media': media,
      'cloudflare': false,
      'storage': storage,
      'login': false,
    },
  };

  Future<IdjPluginStore> storeWith(Map<String, dynamic> manifestJson) async {
    final store = IdjPluginStore(
      preferences: prefs,
      rootDir: rootDir,
      supportDir: supportDir,
      probe: ({required pluginId, required script, required manifest}) async {},
      uriValidator: (_) async {},
    );
    await store.installBundleText(
      jsonEncode({
        'manifest': manifestJson,
        'files': {'main.js': 'export default {};'},
      }),
    );
    return store;
  }

  IdjSiteContentClient clientWith(
    IdjPluginStore store,
    String pluginId,
    Map<String, dynamic> Function(String op) results, {
    List<String>? seenOps,
  }) {
    final runtime = IdjRuntime(
      store: store,
      evalFn: (script, timeoutMs) async {
        final op = ['home', 'category', 'detail', 'play', 'search']
            .firstWhere(
              (name) => script.contains("__idj_plugin['$name']"),
              orElse: () => '',
            );
        seenOps?.add(op);
        return jsonEncode({'ok': true, 'result': results(op), 'storage': {}});
      },
    );
    return IdjSiteContentClient(
      pluginId: pluginId,
      store: store,
      runtime: runtime,
    );
  }

  group('症状一：storage 权限门（MissAV）', () {
    test('组装顺序：注入变量排在垫片之前，storage 分支读得到真值', () {
      final script = buildIdjDriverScript(
        pluginScript: 'export default { home() {} };',
        manifest: manifestOf(
          baseManifest(
            id: 'com.idj.ext.missav',
            http: ['missav.ws'],
            storage: true,
          ),
        ),
        op: 'home',
        args: const {},
        storage: const {},
      );
      final varAt = script.indexOf('var __idjStorageAllowed = true;');
      final branchAt = script.indexOf('if (__idjStorageAllowed)');
      expect(varAt, greaterThanOrEqualTo(0));
      expect(branchAt, greaterThan(varAt));
    });

    test('未声明 storage 不再抛错整站死：垫片是降级实现＋留日志', () {
      final script = buildIdjDriverScript(
        pluginScript: 'export default { home() {} };',
        manifest: manifestOf(
          baseManifest(id: 'com.idj.ext.demo', http: ['example.com']),
        ),
        op: 'home',
        args: const {},
        storage: const {},
      );
      expect(script, isNot(contains("new Error('插件未声明 storage 权限')")));
      expect(script, contains('存储降级为临时'));
    });

    test('运行时域名门带 IP 分支：白名单内公网 IP 放行、回环仍拒', () {
      final script = buildIdjDriverScript(
        pluginScript: 'export default { home() {} };',
        manifest: manifestOf(
          baseManifest(
            id: 'com.idj.ext.huangsecangku',
            http: ['www.hsck01.net'],
            media: ['23.225.11.173'],
          ),
        ),
        op: 'home',
        args: const {},
        storage: const {},
      );
      expect(script, contains("host.split('.')[0] === '127'"));
      expect(script, contains('"23.225.11.173"'));
    });
  });

  group('症状二：域名校验认公网 IP（黄色仓库）', () {
    test('media 里有公网 IP 字面量：校验通过', () {
      final manifest = manifestOf(
        baseManifest(
          id: 'com.idj.ext.huangsecangku',
          http: ['www.hsck01.net', 'hsck.la'],
          media: ['*.vcwinford.cc', '23.225.11.173', 't0.97img.com'],
          storage: true,
        ),
      );
      expect(manifest.problems(), isEmpty);
    });

    test('带协议与端口的 IP 地址：归一化后校验通过', () {
      final manifest = manifestOf(
        baseManifest(
          id: 'com.idj.ext.demo',
          http: ['http://203.0.113.7:8899/api'],
        ),
      );
      expect(manifest.httpDomains, contains('203.0.113.7'));
      expect(manifest.problems(), isEmpty);
    });

    test('回环 IP 仍拒：不许插件把请求打回本机', () {
      final manifest = manifestOf(
        baseManifest(
          id: 'com.idj.ext.demo',
          http: ['example.com'],
          media: ['127.0.0.1'],
        ),
      );
      expect(
        manifest.problems().join('；'),
        contains('域名不合法：127.0.0.1'),
      );
    });
  });

  group('症状三：分类名映射（321AV/rouAV/黄果/18AV）', () {
    test('真包形态 {id, name}：显示中文名而不是 id 生词', () {
      final home = parseIdjHome({
        'categories': [
          {'id': 'latest', 'name': '最新'},
          {'id': '20', 'name': '有码影片'},
          {'id': '21', 'name': '无码影片'},
          {'id': '22', 'name': '中文字幕'},
          {'id': 'actress', 'name': '女优'},
        ],
        'items': [],
      });
      // 首项是宿主自加的「全部」伪分类，其余照插件回包。
      expect(
        home.categories.map((c) => c.name),
        ['全部', '最新', '有码影片', '无码影片', '中文字幕', '女优'],
      );
      expect(home.categories.map((c) => c.id), [
        '',
        'latest',
        '20',
        '21',
        '22',
        'actress',
      ]);
    });

    test('MacCMS 形态 {type_id, type_name}：id 与名都取得出', () {
      final home = parseIdjHome({
        'categories': [
          {'type_id': 7, 'type_name': '国产剧'},
          {'type_id': '3', 'type_name': '纪录片'},
        ],
        'items': [],
      });
      expect(home.categories.map((c) => c.id), ['', '7', '3']);
      expect(home.categories.map((c) => c.name), ['全部', '国产剧', '纪录片']);
    });

    test('旧形态 {id, title} 不回归', () {
      final home = parseIdjHome({
        'categories': [
          {'id': 'movie', 'title': '电影'},
        ],
        'items': [],
      });
      expect(home.categories.map((c) => c.name), ['全部', '电影']);
    });

    test("宿主伪分类 'all' 走 home 路，不再原样喂 category op", () async {
      final store = await storeWith(
        baseManifest(id: 'com.idj.ext.18av', http: ['18av.tv']),
      );
      final seenOps = <String>[];
      final client = clientWith(store, 'com.idj.ext.18av', (op) => {
        'categories': [
          {'type_id': 1, 'type_name': '国产'},
        ],
        'items': [
          {'id': 'v1', 'title': '首页片', 'poster': 'https://i/1.jpg'},
        ],
      }, seenOps: seenOps);
      final page = await client.catalog('all', 1);
      expect(seenOps, ['home']);
      expect(page.items.single.title, '首页片');
    });
  });

  group('症状四：封面后处理（黄果/321AV）', () {
    test('黄果形态：协议相对 cover 补 https 并带站点 Referer', () async {
      final store = await storeWith(
        baseManifest(
          id: 'com.idj.ext.huangguo',
          http: ['huangguoai.com'],
          media: ['*.qnlycc.cn'],
        ),
      );
      final client = clientWith(store, 'com.idj.ext.huangguo', (op) => {
        'categories': [],
        'items': [
          {
            'id': 's1',
            'title': '短剧一',
            'cover': '//cdn.qnlycc.cn/cover/1.jpg',
            'subtitle': '全24集',
          },
        ],
      });
      final page = await client.catalog('', 1);
      final cover = page.items.single.cover;
      expect(cover, startsWith('http://127.0.0.1:9978/proxy?p='));
      final unwrapped = unwrapShellProxyUrl(cover);
      expect(unwrapped?.url, 'https://cdn.qnlycc.cn/cover/1.jpg');
      expect(unwrapped?.headers['Referer'], 'https://huangguoai.com/');
      expect(page.items.single.remark, '全24集');
    });

    test('321AV 形态：自家图床 poster 带站点 Referer 取图', () async {
      final store = await storeWith(
        baseManifest(
          id: 'com.idj.ext.321av',
          http: ['321av.cc', 'www.321av.cc'],
          media: ['*.piccdn2.mom'],
        ),
      );
      final client = clientWith(store, 'com.idj.ext.321av', (op) => {
        'items': [
          {
            'id': '1001',
            'title': '示例片',
            'poster': 'https://www.321av.ink/img/1001.jpg',
            'remarks': '2026-11-20',
          },
        ],
      });
      final page = await client.catalog('20', 1);
      final unwrapped = unwrapShellProxyUrl(page.items.single.cover);
      expect(unwrapped?.url, 'https://www.321av.ink/img/1001.jpg');
      expect(unwrapped?.headers['Referer'], 'https://321av.cc/');
    });
  });

  group('症状四附带：321AV 详情 MacCMS 形态', () {
    Map<String, dynamic> vodDetail() => {
      'vod_id': 1001,
      'vod_name': '示例片名',
      'vod_pic': 'https://www.321av.ink/img/1001.jpg',
      'vod_year': '2026',
      'vod_area': '日本',
      'vod_lang': '日语',
      'vod_director': '某导演',
      'vod_actor': '甲,乙',
      'vod_remarks': 'HD',
      'vod_content': '简介正文',
      'vod_play_from': '主线\$\$\$备线',
      'vod_play_url':
          '正片\$https://cdn.example.com/main.m3u8'
          '\$\$\$正片\$https://cdn2.example.com/main.m3u8',
    };

    test('vod_* 字段与播放拼串都映射得出', () {
      final detail = parseIdjDetail(vodDetail(), '1001');
      expect(detail.id, '1001');
      expect(detail.title, '示例片名');
      expect(detail.cover, 'https://www.321av.ink/img/1001.jpg');
      expect(detail.synopsis, '简介正文');
      expect(detail.extra['year'], '2026');
      expect(detail.extra['region'], '日本');
      expect(detail.extra['actors'], '甲,乙');
      expect(detail.extra['status'], 'HD');
      expect(detail.episodes, hasLength(2));
      expect(
        detail.episodes.first.videoId,
        '主线\u0001https://cdn.example.com/main.m3u8',
      );
      expect(detail.episodes.first.title, '正片');
      expect(
        detail.episodes.last.videoId,
        '备线\u0001https://cdn2.example.com/main.m3u8',
      );
    });

    test('经客户端详情：封面同样带 Referer 载荷', () async {
      final store = await storeWith(
        baseManifest(
          id: 'com.idj.ext.321av',
          http: ['321av.cc', 'www.321av.cc'],
        ),
      );
      final client = clientWith(
        store,
        'com.idj.ext.321av',
        (op) => vodDetail(),
      );
      final detail = await client.detail('1001');
      final unwrapped = unwrapShellProxyUrl(detail.cover);
      expect(unwrapped?.url, 'https://www.321av.ink/img/1001.jpg');
      expect(unwrapped?.headers['Referer'], 'https://321av.cc/');
      expect(detail.episodes, hasLength(2));
    });
  });

  group('症状五：看门狗不把契约错误算成插件故障', () {
    test('E_PERMISSION / E_DOMAIN 连环出现也不计数、不停用', () async {
      final store = await storeWith(
        baseManifest(id: 'com.idj.ext.demo', http: ['example.com']),
      );
      for (var i = 0; i < 5; i++) {
        await store.recordFailure('com.idj.ext.demo', code: 'E_PERMISSION');
        await store.recordFailure('com.idj.ext.demo', code: 'E_DOMAIN');
      }
      final entry = (await store.listInstalled()).single.entry;
      expect(entry.failures, 0);
      expect(entry.enabled, isTrue);
    });
  });
}
