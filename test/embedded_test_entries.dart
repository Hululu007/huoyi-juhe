import 'package:fqapp/services/builtin_imported_sites.dart';
import 'package:fqapp/services/jar_bridge.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:fqapp/services/zakatv_builtin.dart';

/// 内嵌站测试条目：按生产登记原样搭（种子 `seed_<id>`、jar
/// `jar:<jarId>:<key>`、builtin=true、contentType 照登记表），
/// 供分档测试直接传给 visibleVideoZoneSites / visibleFilmZoneSites，
/// 不走 SharedPreferences 与 asset 拷贝。
///
/// jar 244 行（zakatvBuiltinSites 244 条里 243 条视频/混合 + YouTube 1 条；
/// 听书 go_tingshu 是 audio，不进视频区）+ 种子 108 条。
List<SourceEntry> embeddedTestEntries() {
  final entries = <SourceEntry>[];
  for (final site in zakatvBuiltinSites) {
    entries.add(
      SourceEntry(
        id: JarSiteSpec.siteIdFor(zakatvJarId, site.key),
        name: site.name,
        kind: SourceKind.jarImport,
        address: zakatvJarAsset,
        extra: {
          'configId': zakatvJarId,
          'className': site.className,
          'contentType': site.contentTypeKey,
          'builtin': true,
        },
      ),
    );
  }
  entries.add(
    SourceEntry(
      id: JarSiteSpec.siteIdFor(youtubeJarId, youtubeBuiltinSite.key),
      name: youtubeBuiltinSite.name,
      kind: SourceKind.jarImport,
      address: youtubeJarAsset,
      extra: {
        'configId': youtubeJarId,
        'className': youtubeBuiltinSite.className,
        'contentType': youtubeBuiltinSite.contentTypeKey,
        'builtin': true,
      },
    ),
  );
  for (final seed in builtinImportedSeeds) {
    entries.add(
      SourceEntry(
        id: 'seed_${seed.seedId}',
        name: seed.name,
        kind: seed.kind,
        address: seed.fileName,
        extra: {
          'contentType': 'video',
          'builtin': true,
          'seedId': seed.seedId,
        },
      ),
    );
  }
  return entries;
}
