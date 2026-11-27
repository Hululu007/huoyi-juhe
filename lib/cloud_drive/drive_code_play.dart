/// 竞速第三池：按番号在他 115 网盘里找已离线/已有的成品
/// 文件，找到就取直链作一条竞速候选（2026-11-27 用户令：
/// 播放竞速从在线＋数据库两池扩成网盘＋在线＋数据库三池）。
///
/// 只做「找片＋取链」，不碰界面与竞速编排：登录判据、搜索
/// 与取链函数都由调用方注入（生产走引擎 searchPan115Files
/// / pan115DirectLink，测试注入假件）。任何一步失败/超时
/// 都回 null（弃池），竞速照旧走其余池，绝不拖慢起播。
library;

import 'cloud_115_offline.dart';
import 'cloud_drive_types.dart';
import 'cloud_providers.dart';

/// 网盘命中：可直接喂验活/播放的直链 + 请求头。
typedef DrivePlayHit = ({String url, Map<String, String> headers});

/// 按番号在 115 里找可播文件并取直链。
class DriveCodePlayFinder {
  DriveCodePlayFinder({
    required this.isLoggedIn,
    required this.search,
    required this.directLink,
    this.searchTimeout = const Duration(seconds: 12),
  });

  /// 115 是否已登入（与引擎 pan115LoggedIn 同口径）。
  final Future<bool> Function() isLoggedIn;

  /// 按关键词全盘搜文件（生产走引擎根目录搜索）。
  final Future<List<CloudDriveFile>> Function(String keyword) search;

  /// 文件取直链（生产走引擎 pan115DirectLink，headers 已按
  /// 取链口径组装好）。
  final Future<CloudDirectLink> Function(CloudDriveFile file) directLink;

  /// 搜索超时上限：115 搜索慢/挂时到点弃池，竞速不等它。
  /// 详情页线路在开页时就后台开搜（与其它线路同口径），
  /// 点播时多半已出结果；12 秒是给弱网留的上限。
  final Duration searchTimeout;

  /// 按番号找片：登入才找；文件名匹配走 [pan115FileForCode]
  /// （提码精确命中优先、提不出码退回文件名归一包含），覆
  /// 盖离线任务的常见命名（番号大小写/连字符有无/方括号前
  /// 缀/扩展名变体都在提码与归一规则里）。找不到/未登入/
  /// 超时/任何异常 → null（弃池）。慢环节只有搜索一步，
  /// 已由 [searchTimeout] 封顶；登入判据与取链都是引擎内
  /// 单次调用，不另设总超时（避免无谓的悬挂定时器）。
  Future<DrivePlayHit?> find(String code) async {
    if (code.trim().isEmpty) return null;
    try {
      if (!await isLoggedIn()) return null;
    } catch (_) {
      return null;
    }
    final List<CloudDriveFile> files;
    try {
      files = await search(code).timeout(searchTimeout);
    } catch (_) {
      return null;
    }
    final file = pan115FileForCode(files, code);
    if (file == null) return null;
    try {
      final link = await directLink(file);
      if (link.url.isEmpty) return null;
      return (url: link.url, headers: link.headers);
    } catch (_) {
      return null;
    }
  }
}
