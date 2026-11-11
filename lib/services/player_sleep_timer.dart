import 'dart:async';

/// 播放页定时停止：对照 hongguoTV `SleepTimer`
///（`kotlin-tv/core/.../PlaybackComfort.kt`）。
///
/// 语义与对照完全一致：纯 Dart 计时、与播放倍速无关；分钟档按单调时钟
/// 到期，集数档在每集播完时扣一集、扣到 0 停；两种档互斥，后设的覆盖
/// 先设的。进程内有效，不落盘——对照的定时器同样只活在当次播放里。
///
/// 驱动方式：宿主（`PlayerPage`）在 5 秒进度心跳里调 [poll]，在每集
/// 播完时调 [episodeEnded]；本类自己不建 [Timer]，不另外占调度资源。
class PlayerSleepTimer {
  PlayerSleepTimer({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  DateTime? _deadline;

  /// 集数档剩余集数：0 = 没设集数档。
  int _episodesLeft = 0;

  bool get active => _deadline != null || _episodesLeft > 0;

  /// 分钟档剩余时长；没设分钟档时为 null。
  Duration? get remaining {
    final deadline = _deadline;
    if (deadline == null) return null;
    final value = deadline.difference(_now());
    return value.isNegative ? Duration.zero : value;
  }

  /// 集数档剩余集数（分钟档时为 0）。
  int get episodesLeft => _episodesLeft;

  /// 到期后是否在播完当前集就停：只看集数档剩 1 集的情况，与对照
  /// `MainActivity` 里「`episodesLeft == 1` 取消预热/预取」同门。
  bool get stopsAfterCurrentEpisode => _episodesLeft == 1;

  /// 对照 `SleepTimer.label()`：分钟档「N 分钟后」，集数档
  /// 「再播完 N 集」，都没设时「关闭」。
  String get label {
    final value = remaining;
    if (value != null) {
      final minutes = (value.inSeconds / 60).ceil();
      return '$minutes 分钟后';
    }
    if (_episodesLeft > 0) return '再播完 $_episodesLeft 集';
    return '关闭';
  }

  void cancel() {
    _deadline = null;
    _episodesLeft = 0;
  }

  /// 分钟档：对照 `afterMinutes`，只接受 1–180 分钟。
  void afterMinutes(int minutes) {
    if (minutes < 1 || minutes > 180) {
      throw ArgumentError.value(minutes, 'minutes', '只接受 1–180 分钟');
    }
    cancel();
    _deadline = _now().add(Duration(minutes: minutes));
  }

  /// 集数档：对照 `afterEpisodes`，只接受 1–10 集。
  void afterEpisodes(int count) {
    if (count < 1 || count > 10) {
      throw ArgumentError.value(count, 'count', '只接受 1–10 集');
    }
    cancel();
    _episodesLeft = count;
  }

  /// 分钟档到期返回 true，到期即清掉（只触发一次）。
  bool poll() {
    final deadline = _deadline;
    if (deadline == null || _now().isBefore(deadline)) return false;
    cancel();
    return true;
  }

  /// 每集播完时调一次：分钟档到期同样返回 true；集数档扣一集，
  /// 扣到 0 返回 true；都没到返回 false。
  bool episodeEnded() {
    if (poll()) return true;
    if (_episodesLeft <= 0) return false;
    _episodesLeft--;
    return _episodesLeft == 0;
  }
}

/// 定时停止弹层里的档位。对照的对话框是：取消 / 15 / 30 / 60 / 90 分钟 /
/// 再播 1 / 3 / 5 集（`MainActivity` 4361–4363 行）；本地按任务口径
/// 另加「播完本集」（= 再播 1 集）。
enum PlayerSleepChoice {
  off('关闭定时'),
  minutes15('15 分钟后停止', minutes: 15),
  minutes30('30 分钟后停止', minutes: 30),
  minutes60('60 分钟后停止', minutes: 60),
  minutes90('90 分钟后停止', minutes: 90),
  endOfEpisode('播完本集停止', episodes: 1),
  after3Episodes('再播完 3 集停止', episodes: 3);

  const PlayerSleepChoice(this.label, {this.minutes, this.episodes});

  final String label;

  /// 分钟档的分钟数；集数档/关闭时为 null。
  final int? minutes;

  /// 集数档的集数；分钟档/关闭时为 null。
  final int? episodes;

  /// 把档位落到一个计时器上。
  void applyTo(PlayerSleepTimer timer) {
    if (this == off) {
      timer.cancel();
      return;
    }
    if (minutes case final int value) {
      timer.afterMinutes(value);
      return;
    }
    if (episodes case final int value) {
      timer.afterEpisodes(value);
    }
  }

  /// 从计时器当前状态反推落在哪个档位；没定时返回 [off]，
  /// 非常规值（比如 45 分钟）按最接近的一档显示，不造新档。
  static PlayerSleepChoice currentOf(PlayerSleepTimer timer) {
    if (!timer.active) return off;
    final remaining = timer.remaining;
    if (remaining != null) {
      final minutes = (remaining.inSeconds / 60).ceil();
      if (minutes <= 15) return minutes15;
      if (minutes <= 30) return minutes30;
      if (minutes <= 60) return minutes60;
      return minutes90;
    }
    return switch (timer.episodesLeft) {
      1 => endOfEpisode,
      _ => after3Episodes,
    };
  }
}
