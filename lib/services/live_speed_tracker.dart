import 'dart:async';

import 'package:flutter/foundation.dart';

import 'live_platform.dart';

/// 全屏顶栏网速：最小可用版，对齐火蚁TV 顶栏的网速位。
///
/// 火蚁TV 的网速来自 NetworkSpeedTracker，采样 mpv 的 demuxer 状态
///（raw-input-rate / total-bytes）；修仙版 NativePlayer 没有网络采样
/// 接口，取不到 mpv 那种数据。替代采样：直播流本身走 LiveRelay 本地中继
///（明文 http FLV 全走这条路），直接数中继每秒转发的字节，精度够顶栏
/// 显示用。直连 https 流不走中继，采不到，顶栏不显示网速。
/// 1 秒 tick 一次，只改 speedText，不整页 setState。
class LiveSpeedTracker {
  LiveSpeedTracker() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  final ValueNotifier<String?> speedText = ValueNotifier<String?>(null);
  Timer? _timer;
  bool _disposed = false;

  void _tick() {
    if (_disposed) return;
    final bytes = LiveRelay.instance.recentBytesPerSecond();
    final text = bytes == null ? null : formatLiveSpeed(bytes);
    if (speedText.value != text) speedText.value = text;
  }

  /// 换台时清掉旧采样，避免上一条流的速率残留到新台顶栏。
  void reset() {
    LiveRelay.instance.resetRateSamples();
    if (speedText.value != null) speedText.value = null;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    speedText.dispose();
  }
}

/// 与火蚁TV formatNetworkSpeed 同档的格式化：B/s、KB/s、MB/s、GB/s。
String formatLiveSpeed(double bytesPerSecond) {
  if (!bytesPerSecond.isFinite || bytesPerSecond < 0) return '0 KB/s';
  if (bytesPerSecond < 1024) return '${bytesPerSecond.round()} B/s';
  if (bytesPerSecond < 1024 * 1024) {
    return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
  }
  if (bytesPerSecond < 1024 * 1024 * 1024) {
    return '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(1)} MB/s';
  }
  return '${(bytesPerSecond / 1024 / 1024 / 1024).toStringAsFixed(1)} GB/s';
}
