/// 解码兼容策略：能力探测 + 失败回退链 + 手动档位。
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'episode_source_cache.dart';

/// 对照 hongguoTV 的三件套（只取思路，未拷对方代码）：
/// - `CodecCapabilities`：静态能力探测，声称支持却解不出来的
///   记下来（`DecoderLessons`），下次不再信它；
/// - `PlaybackRenderers`：解码器回退（ExoPlayer `setEnableDecoderFallback`）；
/// - `PlaybackStallGuard`：有缓冲却不出帧的静默卡死，超时后触发恢复。
///
/// 本仓库的落点（Dart/service 层，不动原生渲染器）：
/// - 手动档位已有：设置页「视频解码器」（自动/硬解/软解，
///   `DecoderPreferenceCache`，新起的播放器生效）；
/// - 失败回退已有半截：起播失败先静默重试一次（换新地址），第二次
///   降一档清晰度（`fallbackVariant`）；
/// - 本文件补缺的两块：①学到的失败档位跨启动记忆（下次起播直接
///   跳过坏档位，不再拿它撞一次墙）；②静默卡死检测（播着播着
///   位置不动、又不在缓冲，20 秒后触发一次降档重建）。
/// 原生渲染器大改（换 MPV/软解渲染链）不在本次范围。

/// 学到的解码失败：设备声称支持、实际解不出来的编解码组合。
///
/// 键是「编解码 + 尺寸」，竖屏 1080x1920 失败绝不连坐横屏
/// 1920x1080（对照 `DecoderLessons.kt`）。尺寸缺失时记一条
/// 不带尺寸的 verdict，覆盖该编解码的全部尺寸。
class DecoderLessons {
  DecoderLessons([Set<String>? initial]) : _failed = Set.of(initial ?? const {});

  final Set<String> _failed;

  /// 键：`codec|宽x高`；尺寸缺失时只有 codec。
  static String? key(String codec, int? width, int? height) {
    final normalized = codec.trim().toLowerCase();
    if (normalized.isEmpty) return null;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return normalized;
    }
    return '$normalized|$width|$height';
  }

  /// 记住一次失败，返回记下的键（codec 为空时返回 null）。
  String? remember(String codec, int? width, int? height) {
    final exact = key(codec, width, height);
    if (exact == null) return null;
    _failed.add(exact);
    return exact;
  }

  /// 该组合是否学到过失败。不带尺寸的 verdict 覆盖全部尺寸。
  bool fails(String codec, int? width, int? height) {
    final normalized = codec.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    if (width != null &&
        height != null &&
        width > 0 &&
        height > 0 &&
        _failed.contains('$normalized|$width|$height')) {
      return true;
    }
    return _failed.contains(normalized);
  }

  Set<String> keys() => Set.of(_failed);

  void restore(Set<String> keys) {
    _failed
      ..clear()
      ..addAll(keys);
  }

  void reset() => _failed.clear();

  int get size => _failed.length;
}

/// `DecoderLessons` 的落盘：SharedPreferences 里一组字符串。
class DecoderLessonStore {
  DecoderLessonStore._();

  static const prefsKey = 'decoder-lessons-v1';

  static Future<DecoderLessons> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return DecoderLessons(prefs.getStringList(prefsKey)?.toSet());
    } catch (_) {
      return DecoderLessons();
    }
  }

  static Future<void> save(DecoderLessons lessons) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(prefsKey, lessons.keys().toList());
    } catch (_) {
      // 落盘失败不影响播放：下次起播只是再撞一次已知的坏档位。
    }
  }
}

/// 静默卡死检测：播着、没在缓冲、位置却长时间不动。
///
/// Dart 层拿不到原生帧计数（对照 `PlaybackStallGuard.kt` 的
/// frames），用播放位置代替：位置前进即视为有进展。只在
/// 「正在播 + 不在缓冲」时观察；暂停/缓冲/切集时不累计。
class PlaybackStallGuard {
  PlaybackStallGuard({
    this.timeout = const Duration(seconds: 20),
    this.maxRecoveries = 2,
  });

  /// 卡死判定超时（对照原生 20 秒）。
  final Duration timeout;

  /// 同一集最多触发几次恢复，之后不再打扰（对照原生 recoveries>=2 停）。
  final int maxRecoveries;

  String _episode = '';
  int? _lastPositionMs;
  DateTime? _lastProgressAt;
  int _recoveries = 0;

  /// 有进展返回 false；确认卡死返回 true（调用方触发一次恢复）。
  bool offer({
    required String episodeId,
    required int positionMs,
    required bool playing,
    required bool buffering,
    required DateTime now,
  }) {
    if (episodeId != _episode) {
      _episode = episodeId;
      _recoveries = 0;
      _lastPositionMs = null;
      _lastProgressAt = null;
    }
    if (!playing || buffering || episodeId.isEmpty) {
      _lastPositionMs = null;
      _lastProgressAt = now;
      return false;
    }
    if (_lastPositionMs == null || positionMs != _lastPositionMs) {
      _lastPositionMs = positionMs;
      _lastProgressAt = now;
      return false;
    }
    final since = _lastProgressAt == null
        ? Duration.zero
        : now.difference(_lastProgressAt!);
    if (_recoveries >= maxRecoveries || since < timeout) return false;
    _recoveries++;
    _lastPositionMs = null;
    _lastProgressAt = now;
    return true;
  }
}

/// 失败后的档位选择：先降档，再看学到的失败记忆。
///
/// 档位在 [EpisodeVariant] 里只有名与高，没有编解码字段，因此
/// 学到的键用档位名作「编解码」位：`variant:<档位名>`（尺寸位空着，
/// 即该档位全尺寸都算失败——短剧同一档位各集尺寸一致，这个
/// 粗粒度在这里是够用的）。
class DecoderFallbackPlan {
  DecoderFallbackPlan._();

  /// 档位对应的学到失败键。
  static String lessonKeyForVariant(EpisodeVariant variant) =>
      lessonKeyForName(variant.name);

  /// 档位名对应的学到失败键（起播失败时只有档位名、无对象时用）。
  static String lessonKeyForName(String name) =>
      'variant:${name.trim().toLowerCase()}';

  /// 刚失败的 [failedName] 之后该试的档位：先按 [fallbackVariant]
  /// 往低档走，撞上学到过失败的档位就继续往下跳；没有可试的返回 null。
  static EpisodeVariant? nextAfterFailure({
    required List<EpisodeVariant> variants,
    required String failedName,
    required DecoderLessons lessons,
  }) {
    var failed = failedName;
    for (var i = 0; i < variants.length; i++) {
      final next = fallbackVariant(variants, failed);
      if (next == null) return null;
      if (!lessons.fails(lessonKeyForVariant(next), null, null)) {
        return next;
      }
      failed = next.name;
    }
    return null;
  }
}
