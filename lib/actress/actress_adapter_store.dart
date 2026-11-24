// 适配层：女优库模块在魔蚁侧依赖的 LocalStore（原 lib/local_store.dart
// 的子集）。修仙版没有 LocalStore，也没有“身份/ profile”概念。
//
// 女优库实际只用这四个成员（其余如收藏/进度/主题全是魔蚁整站用的，
// 未搬）：
// - visibleSources：可见站源表；
// - siteVisible(id)：该站当前是否可见（未被用户关掉）；
// - allowsSource(id)：该站当前是否允许用（与 siteVisible 同口径）；
// - profileEpoch：身份版本号（切身份时递增，播放链用它中途停链）。
//
// 口径映射（修仙版等价物）：
// - 站源表 ← SourceRegistry.visibleDramaSites（内置 + 已启用自定义，
//   影视/综合类型；短剧站按 isShortDramaSite 标 drama 分区，其余标
//   video 分区，与 actressSearchSiteIds 的 isVideoSection 过滤同口径）；
// - 可见 ← 内置站 isBuiltinEnabled / 自定义站 entry.enabled /
//   测试注入的 SourceSite.importedSites；注册表里没有的 id
//   （如 whos / nvku / jar:…、来源不明的候选站）一律不可见——
//   魔蚁 profile 口径：未知站源不允许（actress_test '不允许的
//   站源直接跳过不预检'）；否则跨站链会把来源不明的候选推给播放
//   器，而仓库层根本解不了它（clientFor 回空）。站点合并完成、
//   站进了注册表后自动可见，不用改这里；
// - 身份：修仙版无多身份，profileEpoch 恒为 0，只在 refresh() 时
//   递增一次（站表变了，旧播放链停掉重排）。

import 'package:flutter/foundation.dart';

import '../services/cultivation.dart' show adultSiteIdForUnifiedId;
import '../services/drama_sites.dart' show dramaSites, isShortDramaSite;
import '../services/source_registry.dart'
    show ContentType, SourceRegistry;
import 'actress_adapter_models.dart' show SourceSite;

class LocalStore extends ChangeNotifier {
  LocalStore();

  /// 应用内共享的一份（入口 VideoPage 只传这一份）。
  static final LocalStore instance = LocalStore._shared();

  LocalStore._shared();

  var _epoch = 0;

  int get profileEpoch => _epoch;

  /// 可见站源：注册表当前可见的影视/综合站。短剧站标 drama 分区。
  /// 另含 SourceSite.importedSites（测试注入的合成站）。
  List<SourceSite> get visibleSources {
    final sites = SourceRegistry.instance.visibleDramaSites(
      types: const {ContentType.video, ContentType.mixed},
    );
    final ids = <String>{};
    return [
      for (final site in sites)
        if (ids.add(site.id))
          SourceSite(
            site.id,
            site.name,
            '',
            section: isShortDramaSite(
                  adultSiteIdForUnifiedId(site.id),
                  site.name,
                )
                ? SourceSite.sectionDrama
                : SourceSite.sectionVideo,
          ),
      for (final site in SourceSite.importedSites.values)
        if (ids.add(site.id)) site,
    ];
  }

  /// 该站当前是否可见（未被用户关掉）。
  /// 只有三类算可见：测试注入站、已启用自定义站、在内置表里且未被
  /// 关掉的内置站。注册表里没有的 id 一律不可见（见文件头口径）。
  bool siteVisible(String source) {
    if (SourceSite.importedSites.containsKey(source)) return true;
    final entry = SourceRegistry.instance.customById(source);
    if (entry != null) return entry.enabled;
    return dramaSites.any((site) => site.id == source) &&
        SourceRegistry.instance.isBuiltinEnabled(source);
  }

  /// 该站当前是否允许用：修仙版无多身份/会员档，与可见同口径。
  bool allowsSource(String source) => siteVisible(source);

  /// 站表变了（导入/删除站源后）调一次：epoch +1 让旧播放链停掉，
  /// 并通知正在监听的女优库页面重读站表。
  void refresh() {
    _epoch++;
    notifyListeners();
  }
}
