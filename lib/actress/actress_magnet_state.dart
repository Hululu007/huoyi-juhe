import 'package:shared_preferences/shared_preferences.dart';

import '../cloud_drive/auto_offline.dart';
import '../cloud_drive/cloud_115_offline.dart';
import '../cloud_drive/cloud_drive_factory.dart';
import '../cloud_drive/drive_code_play.dart';

/// 磁力作品的 115 网盘三态（修仙版新拼，修仙版此前没有现成
/// 合成逻辑）：不做 P2P、不做本机种子引擎；三态由网盘离线
/// 任务列表＋本地已提交记录合成，详情页再按番号查盘确认一
/// 次、网盘里真有文件才算「网盘可播」。
enum MagnetDriveState { notDownloaded, offlineRunning, drivePlayable }

extension MagnetDriveStateLabel on MagnetDriveState {
  String get label => switch (this) {
    MagnetDriveState.notDownloaded => '未下载',
    MagnetDriveState.offlineRunning => '离线中',
    MagnetDriveState.drivePlayable => '网盘可播',
  };
}

/// 任务与作品的匹配（番号尺）：任务名里提到的番号与作品
/// 番号归一后相同才命中。
bool pan115TaskMatchesCode(Pan115OfflineTask task, String code) {
  final key = pan115CodeKeyOf(code);
  if (key.isEmpty) return false;
  final extracted = pan115ExtractCode(task.name);
  return extracted != null && pan115CodeKeyOf(extracted) == key;
}

/// 任务与作品的匹配（infohash 尺）：任务的 infoHash 与任一
/// 条磁力的 btih 同小写比对。无番号作品（如韩国主播，vod_id
/// 是合成的 magnet-<哈希>）按名字对不上番号，只能靠这一路
/// 认任务。
bool pan115TaskMatchesMagnets(
  Pan115OfflineTask task,
  List<String> magnetUrls,
) {
  final hash = task.infoHash.trim().toLowerCase();
  if (hash.isEmpty) return false;
  return magnetUrls.any((url) => pan115InfoHashOf(url) == hash);
}

/// 哈希命中或任务名番号命中任一即可。
bool pan115TaskMatchesWork(
  Pan115OfflineTask task,
  String code,
  List<String> magnetUrls,
) =>
    pan115TaskMatchesMagnets(task, magnetUrls) ||
    pan115TaskMatchesCode(task, code);

/// 三态合成要看的一部作品（列表快照合成的入参）。
class MagnetWorkRef {
  const MagnetWorkRef({
    required this.vodId,
    required this.code,
    required this.magnetUrls,
  });

  final String vodId;

  /// 番号；无番号作品传 vodId 占位（合成只靠 infohash 尺）。
  final String code;

  final List<String> magnetUrls;
}

/// 一次快照：已提交哈希集合＋离线任务列表。
typedef MagnetDriveSnapshot = ({
  Set<String> submitted,
  List<Pan115OfflineTask> tasks,
});

/// 三态解析器：三口可注入（任务列表、已提交哈希、查盘
/// 确认），不传时接生产实现——任务走引擎的
/// [Pan115OfflineClient.listTasks]、已提交走
/// [SubmittedOfflineLinks] 指纹表、查盘走 [DriveCodePlayFinder]。
class MagnetDriveStateResolver {
  MagnetDriveStateResolver({
    Future<List<Pan115OfflineTask>> Function()? listTasks,
    Future<Set<String>> Function()? submittedHashes,
    Future<bool> Function(String code)? confirmInDrive,
  }) : _listTasks = listTasks ?? _prodListTasks,
       _submittedHashes = submittedHashes ?? _prodSubmittedHashes,
       _confirmInDrive = confirmInDrive ?? _prodConfirmInDrive;

  final Future<List<Pan115OfflineTask>> Function() _listTasks;
  final Future<Set<String>> Function() _submittedHashes;
  final Future<bool> Function(String code) _confirmInDrive;

  static Future<List<Pan115OfflineTask>> _prodListTasks() async {
    final engine = await CloudDriveFactory.engine();
    final client = engine.pan115OfflineClient();
    if (client == null) return const [];
    return client.listTasks();
  }

  /// 已提交指纹表存的是 offlineLinkFingerprint（磁力是
  /// 'bt:<小写哈希>'），这里只取 bt: 段还原成哈希集合，与
  /// 任务/infohash 尺同口径。
  static Future<Set<String>> _prodSubmittedHashes() async {
    final prefs = await SharedPreferences.getInstance();
    final entries =
        prefs.getStringList(SubmittedOfflineLinks.prefsKey) ??
        const <String>[];
    final hashes = <String>{};
    for (final entry in entries) {
      if (entry.startsWith('bt:')) {
        final hash = entry.substring(3).trim().toLowerCase();
        if (hash.isNotEmpty) hashes.add(hash);
      }
    }
    return hashes;
  }

  static Future<bool> _prodConfirmInDrive(String code) async {
    final finder = DriveCodePlayFinder(
      isLoggedIn: () async {
        final engine = await CloudDriveFactory.engine();
        return engine.pan115LoggedIn;
      },
      search: (keyword) async {
        final engine = await CloudDriveFactory.engine();
        return engine.searchPan115Files(keyword);
      },
      directLink: (file) async {
        final engine = await CloudDriveFactory.engine();
        return engine.pan115DirectLink(file);
      },
    );
    return await finder.find(code) != null;
  }

  /// 取一次快照：两路各自吞错——读不到提交记录按没提交过
  /// 走、任务列表拉不到按没有任务走。
  Future<MagnetDriveSnapshot> snapshot() async {
    var submitted = <String>{};
    try {
      submitted = await _submittedHashes();
    } catch (_) {
      // 读不到提交记录按没提交过走。
    }
    var tasks = const <Pan115OfflineTask>[];
    try {
      tasks = await _listTasks();
    } catch (_) {
      // 任务列表拉不到按没有任务走。
    }
    return (submitted: submitted, tasks: tasks);
  }

  /// 纯合成（不碰网络）：任务命中优先——完成了算网盘可播、
  /// 在跑算离线中；没任务但磁力哈希在已提交记录里算离线
  /// 中；其余未下载。
  MagnetDriveState stateFromSnapshot({
    required String code,
    required List<String> magnetUrls,
    required Set<String> submitted,
    required List<Pan115OfflineTask> tasks,
  }) {
    for (final task in tasks) {
      if (pan115TaskMatchesWork(task, code, magnetUrls)) {
        return task.done
            ? MagnetDriveState.drivePlayable
            : MagnetDriveState.offlineRunning;
      }
    }
    for (final url in magnetUrls) {
      final hash = pan115InfoHashOf(url);
      if (hash.isNotEmpty && submitted.contains(hash)) {
        return MagnetDriveState.offlineRunning;
      }
    }
    return MagnetDriveState.notDownloaded;
  }

  /// 列表快照合成：只取一次快照，逐部纯合成（不逐卡查网
  /// 盘）。回 vod_id → 状态；没有磁力地址的作品不进结果。
  Future<Map<String, MagnetDriveState>> snapshotForWorks(
    List<MagnetWorkRef> works,
  ) async {
    final targets = [
      for (final work in works)
        if (work.magnetUrls.isNotEmpty) work,
    ];
    if (targets.isEmpty) return const {};
    final snap = await snapshot();
    return {
      for (final work in targets)
        work.vodId: stateFromSnapshot(
          code: work.code,
          magnetUrls: work.magnetUrls,
          submitted: snap.submitted,
          tasks: snap.tasks,
        ),
    };
  }

  /// 详情页口径：先快照合成；已是网盘可播直接回；否则再按
  /// 番号查盘确认——网盘里真有文件才升「网盘可播」（用户
  /// 可能在别处早就下好了这部片、没有离线任务记录）。查盘
  /// 异常吞掉、不改合成结论。
  Future<MagnetDriveState> resolveForWork({
    required String code,
    required List<String> magnetUrls,
  }) async {
    final snap = await snapshot();
    final state = stateFromSnapshot(
      code: code,
      magnetUrls: magnetUrls,
      submitted: snap.submitted,
      tasks: snap.tasks,
    );
    if (state == MagnetDriveState.drivePlayable) return state;
    if (code.trim().isEmpty) return state;
    try {
      if (await _confirmInDrive(code)) {
        return MagnetDriveState.drivePlayable;
      }
    } catch (_) {
      // 查盘失败不改合成结论。
    }
    return state;
  }
}
