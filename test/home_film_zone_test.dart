import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:fqapp/widgets/home/home_film_zone.dart';

import 'embedded_test_entries.dart';

/// 推荐页全局「影视」区：站表按修为分档，未解锁的站完全不出现；
/// 视频站与阅读站按登记表顺序拼在一起（纯函数 [visibleFilmZoneSites]
/// 不分池，widget 层只取其中视频站平铺推荐，阅读站走各自的分站区）。
///
/// 影视区不含短剧：短剧站已在统一表里摘掉。视频行
/// 291 行 = 分档影视行 240（第 1 档 49 + 第 2 档 60 + 第 3 档 54 +
/// 第 4 档 77）+ 不分档影视行 51（从未进核心的 jar/种子站
/// 与 YouTube 行；芽果/AI淫航/幻影AI 各 jar+种子两行共 6 行是
/// 短剧站，不分档，57→51 全是这 6 行）；阅读档位按 31 站登记顺序的固定分档
/// （阅读站表不变，变了再改这里）。
/// 行数与 video_page_tier_test 的统一表一致（291 行）；旧注里的
/// 239 分档（49/61/54/75）与 54 不分档是并行加站前的旧数。
void main() {
  /// 内嵌站测试条目（种子 + jar），与生产登记一致。
  final entries = embeddedTestEntries();

  /// 门禁开关：生产默认值 true（测试期临时关闭）会放行全部档位，
  /// 分档断言须先关掉，用完恢复。
  void gateOff() {
    cultivationAdultTierGateDisabledForTesting = false;
    addTearDown(() => cultivationAdultTierGateDisabledForTesting = true);
  }

  /// 非成人阅读站 id。
  final nonAdultReading = coreReadingSiteIds
      .where((id) => !coreAdultReadingSiteIds.contains(id))
      .toList();

  /// 各档的成人阅读站（按阅读登记表下标分档：31 站，8/8/8/7）。
  const readingTierAdult = <int, List<String>>{
    0: [
      '1000novel', '69story', 'buliang', 'canovel', 'cheniyo', 'cjg',
      'h528',
    ],
    1: [
      'hwg4', 'jywx2', 'lbwen', 'ssxxs', 'yinse', '55comics',
      'csmanhua',
    ],
    2: ['ho5ho', 'modu18'],
    3: ['hsvoice31', 'hysxs'],
  };

  test('修为 0 时只有不分档视频站 + 非成人阅读站', () {
    gateOff();
    final sites = visibleFilmZoneSites(0, entries);
    expect(
      sites.length,
      51 + nonAdultReading.length,
    );
    final video = [for (final s in sites) if (s.kind == 'video') s];
    // 51 行不分档影视行；分档行一个都不露。
    expect(video.length, 51);
    expect(
      video.any((s) => s.id == 'jar:zakatv:ZakaMjv011'),
      isFalse,
    );
    expect(
      video.any((s) => s.id == 'jar:zakatv:ZakaMissav'),
      isFalse,
    );
    expect(video.any((s) => s.id == 'seed_abjav'), isFalse);
    final reading = [for (final s in sites) if (s.kind != 'video') s];
    expect(
      reading.map((s) => s.id).toSet(),
      nonAdultReading.toSet(),
    );
    // 一个成人站都不露。
    for (final s in sites) {
      expect(coreAdultReadingSiteIds.contains(s.id), isFalse);
    }
    expect(sites.any((s) => s.id == 'missav'), isFalse);
    expect(sites.any((s) => s.id == 'javrate'), isFalse);
    expect(sites.any((s) => s.id == '1000novel'), isFalse);
    expect(sites.any((s) => s.id == 'hsvoice31'), isFalse);
  });

  test('元婴 3000 时第 1 档视频站与第 1 档成人阅读站出现', () {
    gateOff();
    final sites = visibleFilmZoneSites(3000, entries);
    final ids = sites.map((s) => s.id).toSet();
    // 登记表第 1 个视频站（mjv011，jar 行）在第 1 档，3000 修为可见。
    expect(ids.contains('jar:zakatv:ZakaMjv011'), isTrue);
    // missav 与鉴黄师钉第 4 档末尾，3000 修为还看不到。
    expect(ids.contains('jar:zakatv:ZakaMissav'), isFalse);
    expect(ids.contains('jar:zakatv:ZakaJavrate'), isFalse);
    // 阅读登记表第 1 位（1000novel）在第 1 档；第 27 位（hsvoice31）
    // 在第 4 档，3000 修为还看不到。
    expect(ids.contains('1000novel'), isTrue);
    expect(ids.contains('hsvoice31'), isFalse);
    // 视频不分档 51 + 第 1 档 49；阅读非成人 + 第 1 档 7 个。
    expect(
      sites.where((s) => s.kind == 'video').length,
      100,
    );
    expect(
      sites.where((s) => s.kind != 'video').length,
      nonAdultReading.length + readingTierAdult[0]!.length,
    );
  });

  test('化神 8000 与炼虚 15000 逐档放开', () {
    gateOff();
    final at8000 = visibleFilmZoneSites(8000, entries);
    expect(
      at8000.where((s) => s.kind == 'video').length,
      160,
    );
    expect(
      at8000.where((s) => s.kind != 'video').length,
      nonAdultReading.length +
          readingTierAdult[0]!.length +
          readingTierAdult[1]!.length,
    );
    // 第 3 档的成人阅读站（ho5ho）在 8000 时还不出现。
    expect(
      at8000.any((s) => s.id == 'ho5ho'),
      isFalse,
    );
    final at15000 = visibleFilmZoneSites(15000, entries);
    expect(
      at15000.where((s) => s.kind == 'video').length,
      220,
    );
    expect(
      at15000.where((s) => s.kind != 'video').length,
      nonAdultReading.length +
          readingTierAdult[0]!.length +
          readingTierAdult[1]!.length +
          readingTierAdult[2]!.length,
    );
    expect(at15000.any((s) => s.id == 'ho5ho'), isTrue);
    expect(at15000.any((s) => s.id == 'hsvoice31'), isFalse);
  });

  test('合体 30000 时全部开完，四类齐全，无重复 id', () {
    gateOff();
    final sites = visibleFilmZoneSites(30000, entries);
    // 视频 291 行；阅读 31 站。
    expect(
      sites.where((s) => s.kind == 'video').length,
      291,
    );
    expect(
      sites.length,
      291 + coreReadingSiteIds.length,
    );
    final kinds = <String, int>{};
    for (final s in sites) {
      kinds[s.kind] = (kinds[s.kind] ?? 0) + 1;
    }
    final readingKinds = <String, int>{};
    for (final kind in coreReadingKinds.values) {
      readingKinds[kind] = (readingKinds[kind] ?? 0) + 1;
    }
    expect(kinds['video'], 291);
    expect(kinds['novel'], readingKinds['novel']);
    expect(kinds['comic'], readingKinds['comic']);
    expect(kinds['audio'], readingKinds['audio']);
    final ids = sites.map((s) => s.id).toList();
    expect(ids.toSet().length, ids.length);
    expect(ids.contains('jar:zakatv:ZakaMissav'), isTrue);
    expect(ids.contains('jar:zakatv:ZakaJavrate'), isTrue);
    expect(ids.contains('hsvoice31'), isTrue);
    expect(ids.contains('hysxs'), isTrue);
    // 阅读站名：有中文名的用中文名，没中文名的用 id；与视频站同 id
    // 的红果听书按阅读侧显示名，不跟视频红果撞。
    final byId = {for (final s in sites) s.id: s};
    expect(byId['dongmanla']!.name, '动漫啦');
    expect(byId['kuaikan']!.name, '快看漫画');
    expect(byId['tencent']!.name, '腾讯动漫');
    expect(byId['shuyinfm']!.name, '书音FM');
    expect(byId['hongguo']!.name, '红果听书');
    expect(byId['hongguo']!.kind, 'audio');
    expect(byId['aabook']!.name, 'aabook');
    expect(byId['aabook']!.kind, 'novel');
  });

  group('影视区 widget', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    /// 表面 360 宽时网格区宽 328（360 - 两侧各 16 边距），与传入
    /// HomeFilmZone 的 gridWidth 一致；不一致时卡片按窄算、按宽排，
    /// 会报 RenderFlex 溢出。
    Future<void> setPhoneSurface(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    }

    testWidgets('打开即自动取首窗推荐平铺，阅读站不进池', (tester) async {
      await setPhoneSurface(tester);
      final sites = <({String id, String name, String kind})>[
        (id: 'video1', name: '测试视频站', kind: 'video'),
        (id: 'novel1', name: '测试小说站', kind: 'novel'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                HomeFilmZone(
                  gridWidth: 328,
                  sites: sites,
                  clientForSite: (id) => _FakeFilmClient(
                    title: id == 'video1' ? '视频站作品' : '小说站作品',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('影视'), findsOneWidget);
      // 打开就自动取数挂网格，不用点站；池子只留视频站，小说站不进。
      expect(find.text('视频站作品'), findsOneWidget);
      expect(find.text('小说站作品'), findsNothing);
      // 池子只有 1 站，不到 3 站窗口，没有「换一批」。
      expect(find.byKey(const ValueKey('film-zone-next-batch')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('池子超过 3 站时「换一批」换下 3 个站', (tester) async {
      await setPhoneSurface(tester);
      final sites = <({String id, String name, String kind})>[
        for (var i = 1; i <= 4; i++)
          (id: 'video$i', name: '测试视频站$i', kind: 'video'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                HomeFilmZone(
                  gridWidth: 328,
                  sites: sites,
                  clientForSite: (id) => _FakeFilmClient(
                    title: '作品${id.substring('video'.length)}',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('作品1'), findsOneWidget);
      expect(find.text('作品2'), findsOneWidget);
      expect(find.text('作品3'), findsOneWidget);
      expect(find.text('作品4'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('film-zone-next-batch')));
      await tester.pumpAndSettle();
      // 窗口滑到第 4 站起（含回绕）：作品4 出现，作品3 换出。
      expect(find.text('作品4'), findsOneWidget);
      expect(find.text('作品3'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('修为到了新档位，影视区自动出现新站', (tester) async {
      await setPhoneSurface(tester);
      final previous =
          CultivationService.instance.snapshotNotifier.value;
      addTearDown(
        () => CultivationService.instance.snapshotNotifier.value =
            previous,
      );
      // 门禁开关关掉才按档位拦（生产默认值 true 是测试期临时关闭）。
      final wasDisabled = cultivationAdultTierGateDisabledForTesting;
      cultivationAdultTierGateDisabledForTesting = false;
      addTearDown(
        () => cultivationAdultTierGateDisabledForTesting = wasDisabled,
      );
      // 往登记表里只放 mjv011 的 jar 行：修为 0 时视频池是空的
      // （第 1 档的 mjv011 还没进池）。
      SharedPreferences.setMockInitialValues({
        'juhe_custom_sources': jsonEncode([
          const SourceEntry(
            id: 'jar:zakatv:ZakaMjv011',
            name: '🔞mjv011',
            kind: SourceKind.jarImport,
            extra: {'builtin': true, 'contentType': 'video'},
          ).toJson(),
        ]),
      });
      await SourceRegistry.instance.load();
      CultivationService.instance.snapshotNotifier.value =
          CultivationSnapshot.empty;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                HomeFilmZone(
                  gridWidth: 328,
                  clientForSite: (id) =>
                      _FakeFilmClient(title: '作品-$id'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 修为 0 时池里是空的，影视区显示空态，第 1 档的 mjv011 还没进池。
      expect(find.text('暂无可显示的影视站'), findsOneWidget);
      expect(find.text('作品-jar:zakatv:ZakaMjv011'), findsNothing);
      // 修为到元婴 3000，第 1 档解锁，首窗里自动出现 mjv011。
      CultivationService.instance.snapshotNotifier.value =
          const CultivationSnapshot(bonusXp: 3000);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('作品-jar:zakatv:ZakaMjv011'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('回空的站不记失败：有内容的站出卡，不显示“取不到”', (tester) async {
      await setPhoneSurface(tester);
      final sites = <({String id, String name, String kind})>[
        (id: 'video1', name: '测试视频站1', kind: 'video'),
        (id: 'video2', name: '测试视频站2', kind: 'video'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                HomeFilmZone(
                  gridWidth: 328,
                  sites: sites,
                  clientForSite: (id) => id == 'video2'
                      ? _FakeFilmClient(title: '空站作品', emptyCatalog: true)
                      : _FakeFilmClient(title: '视频站作品'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('视频站作品'), findsOneWidget);
      // 回空的站不算失败：不显示「N 个站取不到」。
      expect(find.textContaining('取不到'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('全失败时显示取不到、可重试', (tester) async {
      await setPhoneSurface(tester);
      final sites = <({String id, String name, String kind})>[
        (id: 'video1', name: '测试视频站', kind: 'video'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                HomeFilmZone(
                  gridWidth: 328,
                  sites: sites,
                  clientForSite: (id) =>
                      _FakeFilmClient(title: '视频站作品', throwCatalog: true),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('推荐影视暂时取不到，稍后再试一次。'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('全回空时显示暂无内容，不说取不到', (tester) async {
      await setPhoneSurface(tester);
      final sites = <({String id, String name, String kind})>[
        (id: 'video1', name: '测试视频站', kind: 'video'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                HomeFilmZone(
                  gridWidth: 328,
                  sites: sites,
                  clientForSite: (id) =>
                      _FakeFilmClient(title: '空站作品', emptyCatalog: true),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 核心正常回空：如实显示暂无内容，不说「取不到」。
      expect(find.text('推荐影视暂无内容。'), findsOneWidget);
      expect(find.text('推荐影视暂时取不到，稍后再试一次。'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

class _FakeFilmClient extends DramaSiteContentClient {
  _FakeFilmClient({
    required this.title,
    this.throwCatalog = false,
    this.emptyCatalog = false,
  });

  final String title;

  /// catalog 抛错：模拟超时/报错的站（记失败）。
  final bool throwCatalog;

  /// catalog 回空列表：模拟核心正常回空的站（不记失败）。
  final bool emptyCatalog;

  @override
  Future<List<DramaSiteCategory>> categories() async =>
      const [DramaSiteCategory('all', '全部')];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    if (throwCatalog) throw StateError('模拟取数失败');
    if (emptyCatalog) {
      return const DramaSiteCatalogPage(items: [], hasMore: false);
    }
    return DramaSiteCatalogPage(
      items: [DramaSiteItem(id: 'v1', title: title, cover: '')],
      hasMore: false,
    );
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async =>
      const DramaSiteDetail(id: '', title: '', cover: '', episodes: []);

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async =>
      const DramaPlaySource(url: '');
}
