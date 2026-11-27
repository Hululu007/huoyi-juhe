import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart' as mk;
import 'package:path_provider/path_provider.dart';

import 'actress_online_sources.dart' show actressCodeKey;

/// 剧照截帧器（可注入接口，测试用假实现）：给一条能播的流，
/// 在多个时间点截帧回图片字节。拿不到回空表、不抛错——截
/// 帧只是 JavDB 无剧照时的兜底，失败就让剧照区保持不出。
abstract class ActressStillCapturer {
  Future<List<Uint8List>> captureFrames({
    required String url,
    Map<String, String> headers = const {},
    int count = 5,
  });
}

/// media_kit 无头截帧（现行播放栈的 libmpv 通道）：
/// Player.screenshot 是 media_kit 1.2.6 的现成接口（pub 缓
/// 存源码 platform_player/player.dart 实证，native 走 mpv
/// 的 screenshot-raw）。不开 VideoController、不挂画面：
/// 开流 → 等时长 → 按时长比例 seek 到拉开的几个时间点 →
/// 逐点截帧 → 释放。全程吞错回已截到的部分。
///
/// 平台实情（照实）：本 App 的安卓包刻意不带 libmpv（pubspec
/// 只挂 windows / ios 的 media_kit_libs，注释写明安卓带上要
/// 多约 11MB），安卓真机上这条路大概率起不来、会静默回空，
/// 只剩 JavDB 剧照一路；桌面/iOS 包内有 libmpv。真机可用性
/// 待验，见本批回报。
class MediaKitStillCapturer implements ActressStillCapturer {
  const MediaKitStillCapturer();

  @override
  Future<List<Uint8List>> captureFrames({
    required String url,
    Map<String, String> headers = const {},
    int count = 5,
  }) async {
    final frames = <Uint8List>[];
    mk.Player? player;
    try {
      mk.MediaKit.ensureInitialized();
      player = mk.Player(
        configuration: const mk.PlayerConfiguration(
          title: 'actress-stills',
          logLevel: mk.MPVLogLevel.error,
        ),
      );
      await player
          .open(mk.Media(url, httpHeaders: headers), play: true)
          .timeout(const Duration(seconds: 25));
      // 等时长出来（直播/未知时长给固定时间点）。
      var duration = Duration.zero;
      try {
        duration = await player.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 12));
      } catch (_) {
        duration = Duration.zero;
      }
      final points = duration > const Duration(seconds: 30)
          ? [
              for (final ratio in const [0.08, 0.26, 0.45, 0.64, 0.83])
                duration * ratio,
            ]
          : const [
              Duration(seconds: 5),
              Duration(seconds: 30),
              Duration(seconds: 75),
              Duration(seconds: 150),
              Duration(seconds: 300),
            ];
      for (final point in points.take(count)) {
        if (frames.length >= count) break;
        try {
          await player.seek(point).timeout(const Duration(seconds: 10));
          // 等解码落帧再截，太急会截到上一帧/黑帧。
          await Future<void>.delayed(const Duration(milliseconds: 700));
          final shot = await player
              .screenshot(format: 'image/jpeg')
              .timeout(const Duration(seconds: 10));
          if (shot != null && shot.length > 1024) frames.add(shot);
        } catch (_) {
          // 单点失败跳下一点。
        }
      }
    } catch (_) {
      // 无头播放器起不来（平台无 libmpv 等）→ 回已截到的部分。
    } finally {
      try {
        await player?.dispose();
      } catch (_) {}
    }
    return frames;
  }
}

/// 截帧缓存：帧存 App 缓存目录（key = 归一化番号 + 来源），
/// 重复打开同一部片先读缓存不重截。目录可注入（测试用临时
/// 目录）；一帧一个文件 frame_N.jpg，全套在才算命中。
class ActressStillCache {
  ActressStillCache({Future<Directory> Function()? directoryOf})
    : _directoryOf = directoryOf ?? _defaultDirectory;

  final Future<Directory> Function() _directoryOf;

  static Future<Directory> _defaultDirectory() async {
    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/actress_stills');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  String _prefix(String code, String sourceId) {
    final key = actressCodeKey(code);
    final source = sourceId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return '${key}_$source';
  }

  /// 读缓存：回帧文件路径列表（按序号排），没缓存回空。
  /// 内部用同步文件 API：帧文件就几个小文件，同步读写不卡
  /// 界面；且异步流式目录枚举在某些执行环境（FakeAsync 测
  /// 试区）永远不回包，同步口径没这个坑。
  Future<List<String>> read(String code, String sourceId) async {
    try {
      final dir = await _directoryOf();
      final prefix = _prefix(code, sourceId);
      final files = dir
          .listSync()
          .whereType<File>()
          .where((file) {
            final name = file.uri.pathSegments.last;
            return name.startsWith('${prefix}_frame_') &&
                name.endsWith('.jpg');
          })
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      return [for (final file in files) file.path];
    } catch (_) {
      return const [];
    }
  }

  /// 写缓存：落盘后回文件路径列表；落盘失败回空（不挡显示，
  /// 调用方仍可直接用内存里的路径——本方法落盘失败即无路径）。
  Future<List<String>> write(
    String code,
    String sourceId,
    List<Uint8List> frames,
  ) async {
    try {
      final dir = await _directoryOf();
      final prefix = _prefix(code, sourceId);
      final paths = <String>[];
      for (var i = 0; i < frames.length; i++) {
        final file = File('${dir.path}/${prefix}_frame_$i.jpg');
        file.writeAsBytesSync(frames[i], flush: true);
        paths.add(file.path);
      }
      return paths;
    } catch (_) {
      return const [];
    }
  }
}
