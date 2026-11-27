import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 魔蚁 Legado 书源移植批（2026-11-26）种子结构验证。
///
/// 站点库批（2026-11-27）适配：Legado 种子已移出包、进站点库，
/// 本文件改查随包名单 assets/site_library/roster.json：legadoImport
/// 共 102 行（旧种子表里 101 条 legado_ 前缀 + dabaitu_video 1 条），
/// 分区计数与移植定级表一致。逐份 JSON 的引擎解析验证随内容搬家
/// 归生成器侧（verify_bundle.py 对站点库逐行哈希与内容复验，
/// 见工作目录 ACCOUNT.md）；verifyNote 标记在库内 stations 表，
/// 名单不带此字段，本文件不再断言。
const kExpectedLegadoCount = 102;
const kExpectedNovelCount = 86;
const kExpectedComicCount = 5;
const kExpectedAudioCount = 1;
const kExpectedVideoCount = 10;

void main() {
  final raw = File('assets/site_library/roster.json').readAsStringSync();
  final stations =
      (jsonDecode(raw) as Map<String, dynamic>)['stations'] as List;
  final legadoRows = stations
      .where((s) => (s as Map<String, dynamic>)['kind'] == 'legadoImport')
      .toList();

  test('legado 书源（站点库名单）：总数与分区计数', () {
    expect(legadoRows.length, kExpectedLegadoCount);
    final byZone = <String, int>{};
    for (final row in legadoRows) {
      final zone = (row as Map<String, dynamic>)['zone'] as String;
      byZone[zone] = (byZone[zone] ?? 0) + 1;
    }
    expect(byZone['novel'] ?? 0, kExpectedNovelCount);
    expect(byZone['comic'] ?? 0, kExpectedComicCount);
    expect(byZone['audio'] ?? 0, kExpectedAudioCount);
    expect(byZone['video'] ?? 0, kExpectedVideoCount);
  });

  test('legado 书源（站点库名单）：类型与标记规矩', () {
    for (final row in legadoRows) {
      final s = row as Map<String, dynamic>;
      expect(s['zone'], isNotNull, reason: '${s['id']}');
      expect(s['zone'], isNot('music'), reason: '${s['id']}');
      expect((s['name'] as String), isNotEmpty, reason: '${s['id']}');
      expect(s['siteId'], startsWith('seed_'), reason: '${s['id']}');
    }
  });
}
