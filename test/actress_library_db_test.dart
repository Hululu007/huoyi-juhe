// 合并演员库页数据库兜底（ActressLibraryDbFallback）单元测试。
// 不碰真 sqlite（flutter test 无桌面实现）：注入假查询函数，按
// SQL 特征回固定行，断言操作分发、参数化、官方分类映射形态与
// 硬线排除参数在每条查询里都在。
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_library_db.dart';

class _FakeDb {
  final tables = {
    'videos',
    'video_play_urls',
    'video_actress',
    'actresses',
    'video_tag',
    'video_ranking',
    'index_categories',
  };
  final calls = <(String, List<Object?>?)>[];

  Map<String, Object?> _videoRow(
    String id, {
    String play = 'https://v.hersav.me/h/h.m3u8',
    String playAlt = '',
    String typeName = '成人影片',
  }) => {
    'vodId': id,
    'title': '作品$id',
    'pic': 'https://v.hersav.me/images/av/x.jpg',
    'play': play,
    'playAlt': playAlt,
    'date': '2024-01-01',
    'typeName': typeName,
    'actress': '演员甲',
  };

  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? args,
  ]) async {
    calls.add((sql, args));
    if (sql.contains('sqlite_master')) {
      return [for (final t in tables) {'name': t}];
    }
    if (sql.contains('FROM video_ranking')) {
      return [_videoRow('rank-001')];
    }
    if (sql.contains('category_name AS name')) {
      // tags 操作：主查 index_categories 的名单行（actresses 的
      // 计数子查询也提 index_categories，但选的是 ic.video_count，
      // 不长这样）。
      return [
        {'name': '中文字幕', 'cnt': 3631},
        {'name': '巨乳美乳', 'cnt': 6234},
      ];
    }
    if (sql.contains('FROM actresses a')) {
      return [
        {'name': '演员甲', 'avatar': 'https://x.test/a.jpg', 'cnt': 42},
        {'name': '演员乙', 'avatar': '', 'cnt': 7},
      ];
    }
    if (sql.contains('FROM video_play_urls')) {
      // detail 的多线路 / list 的 play 兜底都走这张表。
      if (sql.contains('LIMIT 8')) {
        return [
          {'play_url': 'https://v.hersav.me/h/h.m3u8'},
          {'play_url': 'https://cdn.test/alt.m3u8'},
        ];
      }
      return [
        {'play_url': 'https://v.hersav.me/fallback/f.m3u8'},
      ];
    }
    if (sql.contains('SELECT a.name AS name FROM video_actress')) {
      return [
        {'name': '演员甲'},
        {'name': '演员乙'},
      ];
    }
    if (sql.contains('SELECT tag_name AS name FROM video_tag')) {
      return [
        {'name': '中文字幕'},
      ];
    }
    if (sql.contains('FROM videos v')) {
      // detail：vod_id 精确查（带 LIMIT 1 且无 ORDER BY 分页尾）。
      if (sql.contains('WHERE v.vod_id = ?')) {
        final id = args?.first?.toString() ?? '';
        if (id == 'gone-001') return [];
        return [_videoRow(id, play: '')];
      }
      // related 的同类兜底（type_name = ?）回空，断言主相关即可。
      if (sql.contains('v.type_name = ?')) return [];
      return [_videoRow('ssis-001'), _videoRow('mida-002', play: '')];
    }
    return [];
  }
}

ActressLibraryDbFallback _service(_FakeDb db, {bool hasDb = true}) {
  return ActressLibraryDbFallback(
    pathResolver: () async => hasDb ? '/fake/女优库.db' : null,
    opener: (path) async => hasDb ? db.query : null,
  );
}

void main() {
  group('ActressLibraryDbFallback', () {
    test('没有可用库时回 ok:false，不抛错', () async {
      final service = _service(_FakeDb(), hasDb: false);
      final result = await service.handle({'op': 'list', 'kind': 'latest'});
      expect(result['ok'], isFalse);
    });

    test('list latest：发布日期倒序 + 分页参数 + 排除参数在位', () async {
      final db = _FakeDb();
      final service = _service(db);
      final result = await service.handle({
        'op': 'list',
        'kind': 'latest',
        'page': 2,
        'limit': 24,
      });
      expect(result['ok'], isTrue);
      final items = result['items'] as List;
      expect(items, hasLength(2));
      expect(items.first['vodId'], 'ssis-001');
      expect(items.first['code'], 'ssis-001');
      final listCall = db.calls.firstWhere(
        (c) => c.$1.contains('FROM videos v') && c.$1.contains('ORDER BY'),
      );
      expect(listCall.$1, contains('v.vod_pubdate DESC'));
      expect(listCall.$1, contains('type_name NOT IN'));
      expect(listCall.$2, contains('少女萝莉'));
      expect(listCall.$2!.sublist(listCall.$2!.length - 2), [24, 24]);
    });

    test('list latest 带厂牌前缀：vod_id 前缀 LIKE 参数', () async {
      final db = _FakeDb();
      final service = _service(db);
      await service.handle({'op': 'list', 'kind': 'latest', 'q': 'SSIS'});
      final listCall = db.calls.firstWhere(
        (c) => c.$1.contains('FROM videos v') && c.$1.contains('LIKE'),
      );
      expect(listCall.$2, contains('ssis%'));
    });

    test('list 的 play 兜底：m3u8 为空时用播放地址表第一条', () async {
      final db = _FakeDb();
      final service = _service(db);
      final result = await service.handle({'op': 'list', 'kind': 'latest'});
      final items = result['items'] as List;
      final second = items[1] as Map;
      expect(second['play'], 'https://v.hersav.me/fallback/f.m3u8');
    });

    test('list rank：走 video_ranking 行序、固定 50', () async {
      final db = _FakeDb();
      final service = _service(db);
      final result = await service.handle({'op': 'list', 'kind': 'rank'});
      expect(result['ok'], isTrue);
      final items = result['items'] as List;
      expect(items.single['vodId'], 'rank-001');
      final rankCall = db.calls.firstWhere(
        (c) => c.$1.contains('FROM video_ranking'),
      );
      expect(rankCall.$1, contains('ORDER BY r.rowid LIMIT 50'));
      expect(rankCall.$2, contains('少女萝莉'));
    });

    test('search：番号精确/前缀优先的排序形态与参数', () async {
      final db = _FakeDb();
      final service = _service(db);
      await service.handle({'op': 'search', 'q': 'SSIS-001', 'page': 1});
      final call = db.calls.firstWhere(
        (c) => c.$1.contains('CASE WHEN v.vod_id = ?'),
      );
      expect(call.$2, contains('ssis-001'));
      expect(call.$2, contains('ssis-001%'));
      expect(call.$2, contains('%ssis-001%'));
    });

    test('search 空关键词回空表 ok', () async {
      final service = _service(_FakeDb());
      final result = await service.handle({'op': 'search', 'q': '  '});
      expect(result['ok'], isTrue);
      expect(result['items'], isEmpty);
    });

    test('works actress：name 与 cate_id 双命中子查询', () async {
      final db = _FakeDb();
      final service = _service(db);
      final result = await service.handle({
        'op': 'works',
        'actress': '演员甲',
      });
      expect(result['ok'], isTrue);
      final call = db.calls.firstWhere(
        (c) => c.$1.contains('a.name = ? OR a.cate_id = ?'),
      );
      expect(call.$2, contains('演员甲'));
    });

    test('works tag：走 video_tag 关联', () async {
      final db = _FakeDb();
      final service = _service(db);
      final result = await service.handle({'op': 'works', 'tag': '中文字幕'});
      expect(result['ok'], isTrue);
      final call = db.calls.firstWhere(
        (c) => c.$1.contains('FROM video_tag WHERE tag_name = ?'),
      );
      expect(call.$2, contains('中文字幕'));
    });

    test('works 无参数回 ok:false', () async {
      final service = _service(_FakeDb());
      final result = await service.handle({'op': 'works'});
      expect(result['ok'], isFalse);
    });

    test('actresses：计数走 index_categories、按计数倒序', () async {
      final db = _FakeDb();
      final service = _service(db);
      final result = await service.handle({'op': 'actresses', 'page': 1});
      expect(result['ok'], isTrue);
      final actresses = result['actresses'] as List;
      expect(actresses.first['name'], '演员甲');
      expect(actresses.first['count'], 42);
      final call = db.calls.firstWhere(
        (c) => c.$1.contains('FROM actresses a'),
      );
      expect(call.$1, contains("category_type = 'actress'"));
      expect(call.$1, contains('cnt DESC'));
    });

    test('tags：走 index_categories 的 tag 行、上限 120', () async {
      final db = _FakeDb();
      final service = _service(db);
      final result = await service.handle({'op': 'tags'});
      expect(result['ok'], isTrue);
      final tags = result['tags'] as List;
      expect(tags.first['name'], '中文字幕');
      final call = db.calls.firstWhere(
        (c) => c.$1.contains('FROM index_categories'),
      );
      expect(call.$1, contains('LIMIT 120'));
      expect(call.$2, contains('少女萝莉'));
    });

    test('detail：多线路去重组装 + 女优/标签/相关作品', () async {
      final db = _FakeDb();
      final service = _service(db);
      final result = await service.handle({'op': 'detail', 'vodId': 'SSIS-001'});
      expect(result['ok'], isTrue);
      final item = result['item'] as Map;
      expect(item['vodId'], 'ssis-001');
      final playUrls = item['playUrls'] as List;
      expect(playUrls, [
        'https://v.hersav.me/h/h.m3u8',
        'https://cdn.test/alt.m3u8',
      ]);
      expect(item['play'], 'https://v.hersav.me/h/h.m3u8');
      expect(item['actresses'], ['演员甲', '演员乙']);
      expect(item['tags'], ['中文字幕']);
      expect(item['related'], isA<List>());
    });

    test('detail：库里没有的番号回 ok:false', () async {
      final service = _service(_FakeDb());
      final result = await service.handle({'op': 'detail', 'vodId': 'gone-001'});
      expect(result['ok'], isFalse);
    });

    test('未知 op 回 ok:false', () async {
      final service = _service(_FakeDb());
      final result = await service.handle({'op': 'nope'});
      expect(result['ok'], isFalse);
    });
  });
}
