// JavDB 客户端对齐 jar 版路线回归测试（2026-11-27）：
// ①主域名 apidd.spthgb.com + POST api/v1/sessions 开会话
// 换令牌（base85 字段 + multipart），请求带 Authorization、
// 签名头全小写 jdsignature；信封 success≠1 清令牌再试一
// 次开会话并重试一次；开会话是机会性尝试——失败/超时不
// 挡数据请求（jar 版 api() 源码实证：不看开会话成败、没
// 令牌只带签名头照常取数），信封失败原文不外抛、只给固
// 定中文说明；
// ②详情走 api/v4/movies/{id} 取 data.movie（旧 v1 实测
// 404）；搜索参数名 q；duration 单位是分钟；
// ③图片：spfcas 图床同样是 XOR 图；
// ④磁力不在 v4 详情里，真来源是 api/v1/movies/{id}/magnets
// （jar 版实证），照 jar 版打分排序去重。
// 真接口在本机出口连不上：只验请求形状与解析，手机终验为准。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_http.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_javdb_api.dart';
import 'package:fqapp/actress/actress_online_sources.dart';

String _envelope(Object? data) => jsonEncode({'success': 1, 'data': data});

/// 假 ContentHttp：记录每次请求的 URL/头/正文，按脚本回信封。
class _FakeHttp extends ContentHttp {
  _FakeHttp({required this.onGet, required this.onPost});

  final String Function(String url) onGet;
  final String Function(String url, String body) onPost;
  final calls = <String>[];
  final getHeaders = <Map<String, String>>[];

  @override
  Future<String> get(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = contentTimeout,
  }) async {
    calls.add('GET $url');
    getHeaders.add(headers);
    return onGet(url);
  }

  @override
  Future<String> postRaw(
    String url,
    String body, {
    Map<String, String> headers = const {},
    Duration timeout = contentTimeout,
  }) async {
    calls.add('POST $url');
    expect(headers['Content-Type'], startsWith('multipart/form-data'));
    return onPost(url, body);
  }
}

void main() {
  test('签名：格式与 MD5 向量对得上', () {
    expect(
      javdbSignature(1700000000),
      '1700000000.lpw6vgqzsp.dacaffcd8b4e1b35c2752f065e906f3a',
    );
  });

  group('base85 解码（jar 版 b85decode 向量）', () {
    test('整组与尾组都对得上独立实现', () {
      expect(javdbB85Decode('Xk~0{Zv'), 'hello');
      expect(javdbB85Decode('VPX'), 'ab');
      expect(javdbB85Decode(''), '');
    });
  });

  test('图片解密：魔数图原样、加密图首字节异或还原；spfcas 认图床', () {
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0x10, 0x20]);
    expect(javdbDecryptImageBytes(jpeg), jpeg);
    const key = 0x5A;
    final plain = [0xFF, 0xD8, 0xFF, 0x00, 0x42];
    final encrypted = Uint8List.fromList([
      key,
      for (final b in plain) b ^ key,
    ]);
    expect(javdbDecryptImageBytes(encrypted), plain);
    expect(javdbIsImageUrl('https://tp.spfcas.com/covers/m1.jpg'), isTrue);
    expect(javdbIsImageUrl('https://c0.jdbstatic.com/covers/m1.jpg'), isTrue);
    expect(javdbIsImageUrl('https://img.example.com/m1.jpg'), isFalse);
  });

  group('开会话 + v4 详情', () {
    test('先开会话拿令牌、success≠1 清令牌再试一次；头名小写+带令牌', () async {
      var detailAttempts = 0;
      final http = _FakeHttp(
        onGet: (url) {
          detailAttempts++;
          if (detailAttempts == 1) {
            return jsonEncode({
              'success': 0,
              'action': 'JWTVerificationError',
              'message': '請登錄帳號',
            });
          }
          return _envelope({
            'movie': {
              'id': 'm1',
              'number': 'SAME-711',
              'score': 4.2,
              'cover_url': 'https://tp.spfcas.com/covers/m1.jpg',
              'origin_title': '原名タイトル',
              'tags': [
                {'name': '剧情'},
                {'name': '单体作品'},
              ],
              'actors': [
                {
                  'name': '演员甲',
                  'avatar_url': 'https://c0.jdbstatic.com/avatars/a.jpg',
                },
                {
                  'name': '演员乙',
                  'cover_url': 'https://c0.jdbstatic.com/avatars/b.jpg',
                },
              ],
              'preview_images': [
                {'large_url': 'https://tp.spfcas.com/samples/s1.jpg'},
                {'thumb_url': 'https://tp.spfcas.com/samples/s2.jpg'},
              ],
              'relative_movies': [
                {'id': 'm2', 'number': 'SAME-712', 'title': '相关作品'},
              ],
              'actor_movies': [
                {'id': 'm3', 'number': 'SAME-700', 'title': '她还演过'},
              ],
            },
          });
        },
        onPost: (url, body) {
          expect(body, contains('name="username"'));
          expect(body, contains('name="password"'));
          expect(body, contains('name="device_uuid"'));
          expect(body, contains('name="app_version_number"'));
          expect(body, contains('1.9.35'));
          return jsonEncode({
            'success': 1,
            'data': {'token': 'test-token-123456'},
          });
        },
      );
      final client = JavdbApiClient(http: http);
      final extra = await client.movieExtra('m1');
      // 顺序：开会话 → 详情(被拒) → 再开会话 → 详情(成功)，全走主域名。
      expect(http.calls[0], 'POST https://apidd.spthgb.com/api/v1/sessions');
      expect(http.calls[1], contains('https://apidd.spthgb.com/api/v4/movies/m1'));
      expect(http.calls[2], startsWith('POST '));
      expect(http.calls[3], contains('api/v4/movies/m1'));
      // 请求头：签名头名全小写、带 Authorization、UA 照 jar 版。
      final lastHeaders = http.getHeaders.last;
      expect(lastHeaders.containsKey('jdsignature'), isTrue);
      expect(lastHeaders.containsKey('jdSignature'), isFalse);
      expect(lastHeaders['jdsignature'], matches(RegExp(r'^\d+\.lpw6vgqzsp\.[0-9a-f]{32}$')));
      expect(lastHeaders['Authorization'], 'Bearer test-token-123456');
      expect(lastHeaders['User-Agent'], 'Dart/3.5 (dart:io)');
      // v4 解析：data.movie 里的演员/剧照/封面/原名/标签/两排推荐。
      expect(extra.actors, hasLength(2));
      expect(extra.actors[0].avatarUrl, contains('avatars/a.jpg'));
      // 头像 avatar_url 空时落 cover_url（jar 版取值顺序）。
      expect(extra.actors[1].avatarUrl, contains('avatars/b.jpg'));
      expect(extra.stills, [
        'https://tp.spfcas.com/samples/s1.jpg',
        'https://tp.spfcas.com/samples/s2.jpg',
      ]);
      expect(extra.poster, 'https://tp.spfcas.com/covers/m1.jpg');
      expect(extra.score, '4.2');
      expect(extra.originTitle, '原名タイトル');
      expect(extra.tags, ['剧情', '单体作品']);
      expect(extra.relativeMovies.single.number, 'SAME-712');
      expect(extra.actorMovies.single.number, 'SAME-700');
    });

    test('开会话失败不挡数据接口（搜索照常解析、参数名 q）', () async {
      String? seenUrl;
      final client = JavdbApiClient(
        fetch: (url) async {
          seenUrl = url;
          return _envelope({
            'movies': [
              {'id': 'm1', 'number': 'ADN-821', 'title': '标题', 'duration': 150},
            ],
          });
        },
        post: (url, body, contentType) async =>
            jsonEncode({'success': 0, 'message': 'bad credentials'}),
      );
      final movies = await client.searchMovies('ADN-821');
      expect(seenUrl, contains('api/v2/search?q=ADN-821&page=1'));
      expect(seenUrl, isNot(contains('keyword=')));
      expect(movies.single.number, 'ADN-821');
      // duration 单位是分钟：150 就是 150 分钟，不许再除 60。
      expect(movies.single.durationMinutes, 150);
    });
  });

  group('开会话不挡数据（2026-11-27 纠正口径）', () {
    test('开会话 POST 抛网络异常：搜索照常出数据', () async {
      final client = JavdbApiClient(
        fetch: (url) async => _envelope({
          'movies': [
            {'id': 'm1', 'number': 'ADN-821', 'title': '标题'},
          ],
        }),
        post: (url, body, contentType) async =>
            throw Exception('connection reset'),
      );
      final movies = await client.searchMovies('ADN-821');
      expect(movies.single.number, 'ADN-821');
    });

    test('开会话 POST 挂住不回：到上限就放弃、搜索照常出数据', () async {
      final client = JavdbApiClient(
        fetch: (url) async => _envelope({
          'movies': [
            {'id': 'm1', 'number': 'ADN-821', 'title': '标题'},
          ],
        }),
        post: (url, body, contentType) => Completer<String>().future,
        sessionTimeout: const Duration(milliseconds: 300),
      );
      final watch = Stopwatch()..start();
      final movies = await client.searchMovies('ADN-821');
      expect(movies.single.number, 'ADN-821');
      // 没有 4 秒默认上限的拖累：会话尝试 300 毫秒到点即弃。
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('信封失败：服务端原文不外抛，只给固定中文说明', () async {
      // 拿不到令牌（开会话被拒）+ 数据接口回授权类失败。
      final noToken = JavdbApiClient(
        fetch: (url) async => jsonEncode({
          'success': 0,
          'action': 'JWTVerificationError',
          'message': '請登錄帳號',
        }),
        post: (url, body, contentType) async =>
            jsonEncode({'success': 0, 'message': 'bad credentials'}),
      );
      await expectLater(
        noToken.movieExtra('m1'),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.message,
            'message',
            allOf(
              equals('此内容需要接口授权，当前拿不到授权'),
              isNot(contains('請登錄帳號')),
            ),
          ),
        ),
      );
      // 有令牌也被拒：给通用中文说明，同样不带原文。
      final withToken = JavdbApiClient(
        fetch: (url) async => jsonEncode({
          'success': 0,
          'message': '請登錄帳號',
        }),
        post: (url, body, contentType) async => jsonEncode({
          'success': 1,
          'data': {'token': 'test-token-123456'},
        }),
      );
      await expectLater(
        withToken.movieExtra('m1'),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.message,
            'message',
            allOf(
              equals('JavDB 接口拒绝了请求'),
              isNot(contains('請登錄帳號')),
            ),
          ),
        ),
      );
    });

    test('补充隔离：详情接口单独失败，搜索命中与磁力照常回', () async {
      final client = JavdbApiClient(
        fetch: (url) async {
          if (url.contains('api/v4/movies/')) {
            return jsonEncode({'success': 0, 'message': '需要授權'});
          }
          if (url.contains('/magnets')) {
            return _envelope({
              'magnets': [
                {
                  'hash': 'dddddddddddddddddddddddddddddddddddddddd',
                  'name': 'SIGL-020.torrent',
                  'size': 2048,
                },
              ],
            });
          }
          return _envelope({
            'movies': [
              {'id': 'm1', 'number': 'SIGL-020', 'title': '本片'},
            ],
          });
        },
      );
      final result = await actressJavdbSupplement(
        code: 'SIGL-020',
        client: client,
      );
      expect(result, isNotNull);
      expect(result!.movie.number, 'SIGL-020');
      // 详情补充缺席（空），磁力照常、不被拖垮。
      expect(result.extra.score, '');
      expect(result.magnets, hasLength(1));
    });
  });

  group('磁力（真来源 api/v1/movies/{id}/magnets）', () {
    test('排序去重 + 字段形态（大小/日期/高清/字幕）', () async {
      String? seenUrl;
      final client = JavdbApiClient(
        fetch: (url) async {
          seenUrl = url;
          return _envelope({
            'magnets': [
              {
                'hash': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'name': '低清版',
                'size': 800,
                'created_at': '2026-11-20',
                'seeders': 2,
              },
              {
                'hash': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'name': '同 hash 高做种版',
                'size': 800,
                'created_at': '2026-11-20',
                'seeders': 50,
              },
              {
                'hash': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
                'name': 'SIGL-020 高清版',
                'size': 5390,
                'created_at': '2026-11-26',
                'hd': true,
                'cnsub': true,
                'seeders': 10,
              },
              {'name': '无 hash 无链接的坏行', 'size': 100},
            ],
          });
        },
      );
      final magnets = await client.movieMagnets('m1');
      expect(seenUrl, contains('api/v1/movies/m1/magnets'));
      // 同 hash 去重只留一条 + 坏行丢弃 = 2 条；做种高的排前。
      expect(magnets, hasLength(2));
      expect(magnets[0].name, '同 hash 高做种版');
      expect(
        magnets[0].url,
        startsWith('magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
      );
      final hd = magnets[1];
      expect(hd.name, 'SIGL-020 高清版');
      expect(hd.sizeLabel, '5.26 GB');
      expect(hd.dateLabel, '2026-11-26');
      expect(hd.hd, isTrue);
      expect(hd.cnsub, isTrue);
    });

    test('现成磁力链接照原样、大小字符串照原样', () async {
      final client = JavdbApiClient(
        fetch: (url) async => _envelope({
          'magnets': [
            {
              'magnet':
                  'magnet:?xt=urn:btih:cccccccccccccccccccccccccccccccccccccccc&dn=x',
              'name': '直给链接',
              'size': '1.2 GB',
            },
          ],
        }),
      );
      final magnets = await client.movieMagnets('m1');
      expect(magnets.single.url, contains('dn=x'));
      expect(magnets.single.sizeLabel, '1.2 GB');
      expect(magnets.single.dateLabel, '');
    });
  });

  group('按番号补充（actressJavdbSupplement）', () {
    JavdbApiClient clientWith({
      required List<Map<String, Object?>> searchMovies,
      Map<String, Object?>? detailMovie,
      List<Map<String, Object?>> magnets = const [],
    }) {
      return JavdbApiClient(
        fetch: (url) async {
          if (url.contains('/magnets')) {
            return _envelope({'magnets': magnets});
          }
          if (url.contains('api/v4/movies/')) {
            return _envelope({'movie': detailMovie ?? {}});
          }
          return _envelope({'movies': searchMovies});
        },
      );
    }

    test('精确命中才认：近似番号不冒充，命中带回详情+磁力', () async {
      final client = clientWith(
        searchMovies: [
          {'id': 'mx', 'number': 'SIGL-021', 'title': '别片'},
          {
            'id': 'm1',
            'number': 'SIGL-020',
            'title': '本片',
            'preview_images': [
              {'large_url': 'https://tp.spfcas.com/samples/p1.jpg'},
            ],
          },
        ],
        detailMovie: {'score': '8.6', 'score_count': 321},
        magnets: [
          {
            'hash': 'dddddddddddddddddddddddddddddddddddddddd',
            'name': 'SIGL-020.torrent',
            'size': 2048,
          },
        ],
      );
      final result = await actressJavdbSupplement(
        code: 'sigl-020',
        client: client,
      );
      expect(result, isNotNull);
      expect(result!.movie.id, 'm1');
      expect(result.extra.score, '8.6');
      expect(result.extra.scoreCount, 321);
      // 详情没给剧照时，搜索信封的 preview_images 兜底。
      expect(result.movie.previewImages, [
        'https://tp.spfcas.com/samples/p1.jpg',
      ]);
      expect(result.magnets.single.sizeLabel, '2 GB');
    });

    test('搜不到精确命中回 null；评分人数 reviews_count 兜底', () async {
      final miss = await actressJavdbSupplement(
        code: 'sigl-999',
        client: clientWith(
          searchMovies: [
            {'id': 'mx', 'number': 'SIGL-021', 'title': '别片'},
          ],
        ),
      );
      expect(miss, isNull);
      final hit = await actressJavdbSupplement(
        code: 'SIGL-020',
        client: clientWith(
          searchMovies: [
            {'id': 'm1', 'number': 'SIGL-020', 'title': '本片'},
          ],
          detailMovie: {'score': 7.5, 'reviews_count': 61},
        ),
      );
      expect(hit!.extra.scoreCount, 61);
      // actressCodeKey 归一仍是补充的匹配口径。
      expect(actressCodeKey('sigl-020'), 'SIGL020');
    });
  });
}
