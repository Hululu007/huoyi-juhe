// 片库详情页自动补全服务（JAV 路）回归测试：假 JavdbApiClient
//（fetch 注入，照 actress_javdb_jar_route_test.dart 先例）+
// 假 dbHandle（按 op 分发 sameCode/search/detail），验三路合
// 成、补不到不编造、单路抛错不拖垮、简介取长、番号提取。
// JavDB 本机真拉连不上是已知老账，只用假件验。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_javdb_api.dart';
import 'package:fqapp/actress/jav_code_meta.dart';
import 'package:fqapp/services/film_detail_fill.dart';

String _envelope(Object? data) => jsonEncode({'success': 1, 'data': data});

/// 假 JavDB 客户端：按 URL 分发搜索 / v4 详情 / 磁力三路信封。
JavdbApiClient _javdbClient({
  List<Map<String, Object?>> movies = const [],
  Map<String, Object?> detailMovie = const {},
  bool throwAll = false,
}) {
  return JavdbApiClient(
    fetch: (url) async {
      if (throwAll) throw Exception('network down');
      if (url.contains('/magnets')) return _envelope({'magnets': const []});
      if (url.contains('api/v4/movies/')) {
        return _envelope({'movie': detailMovie});
      }
      return _envelope({'movies': movies});
    },
  );
}

/// 完整命中的 JavDB 假件（番号 SIGL-020）。
JavdbApiClient _fullJavdbClient() => _javdbClient(
  movies: [
    {
      'id': 'm1',
      'number': 'SIGL-020',
      'title': '搜索标题',
      'release_date': '2024-01-02',
      'duration': 120,
      'score': '7.0',
      'cover_url': 'https://img.example/movie-cover.jpg',
      'preview_images': [
        {'large_url': 'https://img.example/still-movie.jpg'},
      ],
    },
  ],
  detailMovie: {
    'score': '8.6',
    'score_count': 321,
    'cover_url': 'https://img.example/extra-cover.jpg',
    'origin_title': '原題タイトル',
    'director_name': '导演甲',
    'maker_name': '制作商甲',
    'series_name': '系列甲',
    'tags': [
      {'name': '剧情'},
    ],
    'actors': [
      {'name': '演员甲', 'avatar_url': ''},
      {'name': '演员乙', 'avatar_url': 'https://img.example/avatar-b.jpg'},
    ],
    'preview_images': [
      {'large_url': 'https://img.example/still-extra.jpg'},
      // 与搜索信封重复的一张：合成时去重。
      {'large_url': 'https://img.example/still-movie.jpg'},
    ],
  },
);

/// 假本地库 handle：按 op 分发；内容可调，throwAll 时全抛错。
Future<Map<String, dynamic>> Function(Map<String, dynamic>) _dbHandle({
  String sameCodeContent = '同番号短简介',
  String detailContent = '这是一段明显更长的详情简介内容，用来验取长',
  bool throwAll = false,
}) {
  return (request) async {
    if (throwAll) throw Exception('db down');
    switch (request['op']) {
      case 'sameCode':
        return {
          'ok': true,
          'content': sameCodeContent,
          'avatars': [
            {'name': '演员甲', 'avatar': 'https://img.example/avatar-a-db.jpg'},
          ],
        };
      case 'search':
        return {
          'ok': true,
          'items': [
            {'vodId': 'SIGL-021', 'title': '别片'},
            // 小写 slug 与大写番号全等命中（大小写不敏感）。
            {'vodId': 'sigl-020', 'title': '本片'},
          ],
        };
      case 'detail':
        expect(request['vodId'], 'sigl-020');
        return {
          'ok': true,
          'item': {
            'vodId': 'sigl-020',
            'content': detailContent,
            'pic': 'https://img.example/db-cover.jpg',
            'tags': ['库标签'],
            'date': '2020-05-05',
          },
        };
      default:
        return {'ok': false, 'error': '未知 op'};
    }
  };
}

void main() {
  group('fillFilmDetailByCode', () {
    test('①三路合成一份：评分/日期/系列/制作商/导演/剧照/演员齐', () async {
      const meta = CodeMeta(
        code: 'SIGL-020',
        title: '',
        titleAlts: [],
        year: 2023,
        director: '',
        maker: '',
        female: ['演员丙'],
        male: [],
        femaleAvatars: ['https://img.example/avatar-c.jpg'],
      );
      final fill = await fillFilmDetailByCode(
        code: 'SIGL-020',
        javdbClient: _fullJavdbClient(),
        dbHandle: _dbHandle(),
        codeMeta: meta,
      );
      expect(fill.isEmpty, isFalse);
      expect(fill.code, 'SIGL-020');
      // 评分：extra 优先于 movie。
      expect(fill.score, '8.6');
      expect(fill.scoreCount, 321);
      // 封面：extra.poster 优先于 movie 与库封面。
      expect(fill.cover, 'https://img.example/extra-cover.jpg');
      // 日期：JavDB 优先于库 date 与元数据年份。
      expect(fill.releaseDate, '2024-01-02');
      expect(fill.durationText, '120 分钟');
      expect(fill.originTitle, '原題タイトル');
      // extraInfo 标签映射。
      expect(fill.series, '系列甲');
      expect(fill.maker, '制作商甲');
      expect(fill.director, '导演甲');
      // 标签：JavDB 优先于库标签。
      expect(fill.tags, ['剧情']);
      // 剧照：extra.stills + movie.previewImages 去重合成。
      expect(fill.stills, [
        'https://img.example/still-extra.jpg',
        'https://img.example/still-movie.jpg',
      ]);
      // 演员：JavDB 为主；演员甲空头像由同番号头像表补；
      // 元数据独有的演员丙追加在后。
      expect(fill.cast, hasLength(3));
      expect(fill.cast[0].name, '演员甲');
      expect(fill.cast[0].avatar, 'https://img.example/avatar-a-db.jpg');
      expect(fill.cast[1].name, '演员乙');
      expect(fill.cast[1].avatar, 'https://img.example/avatar-b.jpg');
      expect(fill.cast[2].name, '演员丙');
      expect(fill.cast[2].avatar, 'https://img.example/avatar-c.jpg');
      // 简介：detail 更长，取 detail。
      expect(fill.synopsis, contains('更长的详情简介'));
    });

    test('②补不到不编造：三路全空回 isEmpty、评分与日期为空', () async {
      final fill = await fillFilmDetailByCode(
        code: 'NOPE-999',
        javdbClient: _javdbClient(
          movies: [
            {'id': 'mx', 'number': 'NOPE-998', 'title': '别片'},
          ],
        ),
        dbHandle: (request) async => {
          'ok': true,
          'content': '',
          'avatars': const [],
          'items': const [],
        },
      );
      expect(fill.isEmpty, isTrue);
      expect(fill.score, '');
      expect(fill.scoreCount, 0);
      expect(fill.releaseDate, '');
      expect(fill.cover, '');
      expect(fill.cast, isEmpty);
      expect(fill.stills, isEmpty);
    });

    test('③单路抛错不拖垮其余两路', () async {
      // 本地库全抛错：JavDB 一路照常合成。
      final javdbOnly = await fillFilmDetailByCode(
        code: 'SIGL-020',
        javdbClient: _fullJavdbClient(),
        dbHandle: _dbHandle(throwAll: true),
      );
      expect(javdbOnly.score, '8.6');
      expect(javdbOnly.director, '导演甲');
      expect(javdbOnly.synopsis, '');
      // 演员甲头像无库可补，保持空（不编造）。
      expect(javdbOnly.cast[0].avatar, '');

      // JavDB 全抛错：本地库一路照常合成（简介/封面/日期/标签兜底）。
      final dbOnly = await fillFilmDetailByCode(
        code: 'SIGL-020',
        javdbClient: _javdbClient(throwAll: true),
        dbHandle: _dbHandle(),
      );
      expect(dbOnly.score, '');
      expect(dbOnly.synopsis, contains('更长的详情简介'));
      expect(dbOnly.cover, 'https://img.example/db-cover.jpg');
      expect(dbOnly.releaseDate, '2020-05-05');
      expect(dbOnly.tags, ['库标签']);
    });

    test('④sameCode 简介与 detail 简介取更长者', () async {
      final longerSameCode = await fillFilmDetailByCode(
        code: 'SIGL-020',
        javdbClient: _javdbClient(throwAll: true),
        dbHandle: _dbHandle(
          sameCodeContent: '同番号这一份简介写得非常非常长，明显超过详情那份',
          detailContent: '详情短简介',
        ),
      );
      expect(longerSameCode.synopsis, startsWith('同番号这一份'));

      final longerDetail = await fillFilmDetailByCode(
        code: 'SIGL-020',
        javdbClient: _javdbClient(throwAll: true),
        dbHandle: _dbHandle(),
      );
      expect(longerDetail.synopsis, contains('更长的详情简介'));
    });

    test('番号元数据兜底：导演/制作商空位与年份补位', () async {
      const meta = CodeMeta(
        code: 'SIGL-020',
        title: '',
        titleAlts: [],
        year: 2023,
        director: '元导演',
        maker: '元制作商',
        female: [],
        male: [],
      );
      final fill = await fillFilmDetailByCode(
        code: 'SIGL-020',
        javdbClient: _javdbClient(throwAll: true),
        dbHandle: (request) async =>
            {'ok': true, 'content': '', 'avatars': const [], 'items': const []},
        codeMeta: meta,
      );
      expect(fill.director, '元导演');
      expect(fill.maker, '元制作商');
      expect(fill.releaseDate, '2023');
    });
  });

  group('resolveFilmCode', () {
    test('⑤番号只在 remark 里时能提出', () {
      final code = resolveFilmCode(
        id: '12345',
        title: '普通标题没有番号',
        remark: '精彩影片 SSIS-001 高清版',
      );
      expect(code, 'SSIS-001');
    });

    test('⑤id 直取优先于 remark', () {
      final code = resolveFilmCode(
        id: 'json:somesite:abcd-123',
        title: '标题',
        remark: 'SSIS-001',
      );
      expect(code, 'ABCD-123');
    });

    test('⑤全无番号回空', () {
      expect(resolveFilmCode(id: 'x', title: '你好', remark: '世界'), '');
      expect(resolveFilmCode(id: '', title: ''), '');
    });
  });
}
