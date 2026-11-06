import 'dart:io';

import 'package:sqflite/sqflite.dart';

/// 测试缝：注入一个假的“打开并查”实现，不依赖真库。
/// 签名：(库路径, SQL, 参数) → 行列表，行是列名→值的 Map。
typedef ChannelShowsExecutor =
    Future<List<Map<String, Object?>>> Function(
      String dbPath,
      String sql,
      List<Object?> args,
    );

/// 按频道从插件本地库 tgdrama.db 里查该频道收录的剧。
///
/// 插件是闭源二进制，没有“按频道列剧”的 HTTP 接口，所以客户端直读
/// 它的 SQLite 库（只读，不写库、不改数据）。表结构是 strings 从插件
/// 二进制里抠出的 DDL 核实的（v1.5.0）：
/// - chats：id（主键）、tg_chat_id（UNIQUE）、name、username、type、
///   enabled 等；
/// - shows：id（主键）、name、norm_name（UNIQUE）、cover_path、
///   intro、status、created_at、updated_at；
/// - episodes：id（主键）、show_id（→shows.id）、episode_no、title；
/// - sources：id（主键）、episode_id（→episodes.id）、chat_id
///   （→chats.id）、message_id 等。
/// 链路：频道 chats.id/tg_chat_id → sources.chat_id →
/// sources.episode_id → episodes.show_id → shows.id。
///
/// 容错：库文件不存在、打不开、被锁、表/字段不对时一律抛 StateError
/// （带原因），调用方据此回退到频道信息详情或报错，不崩、不编数据。
/// 读库前调用方先过 TgdramaService.ensureRunning()：插件没起来库
/// 可能不存在或为空。
class TgdramaChannelDb {
  static const int pageSize = 20;

  /// 主查询：该频道收录的剧去重，附该频道贡献的分集数（remark 用
  /// “共N集”，与 /api/shows 的列表一致），按剧更新时间倒序，翻页
  /// 用 LIMIT/OFFSET。tg_chat_id 是 INTEGER，用 ? 占位传参，不拼
  /// 字符串进 SQL。
  static const String channelShowsSql = '''
SELECT s.id AS id, s.name AS name, s.cover_path AS cover_path,
       s.intro AS intro, COUNT(DISTINCT e.id) AS episode_count
FROM shows s
JOIN episodes e ON e.show_id = s.id
JOIN sources src ON src.episode_id = e.id
JOIN chats c ON c.id = src.chat_id
WHERE c.tg_chat_id = ?
GROUP BY s.id, s.name, s.cover_path, s.intro, s.updated_at
ORDER BY s.updated_at DESC
LIMIT ? OFFSET ?
''';

  /// 兜底查询：主查询因字段缺失编不过时退到这一条（只取
  /// id/name/cover_path，不计分集数、不按更新时间排）。
  /// 字段缺失时解析层把 episode_count/intro 当空处理。
  static const String channelShowsFallbackSql = '''
SELECT DISTINCT s.id AS id, s.name AS name, s.cover_path AS cover_path,
       s.intro AS intro
FROM shows s
JOIN episodes e ON e.show_id = s.id
JOIN sources src ON src.episode_id = e.id
JOIN chats c ON c.id = src.chat_id
WHERE c.tg_chat_id = ?
LIMIT ? OFFSET ?
''';

  /// 查一页该频道收录的剧（原始行，调用方再解析）。
  /// 库文件不存在抛 StateError；主查询失败时用兜底查询重试一次；
  /// 两次都失败抛 StateError。page 小于 1 按 1 算。
  static Future<List<Map<String, Object?>>> queryChannelShows({
    required String dbPath,
    required String tgChatId,
    int page = 1,
    int pageSize = TgdramaChannelDb.pageSize,
    ChannelShowsExecutor? executor,
  }) async {
    final file = File(dbPath);
    if (!await file.exists()) {
      throw StateError('TG影视库本地数据库不存在');
    }
    final exec = executor ?? _queryReadOnly;
    final p = page < 1 ? 1 : page;
    final chatIdArg = int.tryParse(tgChatId) ?? tgChatId;
    final args = <Object?>[chatIdArg, pageSize, (p - 1) * pageSize];
    try {
      return await exec(dbPath, channelShowsSql, args);
    } catch (_) {
      // 主查询编不过（字段缺失等）：退到兜底查询再试一次。
      try {
        return await exec(dbPath, channelShowsFallbackSql, args);
      } catch (error) {
        throw StateError('TG影视库本地数据库读取失败：$error');
      }
    }
  }

  /// 真实现：只读打开库，查完即关。readOnly 模式插件运行时也能读
  /// （共享锁），不写库、不建 -wal/-shm 之外的文件。
  /// 失败（被锁、损坏、表不存在）时抛异常，由调用方接住回退。
  static Future<List<Map<String, Object?>>> _queryReadOnly(
    String dbPath,
    String sql,
    List<Object?> args,
  ) async {
    final db = await openDatabase(dbPath, readOnly: true);
    try {
      return await db.rawQuery(sql, args);
    } finally {
      await db.close();
    }
  }
}
