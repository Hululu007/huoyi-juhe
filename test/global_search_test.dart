import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_site_search.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/source_registry.dart';

/// 全局搜索回归：站表全量收录、类型过滤、境界门禁、单站失败隔离。
///
/// 背景：搜索页综合 tab 只查番茄后端，搜「神瞳」只出小说结果；「站源」
/// 页签只搜站表站，还排除午夜 jar 内置站、不含核心阅读站。全局搜索
/// （searchAllSites）以登记表为准全量查：站表行 + 登记条目（含午夜 jar
/// 内置站）+ 核心阅读站 31 个，门禁沿用影视区境界分档口径。
class _FakeClient implements DramaSiteContentClient {
  _FakeClient({this.items = const [], this.error, this.delay = Duration.zero});

  final List<DramaSiteItem> items;
  final Object? error;
  final Duration delay;

  @override
  Future<List<DramaSiteCategory>> categories() async => const [];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async =>
      throw UnimplementedError();

  @override
  Future<DramaSiteDetail> detail(String seriesId) async =>
      throw UnimplementedError();

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async =>
      throw UnimplementedError();

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (error != null) throw error!;
    return items;
  }
}

DramaSiteItem _item(String id, String title) =>
    DramaSiteItem(id: id, title: title, cover: '');

void main() {
  test('globalSearchTypeLabel：四种内容叫法', () {
    expect(globalSearchTypeLabel(ContentType.video), '视频');
    expect(globalSearchTypeLabel(ContentType.novel), '小说');
    expect(globalSearchTypeLabel(ContentType.comic), '漫画');
    expect(globalSearchTypeLabel(ContentType.audio), '听书');
    expect(globalSearchTypeLabel(ContentType.mixed), '综合');
  });

  test('站表收齐三块：站表行 + 登记条目（含午夜 jar 内置站）+ 核心阅读站', () {
    final targets = globalSearchTargets(
      dramaSiteRows: [
        const DramaSite('row1', '站表站'),
        const DramaSite('original', '番茄短剧'),
      ],
      customEntries: [
        const SourceEntry(
          id: 'seed_py1',
          name: '种子站',
          kind: SourceKind.pyImport,
          extra: {'contentType': 'video', 'seedId': 'py1'},
        ),
        const SourceEntry(
          id: 'jar:zakatv:ZakaX',
          name: 'jar 内置站',
          kind: SourceKind.jarImport,
          extra: {'contentType': 'video', 'builtin': true},
        ),
        const SourceEntry(
          id: 'import_1',
          name: '用户小说站',
          kind: SourceKind.pyImport,
          extra: {'contentType': 'novel'},
        ),
        // 远程 JSON 配置不是可搜条目，不进。
        const SourceEntry(
          id: 'remote_1',
          name: '远程配置',
          kind: SourceKind.remoteJson,
        ),
        // 被用户关掉的条目不进。
        const SourceEntry(
          id: 'off_1',
          name: '已关站',
          kind: SourceKind.pyImport,
          enabled: false,
          extra: {'contentType': 'video'},
        ),
      ],
      isBuiltinEnabled: (_) => true,
    );
    final ids = targets.map((t) => t.id).toSet();
    expect(
      ids,
      containsAll(['row1', 'seed_py1', 'jar:zakatv:ZakaX', 'import_1']),
    );
    expect(ids, isNot(contains('original')));
    expect(ids, isNot(contains('remote_1')));
    expect(ids, isNot(contains('off_1')));
    // 核心阅读站 31 个全收，阅读标记正确。
    final reading = targets.where((t) => t.readingCore).toList();
    expect(reading.length, coreReadingSiteIds.length);
    expect(reading.length, 31);
    expect(reading.map((t) => t.id).toSet(), containsAll(coreReadingSiteIds));
  });

  test('去重：裸行与登记条目归一化撞上只留裸行，裸行被关时条目存活', () {
    const seed = SourceEntry(
      id: 'seed_aisxpc',
      name: '种子 Ai小视频',
      kind: SourceKind.pyImport,
      extra: {'contentType': 'video', 'seedId': 'aisxpc'},
    );
    final deduped = globalSearchTargets(
      dramaSiteRows: [const DramaSite('aisxpc', '🔞Ai小视频')],
      customEntries: [seed],
      isBuiltinEnabled: (_) => true,
    );
    expect(deduped.map((t) => t.id), contains('aisxpc'));
    expect(deduped.map((t) => t.id), isNot(contains('seed_aisxpc')));

    final bareDisabled = globalSearchTargets(
      dramaSiteRows: [const DramaSite('aisxpc', '🔞Ai小视频')],
      customEntries: [seed],
      isBuiltinEnabled: (id) => id != 'aisxpc',
    );
    expect(bareDisabled.map((t) => t.id), contains('seed_aisxpc'));
    expect(bareDisabled.map((t) => t.id), isNot(contains('aisxpc')));
  });

  test('类型过滤：小说只出小说、漫画 11 个、听书 6 个含书音FM', () {
    final novels = globalSearchTargets(
      dramaSiteRows: const [DramaSite('row1', '站表站')],
      customEntries: const [],
      isBuiltinEnabled: (_) => true,
      types: {ContentType.novel},
    );
    expect(novels, isNotEmpty);
    expect(novels.every((t) => t.contentType == ContentType.novel), isTrue);
    expect(novels.where((t) => t.readingCore).length, 14);

    final comics = globalSearchTargets(
      dramaSiteRows: const [],
      customEntries: const [],
      isBuiltinEnabled: (_) => true,
      types: {ContentType.comic},
    );
    expect(comics.length, 11);
    expect(comics.every((t) => t.contentType == ContentType.comic), isTrue);

    final audios = globalSearchTargets(
      dramaSiteRows: const [],
      customEntries: const [],
      isBuiltinEnabled: (_) => true,
      types: {ContentType.audio},
    );
    expect(audios.map((t) => t.id).toSet(), {
      'tingyou',
      'hsvoice31',
      'hysxs',
      'ximalaya',
      'hongguo',
      'shuyinfm',
    });
  });

  test('短剧过滤：只留短剧站，电影站与阅读站不出', () {
    final targets = globalSearchTargets(
      dramaSiteRows: const [
        DramaSite('dj69', '🔞69短剧'),
        DramaSite('film1', '电影站'),
      ],
      customEntries: const [],
      isBuiltinEnabled: (_) => true,
      types: {ContentType.video, ContentType.mixed},
      shortDramaOnly: true,
    );
    expect(targets.map((t) => t.id), ['dj69']);
  });

  test('门禁：xp=0 藏分档成人站，修为够了才放行，表外站始终可见', () {
    List<String> idsAt(int xp) => globalSearchTargets(
      dramaSiteRows: const [
        DramaSite('mjv011', '🔞mjv011'),
        DramaSite('missav', '🔞MissAV'),
        DramaSite('plain1', '普通站'),
      ],
      customEntries: const [],
      isBuiltinEnabled: (_) => true,
      xp: xp,
      includeReadingCore: false,
    ).map((t) => t.id).toList();

    // mjv011 是分档表首站（第 1 档，3000 开）；missav 钉在第 4 档（30000 开）。
    expect(idsAt(0), ['plain1']);
    expect(idsAt(3000), containsAll(['mjv011', 'plain1']));
    expect(idsAt(3000), isNot(contains('missav')));
    expect(idsAt(15000), isNot(contains('missav')));
    expect(idsAt(30000), containsAll(['mjv011', 'missav', 'plain1']));
  });

  test('门禁：阅读成人站按阅读登记顺序分档，非成人阅读站始终可见', () {
    List<String> readingIdsAt(int xp) => globalSearchTargets(
      dramaSiteRows: const [],
      customEntries: const [],
      isBuiltinEnabled: (_) => true,
      xp: xp,
    ).map((t) => t.id).toList();

    // buliang 在成人阅读表里，xp=0 藏、修为满放行；aabook 不在表里，始终可见。
    expect(coreAdultReadingSiteIds, contains('buliang'));
    expect(readingIdsAt(0), isNot(contains('buliang')));
    expect(readingIdsAt(0), contains('aabook'));
    expect(readingIdsAt(30000), contains('buliang'));
  });

  test('门禁谓词与影视区口径一致：归一化 id 同样被拦', () {
    // 种子 id 与 jar id 归一化后撞上分档表，同样按档位拦。
    expect(
      globalSearchSiteVisible('seed_mjv011', 0, readingCore: false),
      isFalse,
    );
    expect(
      globalSearchSiteVisible('seed_mjv011', 3000, readingCore: false),
      isTrue,
    );
    expect(globalSearchSiteVisible('plain1', 0, readingCore: false), isTrue);
  });

  test('聚合：三家假站都出结果 → 三组，站名/类型/阅读标记正确', () async {
    final targets = [
      const GlobalSearchTarget(
        id: 'v1',
        name: '视频站',
        contentType: ContentType.video,
      ),
      const GlobalSearchTarget(
        id: 'n1',
        name: '小说站',
        contentType: ContentType.novel,
        readingCore: true,
      ),
      const GlobalSearchTarget(
        id: 'a1',
        name: '听书站',
        contentType: ContentType.audio,
        readingCore: true,
      ),
    ];
    final results = await searchGlobalTargets(
      '神瞳',
      targets,
      clientResolver: (target) async =>
          _FakeClient(items: [_item('${target.id}-1', '神瞳·${target.name}')]),
    );
    expect(results.map((r) => r.siteId), ['v1', 'n1', 'a1']);
    expect(results[0].siteName, '视频站');
    expect(results[0].contentType, ContentType.video);
    expect(results[0].readingCore, isFalse);
    expect(results[1].contentType, ContentType.novel);
    expect(results[1].readingCore, isTrue);
    expect(results[2].contentType, ContentType.audio);
    expect(results[2].items.single.title, '神瞳·听书站');
  });

  test('单站失败不拖垮整次搜索：抛错/超时/无客户端/空结果都只回空组', () async {
    final targets = [
      const GlobalSearchTarget(
        id: 'good',
        name: '好站',
        contentType: ContentType.video,
      ),
      const GlobalSearchTarget(
        id: 'boom',
        name: '抛错站',
        contentType: ContentType.video,
      ),
      const GlobalSearchTarget(
        id: 'slow',
        name: '超时站',
        contentType: ContentType.video,
      ),
      const GlobalSearchTarget(
        id: 'none',
        name: '无客户端站',
        contentType: ContentType.video,
      ),
      const GlobalSearchTarget(
        id: 'empty',
        name: '空结果站',
        contentType: ContentType.video,
      ),
    ];
    final results = await searchGlobalTargets(
      '神瞳',
      targets,
      clientResolver: (target) async {
        switch (target.id) {
          case 'good':
            return _FakeClient(items: [_item('1', '神瞳')]);
          case 'boom':
            return _FakeClient(error: StateError('boom'));
          case 'slow':
            return _FakeClient(
              delay: const Duration(seconds: 5),
              items: [_item('2', '神瞳·慢')],
            );
          case 'empty':
            return _FakeClient();
          default:
            return null;
        }
      },
      perSiteTimeout: const Duration(milliseconds: 100),
    );
    expect(results.map((r) => r.siteId), ['good']);
    expect(results.single.items.single.title, '神瞳');
  });

  test('空查询直接回空，不解析客户端', () async {
    final results = await searchGlobalTargets('   ', const [
      GlobalSearchTarget(id: 'v1', name: '视频站', contentType: ContentType.video),
    ], clientResolver: (_) async => throw StateError('must not resolve'));
    expect(results, isEmpty);
  });

  test('searchAllSites 空查询直接回空，不取站表', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await searchAllSites('   '), isEmpty);
  });

  test('searchAllSites 限定站：站 id 不在站表里时直接回空，不联网', () async {
    SharedPreferences.setMockInitialValues({});
    final results = await searchAllSites(
      '神瞳',
      siteIds: {'no-such-site'},
      xp: 0,
    );
    expect(results, isEmpty);
  });

  test('searchAllSites 真登记表 + 假客户端：听书页签搜出 6 个听书站', () async {
    SharedPreferences.setMockInitialValues({});
    final seen = <String>[];
    final results = await searchAllSites(
      '神瞳',
      types: {ContentType.audio},
      xp: 30000,
      clientResolver: (target) async {
        seen.add(target.id);
        return _FakeClient(items: [_item('1', '神瞳·${target.name}')]);
      },
    );
    // 6 个听书站（含书音FM）全被搜到，且都走了阅读客户端标记。
    expect(seen.toSet(), {
      'tingyou',
      'hsvoice31',
      'hysxs',
      'ximalaya',
      'hongguo',
      'shuyinfm',
    });
    expect(results.length, 6);
    expect(results.every((r) => r.readingCore), isTrue);
    expect(results.every((r) => r.contentType == ContentType.audio), isTrue);
  });
}
