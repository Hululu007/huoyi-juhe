import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/widgets/home/home_film_zone.dart';

/// 推荐页全局「影视」区：站表按修为分档，未解锁的站完全不出现；
/// 视频、小说、漫画、听书四类齐全；修为到了新档位自动出现。
///
/// 视频站总数随登记表变（主聊还在往 200 补），所以档位规模不写死：
/// 视频档位规模从 adultTierSiteIds 现算，阅读档位按 31 站登记顺序
/// 的固定分档（阅读站表不变，变了再改这里）。
void main() {
  /// 视频某档的站数（按当前登记表现算）。
  int videoTierSize(int tier) =>
      adultTierSiteIds(tier, coreVideoSiteIds.toList()).length;

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

  test('修为 0 时只有 5 个果站视频 + 非成人阅读站', () {
    final sites = visibleFilmZoneSites(0);
    expect(
      sites.length,
      5 + nonAdultReading.length,
    );
    final video = [for (final s in sites) if (s.kind == 'video') s];
    expect(
      video.map((s) => s.id).toList(),
      ['huangdou', 'huangju', 'yeguo', 'yaguo', 'niuguo'],
    );
    final reading = [for (final s in sites) if (s.kind != 'video') s];
    expect(
      reading.map((s) => s.id).toSet(),
      nonAdultReading.toSet(),
    );
    // 一个成人站都不露。
    for (final s in sites) {
      expect(coreVideoSiteIds.contains(s.id), isFalse);
      expect(coreAdultReadingSiteIds.contains(s.id), isFalse);
    }
    expect(sites.any((s) => s.id == 'missav'), isFalse);
    expect(sites.any((s) => s.id == 'javrate'), isFalse);
    expect(sites.any((s) => s.id == '1000novel'), isFalse);
    expect(sites.any((s) => s.id == 'hsvoice31'), isFalse);
  });

  test('元婴 3000 时第 1 档视频站与第 1 档成人阅读站出现', () {
    final sites = visibleFilmZoneSites(3000);
    final ids = sites.map((s) => s.id).toSet();
    // 登记表第 1 个视频站（mjv011）在第 1 档，3000 修为可见。
    expect(ids.contains('mjv011'), isTrue);
    // missav 与鉴黄师钉第 4 档末尾，3000 修为还看不到。
    expect(ids.contains('missav'), isFalse);
    expect(ids.contains('javrate'), isFalse);
    // 阅读登记表第 1 位（1000novel）在第 1 档；第 27 位（hsvoice31）
    // 在第 4 档，3000 修为还看不到。
    expect(ids.contains('1000novel'), isTrue);
    expect(ids.contains('hsvoice31'), isFalse);
    // 视频 5 果站 + 第 1 档；阅读非成人 + 第 1 档 7 个。
    expect(
      sites.where((s) => s.kind == 'video').length,
      5 + videoTierSize(0),
    );
    expect(
      sites.where((s) => s.kind != 'video').length,
      nonAdultReading.length + readingTierAdult[0]!.length,
    );
  });

  test('化神 8000 与炼虚 15000 逐档放开', () {
    final at8000 = visibleFilmZoneSites(8000);
    expect(
      at8000.where((s) => s.kind == 'video').length,
      5 + videoTierSize(0) + videoTierSize(1),
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
    final at15000 = visibleFilmZoneSites(15000);
    expect(
      at15000.where((s) => s.kind == 'video').length,
      5 + videoTierSize(0) + videoTierSize(1) + videoTierSize(2),
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
    final sites = visibleFilmZoneSites(30000);
    expect(
      sites.length,
      5 + coreVideoSiteIds.length + coreReadingSiteIds.length,
    );
    final kinds = <String, int>{};
    for (final s in sites) {
      kinds[s.kind] = (kinds[s.kind] ?? 0) + 1;
    }
    final readingKinds = <String, int>{};
    for (final kind in coreReadingKinds.values) {
      readingKinds[kind] = (readingKinds[kind] ?? 0) + 1;
    }
    expect(kinds['video'], 5 + coreVideoSiteIds.length);
    expect(kinds['novel'], readingKinds['novel']);
    expect(kinds['comic'], readingKinds['comic']);
    expect(kinds['audio'], readingKinds['audio']);
    final ids = sites.map((s) => s.id).toList();
    expect(ids.toSet().length, ids.length);
    expect(ids.contains('missav'), isTrue);
    expect(ids.contains('javrate'), isTrue);
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

    testWidgets('标题与站点药丸显示，点药丸切站换网格', (tester) async {
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
      expect(find.text('测试视频站'), findsOneWidget);
      expect(find.text('测试小说站·小说'), findsOneWidget);
      // 没点药丸时不挂网格、不取数，只留一行提示。
      expect(find.text('点一个站点看内容'), findsOneWidget);
      expect(find.text('视频站作品'), findsNothing);
      await tester.tap(find.byKey(const Key('film-zone-site-video1')));
      await tester.pumpAndSettle();
      expect(find.text('视频站作品'), findsOneWidget);
      await tester.tap(find.byKey(const Key('film-zone-site-novel1')));
      await tester.pumpAndSettle();
      expect(find.text('小说站作品'), findsOneWidget);
      expect(find.text('视频站作品'), findsNothing);
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
      CultivationService.instance.snapshotNotifier.value =
          CultivationSnapshot.empty;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                HomeFilmZone(
                  gridWidth: 328,
                  clientForSite: (_) =>
                      _FakeFilmClient(title: '作品'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 修为 0 时登记表第 1 个视频站（mjv011，第 1 档）不在药丸条里。
      await tester.drag(
        find.byKey(const Key('film-zone-site-strip')),
        const Offset(-600, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('🔞mjv011'), findsNothing);
      // 修为到元婴 3000，第 1 档解锁，药丸条里自动出现。
      CultivationService.instance.snapshotNotifier.value =
          const CultivationSnapshot(bonusXp: 3000);
      await tester.pump();
      await tester.pumpAndSettle();
      // 先拖回条首（上一次拖动停在 600 偏移，mjv011 在条首附近），
      // 再小幅左移把它露出来。
      await tester.drag(
        find.byKey(const Key('film-zone-site-strip')),
        const Offset(1000, 0),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('film-zone-site-strip')),
        const Offset(-60, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('🔞mjv011'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

class _FakeFilmClient extends DramaSiteContentClient {
  _FakeFilmClient({required this.title});

  final String title;

  @override
  Future<List<DramaSiteCategory>> categories() async =>
      const [DramaSiteCategory('all', '全部')];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
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
