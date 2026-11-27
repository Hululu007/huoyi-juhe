/// 网盘当站（修仙版）：登录后的网盘作为站进影视区站表。
///
/// 只有登录后的网盘才产出条目（未登录的站点了也是死入口，登录
/// 走登入中心/网盘页）。条目只存内存：经 [SourceRegistry] 的
/// cloudDriveEntries 内存列表挂进站体系，不落盘、不进 _custom
/// 持久化（SourceEntry.fromJson 的往返与它们无关，天然避开）。
/// 启动加载后与每次登录/退出后调用 [CloudDriveStations.refresh]。
library;

import '../services/source_registry.dart';
import 'cloud_credential_store.dart';
import 'cloud_drive_factory.dart';
import 'cloud_providers.dart';

class CloudDriveStations {
  CloudDriveStations._();

  /// 按凭证存储现算条目（纯函数，单测直接用假存储验）。
  static List<SourceEntry> entriesFor(CloudCredentialStore store) {
    final loggedIn = store.loggedInProviderIds(cloudDriveDisplayNames.keys);
    return [
      for (final id in loggedIn)
        SourceEntry(
          id: 'cloud:$id',
          name: cloudDriveDisplayNames[id] ?? id,
          kind: SourceKind.cloudDrive,
          extra: const {'contentType': 'video'},
        ),
    ];
  }

  /// 当前内存条目（同步读口，页面/站表汇合点用）。
  static List<SourceEntry> get entries =>
      SourceRegistry.instance.cloudDriveEntries;

  /// 按当前登录状态刷新内存注册表。凭证存储可注入（单测用）；
  /// 不传走 [CloudDriveFactory] 的单例存储。整体 fail-soft：
  /// 存储读不到时按未登录处理（清空条目），不打断启动加载。
  static Future<void> refresh([CloudCredentialStore? store]) async {
    try {
      final resolved = store ?? await CloudDriveFactory.credentialStore();
      SourceRegistry.instance.setCloudDriveEntries(entriesFor(resolved));
    } catch (_) {
      SourceRegistry.instance.setCloudDriveEntries(const []);
    }
  }
}
