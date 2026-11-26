import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'actress_database.dart' show applyActressDbReadPragmas;
import 'actress_mytv_bind.dart';

/// 合并演员库页的本地女优库兜底查询：参数化只读 SQL 的形态。
/// 测试注入假实现，真机走 sqflite 独立只读连接。
typedef ActressLibRawQuery =
    Future<List<Map<String, Object?>>> Function(
      String sql, [
      List<Object?>? arguments,
    ]);

/// 库路径解析：回可读库文件的绝对路径；没有可用库回 null。
typedef ActressLibPathResolver = Future<String?> Function();

/// 合并演员库页（assets/actress_library.html）whos 板块的数据库
/// 兜底：在线 whos.tv 取不到/无结果时，网页经宿主桥落到这里查
/// 本地女优库。查询口径照《数据库兜底对接说明》：
///
/// - 操作集：list（latest / rank）、search、works（actress / tag）、
///   actresses、tags、detail，返回字段与页面协议一致；
/// - 分类只按 whos 官方五维组织（最新 / 排行榜 / 演员 / 标签 /
///   厂牌前缀），映射全在查询层做，库文件本体一字不改；库里的
///   主分类、类型名、cate 三套非官方名目不进分类栏；
/// - 硬线排除：类型名明确指向未成年题材的那一类，在所有查询里
///   整体过滤（只过滤结果，不删库数据）。
///
/// 库形态两种都走同一条路：路径由 [ActressMytvBind] 解析——
/// 安卓是 MYTV/db/女优库.db 直读（或 SAF 镜像落点），iOS 是
/// .sql 导入落成的私有库；本服务只认解析出的路径。开库纪律与
/// 原生库页同款：openDatabase 只读、不传 version、无
/// onCreate/onUpgrade、只读 PRAGMA 组（见
/// [applyActressDbReadPragmas]），独立连接（singleInstance:
/// false），不碰原生页的连接。库文件戳（路径+大小+mtime）变了
/// 就关连接、重开、清表缓存三件一起做，换库后不读旧连接。
class ActressLibraryDbFallback {
  ActressLibraryDbFallback({
    ActressLibPathResolver? pathResolver,
    Future<ActressLibRawQuery?> Function(String path)? opener,
  }) : _pathResolver = pathResolver ?? _resolveBoundDbPath,
       _opener = opener ?? _openReadOnlyAt;

  /// 进程级共享实例（桥每次调用复用同一连接）。
  static final ActressLibraryDbFallback shared = ActressLibraryDbFallback();

  final ActressLibPathResolver _pathResolver;
  final Future<ActressLibRawQuery?> Function(String path) _opener;

  ActressLibRawQuery? _query;
  String? _openStamp;
  Future<ActressLibRawQuery?>? _opening;
  Set<String>? _tables;

  /// 硬线排除名单：该类型名明确指向未成年题材，查询层整体不
  /// 返回（魔蚁侧同口径：1 个类型名、3,115 部）。
  static const List<String> excludedTypeNames = ['少女萝莉'];

  /// 默认路径解析：走 MYTV 绑定（安卓四路阶梯 / iOS 导入库都在
  /// 绑定层收敛），dbPath 为空 = 没有可用库。
  static Future<String?> _resolveBoundDbPath() async {
    try {
      final bind = await ActressMytvBind.instance.ensureBound();
      if (!bind.hasVideoDb || bind.dbPath.isEmpty) return null;
      return bind.dbPath;
    } catch (_) {
      return null;
    }
  }

  /// 默认开库：独立只读连接，开库纪律与原生库页一致。
  static Future<ActressLibRawQuery?> _openReadOnlyAt(String path) async {
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() == 0) return null;
    final db = await openDatabase(
      path,
      readOnly: true,
      singleInstance: false,
      onOpen: applyActressDbReadPragmas,
    );
    try {
      await db.rawQuery('SELECT COUNT(*) FROM sqlite_master');
    } catch (_) {
      await db.close();
      rethrow;
    }
    return (sql, [arguments]) => db.rawQuery(sql, arguments);
  }

  /// 文件戳：路径 + 大小 + 修改时间。取不到回 null（按未开处理）。
  static String? _stampOf(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final stat = file.statSync();
      return '$path|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    } catch (_) {
      return null;
    }
  }

  /// 拿到当前可用查询函数：未开则开；戳变则关旧开新。
  /// 测试注入 opener 时不开真库，戳记按路径常量处理。
  Future<ActressLibRawQuery?> _ensureQuery() async {
    final path = await _pathResolver();
    if (path == null || path.isEmpty) {
      _reset();
      return null;
    }
    final stamp = _stampOf(path) ?? path;
    if (_query != null && _openStamp == stamp) return _query;
    final opening = _opening;
    if (opening != null && _openStamp == stamp) return opening;
    _reset();
    _openStamp = stamp;
    final future = _opener(path);
    _opening = future;
    final query = await future;
    if (identical(_opening, future)) {
      _opening = null;
      _query = query;
      if (query == null) _openStamp = null;
    }
    return query;
  }

  void _reset() {
    _query = null;
    _opening = null;
    _openStamp = null;
    _tables = null;
    _columnCache.clear();
  }

  Future<Set<String>> _tableSet(ActressLibRawQuery query) async {
    final cached = _tables;
    if (cached != null) return cached;
    final rows = await query(
      "SELECT name FROM sqlite_master WHERE type IN ('table','view')",
    );
    return _tables = {for (final row in rows) row['name']?.toString() ?? ''};
  }

  /// 桥入口：按 op 分发。任何失败回 {ok:false, error}，不抛错。
  Future<Map<String, dynamic>> handle(Map<String, dynamic> params) async {
    try {
      final query = await _ensureQuery();
      if (query == null) {
        return {'ok': false, 'error': '本地女优库尚未就绪（未绑定或未导入）'};
      }
      final tables = await _tableSet(query);
      if (!tables.contains('videos')) {
        return {'ok': false, 'error': '本地女优库结构不完整（缺 videos 表）'};
      }
      final op = (params['op'] ?? '').toString();
      switch (op) {
        case 'list':
          return await _list(query, tables, params);
        case 'search':
          return await _search(query, tables, params);
        case 'works':
          return await _works(query, tables, params);
        case 'actresses':
          return await _actresses(query, tables, params);
        case 'tags':
          return await _tags(query, tables);
        case 'detail':
          return await _detail(query, tables, params);
        default:
          return {'ok': false, 'error': '未知 op：$op'};
      }
    } catch (error) {
      _reset();
      return {'ok': false, 'error': '本地女优库不可用：$error'};
    }
  }

  int _page(Map<String, dynamic> params) {
    final page = int.tryParse('${params['page'] ?? 1}') ?? 1;
    return page < 1 ? 1 : page;
  }

  int _limit(Map<String, dynamic> params, {int fallback = 24}) {
    final limit = int.tryParse('${params['limit'] ?? fallback}') ?? fallback;
    return limit < 1 ? 1 : (limit > 50 ? 50 : limit);
  }

  String get _exclusionSql =>
      '(v.type_name IS NULL OR v.type_name NOT IN '
      '(${List.filled(excludedTypeNames.length, '?').join(',')}))';

  List<Object?> get _exclusionArgs => [...excludedTypeNames];

  static const String _itemColumns =
      'v.vod_id AS vodId, v.title AS title, v.pic_url AS pic, '
      'v.m3u8_url AS play, v.vod_play_url AS playAlt, '
      'v.vod_pubdate AS date, v.type_name AS typeName';

  Map<String, dynamic> _itemRow(Map<String, Object?> row) {
    final vodId = row['vodId']?.toString() ?? '';
    return {
      'vodId': vodId,
      'title': row['title']?.toString() ?? '',
      'pic': row['pic']?.toString() ?? '',
      'play': row['play']?.toString() ?? '',
      'actress': row['actress']?.toString() ?? '',
      'code': vodId,
      'date': row['date']?.toString() ?? '',
      'typeName': row['typeName']?.toString() ?? '',
    };
  }

  /// 作品行查询：带第一女优名；m3u8_url 为空的行依次用播放地址
  /// 表第一条、vod_play_url 兜底出 play。
  Future<List<Map<String, dynamic>>> _videoRows(
    ActressLibRawQuery query,
    Set<String> tables, {
    required String where,
    required List<Object?> whereArgs,
    required String orderBy,
    List<Object?> orderArgs = const [],
    required int limit,
    required int offset,
  }) async {
    final actressExpr =
        tables.contains('video_actress') && tables.contains('actresses')
        ? '(SELECT a.name FROM video_actress va '
              'JOIN actresses a ON a.cate_id = va.cate_id '
              'WHERE va.vod_id = v.vod_id LIMIT 1) AS actress'
        : "'' AS actress";
    final rows = await query(
      'SELECT $_itemColumns, $actressExpr FROM videos v '
      'WHERE $where ORDER BY $orderBy LIMIT ? OFFSET ?',
      [...whereArgs, ...orderArgs, limit, offset],
    );
    final items = <Map<String, dynamic>>[];
    final altByIndex = <int, String>{};
    for (var i = 0; i < rows.length; i++) {
      items.add(_itemRow(rows[i]));
      altByIndex[i] = rows[i]['playAlt']?.toString() ?? '';
    }
    if (tables.contains('video_play_urls')) {
      for (var i = 0; i < items.length; i++) {
        if ((items[i]['play'] as String).isNotEmpty) continue;
        final urls = await query(
          'SELECT play_url FROM video_play_urls WHERE vod_id = ? '
          'ORDER BY rowid LIMIT 1',
          [items[i]['vodId']],
        );
        if (urls.isNotEmpty) {
          items[i]['play'] = urls.first['play_url']?.toString() ?? '';
        }
      }
    }
    for (var i = 0; i < items.length; i++) {
      if ((items[i]['play'] as String).isEmpty &&
          (altByIndex[i] ?? '').isNotEmpty) {
        items[i]['play'] = altByIndex[i];
      }
    }
    return items;
  }

  Future<Map<String, dynamic>> _list(
    ActressLibRawQuery query,
    Set<String> tables,
    Map<String, dynamic> params,
  ) async {
    final kind = (params['kind'] ?? 'latest').toString();
    if (kind == 'rank') {
      if (!tables.contains('video_ranking')) {
        return {'ok': false, 'error': '本地库无排行榜数据'};
      }
      final rows = await query(
        'SELECT $_itemColumns FROM video_ranking r '
        'JOIN videos v ON v.vod_id = r.vod_id '
        'WHERE $_exclusionSql ORDER BY r.rowid LIMIT 50',
        _exclusionArgs,
      );
      return {
        'ok': true,
        'items': [for (final row in rows) _itemRow(row)],
      };
    }
    final page = _page(params);
    final limit = _limit(params);
    // 厂牌前缀：vod_id 是小写番号 slug，前缀即厂牌码（官方五维
    // 之一，站上靠 /videos?q=<前缀> 实现，库侧走前缀匹配）。
    final prefix = (params['q'] ?? '').toString().trim().toLowerCase();
    var where = _exclusionSql;
    final args = [..._exclusionArgs];
    if (prefix.isNotEmpty) {
      where += " AND v.vod_id LIKE ? ESCAPE '\\'";
      args.add('${_escapeLike(prefix)}%');
    }
    final items = await _videoRows(
      query,
      tables,
      where: where,
      whereArgs: args,
      orderBy: 'v.vod_pubdate DESC, v.vod_id DESC',
      limit: limit,
      offset: (page - 1) * limit,
    );
    return {'ok': true, 'items': items};
  }

  Future<Map<String, dynamic>> _search(
    ActressLibRawQuery query,
    Set<String> tables,
    Map<String, dynamic> params,
  ) async {
    final raw = (params['q'] ?? '').toString().trim();
    if (raw.isEmpty) return {'ok': true, 'items': const []};
    final page = _page(params);
    final limit = _limit(params);
    final code = raw.toLowerCase();
    final contains = '%${_escapeLike(code)}%';
    final items = await _videoRows(
      query,
      tables,
      where: "$_exclusionSql AND (v.vod_id LIKE ? ESCAPE '\\' "
          "OR v.title LIKE ? ESCAPE '\\')",
      whereArgs: [..._exclusionArgs, contains, '%${_escapeLike(raw)}%'],
      // 番号精确 > 番号前缀 > 其余包含（接口说明口径）。
      orderBy: 'CASE WHEN v.vod_id = ? THEN 0 '
          "WHEN v.vod_id LIKE ? ESCAPE '\\' THEN 1 ELSE 2 END, "
          'v.vod_pubdate DESC, v.vod_id DESC',
      orderArgs: [code, '${_escapeLike(code)}%'],
      limit: limit,
      offset: (page - 1) * limit,
    );
    return {'ok': true, 'items': items};
  }

  Future<Map<String, dynamic>> _works(
    ActressLibRawQuery query,
    Set<String> tables,
    Map<String, dynamic> params,
  ) async {
    final page = _page(params);
    final limit = _limit(params);
    final actress = (params['actress'] ?? '').toString().trim();
    final tag = (params['tag'] ?? '').toString().trim();
    if (actress.isNotEmpty) {
      if (!tables.contains('video_actress') || !tables.contains('actresses')) {
        return {'ok': false, 'error': '本地库无演员关联数据'};
      }
      // 页面传女优名或 cate_id 都收；同名多 cate_id 行（库里同人
      // 常拆两行）按 name 一起命中，不漏作品。
      final items = await _videoRows(
        query,
        tables,
        where: '$_exclusionSql AND v.vod_id IN '
            '(SELECT va.vod_id FROM video_actress va '
            'JOIN actresses a ON a.cate_id = va.cate_id '
            'WHERE a.name = ? OR a.cate_id = ?)',
        whereArgs: [..._exclusionArgs, actress, actress],
        orderBy: 'v.vod_pubdate DESC, v.vod_id DESC',
        limit: limit,
        offset: (page - 1) * limit,
      );
      return {'ok': true, 'items': items};
    }
    if (tag.isNotEmpty) {
      if (!tables.contains('video_tag')) {
        return {'ok': false, 'error': '本地库无标签关联数据'};
      }
      final items = await _videoRows(
        query,
        tables,
        where: '$_exclusionSql AND v.vod_id IN '
            '(SELECT vod_id FROM video_tag WHERE tag_name = ?)',
        whereArgs: [..._exclusionArgs, tag],
        orderBy: 'v.vod_pubdate DESC, v.vod_id DESC',
        limit: limit,
        offset: (page - 1) * limit,
      );
      return {'ok': true, 'items': items};
    }
    return {'ok': false, 'error': 'works 需要 actress 或 tag 参数'};
  }

  Future<Map<String, dynamic>> _actresses(
    ActressLibRawQuery query,
    Set<String> tables,
    Map<String, dynamic> params,
  ) async {
    if (!tables.contains('actresses')) {
      return {'ok': false, 'error': '本地库无演员表'};
    }
    final page = _page(params);
    final limit = _limit(params);
    final q = (params['q'] ?? '').toString().trim();
    // 计数一律走 index_categories 索引表，不现算全表聚合。
    final hasCounts = tables.contains('index_categories');
    final countExpr = hasCounts
        ? '(SELECT ic.video_count FROM index_categories ic '
              "WHERE ic.category_type = 'actress' "
              'AND ic.category_name = a.name)'
        : null;
    final where = q.isEmpty ? '' : "WHERE a.name LIKE ? ESCAPE '\\'";
    final args = <Object?>[
      if (q.isNotEmpty) '%${_escapeLike(q)}%',
      limit,
      (page - 1) * limit,
    ];
    final rows = await query(
      'SELECT a.name AS name, a.avatar AS avatar'
      '${countExpr == null ? '' : ', $countExpr AS cnt'} '
      'FROM actresses a $where '
      'ORDER BY ${countExpr == null ? 'a.name ASC' : 'cnt DESC, a.name ASC'} '
      'LIMIT ? OFFSET ?',
      args,
    );
    return {
      'ok': true,
      'actresses': [
        for (final row in rows)
          {
            'name': row['name']?.toString() ?? '',
            'avatar': row['avatar']?.toString() ?? '',
            'count': (row['cnt'] as num?)?.toInt() ?? 0,
          },
      ],
    };
  }

  Future<Map<String, dynamic>> _tags(
    ActressLibRawQuery query,
    Set<String> tables,
  ) async {
    final excluded = excludedTypeNames;
    final placeholders = List.filled(excluded.length, '?').join(',');
    if (tables.contains('index_categories')) {
      final rows = await query(
        'SELECT category_name AS name, video_count AS cnt '
        'FROM index_categories '
        "WHERE category_type = 'tag' AND category_name NOT IN "
        '($placeholders) '
        'ORDER BY video_count DESC LIMIT 120',
        [...excluded],
      );
      return {
        'ok': true,
        'tags': [
          for (final row in rows)
            {
              'name': row['name']?.toString() ?? '',
              'count': (row['cnt'] as num?)?.toInt() ?? 0,
            },
        ],
      };
    }
    if (tables.contains('video_tag')) {
      final rows = await query(
        'SELECT tag_name AS name, COUNT(*) AS cnt FROM video_tag '
        'WHERE tag_name NOT IN ($placeholders) '
        'GROUP BY tag_name ORDER BY cnt DESC LIMIT 120',
        [...excluded],
      );
      return {
        'ok': true,
        'tags': [
          for (final row in rows)
            {
              'name': row['name']?.toString() ?? '',
              'count': (row['cnt'] as num?)?.toInt() ?? 0,
            },
        ],
      };
    }
    return {'ok': false, 'error': '本地库无标签数据'};
  }

  Future<Map<String, dynamic>> _detail(
    ActressLibRawQuery query,
    Set<String> tables,
    Map<String, dynamic> params,
  ) async {
    final vodId = (params['vodId'] ?? '').toString().trim().toLowerCase();
    if (vodId.isEmpty) return {'ok': false, 'error': '缺少 vodId'};
    final rows = await query(
      'SELECT $_itemColumns FROM videos v WHERE v.vod_id = ? '
      'AND $_exclusionSql LIMIT 1',
      [vodId, ..._exclusionArgs],
    );
    if (rows.isEmpty) return {'ok': false, 'error': '本地库无此番号'};
    final item = _itemRow(rows.first);

    // 播放地址以 video_play_urls 为准（多条 = 多线路），本表无行
    // 时退 m3u8_url / vod_play_url（接口说明口径）。
    final playUrls = <String>[];
    void addUrl(String url) {
      final trimmed = url.trim();
      if (trimmed.isNotEmpty && !playUrls.contains(trimmed)) {
        playUrls.add(trimmed);
      }
    }

    if (tables.contains('video_play_urls')) {
      final urls = await query(
        'SELECT play_url FROM video_play_urls WHERE vod_id = ? '
        'ORDER BY rowid LIMIT 8',
        [vodId],
      );
      for (final row in urls) {
        addUrl(row['play_url']?.toString() ?? '');
      }
    }
    addUrl(item['play'] as String);
    addUrl(rows.first['playAlt']?.toString() ?? '');
    if (playUrls.isNotEmpty) item['play'] = playUrls.first;

    var actresses = <String>[];
    var actressInfo = <Map<String, dynamic>>[];
    if (tables.contains('video_actress') && tables.contains('actresses')) {
      final names = await query(
        'SELECT a.name AS name FROM video_actress va '
        'JOIN actresses a ON a.cate_id = va.cate_id '
        'WHERE va.vod_id = ? ORDER BY a.name',
        [vodId],
      );
      actresses = [
        for (final row in names)
          if ((row['name']?.toString() ?? '').isNotEmpty)
            row['name'].toString(),
      ];
      // 演员头像（详情页演员区用）：actresses.avatar 列在才查，
      // 没有该列就只回名字、头像留空（详情页回落首字占位）。
      final actressCols = await _columnSet(query, 'actresses');
      if (actressCols.contains('avatar')) {
        final rows = await query(
          'SELECT a.name AS name, a.avatar AS avatar FROM video_actress va '
          'JOIN actresses a ON a.cate_id = va.cate_id '
          'WHERE va.vod_id = ? ORDER BY a.name',
          [vodId],
        );
        actressInfo = [
          for (final row in rows)
            if ((row['name']?.toString() ?? '').isNotEmpty)
              {
                'name': row['name'].toString(),
                'avatar': row['avatar']?.toString() ?? '',
              },
        ];
      } else {
        actressInfo = [
          for (final name in actresses) {'name': name, 'avatar': ''},
        ];
      }
    }

    // 简介（详情页用）：videos.content 列在才查，没有就留空，
    // 详情页不显示简介区（不编内容）。
    final videoCols = await _columnSet(query, 'videos');
    if (videoCols.contains('content')) {
      final rows = await query(
        'SELECT content AS content FROM videos WHERE vod_id = ? LIMIT 1',
        [vodId],
      );
      if (rows.isNotEmpty) {
        item['content'] = rows.first['content']?.toString() ?? '';
      }
    }

    var tags = <String>[];
    if (tables.contains('video_tag')) {
      final names = await query(
        'SELECT tag_name AS name FROM video_tag WHERE vod_id = ? '
        'ORDER BY tag_name LIMIT 20',
        [vodId],
      );
      tags = [
        for (final row in names)
          if ((row['name']?.toString() ?? '').isNotEmpty)
            row['name'].toString(),
      ];
    }

    var related = <Map<String, dynamic>>[];
    if (actresses.isNotEmpty) {
      related = await _videoRows(
        query,
        tables,
        where: '$_exclusionSql AND v.vod_id <> ? AND v.vod_id IN '
            '(SELECT va.vod_id FROM video_actress va '
            'JOIN actresses a ON a.cate_id = va.cate_id '
            'WHERE a.name = ?)',
        whereArgs: [..._exclusionArgs, vodId, actresses.first],
        orderBy: 'v.vod_pubdate DESC, v.vod_id DESC',
        limit: 12,
        offset: 0,
      );
    }
    if (related.isEmpty && (item['typeName'] as String).isNotEmpty) {
      related = await _videoRows(
        query,
        tables,
        where: '$_exclusionSql AND v.vod_id <> ? AND v.type_name = ?',
        whereArgs: [..._exclusionArgs, vodId, item['typeName']],
        orderBy: 'v.vod_pubdate DESC, v.vod_id DESC',
        limit: 12,
        offset: 0,
      );
    }

    return {
      'ok': true,
      'item': {
        ...item,
        'playUrls': playUrls,
        'actresses': actresses,
        'actressInfo': actressInfo,
        'tags': tags,
        'related': related,
      },
    };
  }

  /// 表的列名集（PRAGMA table_info）：给可选列（content /
  /// avatar 这类不是每版库都有的列）做在场判定，查不到/出
  /// 错按无列处理，绝不让可选列把主查询打挂。结果按表缓存，
  /// _reset 时一并清。
  final _columnCache = <String, Set<String>>{};

  Future<Set<String>> _columnSet(
    ActressLibRawQuery query,
    String table,
  ) async {
    final cached = _columnCache[table];
    if (cached != null) return cached;
    try {
      final rows = await query('PRAGMA table_info($table)');
      return _columnCache[table] = {
        for (final row in rows) row['name']?.toString() ?? '',
      };
    } catch (_) {
      return _columnCache[table] = const {};
    }
  }

  static String _escapeLike(String value) => value
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');
}
