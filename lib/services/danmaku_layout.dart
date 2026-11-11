/// 时间轴弹幕的轨道调度：只做时间与轨道分配，不涉及绘制。
///
/// 对照 hongguoTV `DanmakuLayout.kt` 的结构（只取调度思路，未拷对方
/// 代码）：旧实现是「轨道被占用就丢弃这条弹幕」，默认轨道少、每条占满
/// 整个飞行时长，拥挤时段大半弹幕直接消失；这里改为轨道按需排队，
/// 超出容量时短暂顺延或同时进入，不丢弃；五秒内相同文本合并计数。
library;

/// 一条待排弹幕。
class DanmakuLayoutItem {
  const DanmakuLayoutItem({
    required this.id,
    required this.text,
    required this.timeMs,
  });

  final String id;
  final String text;

  /// 在视频里的时间点（毫秒）。
  final int timeMs;
}

/// 一条排好的弹幕。
class ScheduledDanmaku {
  const ScheduledDanmaku({
    required this.id,
    required this.text,
    required this.startMs,
    required this.lane,
    required this.endMs,
    required this.count,
  });

  /// 首条原始弹幕的 id（合并时取最早那条），供渲染层找回原文。
  final String id;
  final String text;
  final int startMs;
  final int lane;
  final int endMs;

  /// 合并的同文条数（1 = 未合并）。
  final int count;
}

class DanmakuLayout {
  DanmakuLayout._();

  /// 同轨道两条弹幕之间的最小间隔，避免文字重叠。
  static const int minGapMs = 400;

  /// 允许的最大顺延；拥挤时允许重叠，避免排队到剧集结束后。
  static const int maxDelayMs = 3000;

  /// 五秒内相同文本合并为「文字 ×N」，保留最早出现时间。
  static const int mergeWindowMs = 5000;

  /// 给 [items] 分轨道、定开始时间。
  ///
  /// [lanes] 是可用轨道数（已按屏幕高度算好），[travelMs] 是单条弹幕
  /// 完整穿过屏幕的时间。返回按开始时间排好的列表，一条都不丢。
  static List<ScheduledDanmaku> assign(
    List<DanmakuLayoutItem> items, {
    required int lanes,
    required int travelMs,
    bool merge = true,
  }) {
    if (items.isEmpty || lanes <= 0 || travelMs <= 0) return const [];
    // 先按真实 id 去重，避免重叠时间段重复计数；相同文字只在五秒内合并。
    final seenIds = <String>{};
    final unique = <DanmakuLayoutItem>[];
    for (final item in items) {
      final key = item.id.isEmpty ? '${item.timeMs}:${item.text}' : item.id;
      if (seenIds.add(key)) unique.add(item);
    }
    unique.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    final prepared = <_Prepared>[];
    final latest = <String, int>{};
    for (final item in unique) {
      final text = item.text.trim();
      if (text.isEmpty) continue;
      final index = merge ? latest[text] : null;
      final previous = index == null ? null : prepared[index];
      if (previous != null && item.timeMs - previous.timeMs <= mergeWindowMs) {
        prepared[index!] = previous.copyWith(count: previous.count + 1);
      } else {
        latest[text] = prepared.length;
        prepared.add(_Prepared(id: item.id, text: text, timeMs: item.timeMs));
      }
    }

    final laneFreeAt = List<int>.filled(lanes, -1 << 62);
    final output = <ScheduledDanmaku>[];
    for (final entry in prepared) {
      var bestLane = 0;
      var bestStart = 1 << 62;
      for (var lane = 0; lane < lanes; lane++) {
        final earliest = entry.timeMs > laneFreeAt[lane] + minGapMs
            ? entry.timeMs
            : laneFreeAt[lane] + minGapMs;
        if (earliest < bestStart) {
          bestStart = earliest;
          bestLane = lane;
        }
      }
      // 限制等待时间，轨道拥挤时允许重叠，不能把弹幕推迟到片尾之后。
      final maxStart = entry.timeMs + (maxDelayMs < 0 ? 0 : maxDelayMs);
      final start = bestStart < maxStart ? bestStart : maxStart;
      final clamped = start < entry.timeMs ? entry.timeMs : start;
      laneFreeAt[bestLane] = clamped + travelMs ~/ 3;
      output.add(
        ScheduledDanmaku(
          id: entry.id,
          text: entry.count > 1 ? '${entry.text} ×${entry.count}' : entry.text,
          startMs: clamped,
          lane: bestLane,
          endMs: clamped + travelMs,
          count: entry.count,
        ),
      );
    }
    return output;
  }

  /// 按屏幕高度推算可用轨道数，单条行高由字号决定。
  static int laneCountFor({
    required int heightPx,
    required int textSizePx,
    required int topPaddingPx,
    int maxLanes = 12,
  }) {
    if (heightPx <= 0 || textSizePx <= 0) return 1;
    final usable = heightPx - topPaddingPx;
    final lineHeight = (textSizePx * 1.8).toInt() < 1
        ? 1
        : (textSizePx * 1.8).toInt();
    final lanes = usable ~/ lineHeight;
    if (lanes < 1) return 1;
    if (lanes > maxLanes) return maxLanes;
    return lanes;
  }
}

class _Prepared {
  const _Prepared({required this.id, required this.text, required this.timeMs, this.count = 1});

  final String id;
  final String text;
  final int timeMs;
  final int count;

  _Prepared copyWith({int? count}) =>
      _Prepared(id: id, text: text, timeMs: timeMs, count: count ?? this.count);
}
