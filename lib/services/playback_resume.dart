/// 播放恢复：本地续播 + 云端续播的归并。
library;

import '../models/media_item.dart';
import 'hongguo_account.dart';
import 'player_history.dart';

/// 本地续播（`PlayerHistory`，按剧/集/秒数存）早已接好：起播位置
/// 在 `create` 之前算好、原生在 prepare 前应用；5 秒心跳 + 暂停/
/// 切集/播完/退后台/被杀广播都会落盘。
///
/// 云端续播接登录组的现成接口，不另造账号同步：
/// - 读：`HongguoAccountService.resumeForSeries` /
///   `cachedResumeForSeries`（缓存，登录/恢复时由登录组 `refresh()`
///   拉过，不发请求）；
/// - 写：`HongguoAccountService.reportProgress`（同一集 30 秒内
///   只传一次，先写账号箱再后台上传，未登录静默丢弃）；
/// - 合并：`mergeCloudProgress`（更新时间新者赢，时间相同取本机）。
///
/// 本文件是纯函数层：把「本地记录 + 云端记录 + 当前集表」算成一个
/// 起播点，播放页只负责在入页时取一次、按点起播。

/// 一个算好的起播点。
class PlaybackResumePoint {
  const PlaybackResumePoint({
    required this.episodeIndex,
    required this.positionMs,
    required this.durationMs,
    required this.fromCloud,
  });

  /// 0 起的集下标。
  final int episodeIndex;

  /// 起播位置（毫秒）；0 = 从头播。
  final int positionMs;

  /// 该集总时长（毫秒）；0 = 未知。
  final int durationMs;

  /// true = 该点来自云端记录，false = 来自本机记录。
  final bool fromCloud;

  /// 已看完（剩不到 5 秒算看完）：从该集开头播，不自动跳下一集。
  bool get finished => durationMs > 0 && durationMs - positionMs <= 5000;
}

class PlaybackResume {
  PlaybackResume._();

  /// 把本机历史记录转成与云端同形的进度（供合并用）。
  ///
  /// `updatedAtMs` 取记录的 `time` 字段；没有时间戳时当 0（云端
  /// 只要有时间就赢——本机这条本来就没法证明它更新）。
  static HongguoCloudProgress? localProgress({
    required Map<String, dynamic>? saved,
    required String seriesId,
    required List<Chapter> episodes,
  }) {
    if (saved == null || episodes.isEmpty) return null;
    final index = resumeEpisodeIndex(saved, episodes);
    if (index == null) return null;
    final episodeId = episodes[index].itemId;
    if (episodeId.isEmpty) return null;
    final position = saved['position'];
    final duration = saved['duration'];
    final positionMs = position is num
        ? (position.toDouble() * 1000).round()
        : 0;
    final durationMs = duration is num
        ? (duration.toDouble() * 1000).round()
        : 0;
    if (positionMs <= 0) return null;
    final time = saved['time'];
    return HongguoCloudProgress(
      seriesId: seriesId,
      episodeId: episodeId,
      episodeIndex: index,
      positionMs: positionMs,
      durationMs: durationMs,
      updatedAtMs: time is num ? time.toInt() : 0,
    );
  }

  /// 本机 + 云端算出入页起播点；两边都没有返回 null（从头播）。
  ///
  /// - 赢的一方先按集 id 在当前集表里定位，找不到 id 再按下标；
  ///   id 与下标都对不上（集表变了）时该方作废，退回另一方；
  /// - 位置超过总时长（或已看完）时从该集开头播，不自动跳集；
  /// - 显式入口（调用方传的 `startPosition`）优先于本函数，
  ///   调用方不要把显式位置再喂进来。
  static PlaybackResumePoint? resolve({
    required Map<String, dynamic>? saved,
    required HongguoCloudProgress? cloud,
    required String seriesId,
    required List<Chapter> episodes,
  }) {
    if (episodes.isEmpty) return null;
    final local = localProgress(
      saved: saved,
      seriesId: seriesId,
      episodes: episodes,
    );
    final winner = mergeCloudProgress(local: local, cloud: cloud);
    if (winner == null) return null;
    final fromCloud = identical(winner, cloud);
    final index = _locateEpisode(winner, episodes);
    if (index == null) {
      // 赢的一方对不上当前集表：退回另一方。
      final fallback = fromCloud ? local : cloud;
      if (fallback == null || identical(fallback, winner)) return null;
      final fallbackIndex = _locateEpisode(fallback, episodes);
      if (fallbackIndex == null) return null;
      return _point(fallback, fallbackIndex, fromCloud: !fromCloud);
    }
    return _point(winner, index, fromCloud: fromCloud);
  }

  static int? _locateEpisode(
    HongguoCloudProgress progress,
    List<Chapter> episodes,
  ) {
    if (progress.episodeId.isNotEmpty) {
      final byId = episodes.indexWhere(
        (episode) => episode.itemId == progress.episodeId,
      );
      if (byId >= 0) return byId;
    }
    if (progress.episodeIndex >= 0 &&
        progress.episodeIndex < episodes.length) {
      return progress.episodeIndex;
    }
    return null;
  }

  static PlaybackResumePoint _point(
    HongguoCloudProgress progress,
    int index, {
    required bool fromCloud,
  }) {
    var positionMs = progress.positionMs;
    if (positionMs < 0) positionMs = 0;
    if (progress.durationMs > 0 && positionMs >= progress.durationMs) {
      positionMs = 0;
    }
    // 已看完（剩不到 5 秒）：从该集开头播，不自动跳下一集。
    if (progress.finished) positionMs = 0;
    return PlaybackResumePoint(
      episodeIndex: index,
      positionMs: positionMs,
      durationMs: progress.durationMs,
      fromCloud: fromCloud,
    );
  }
}
