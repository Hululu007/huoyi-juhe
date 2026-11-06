import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/tgdrama_channel_db.dart';

void main() {
  group('按频道列剧 SQL', () {
    test('主查询：四表链路 + tg_chat_id 占位 + 按更新时间倒序 + 翻页占位', () {
      final sql = TgdramaChannelDb.channelShowsSql;
      expect(sql, contains('FROM shows s'));
      expect(sql, contains('JOIN episodes e ON e.show_id = s.id'));
      expect(sql, contains('JOIN sources src ON src.episode_id = e.id'));
      expect(sql, contains('JOIN chats c ON c.id = src.chat_id'));
      expect(sql, contains('WHERE c.tg_chat_id = ?'));
      expect(sql, contains('COUNT(DISTINCT e.id) AS episode_count'));
      expect(sql, contains('ORDER BY s.updated_at DESC'));
      expect(sql, contains('LIMIT ? OFFSET ?'));
      // 占位符正好 3 个：频道 id、每页条数、偏移。
      expect('?'.allMatches(sql).length, 3);
    });

    test('兜底查询：同样四表链路，不计分集数、不按更新时间排', () {
      final sql = TgdramaChannelDb.channelShowsFallbackSql;
      expect(sql, contains('FROM shows s'));
      expect(sql, contains('JOIN episodes e ON e.show_id = s.id'));
      expect(sql, contains('JOIN sources src ON src.episode_id = e.id'));
      expect(sql, contains('JOIN chats c ON c.id = src.chat_id'));
      expect(sql, contains('WHERE c.tg_chat_id = ?'));
      expect(sql, contains('LIMIT ? OFFSET ?'));
      expect(sql.contains('COUNT('), isFalse);
      expect(sql.contains('ORDER BY'), isFalse);
    });

    test('pageSize 是 20', () {
      expect(TgdramaChannelDb.pageSize, 20);
    });
  });

  group('queryChannelShows 容错与翻页', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('tgdrama_db_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('库文件不存在抛 StateError（不调执行器）', () async {
      var called = false;
      await expectLater(
        TgdramaChannelDb.queryChannelShows(
          dbPath: '${tempDir.path}/no_such.db',
          tgChatId: '-100111',
          executor: (_, _, _) async {
            called = true;
            return [];
          },
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('本地数据库不存在'),
          ),
        ),
      );
      expect(called, isFalse);
    });

    test('假执行器：频道 id 转整数传参，页码算对 LIMIT/OFFSET', () async {
      final dbFile = File('${tempDir.path}/tgdrama.db');
      await dbFile.writeAsBytes([0]);
      final seen = <List<Object?>>[];
      final seenSql = <String>[];
      Future<List<Map<String, Object?>>> fake(
        String path,
        String sql,
        List<Object?> args,
      ) async {
        seen.add(args);
        seenSql.add(sql);
        return [
          {'id': 1, 'name': '剧一'},
        ];
      }

      final rows = await TgdramaChannelDb.queryChannelShows(
        dbPath: dbFile.path,
        tgChatId: '-100111',
        page: 2,
        executor: fake,
      );
      expect(rows.length, 1);
      // 频道 id 是整数 -100111（不是字符串），每页 20，第 2 页偏移 20。
      expect(seen.single, [-100111, 20, 20]);
      expect(seenSql.single, TgdramaChannelDb.channelShowsSql);
    });

    test('页码小于 1 按 1 算，偏移为 0', () async {
      final dbFile = File('${tempDir.path}/tgdrama.db');
      await dbFile.writeAsBytes([0]);
      final seen = <List<Object?>>[];
      await TgdramaChannelDb.queryChannelShows(
        dbPath: dbFile.path,
        tgChatId: '-100111',
        page: 0,
        executor: (_, _, args) async {
          seen.add(args);
          return [];
        },
      );
      expect(seen.single, [-100111, 20, 0]);
    });

    test('主查询失败时用兜底查询重试一次，兜底成功就返回兜底结果', () async {
      final dbFile = File('${tempDir.path}/tgdrama.db');
      await dbFile.writeAsBytes([0]);
      final seenSql = <String>[];
      var calls = 0;
      Future<List<Map<String, Object?>>> flaky(
        String path,
        String sql,
        List<Object?> args,
      ) async {
        calls++;
        seenSql.add(sql);
        if (sql == TgdramaChannelDb.channelShowsSql) {
          throw StateError('no such column: episode_count');
        }
        return [
          {'id': 2, 'name': '兜底剧'},
        ];
      }

      final rows = await TgdramaChannelDb.queryChannelShows(
        dbPath: dbFile.path,
        tgChatId: '-100222',
        executor: flaky,
      );
      expect(calls, 2);
      expect(seenSql[1], TgdramaChannelDb.channelShowsFallbackSql);
      expect(rows.single['name'], '兜底剧');
    });

    test('主查询与兜底都失败抛带原因的 StateError', () async {
      final dbFile = File('${tempDir.path}/tgdrama.db');
      await dbFile.writeAsBytes([0]);
      await expectLater(
        TgdramaChannelDb.queryChannelShows(
          dbPath: dbFile.path,
          tgChatId: '-100111',
          executor: (_, _, _) async => throw StateError('file is not a database'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('本地数据库读取失败'),
          ),
        ),
      );
    });

    test('非数字频道 id 原样传字符串参数', () async {
      final dbFile = File('${tempDir.path}/tgdrama.db');
      await dbFile.writeAsBytes([0]);
      final seen = <List<Object?>>[];
      await TgdramaChannelDb.queryChannelShows(
        dbPath: dbFile.path,
        tgChatId: 'abc',
        executor: (_, _, args) async {
          seen.add(args);
          return [];
        },
      );
      expect(seen.single[0], 'abc');
    });
  });
}
