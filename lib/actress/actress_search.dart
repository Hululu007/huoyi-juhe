import 'actress_adapter_store.dart';

/// 全站搜索用的站源 id：可见视频站（与跨站探活同一口径，去网盘站）。
/// 原同文件的 ActressEnrichment（双键合流补全，搜到写库）已随
/// 2026-11-26 同步/写入整套删除；本函数是读侧口径，播放补链在用。
List<String> actressSearchSiteIds(LocalStore store) => [
  for (final site in store.visibleSources)
    if (site.isVideoSection &&
        !site.id.startsWith('cloud:') &&
        store.siteVisible(site.id))
      site.id,
];
