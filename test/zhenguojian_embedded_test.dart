// 真果鉴内置批（2026-11-26）：6 个全链实测过的苹果CMS 站以 py 种子
// 进短剧区（成人站带 🔞 前缀并进成人分档表末尾）；听读新开「音乐」
// 一级分型（ContentType.music）只落结构、本批无音乐源。
//
// 站点库批（2026-11-27）适配：py 种子表与 assets/builtin_sites 已移出
// 包、进「凡人修仙站点.sql」站点库；本文件里原先查种子表与盘上 .py
// 的断言改查随包名单 assets/site_library/roster.json（站名/分型/在册），
// .py 全文与站点库内容校验归生成器侧（verify_bundle.py 已复验）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/source_registry.dart';

void main() {
  const newStations = <String, String>{
    'youguo': '🔞柚果',
    'manman': '🔞漫果',
    'luguo': '🔞露果',
    'liuguo': '🔞榴果',
    'liguo': '🔞荔果',
    'ningguo': '🔞柠果',
  };

  List<dynamic> rosterStations() {
    final raw = File('assets/site_library/roster.json').readAsStringSync();
    return (jsonDecode(raw) as Map<String, dynamic>)['stations'] as List;
  }

  test('真果鉴 6 站在站点库名单里齐全：py 型、🔞 名', () {
    final stations = rosterStations();
    for (final e in newStations.entries) {
      final rows = stations
          .where((s) => (s as Map<String, dynamic>)['id'] == e.key)
          .toList();
      expect(rows.length, 1, reason: e.key);
      final row = rows.single as Map<String, dynamic>;
      expect(row['kind'], 'pyImport', reason: e.key);
      expect(row['name'], e.value, reason: e.key);
      expect(row['adult'], isTrue, reason: e.key);
    }
  });

  test('真果鉴 6 站归短剧区且在 drama 裸表里', () {
    for (final e in newStations.entries) {
      expect(shortDramaSiteIds.contains(e.key), isTrue, reason: e.key);
      final rows = dramaSites.where((s) => s.id == e.key).toList();
      expect(rows.length, 1, reason: e.key);
      expect(rows.single.name, e.value, reason: e.key);
    }
  });

  test('真果鉴 6 站按登记顺序追加在成人分档表末尾', () {
    final tail = adultVideoSiteOrder
        .sublist(adultVideoSiteOrder.length - newStations.length);
    expect(tail, newStations.keys.toList());
    for (final id in newStations.keys) {
      expect(adultTierForSiteId(id, adultVideoSiteOrder), isNotNull,
          reason: id);
    }
  });

  test('音乐分型：key/label 往返、归书源侧', () {
    expect(ContentType.music.key, 'music');
    expect(ContentType.music.label, '音乐');
    expect(ContentTypeLabel.fromKey('music'), ContentType.music);
    const entry = SourceEntry(
      id: 'seed_fanqie_music_probe',
      name: '音乐探针',
      kind: SourceKind.pyImport,
      extra: {'contentType': 'music'},
    );
    expect(entry.contentType, ContentType.music);
    expect(isBookSourceEntry(entry), isTrue);
  });

  test('本批无音乐站：名单里没有 music 分区条目', () {
    for (final s in rosterStations()) {
      final row = s as Map<String, dynamic>;
      expect(row['zone'], isNot('music'), reason: '${row['id']}');
    }
  });
}
