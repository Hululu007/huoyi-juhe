/// 网盘运行时装配（修仙版）：凭证存储与引擎的单例工厂。
///
/// 装配方式与魔蚁 core_bridge 的 `_createCloudDriveEngine` 等价：
/// 同一份 SharedPreferences 造 [CloudCredentialStore]，`http.Client`
/// 直连，疑似广告开关读 [CloudDriveSettings] 的内存缓存，目录页
/// 落盘缓存目录放应用支持目录下的 `cloud_catalog_cache`。
/// 引擎懒建单例：全应用共用一个引擎实例，它的目录/条目缓存
/// 才能在「目录 → 详情 → 播放」之间接得上（详情按 id 重建靠它）。
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_credential_store.dart';
import 'cloud_drive_client.dart';
import 'cloud_drive_engine.dart';
import 'cloud_drive_settings.dart';

class CloudDriveFactory {
  CloudDriveFactory._();

  static Future<CloudCredentialStore>? _storeFuture;
  static Future<CloudDriveEngine>? _engineFuture;

  /// 凭证存储单例（登录中心、站点注册、引擎共用同一份）。
  static Future<CloudCredentialStore> credentialStore() {
    return _storeFuture ??= () async {
      final prefs = await SharedPreferences.getInstance();
      return CloudCredentialStore(prefs);
    }();
  }

  /// rooted 内容客户端（片库网格点文件夹卡下钻用）：钉死在
  /// [rootFolderId] 上的 [CloudDriveContentClient]，网关仍走
  /// 引擎单例，与普通客户端共用同一份目录/条目缓存。
  static CloudDriveContentClient rootedClient(
    String providerId,
    String rootFolderId, {
    String? rootFolderName,
  }) {
    return CloudDriveContentClient(
      providerId: providerId,
      rootFolderId: rootFolderId,
      rootFolderName: rootFolderName,
    );
  }

  /// 引擎单例（懒建，第一次打开网盘站/网盘页时才建）。
  static Future<CloudDriveEngine> engine() {
    return _engineFuture ??= () async {
      final store = await credentialStore();
      await CloudDriveSettings.load();
      return CloudDriveEngine(
        credentialStore: store,
        httpClient: http.Client(),
        showSuspectedAds: () => CloudDriveSettings.showSuspectedAdVideosNow,
        catalogCacheDir: () async {
          final support = await getApplicationSupportDirectory();
          return Directory('${support.path}/cloud_catalog_cache');
        },
      );
    }();
  }
}
