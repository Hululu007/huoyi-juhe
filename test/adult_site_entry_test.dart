import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/game_data.dart';
import 'package:fqapp/services/game_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GameService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CultivationService.instance.resetForTest();
    await GameService.instance.resetForTest();
    service = GameService.instance;
    await service.ensureInitialized();
  });

  tearDown(() async {
    await GameService.instance.resetForTest();
    await CultivationService.instance.resetForTest();
  });

  group('影视区看片扣费（进详情页扣 20 元宝，不分档）', () {
    test('定价是每部 20 元宝，不分档', () {
      expect(gameAdultFilmCost, 20);
    });

    test('第 1 档站与第 4 档站看一部片子都只扣 20', () async {
      service.yuanbao = 100;
      final first = await service.tryChargeAdultFilm(
        'mjv011',
        seriesId: 'film-a',
        label: '片子A',
      );
      expect(first.status, AdultEntryStatus.paid);
      expect(first.cost, 20);
      expect(first.tier, 0);
      expect(service.yuanbao, 80);
      final fourth = await service.tryChargeAdultFilm(
        'wohs',
        seriesId: 'film-b',
        label: '片子B',
      );
      expect(fourth.status, AdultEntryStatus.paid);
      expect(fourth.cost, 20);
      expect(fourth.tier, 3);
      expect(service.yuanbao, 60);
    });

    test('同一部片子重复进详情页不再重复扣，换一部再扣 20', () async {
      service.yuanbao = 100;
      final first = await service.tryChargeAdultFilm(
        'mjv011',
        seriesId: 'film-a',
        label: '片子A',
      );
      expect(first.status, AdultEntryStatus.paid);
      expect(service.yuanbao, 80);
      final again = await service.tryChargeAdultFilm(
        'mjv011',
        seriesId: 'film-a',
        label: '片子A',
      );
      expect(again.status, AdultEntryStatus.alreadyPaid);
      expect(service.yuanbao, 80);
      final other = await service.tryChargeAdultFilm(
        'mjv011',
        seriesId: 'film-b',
        label: '片子B',
      );
      expect(other.status, AdultEntryStatus.paid);
      expect(service.yuanbao, 60);
    });

    test('余额不足 20 进不了详情页：不扣，报还差多少', () async {
      service.yuanbao = 19;
      final outcome = await service.tryChargeAdultFilm(
        'mjv011',
        seriesId: 'film-a',
        label: '片子A',
      );
      expect(outcome.status, AdultEntryStatus.insufficient);
      expect(outcome.cost, 20);
      expect(outcome.balance, 19);
      expect(outcome.shortfall, 1);
      expect(outcome.allowed, isFalse);
      expect(service.yuanbao, 19);
      expect(service.adultSpendHistory, isEmpty);
    });

    test('余额正好 20 能进，扣完剩 0', () async {
      service.yuanbao = 20;
      final outcome = await service.tryChargeAdultFilm(
        'mjv011',
        seriesId: 'film-a',
        label: '片子A',
      );
      expect(outcome.status, AdultEntryStatus.paid);
      expect(service.yuanbao, 0);
    });

    test('非成人站不扣，放行', () async {
      service.yuanbao = 10;
      final outcome = await service.tryChargeAdultFilm(
        'not_a_real_site_xyz',
        seriesId: 'film-a',
        label: '片子A',
      );
      expect(outcome.status, AdultEntryStatus.free);
      expect(outcome.cost, 0);
      expect(service.yuanbao, 10);
    });

    test('账本记下看片费：余额对得上，最新在前', () async {
      service.yuanbao = 100;
      await service.tryChargeAdultFilm(
        'mjv011',
        seriesId: 'film-a',
        label: '片子A',
      );
      await service.tryChargeAdultFilm(
        'wohs',
        seriesId: 'film-b',
        label: '片子B',
      );
      final history = service.adultSpendHistory;
      expect(history.length, 2);
      expect(history.first.label, '片子B');
      expect(history.first.cost, 20);
      expect(history.first.balanceAfter, 60);
      expect(history.first.source, 'detail');
      expect(history.last.balanceAfter, 80);
    });

    test('账本最多 50 条，超了丢最旧的', () async {
      service.yuanbao = 10000;
      for (var i = 0; i < 51; i++) {
        await service.tryChargeAdultFilm(
          'mjv011',
          seriesId: 'film-$i',
          label: '片子$i',
        );
      }
      final history = service.adultSpendHistory;
      expect(history.length, 50);
      expect(history.first.label, '片子50');
      expect(history.last.label, '片子1');
    });

    test('扣费记录编解码来回一致', () {
      final record = AdultSpendRecord(
        timeMillis: 1700000000000,
        coreId: 'mjv011',
        label: '片子A',
        tier: 0,
        cost: 20,
        balanceAfter: 80,
        source: 'detail',
      );
      final decoded = AdultSpendRecord.decode(record.encode());
      expect(decoded, isNotNull);
      expect(decoded!.coreId, 'mjv011');
      expect(decoded.label, '片子A');
      expect(decoded.cost, 20);
      expect(decoded.balanceAfter, 80);
      expect(decoded.source, 'detail');
    });

    test('resetForTest 清空已扣判断：同一部片子能再扣一次', () async {
      service.yuanbao = 100;
      await service.tryChargeAdultFilm(
        'mjv011',
        seriesId: 'film-a',
        label: '片子A',
      );
      await GameService.instance.resetForTest();
      await service.ensureInitialized();
      service.yuanbao = 100;
      final outcome = await service.tryChargeAdultFilm(
        'mjv011',
        seriesId: 'film-a',
        label: '片子A',
      );
      expect(outcome.status, AdultEntryStatus.paid);
      expect(service.yuanbao, 80);
    });
  });

  group('游戏节点进站免费（境界与塔层够了就能进，不扣元宝）', () {
    test('进站不扣：第 1 档与第 4 档站进站都免费', () async {
      service.yuanbao = 100;
      final first = await service.tryEnterAdultSite('mjv011');
      expect(first.status, AdultEntryStatus.free);
      expect(first.cost, 0);
      expect(first.tier, 0);
      expect(first.allowed, isTrue);
      expect(service.yuanbao, 100);
      final fourth = await service.tryEnterAdultSite('wohs');
      expect(fourth.status, AdultEntryStatus.free);
      expect(fourth.cost, 0);
      expect(fourth.tier, 3);
      expect(service.yuanbao, 100);
    });

    test('节点档位只用来展示：xhamster 仍是节点第 4 档，但不扣费', () async {
      service.yuanbao = 0;
      final outcome = await service.tryEnterAdultSite('xhamster');
      expect(outcome.status, AdultEntryStatus.free);
      expect(outcome.tier, 3);
      expect(outcome.cost, 0);
      expect(outcome.allowed, isTrue);
      expect(service.yuanbao, 0);
    });

    test('同一站反复进站都不扣、不记账', () async {
      service.yuanbao = 100;
      await service.tryEnterAdultSite('mjv011');
      final again = await service.tryEnterAdultSite('mjv011');
      expect(again.status, AdultEntryStatus.free);
      expect(service.yuanbao, 100);
      expect(service.adultSpendHistory, isEmpty);
    });

    test('进站免费、看片另扣：进站不扣，进详情页再扣 20', () async {
      service.yuanbao = 100;
      final entry = await service.tryEnterAdultSite('mjv011');
      expect(entry.status, AdultEntryStatus.free);
      expect(service.yuanbao, 100);
      final film = await service.tryChargeAdultFilm(
        'mjv011',
        seriesId: 'film-a',
        label: '片子A',
      );
      expect(film.status, AdultEntryStatus.paid);
      expect(film.cost, 20);
      expect(service.yuanbao, 80);
    });

    test('spendForAdultView 只看解锁：解锁了放行、不扣，未解锁拦住', () async {
      final node =
          gameSiteNodes.firstWhere((n) => n.coreId == 'xhamster');
      service.yuanbao = 100;
      expect(await service.spendForAdultView(node), isFalse);
      expect(service.yuanbao, 100);
      await CultivationService.instance.addGameXp(node.requiredRealmXp);
      service.towerFloor = node.requiredTowerFloor;
      service.yuanbao = 0;
      expect(await service.spendForAdultView(node), isTrue);
      expect(service.yuanbao, 0);
    });

    test('非成人站进站不扣', () async {
      service.yuanbao = 10;
      final outcome = await service.tryEnterAdultSite('not_a_real_site_xyz');
      expect(outcome.status, AdultEntryStatus.free);
      expect(service.yuanbao, 10);
    });
  });
}
