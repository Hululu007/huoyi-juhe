// 通用读库层（2026-11-20）：字段名归一化与打分、播放地址取值容差、
// 表分类、手动映射存取。纯函数测试，不碰数据库。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_generic_db.dart';

void main() {
  group('字段名归一化与打分', () {
    test('归一化：全小写、去下划线/中划线/空格', () {
      expect(normalizeDbFieldName('Vod_Name'), 'vodname');
      expect(normalizeDbFieldName('play-URL'), 'playurl');
      expect(normalizeDbFieldName(' 标题 '), '标题');
      expect(normalizeDbFieldName('VIDEO_TITLE'), 'videotitle');
    });

    test('女优库字段走精确全名', () {
      expect(roleForColumn('vod_name')?.$1, GenericDbRole.title);
      expect(roleForColumn('vod_pic')?.$1, GenericDbRole.cover);
      expect(roleForColumn('vod_play_url')?.$1, GenericDbRole.playUrl);
      expect(roleForColumn('vod_actor')?.$1, GenericDbRole.actress);
      expect(roleForColumn('vod_code')?.$1, GenericDbRole.code);
      expect(roleForColumn('type_name')?.$1, GenericDbRole.category);
      expect(roleForColumn('vod_pubdate')?.$1, GenericDbRole.date);
    });

    test('大小写与前后缀放宽：Video_Title、PLAY_URL、Cover_URL、ActorName', () {
      expect(roleForColumn('Video_Title')?.$1, GenericDbRole.title);
      expect(roleForColumn('PLAY_URL')?.$1, GenericDbRole.playUrl);
      expect(roleForColumn('Cover_URL')?.$1, GenericDbRole.cover);
      expect(roleForColumn('ActorName')?.$1, GenericDbRole.actress);
    });

    test('关键词打分：含 m3u8/video 当播放地址，含 pic/thumb 当封面', () {
      expect(roleForColumn('m3u8')?.$1, GenericDbRole.playUrl);
      expect(roleForColumn('video')?.$1, GenericDbRole.playUrl);
      expect(roleForColumn('video_path')?.$1, GenericDbRole.playUrl);
      expect(roleForColumn('thumb')?.$1, GenericDbRole.cover);
      expect(roleForColumn('poster_url')?.$1, GenericDbRole.cover);
      expect(roleForColumn('imgurl')?.$1, GenericDbRole.cover);
    });

    test('中文同义词：片名/海报/播放地址/演员/番号/类别/时间', () {
      expect(roleForColumn('片名')?.$1, GenericDbRole.title);
      expect(roleForColumn('海报')?.$1, GenericDbRole.cover);
      expect(roleForColumn('播放地址')?.$1, GenericDbRole.playUrl);
      expect(roleForColumn('演员')?.$1, GenericDbRole.actress);
      expect(roleForColumn('番号')?.$1, GenericDbRole.code);
      expect(roleForColumn('类别')?.$1, GenericDbRole.category);
      expect(roleForColumn('时间')?.$1, GenericDbRole.date);
    });

    test('认不出的不猜：description/status/remark 返回 null', () {
      expect(roleForColumn('description'), isNull);
      expect(roleForColumn('status'), isNull);
      expect(roleForColumn('remark'), isNull);
      expect(roleForColumn(''), isNull);
    });

    test('typename 归分类不归标题', () {
      expect(roleForColumn('type_name')?.$1, GenericDbRole.category);
      expect(roleForColumn('typename')?.$1, GenericDbRole.category);
    });

    test('同角色多列留得分最高的', () {
      final schema = classifyGenericTables({
        'videos': ['id', 'mypic', 'cover', 'title', 'url'],
      });
      // cover（精确全名 10 分）高于 mypic（关键词 pic 3 分）。
      expect(schema.worksTable?.columnFor(GenericDbRole.cover), 'cover');
    });
  });

  group('播放地址取值容差', () {
    test('正片\$地址取 \$ 后面的真地址', () {
      expect(extractPlayUrl('正片\$https://x/1.m3u8'), 'https://x/1.m3u8');
      expect(extractPlayUrl('标题\$https://x/2.mp4'), 'https://x/2.mp4');
    });

    test('裸地址原样返回', () {
      expect(extractPlayUrl('https://x/1.m3u8'), 'https://x/1.m3u8');
    });

    test('JSON 数组取第一个', () {
      expect(
        extractPlayUrl('["https://a/1.m3u8", "https://b/2.m3u8"]'),
        'https://a/1.m3u8',
      );
    });

    test('JSON 对象取 url 键', () {
      expect(
        extractPlayUrl('{"url": "https://a/1.m3u8"}'),
        'https://a/1.m3u8',
      );
    });

    test('多个地址用 \$\$\$ / # 隔开取第一个像地址的', () {
      expect(
        extractPlayUrl('https://a/1.m3u8\$\$\$https://b/2.m3u8'),
        'https://a/1.m3u8',
      );
      expect(
        extractPlayUrl('标清#https://a/1.m3u8#高清#https://b/2.m3u8'),
        'https://a/1.m3u8',
      );
    });

    test('空值返回空串', () {
      expect(extractPlayUrl(null), '');
      expect(extractPlayUrl(''), '');
      expect(extractPlayUrl('   '), '');
    });

    test('List 值取第一个能播的', () {
      expect(extractPlayUrl(['', 'https://a/1.m3u8']), 'https://a/1.m3u8');
    });
  });

  group('封面取值容差', () {
    test('完整地址原样返回', () {
      expect(resolveCoverUrl('https://x/a.jpg'), 'https://x/a.jpg');
    });

    test('// 开头补 https:', () {
      expect(resolveCoverUrl('//x/a.jpg'), 'https://x/a.jpg');
    });

    test('/ 开头有 base 拼完整地址，没 base 原样返回', () {
      expect(
        resolveCoverUrl('/img/a.jpg', baseUrl: 'https://site.com/p/1'),
        'https://site.com/img/a.jpg',
      );
      expect(resolveCoverUrl('/img/a.jpg'), '/img/a.jpg');
    });

    test('相对路径原样返回', () {
      expect(resolveCoverUrl('img/a.jpg'), 'img/a.jpg');
    });
  });

  group('表分类', () {
    test('同时有标题与播放地址的是作品表', () {
      final schema = classifyGenericTables({
        'videos': [
          'id',
          'video_title',
          'video_url',
          'cover_pic',
          'actor_name',
        ],
        'actors': ['id', 'name', 'avatar'],
      });
      expect(schema.worksTable?.table, 'videos');
      expect(
        schema.worksTable?.columnFor(GenericDbRole.title),
        'video_title',
      );
      expect(schema.worksTable?.columnFor(GenericDbRole.playUrl), 'video_url');
      expect(schema.worksTable?.columnFor(GenericDbRole.cover), 'cover_pic');
      expect(
        schema.worksTable?.columnFor(GenericDbRole.actress),
        'actor_name',
      );
      expect(schema.personsTable?.table, 'actors');
    });

    test('字段名差很多的库：中文列名也能认', () {
      final schema = classifyGenericTables({
        '影片': ['编号', '片名', '播放地址', '海报', '演员', '类别'],
      });
      expect(schema.worksTable?.table, '影片');
      expect(schema.worksTable?.columnFor(GenericDbRole.title), '片名');
      expect(schema.worksTable?.columnFor(GenericDbRole.playUrl), '播放地址');
      expect(schema.worksTable?.columnFor(GenericDbRole.cover), '海报');
      expect(schema.worksTable?.columnFor(GenericDbRole.actress), '演员');
      expect(schema.worksTable?.columnFor(GenericDbRole.category), '类别');
    });

    test('认不出的表进未识别，不静默丢', () {
      final schema = classifyGenericTables({
        'videos': ['id', 'title', 'url'],
        'mystery': ['foo', 'bar'],
      });
      expect(schema.worksTable?.table, 'videos');
      expect(schema.unmappedTables.map((t) => t.table), ['mystery']);
    });

    test('没有作品表时 worksTable 为 null', () {
      final schema = classifyGenericTables({
        'actors': ['id', 'name'],
      });
      expect(schema.worksTable, isNull);
      expect(schema.personsTable?.table, 'actors');
    });
  });

  group('手动映射', () {
    test('指定标题与播放地址后成为作品表', () {
      final schema = classifyGenericTables({
        'data': ['a', 'b', 'c'],
      });
      expect(schema.worksTable, isNull);
      final next = schema.withManualMapping(
        table: 'data',
        columns: {GenericDbRole.title: 'a', GenericDbRole.playUrl: 'b'},
      );
      expect(next.worksTable?.table, 'data');
      expect(next.manualTable, 'data');
    });

    test('缺必填角色不改', () {
      final schema = classifyGenericTables({
        'data': ['a', 'b'],
      });
      final next = schema.withManualMapping(
        table: 'data',
        columns: {GenericDbRole.title: 'a'},
      );
      expect(identical(next, schema), isTrue);
    });

    test('映射按结构指纹存取，换指纹取不到', () async {
      final temp = Directory.systemTemp.createTempSync();
      addTearDown(() => temp.deleteSync(recursive: true));
      final store = GenericDbMappingStore(
        file: File('${temp.path}/字段映射.json'),
      );
      expect(await store.loadMapping('fp1'), isNull);
      await store.saveMapping('fp1', 'videos', {
        GenericDbRole.title: 'my_title',
        GenericDbRole.playUrl: 'my_url',
      });
      final loaded = await store.loadMapping('fp1');
      expect(loaded?.table, 'videos');
      expect(loaded?.columns[GenericDbRole.title], 'my_title');
      expect(loaded?.columns[GenericDbRole.playUrl], 'my_url');
      expect(await store.loadMapping('fp2'), isNull);
    });
  });

  group('GenericDbReader.test', () {
    test('给定作品列表、标题/番号 LIKE 搜、翻页', () async {
      final reader = GenericDbReader.test(
        works: const [
          GenericDbWork(
            id: 1,
            title: '测试一',
            code: 'ABC-1',
            playUrl: 'https://x/1.m3u8',
          ),
          GenericDbWork(
            id: 2,
            title: '测试二',
            code: 'XYZ-2',
            playUrl: 'https://x/2.m3u8',
          ),
        ],
      );
      expect(await reader.countWorks(), 2);
      expect((await reader.works(offset: 0, limit: 10)).length, 2);
      expect(
        (await reader.works(offset: 0, limit: 10, query: 'XYZ')).length,
        1,
      );
      expect((await reader.works(offset: 1, limit: 1)).first.title, '测试二');
      expect(await reader.countWorks(query: '测试一'), 1);
    });

    test('toJsonEntry 走 chaoliu 直通、可播', () {
      const work = GenericDbWork(
        id: 1,
        title: '测试一',
        code: 'ABC-1',
        playUrl: 'https://x/1.m3u8',
      );
      final entry = work.toJsonEntry();
      expect(entry.playable, isTrue);
      expect(entry.playUrl, 'https://x/1.m3u8');
      expect(entry.vodCode, 'ABC-1');
    });
  });

  group('多级分类与跨表关系（v28）', () {
    GenericDbTableMapping mappingOf(List<String> columns) {
      final mapped = <GenericDbRole, String>{};
      for (final column in columns) {
        final role = roleForColumn(column);
        if (role == null) continue;
        mapped.putIfAbsent(role.$1, () => column);
      }
      return GenericDbTableMapping(
        table: 'videos',
        columns: mapped,
        allColumns: columns,
        idColumn: 'id',
      );
    }

    test('分类维度列：category 排第一，标签/系列/地区也认，地址与封面列不算', () {
      final columns = categoryFacetColumns(
        mappingOf([
          'id',
          'title',
          'play_url',
          'cover_url',
          'type_name',
          'tags',
          'series',
          'area',
          'duration',
        ]),
      );
      expect(columns.first, 'type_name');
      expect(columns, contains('tags'));
      expect(columns, contains('series'));
      expect(columns, contains('area'));
      expect(columns, isNot(contains('play_url')));
      expect(columns, isNot(contains('cover_url')));
      expect(columns, isNot(contains('duration')));
    });

    test('分类维度：只有一个 category 列时不重复', () {
      final columns = categoryFacetColumns(
        mappingOf(['id', 'title', 'play_url', 'category']),
      );
      expect(columns, ['category']);
    });

    test('外键归一化：主表名 + id、常见 key 都认，裸 id 跳过', () {
      expect(
        relationsFor(
          worksTable: 'movies',
          worksIdColumn: 'id',
          worksColumns: const ['id', 'title'],
          tables: const [
            GenericDbTableMapping(
              table: 'links',
              columns: {GenericDbRole.playUrl: 'url'},
              allColumns: ['id', 'movieId', 'url'],
              idColumn: 'id',
            ),
          ],
        ).length,
        1,
      );
      expect(
        relationsFor(
          worksTable: 'movies',
          worksIdColumn: 'id',
          worksColumns: const ['id', 'title'],
          tables: const [
            GenericDbTableMapping(
              table: 'stills',
              columns: {GenericDbRole.cover: 'pic'},
              allColumns: ['id', 'name', 'pic'],
              idColumn: 'id',
            ),
          ],
        ),
        isEmpty,
      );
    });

    test('GenericDbWork.copyWith 只换地址与封面', () {
      const work = GenericDbWork(
        id: 7,
        title: '标题',
        actress: '某人',
        code: 'ABC-123',
      );
      final next = work.copyWith(
        playUrl: 'https://cdn.example.com/a.m3u8',
        coverUrl: 'https://cdn.example.com/a.jpg',
      );
      expect(next.id, 7);
      expect(next.title, '标题');
      expect(next.actress, '某人');
      expect(next.code, 'ABC-123');
      expect(next.playable, isTrue);
      expect(next.coverUrl, 'https://cdn.example.com/a.jpg');
      expect(work.playUrl, isEmpty);
    });

    test('按人名查（测试注入）：归一化名字匹配、多女优行也能命中', () async {
      final reader = GenericDbReader.test(
        works: const [
          GenericDbWork(id: 1, title: 'A', actress: 'Boda Ye Yi'),
          GenericDbWork(id: 2, title: 'B', actress: '别人'),
        ],
      );
      final rows = await reader.worksForActress('bodayeyi');
      expect(rows.map((w) => w.id), [1]);
    });

    test('按番号查（测试注入）：分隔符差异不影响', () async {
      final reader = GenericDbReader.test(
        works: const [
          GenericDbWork(id: 1, title: 'A', code: 'JUL-893'),
          GenericDbWork(id: 2, title: 'B', code: 'SSIS-001'),
        ],
      );
      final rows = await reader.worksForCode('jul893');
      expect(rows.map((w) => w.id), [1]);
    });

    test('筛选参数进 WHERE：同列 OR、跨列 AND（测试注入按值过滤）', () async {
      final reader = GenericDbReader.test(
        works: const [
          GenericDbWork(id: 1, title: 'A', category: '剧情'),
          GenericDbWork(id: 2, title: 'B', category: '素人'),
        ],
      );
      final rows = await reader.works(
        offset: 0,
        limit: 10,
        query: '素人',
      );
      expect(rows.map((w) => w.id), [2]);
    });
  });

  group('分类（2026-11-22：外来库视频列表页顶部 chips）', () {
    GenericDbReader readerWithCategories() => GenericDbReader.test(
      works: const [
        GenericDbWork(id: 1, title: '有码一', code: 'A-1', category: '有码'),
        GenericDbWork(id: 2, title: '有码二', code: 'A-2', category: '有码'),
        GenericDbWork(id: 3, title: '无码一', code: 'B-1', category: '无码'),
        GenericDbWork(id: 4, title: '没分类', code: 'C-1', category: ''),
      ],
    );

    test('categories() 按分类分组、按数量倒序、空分类不进', () async {
      final reader = readerWithCategories();
      expect(await reader.categories(), [
        ('有码', 2),
        ('无码', 1),
      ]);
    });

    test('works()/countWorks() 按 category 筛，只留当前这个库该分类的行', () async {
      final reader = readerWithCategories();
      expect(await reader.countWorks(category: '有码'), 2);
      expect(await reader.countWorks(category: '无码'), 1);
      expect(await reader.countWorks(category: '欧美'), 0);
      final works = await reader.works(
        offset: 0,
        limit: 10,
        category: '有码',
      );
      expect(works.map((w) => w.title), ['有码一', '有码二']);
      // 分类筛与标题搜可叠加。
      expect(await reader.countWorks(category: '有码', query: '二'), 1);
    });

    test('没有分类的作品：categories() 回空，不编', () async {
      final reader = GenericDbReader.test(
        works: const [
          GenericDbWork(id: 1, title: '没分类', code: 'C-1'),
        ],
      );
      expect(await reader.categories(), isEmpty);
      expect(await reader.countWorks(), 1);
    });
  });
}

// 2026-11-28 v28 追加：多级分类筛选、跨表关系、按人名/番号查。
