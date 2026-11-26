import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/builtin_imported_sites.dart';
import 'package:fqapp/services/legado_content.dart';
import 'package:fqapp/services/source_registry.dart';

/// 魔蚁 Legado 书源移植批（2026-11-26）种子结构验证：
/// ① legado_ 前缀种子全是 legadoImport、全带分区分型、无音乐；
/// ② 每份资产真在包里、能被修仙版引擎解析出名与地址；
/// ③ 分区计数与移植定级表一致（见工作目录 classified.json）；
/// ④ 未验通的带 verifyNote 标记，验通的不带。
const kExpectedLegadoSeedCount = 101;
const kExpectedNovelCount = 86;
const kExpectedComicCount = 5;
const kExpectedAudioCount = 1;
const kExpectedVideoCount = 9;
const kExpectedUnverifiedCount = 101;
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final legadoSeeds = builtinImportedSeeds
      .where((seed) => seed.seedId.startsWith('legado_'))
      .toList();

  test('legado 书源种子：总数与分区计数', () {
    expect(legadoSeeds.length, kExpectedLegadoSeedCount);
    final byZone = <String, int>{};
    for (final seed in legadoSeeds) {
      byZone[seed.contentTypeKey ?? ''] =
          (byZone[seed.contentTypeKey ?? ''] ?? 0) + 1;
    }
    expect(byZone['novel'] ?? 0, kExpectedNovelCount);
    expect(byZone['comic'] ?? 0, kExpectedComicCount);
    expect(byZone['audio'] ?? 0, kExpectedAudioCount);
    expect(byZone['video'] ?? 0, kExpectedVideoCount);
  });

  test('legado 书源种子：类型与标记规矩', () {
    for (final seed in legadoSeeds) {
      expect(seed.kind, SourceKind.legadoImport, reason: seed.seedId);
      expect(seed.contentTypeKey, isNotNull, reason: seed.seedId);
      expect(seed.contentTypeKey, isNot('music'), reason: seed.seedId);
      expect(seed.fileName, '${seed.seedId}.json', reason: seed.seedId);
      if (seed.verifyNote != null) {
        expect(seed.verifyNote, isNotEmpty, reason: seed.seedId);
      }
    }
    final noted = legadoSeeds.where((s) => s.verifyNote != null).length;
    expect(noted, kExpectedUnverifiedCount);
  });

  test('legado 书源种子：资产可加载且引擎可解析', () async {
    for (final seed in legadoSeeds) {
      final text = await rootBundle.loadString(seed.asset);
      final decoded = jsonDecode(text);
      final map = decoded is List ? decoded.first : decoded;
      final source = LegadoSource(map as Map<String, dynamic>);
      expect(source.name, isNotEmpty, reason: seed.seedId);
      expect(source.url, isNotEmpty, reason: seed.seedId);
      expect(source.name, seed.name, reason: seed.seedId);
    }
  });
}
