import 'dart:async';

import '../models/media_item.dart';
import 'cultivation.dart';
import 'library_store.dart';
import 'media_history_store.dart';

/// Shares pending writes across listening pages and the detail resume action.
class AudioHistory {
  static final _writes = Expando<Future<void>>('audio history writes');
  final ReaderStore store;

  AudioHistory(ReaderStore store) : store = scopedHistoryStore(store, 'audio');

  Future<Map<String, dynamic>?> load(String bookId) async {
    await _writes[store];
    final entry = await store.historyEntry(bookId);
    // Novel scroll offsets and audio seconds can use the same upstream ID.
    // An untyped older entry is not enough evidence to resume listening.
    return entry?['kind'] == 'audio' ? entry : null;
  }

  Future<void> save(Map<String, dynamic> entry, {double listenedSeconds = 0}) {
    final guard = ReadingDataWriteGuard(store);
    final snapshot = {...entry, 'kind': 'audio'};
    final previous = _writes[store] ?? Future<void>.value();
    // 读时统计留在等待链里、历史写之前：它是单次 Hive 写，不堵链；
    // save() 被 await 时统计必须已落盘，且统计写进行时历史快照尚未提交，
    // 清除才能拦住这条保存（见 history_clear_barrier_test）。
    // 只有修为记账（CultivationService 的多轮 SharedPreferences 串行写）
    // 走链外后台任务——它在测试假时钟下很慢，会把后面的进度保存全堵在
    // 链上，之前因此丢了换章/切后台的存盘。
    final write = previous.then((_) async {
      if (guard.canWriteReadTime &&
          listenedSeconds.isFinite &&
          listenedSeconds > 0) {
        try {
          await store.accumulateReadTime(
            snapshot['id'] as String,
            'audio',
            listenedSeconds,
          );
        } catch (_) {
          // Statistics must not prevent saving the listening position.
        }
      }
      if (!guard.canWriteHistory) return;
      try {
        await store.addHistory(snapshot);
      } catch (_) {
        // Keep playback and later writes usable after a storage failure.
      }
    });
    _writes[store] = write;
    unawaited(
      write.then((_) async {
        if (guard.canWriteReadTime &&
            listenedSeconds.isFinite &&
            listenedSeconds > 0) {
          // 修为记账：真实收听时长 1 分钟 = 1 修为（服务里 ×1.8）。
          // 记账失败不影响收听进度保存。
          try {
            await CultivationService.instance.addSeconds(
              CultivationCategory.audio,
              listenedSeconds,
            );
          } catch (_) {}
        }
      }),
    );
    return write.whenComplete(() {
      if (identical(_writes[store], write)) _writes[store] = null;
    });
  }
}

/// Stable chapter identity wins over a directory index that may have changed.
int? resumeAudioChapterIndex(
  Map<String, dynamic>? saved,
  List<Chapter> chapters,
) {
  if (saved?['kind'] != 'audio') return null;
  final id = saved?['chapterId'] ?? saved?['episodeId'];
  if (id is String && id.isNotEmpty) {
    final index = chapters.indexWhere((chapter) => chapter.itemId == id);
    return index < 0 ? null : index;
  }
  final index = saved?['episode'];
  if (index is! num ||
      !index.isFinite ||
      index != index.truncateToDouble() ||
      index < 0 ||
      index >= chapters.length) {
    return null;
  }
  return index.toInt();
}
