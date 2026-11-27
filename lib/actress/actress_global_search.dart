import 'actress_library_db.dart';

/// 首页全局搜索的演员库段上限：演员横排一排、作品一屏网格，
/// 都只是入口，全部结果走「更多」进演员库里看（见搜索页）。
const actressGlobalActressCap = 8;
const actressGlobalWorkCap = 12;

/// 首页全局搜索的演员库结果：演员段（按名）+ 作品段
/// （按番号/片名），各带「还有更多」标记。
class ActressGlobalSearchResult {
  const ActressGlobalSearchResult({
    required this.actresses,
    required this.works,
    required this.actressesHasMore,
    required this.worksHasMore,
  });

  /// 演员行：{name, avatar, count}（库层已做显示同名合并）。
  final List<Map<String, dynamic>> actresses;

  /// 作品行：与女优库兜底 item 同形态（vodId/title/pic/code/
  /// date/actress/typeName）。
  final List<Map<String, dynamic>> works;

  final bool actressesHasMore;
  final bool worksHasMore;

  bool get isEmpty => actresses.isEmpty && works.isEmpty;
}

/// 全局搜索演员库段的取数口径：查不到/没库回 null（搜索页
/// 据此静默不出段），不抛错、不回空壳结果冒充查过。
typedef ActressGlobalSearchLoader =
    Future<ActressGlobalSearchResult?> Function(String query);

/// 生产取数：走 [ActressLibraryDbFallback] 的 globalSearch op。
/// 路径解析在兜底层收敛到来源层当前生效的那一本库（外置主
/// 库/导入库二选一，与双库口径一致，不混查）；没有可用库时
/// handle 回 ok:false，这里转成 null——搜索页静默不出演员库
/// 段，不报错、不占位。
Future<ActressGlobalSearchResult?> loadActressGlobalSearch(
  String query, {
  ActressLibraryDbFallback? fallback,
}) async {
  final q = query.trim();
  if (q.isEmpty) return null;
  try {
    final result = await (fallback ?? ActressLibraryDbFallback.shared)
        .handle({
          'op': 'globalSearch',
          'q': q,
          'actressLimit': actressGlobalActressCap,
          'workLimit': actressGlobalWorkCap,
        });
    if (result['ok'] != true) return null;
    List<Map<String, dynamic>> rows(Object? value) => [
      for (final row in (value as List? ?? const []))
        if (row is Map) Map<String, dynamic>.from(row),
    ];
    return ActressGlobalSearchResult(
      actresses: rows(result['actresses']),
      works: rows(result['works']),
      actressesHasMore: result['actressesHasMore'] == true,
      worksHasMore: result['worksHasMore'] == true,
    );
  } catch (_) {
    return null;
  }
}
