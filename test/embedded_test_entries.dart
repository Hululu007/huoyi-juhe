import 'dart:convert';
import 'dart:io';

import 'package:fqapp/services/source_registry.dart';

/// 内嵌站测试条目（站点库批 2026-11-27 适配）：生产登记已移出包、
/// 进站点库，本helper 改按随包名单 assets/site_library/roster.json
/// 搭条目——形态与 SourceRegistry.buildSqlSiteEntries 的产出对齐
/// （id=siteId、extra 带 contentType/sqlManaged/sqlCanon），供分档
/// 测试直接传给 visibleVideoZoneSites / visibleFilmZoneSites。
/// nativeGate 与直播行不在登记表条目形态里（前者是 drama 裸行、
/// 后者走 LiveSources），与旧 helper 的集合口径一致地不纳入。
List<SourceEntry> embeddedTestEntries() {
  final raw = File('assets/site_library/roster.json').readAsStringSync();
  final stations =
      (jsonDecode(raw) as Map<String, dynamic>)['stations'] as List<dynamic>;
  final entries = <SourceEntry>[];
  for (final row in stations) {
    final s = row as Map<String, dynamic>;
    final kindName = s['kind'] as String;
    if (kindName == 'nativeGate' ||
        kindName == 'liveM3u' ||
        kindName == 'livePlatform') {
      continue;
    }
    final kind = switch (kindName) {
      'pyImport' => SourceKind.pyImport,
      'legadoImport' => SourceKind.legadoImport,
      'jarImport' => SourceKind.jarImport,
      _ => SourceKind.pyImport,
    };
    entries.add(
      SourceEntry(
        id: s['siteId'] as String,
        name: s['name'] as String,
        kind: kind,
        extra: {
          'contentType': s['zone'] as String,
          'sqlManaged': true,
          'sqlCanon': s['id'] as String,
        },
      ),
    );
  }
  return entries;
}
