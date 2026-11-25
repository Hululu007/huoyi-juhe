// 真果鉴内置批（2026-11-26）：6 个全链实测过的苹果CMS 站以 py 种子
// 进短剧区（成人站带 🔞 前缀并进成人分档表末尾）；听读新开「音乐」
// 一级分型（ContentType.music）只落结构、本批无音乐源。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/builtin_imported_sites.dart';
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

  test('真果鉴 6 站种子齐全：py 导入型、🔞 名、种子文件在盘上', () {
    for (final e in newStations.entries) {
      final seed = builtinImportedSeeds
          .where((s) => s.seedId == e.key)
          .toList();
      expect(seed.length, 1, reason: e.key);
      expect(seed.single.kind, SourceKind.pyImport, reason: e.key);
      expect(seed.single.name, e.value, reason: e.key);
      expect(seed.single.asset, 'assets/builtin_sites/${e.key}.py');
      expect(File(seed.single.asset).existsSync(), isTrue, reason: e.key);
      // 种子 py 里配置写死（登记时 ext 为空）：含站点原名与主机烘焙。
      final body = File(seed.single.asset).readAsStringSync();
      expect(body.contains('SITE = {'), isTrue, reason: e.key);
      expect(body.contains('class Spider'), isTrue, reason: e.key);
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

  test('本批无音乐种子：音乐区只落结构不塞假源', () {
    for (final seed in builtinImportedSeeds) {
      expect(seed.contentTypeKey, isNot('music'), reason: seed.seedId);
    }
  });
}
