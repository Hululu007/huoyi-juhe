import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'actress_adapter_models.dart';
import 'actress_film_library.dart';
import 'actress_models.dart';
import 'actress_mytv_bind.dart';

/// 共用站点库的文件名：一个文件，不按站分。落点 MYTV/db/，与
/// 女优库.db 同目录（绑定、通用读库、多库兜底都认这个目录）。
const siteDbFileName = '站点库.db';

/// 共用站点库：播起来后把能播的片记一条（只记能播的，播不了的不写）。
/// 表照女优库.db 的 videos 12 字段 + video_category 两表复用，
/// 现有读库代码不用改就能读它、搜它、播它。
/// 写盘只开这一个文件，绝不碰女优库.db；写失败静默跳过、不挡播放。
class ActressSiteDb {
  ActressSiteDb._();

  static final ActressSiteDb instance = ActressSiteDb._();

  Database? _db;
  Future<Database>? _openFuture;

  /// 测试注入：直接用内存库或测试库，跳过 MYTV 绑定。
  @visibleForTesting
  static Database? testDb;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null && existing.isOpen) return existing;
    var pending = _openFuture;
    if (pending == null) {
      pending = _openNow();
      _openFuture = pending;
    }
    try {
      final db = await pending;
      _db = db;
      return db;
    } catch (_) {
      if (identical(_openFuture, pending)) _openFuture = null;
      rethrow;
    }
  }

  Future<Database> _openNow() async {
    final injected = testDb;
    if (injected != null && injected.isOpen) return injected;
    final bind = await ActressMytvBind.instance.ensureBound();
    final filePath = path.join(bind.dbDir.path, siteDbFileName);
    return openDatabase(
      filePath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE videos('
          'vod_id TEXT PRIMARY KEY, '
          'title TEXT, '
          'pic_url TEXT, '
          'm3u8_url TEXT, '
          'vod_remarks TEXT, '
          'vod_pubdate TEXT, '
          'vod_area TEXT, '
          'vod_year TEXT, '
          'vod_content TEXT, '
          'vod_play_from TEXT, '
          'vod_play_url TEXT, '
          'type_name TEXT, '
          'created_at TEXT DEFAULT CURRENT_TIMESTAMP)',
        );
        await db.execute(
          'CREATE TABLE video_category('
          'vod_id TEXT PRIMARY KEY, '
          'main_category TEXT)',
        );
        await db.execute(
          'CREATE INDEX idx_vc_main ON video_category(main_category)',
        );
      },
    );
  }

  /// 记一条播过的片：只在播放器真播起来后调（调用方保证地址已验活）。
  /// 去重按现成合并规则（见 [videoLibraryMergeAction]）：同番号同地址
  /// 跳过、同番号换地址只更新、新番号插入；重复播只留一条，绝不追加。
  /// 返回 true 表示写进去了（新增或更新），false 表示跳过或写失败。
  Future<bool> recordPlay({
    required Drama drama,
    required String playUrl,
  }) async {
    try {
      final url = playUrl.trim();
      if (url.isEmpty) return false;
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !(uri.scheme == 'http' || uri.scheme == 'https')) {
        return false;
      }
      final vodId = videoLibraryVodId(drama.id);
      if (vodId.isEmpty) return false;
      final db = await _open();
      // VideoLibraryEntry 是 record 类型别名，不能当构造器调，
      // 用记录字面量。
      final entry = (
        vodId: vodId,
        title: drama.title,
        picUrl: drama.cover,
        playUrl: url,
        remarks: '高清',
        pubdate: drama.onlineDate,
        area: '',
        year: '',
        content: drama.description,
        playFrom: filmSiteId(drama.source),
        typeName: drama.category,
        category: drama.category,
        actressName: '',
      );
      final existing = await db.query(
        'videos',
        columns: ['vod_play_url'],
        where: 'vod_id = ?',
        whereArgs: [vodId],
        limit: 1,
      );
      final action = videoLibraryMergeAction(
        existing.isEmpty
            ? null
            : existing.first['vod_play_url']?.toString(),
        url,
      );
      switch (action) {
        case VideoLibraryMergeAction.skip:
          return false;
        case VideoLibraryMergeAction.update:
          await db.update(
            'videos',
            {
              'm3u8_url': url,
              'vod_play_url': url,
              if (entry.title.isNotEmpty) 'title': entry.title,
              if (entry.picUrl.isNotEmpty) 'pic_url': entry.picUrl,
              if (entry.playFrom.isNotEmpty) 'vod_play_from': entry.playFrom,
            },
            where: 'vod_id = ?',
            whereArgs: [vodId],
          );
          return true;
        case VideoLibraryMergeAction.insert:
          await db.insert('videos', {
            'vod_id': entry.vodId,
            'title': entry.title,
            'pic_url': entry.picUrl,
            'm3u8_url': entry.playUrl,
            'vod_remarks': entry.remarks,
            'vod_pubdate': entry.pubdate,
            'vod_area': entry.area,
            'vod_year': entry.year,
            'vod_content': entry.content,
            'vod_play_from': entry.playFrom,
            'vod_play_url': entry.playUrl,
            'type_name': entry.typeName,
          });
          if (entry.category.isNotEmpty) {
            await db.insert('video_category', {
              'vod_id': entry.vodId,
              'main_category': entry.category,
            });
          }
          return true;
      }
    } catch (_) {
      // 写库失败（没权限/磁盘满/库被占）：静默跳过，不挡播放、不弹错。
      return false;
    }
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    _openFuture = null;
    await db?.close();
  }
}
