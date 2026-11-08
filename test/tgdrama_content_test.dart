import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/tgdrama_content.dart';
import 'package:fqapp/services/tgdrama_hardcoded_channels.dart';
import 'package:fqapp/services/tgdrama_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 假服务：继承正式 TgdramaService，只覆盖约定里的两个成员
/// （ensureRunning / lastError），不启动真服务、不联网。
/// 用 extends 而不用 implements：正式类除约定成员外还有
/// healthCheck/authStatus 等实例成员，implements 要全补上，
/// extends 只覆盖要改的两个，正式类加成员也不会把测试打碎。
class _FakeService extends TgdramaService {
  bool running;
  String? error;
  int calls = 0;

  _FakeService({this.running = true, this.error});

  @override
  Future<bool> ensureRunning() async {
    calls++;
    return running;
  }

  @override
  String? get lastError => error;
}

TgdramaContentClient _client(
  MockClient transport, {
  _FakeService? service,
}) {
  return TgdramaContentClient(
    httpClient: transport,
    service: service ?? _FakeService(),
  );
}

MockClient _jsonClient(
  Map<String, Object?> responses, {
  void Function(http.BaseRequest request)? onRequest,
}) {
  return MockClient((request) async {
    onRequest?.call(request);
    final key = request.url.path;
    final body = responses[key];
    if (body == null) return http.Response('not found', 404);
    return http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
}

/// 假插件 HTTP 层：按（方法、路径、查询）分发；GET /api/chats 按
/// 调用次数依次回 chatsBodies（用完重复最后一个），模拟“同步前
/// 没有、同步后有”；POST /api/chats/sync 只记录 body，不真同步。
class _PluginTransport {
  _PluginTransport({
    this.chatsBodies = const [],
    this.showsPages = const {},
    this.showEpisodes = const {},
    this.episodeLines = const {},
  }) {
    client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'POST' && path == '/api/chats/sync') {
        final body = request.body;
        syncPosts.add(jsonDecode(body) as Map<String, Object?>);
        return _ok({'ok': true, 'syncing': true});
      }
      if (request.method == 'GET' && path == '/api/chats') {
        final index = chatsCalls < chatsBodies.length
            ? chatsCalls
            : chatsBodies.length - 1;
        chatsCalls++;
        if (chatsBodies.isEmpty) return _ok({'list': []});
        return _ok(chatsBodies[index]);
      }
      if (request.method == 'GET' && path == '/api/shows') {
        final page =
            int.tryParse(request.url.queryParameters['page'] ?? '1') ?? 1;
        return _ok(showsPages[page] ?? {'list': [], 'total': 0});
      }
      final showMatch = RegExp(r'^/api/shows/(\d+)$').firstMatch(path);
      if (request.method == 'GET' && showMatch != null) {
        final id = int.parse(showMatch.group(1)!);
        return _ok({
          'show': {'id': id},
          'episodes': showEpisodes[id] ?? [],
        });
      }
      final linesMatch = RegExp(
        r'^/api/episodes/(\d+)/lines$',
      ).firstMatch(path);
      if (request.method == 'GET' && linesMatch != null) {
        final id = int.parse(linesMatch.group(1)!);
        return _ok({'lines': episodeLines[id] ?? []});
      }
      return http.Response('not found', 404);
    });
  }

  /// GET /api/chats 依次回这些 body，用完后重复最后一个。
  final List<Map<String, Object?>> chatsBodies;

  /// /api/shows?page=N 的 body（缺页回空 list）。
  final Map<int, Map<String, Object?>> showsPages;

  /// /api/shows/{id} 的 episodes 数组。
  final Map<int, List<Map<String, Object?>>> showEpisodes;

  /// /api/episodes/{id}/lines 的 lines 数组。
  final Map<int, List<Map<String, Object?>>> episodeLines;

  late final MockClient client;
  var chatsCalls = 0;
  final syncPosts = <Map<String, Object?>>[];

  http.Response _ok(Object body) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  group('categories 标签解析', () {
    test('字符串数组成分类，末尾多一个「频道」分类', () async {
      final transport = _jsonClient({
        '/api/tags': ['动作', '爱情'],
      });
      addTearDown(transport.close);
      final categories = await _client(transport).categories();
      expect(
        categories.map((c) => c.id).toList(),
        ['动作', '爱情', 'channels'],
      );
      expect(
        categories.map((c) => c.name).toList(),
        ['动作', '爱情', '频道'],
      );
    });

    test('含 name/tag 的对象数组：id 取 tag、名取 name，末尾多「频道」', () async {
      final transport = _jsonClient({
        '/api/tags': [
          {'name': '动作', 'tag': 'action'},
          {'name': '爱情', 'tag': 'love'},
          {'name': '', 'tag': ''},
        ],
      });
      addTearDown(transport.close);
      final categories = await _client(transport).categories();
      expect(
        categories.map((c) => c.id).toList(),
        ['action', 'love', 'channels'],
      );
      expect(
        categories.map((c) => c.name).toList(),
        ['动作', '爱情', '频道'],
      );
    });

    test('空、失败、坏 JSON 都回 [全部]，不抛错、不加「频道」', () async {
      for (final transport in [
        _jsonClient({'/api/tags': []}),
        MockClient((_) async => http.Response('nope', 500)),
        MockClient((_) async => http.Response('{bad json', 200)),
      ]) {
        addTearDown(transport.close);
        final categories = await _client(transport).categories();
        expect(categories.map((c) => c.id).toList(), ['all']);
        expect(categories.map((c) => c.name).toList(), ['全部']);
      }
      final down = _FakeService(running: false, error: '本地服务未拉起');
      final transport = _jsonClient({'/api/tags': ['动作']});
      addTearDown(transport.close);
      final categories = await _client(transport, service: down).categories();
      expect(categories.map((c) => c.id).toList(), ['all']);
    });
  });

  group('频道分类与列表', () {
    Map<String, Object?> chatsBody() {
      return {
        'list': [
          {
            'tg_chat_id': -100111,
            'name': '剧场一号',
            'type': 'channel',
            'username': 'juchang1',
            'enabled': 1,
            'message_count': 128,
            'source_count': 56,
            'syncing': 0,
          },
          {
            'tg_chat_id': -100222,
            'name': '',
            'type': 'channel',
            'enabled': 0,
            'message_count': 0,
            'source_count': 3,
          },
          {
            'tg_chat_id': -100333,
            'name': '布尔开关',
            'type': 'group',
            'enabled': true,
            'syncing': true,
            'message_count': 5,
          },
          {'name': '缺 tg_chat_id 跳过', 'type': 'channel'},
          {
            'tg_chat_id': -100111,
            'name': '重复 id 跳过',
            'type': 'channel',
          },
        ],
        'enabled': 2,
        'syncing': 1,
      };
    }

    test('parseChats：id 带 channel: 前缀、名缺省回退、备注拼数', () {
      final items = TgdramaContentClient.parseChats(chatsBody());
      expect(items.length, 3);
      expect(items[0].id, 'channel:-100111');
      expect(items[0].title, '剧场一号');
      expect(items[0].cover, '');
      expect(items[0].remark, '128条消息 · 56个视频来源');
      expect(items[1].id, 'channel:-100222');
      expect(items[1].title, '频道 -100222');
      expect(items[1].remark, '3个视频来源 · 未启用');
      expect(items[2].id, 'channel:-100333');
      expect(items[2].title, '布尔开关');
      expect(items[2].remark, '5条消息 · group · 同步中');
    });

    test('parseChats 裸数组与 data 包一层也接受', () {
      final bare = TgdramaContentClient.parseChats([
        {'tg_chat_id': 7, 'name': '裸数组'},
      ]);
      expect(bare.length, 1);
      expect(bare.first.id, 'channel:7');
      final wrapped = TgdramaContentClient.parseChats({
        'data': {
          'list': [
            {'tg_chat_id': 8, 'name': '包一层'},
          ],
        },
      });
      expect(wrapped.length, 1);
      expect(wrapped.first.id, 'channel:8');
      expect(TgdramaContentClient.parseChats({'list': 'not a list'}), isEmpty);
      expect(TgdramaContentClient.parseChats(null), isEmpty);
    });

    test('catalog(channels) 调 /api/chats：插件启用的在前、硬编 52 在后', () async {
      final seen = <Uri>[];
      final transport = _jsonClient({
        '/api/chats': chatsBody(),
      }, onRequest: (request) => seen.add(request.url));
      addTearDown(transport.close);
      final page = await _client(transport).catalog('channels', 1);
      expect(seen.last.path, '/api/chats');
      expect(seen.last.queryParameters.containsKey('tag'), isFalse);
      // 插件里启用的 2 个（-100111、-100333）在前，硬编 52 条在后；
      // 未启用的 -100222 不在硬编里，不出。
      expect(page.items.length, 2 + hardcodedChannels.length);
      expect(page.items[0].id, 'channel:-100111');
      expect(page.items[0].title, '剧场一号');
      expect(page.items[1].id, 'channel:-100333');
      expect(page.items[1].title, '布尔开关');
      expect(page.items[2].id, 'channel:-1002753266064');
      expect(page.items[2].title, '日本精品av|中文字幕|Jav');
      expect(page.items[2].remark, '未同步，点击同步');
      expect(page.hasMore, isFalse);
    });

    test('catalog(channels) 接口失败与坏 JSON 抛带接口名的 StateError', () async {
      final failing = MockClient((_) async => http.Response('nope', 500));
      addTearDown(failing.close);
      await expectLater(
        _client(failing).catalog('channels', 1),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('TG影视库频道'),
          ),
        ),
      );
      final badJson = MockClient((_) async => http.Response('{bad json', 200));
      addTearDown(badJson.close);
      await expectLater(
        _client(badJson).catalog('channels', 1),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('TG影视库频道'),
          ),
        ),
      );
    });

    test('detail(channel:id) 回频道信息详情、分集为空、简介有诚实说明', () async {
      final transport = _jsonClient({
        '/api/chats': chatsBody(),
      });
      addTearDown(transport.close);
      final detail = await _client(transport).detail('channel:-100111');
      expect(detail.id, 'channel:-100111');
      expect(detail.title, '剧场一号');
      expect(detail.cover, '');
      expect(detail.episodes, isEmpty);
      expect(detail.synopsis, contains('类型：channel'));
      expect(detail.synopsis, contains('用户名：@juchang1'));
      expect(detail.synopsis, contains('TG 频道 ID：-100111'));
      expect(detail.synopsis, contains('128条消息 · 56个视频来源'));
      expect(detail.synopsis, contains('状态：已启用'));
      expect(detail.synopsis, contains('点开该频道可看它收录的剧。'));
    });

    test('detail(channel:id) 名空时标题回退、硬编外频道抛“不在当前账号里”', () async {
      final transport = _jsonClient({
        '/api/chats': chatsBody(),
      });
      addTearDown(transport.close);
      final client = _client(transport);
      final detail = await client.detail('channel:-100222');
      expect(detail.title, '频道 -100222');
      expect(detail.synopsis, contains('状态：未启用'));
      await expectLater(
        client.detail('channel:-100999'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('不在当前账号里'),
          ),
        ),
      );
    });

    test('detail(channel:id) 硬编频道未进插件：回未同步详情，不抛错', () async {
      final transport = _jsonClient({
        '/api/chats': {'list': []},
      });
      addTearDown(transport.close);
      final detail = await _client(transport).detail('channel:jav_all');
      expect(detail.id, 'channel:-1002753266064');
      expect(detail.title, '日本精品av|中文字幕|Jav');
      expect(detail.episodes, isEmpty);
      expect(detail.synopsis, contains('用户名：@jav_all'));
      expect(detail.synopsis, contains('TG 频道 ID：-1002753266064'));
      expect(detail.synopsis, contains('未同步到插件'));
    });

    test('服务未启动时频道 catalog/detail 也抛错', () async {
      final service = _FakeService(running: false, error: '本地服务未拉起');
      final transport = _jsonClient({
        '/api/chats': chatsBody(),
      });
      addTearDown(transport.close);
      final client = _client(transport, service: service);
      await expectLater(
        client.catalog('channels', 1),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        client.detail('channel:-100111'),
        throwsA(isA<StateError>()),
      );
      expect(service.calls, 2);
    });
  });

  group('硬编频道表', () {
    test('52 条主表：与 jar 的 HARDCODED 同序，裸号唯一', () {
      expect(hardcodedChannels.length, 52);
      expect(hardcodedChannels.first.name, '日本精品av|中文字幕|Jav');
      expect(hardcodedChannels.first.username, 'jav_all');
      expect(hardcodedChannels.first.bareTgId, '2753266064');
      expect(hardcodedChannels.first.fullTgId, -1002753266064);
      expect(hardcodedChannels.last.name, '海角社区|偷情乱伦精选');
      expect(hardcodedChannels.last.username, 'haijiaojingxuan');
      expect(hardcodedChannels.last.fullTgId, -1002401842508);
      final bares = hardcodedChannels.map((c) => c.bareTgId).toList();
      expect(bares.toSet().length, bares.length);
      final users = hardcodedChannels
          .map((c) => c.username)
          .where((u) => u.isNotEmpty)
          .toList();
      expect(users.toSet().length, users.length);
      // 4 条无用户名，只有裸号。
      expect(
        hardcodedChannels.where((c) => c.username.isEmpty).length,
        4,
      );
    });

    test('7 条 ext 表：与 tree_104 的 ZakaTg ext 同序', () {
      expect(extChannels.length, 7);
      expect(extChannels.first.username, 'cctv_av');
      expect(extChannels.last.username, 'shoucangav');
    });
  });

  group('频道列表合并', () {
    test('插件没频道：出硬编 52 条，id 用完整 TG 号', () async {
      final transport = _jsonClient({
        '/api/chats': {'list': []},
      });
      addTearDown(transport.close);
      final page = await _client(transport).catalog('channels', 1);
      expect(page.items.length, 52);
      expect(page.items.first.id, 'channel:-1002753266064');
      expect(page.items.first.title, '日本精品av|中文字幕|Jav');
      expect(page.items.first.remark, '未同步，点击同步');
      expect(page.hasMore, isFalse);
    });

    test('插件里有硬编频道：显示名用硬编名，排在插件独有频道前面', () async {
      final transport = _jsonClient({
        '/api/chats': {
          'list': [
            {
              'id': 3,
              'tg_chat_id': -1001879901314,
              'name': '插件里的姐姐',
              'type': 'channel',
              'username': 'zfjp1024',
              'enabled': 1,
              'message_count': 9,
              'source_count': 4,
            },
            {
              'id': 4,
              'tg_chat_id': -100555,
              'name': '插件独有',
              'type': 'channel',
              'username': 'only_plugin',
              'enabled': 1,
            },
          ],
        },
      });
      addTearDown(transport.close);
      final page = await _client(transport).catalog('channels', 1);
      expect(page.items.first.id, 'channel:-1001879901314');
      expect(page.items.first.title, '那些极品姐姐');
      expect(page.items.first.remark, '9条消息 · 4个视频来源');
      expect(page.items[1].id, 'channel:-100555');
      expect(page.items[1].title, '插件独有');
      // 硬编 52 条里 zfjp1024 已在第一段出过，第三段去重，只剩 51 条。
      expect(page.items.length, 2 + hardcodedChannels.length - 1);
    });
  });

  group('频道里的剧（插件接口扫描）', () {
    Map<String, Object?> chatRow(
      int id,
      int tgChatId,
      String username, {
      String name = '',
      int enabled = 1,
    }) {
      return {
        'id': id,
        'tg_chat_id': tgChatId,
        'name': name.isEmpty ? username : name,
        'type': 'channel',
        'username': username,
        'enabled': enabled,
      };
    }

    test('扫描：首集线路 chat_id 对上才算该频道的剧，集数备注补 ep_count', () async {
      final transport = _PluginTransport(
        chatsBodies: [
          {
            'list': [chatRow(5, -100111, 'juchang1', name: '剧场一号')],
          },
        ],
        showsPages: {
          1: {
            'list': [
              {
                'id': 10,
                'name': '剧十',
                'cover_path': '/api/covers/10',
                'ep_count': 12,
              },
              {
                'id': 11,
                'name': '剧十一',
                'cover_path': '/api/covers/11',
                'ep_count': 3,
              },
            ],
            'total': 2,
          },
        },
        showEpisodes: {
          10: [
            {'id': 101, 'episode_no': 1},
          ],
          11: [
            {'id': 111, 'episode_no': 1},
          ],
        },
        episodeLines: {
          101: [
            {'chat_id': 5, 'name': '剧场一号'},
          ],
          111: [
            {'chat_id': 9, 'name': '别的频道'},
          ],
        },
      );
      addTearDown(transport.client.close);
      final client = _client(transport.client);
      final page = await client.catalog('channel:-100111', 1);
      expect(page.items.length, 1);
      expect(page.items.single.id, '10');
      expect(page.items.single.title, '剧十');
      expect(page.items.single.remark, '共12集');
      expect(
        page.items.single.cover,
        'http://127.0.0.1:5278/api/covers/10',
      );
      expect(page.hasMore, isFalse);
    });

    test('扫描翻页：21 部全中，第 1 页 20 条 hasMore 真、第 2 页 1 条为假', () async {
      final shows = [
        for (var i = 1; i <= 21; i++)
          {'id': i, 'name': '剧$i', 'ep_count': 2},
      ];
      final transport = _PluginTransport(
        chatsBodies: [
          {
            'list': [chatRow(5, -100111, 'juchang1', name: '剧场一号')],
          },
        ],
        showsPages: {
          1: {'list': shows, 'total': 21},
        },
        showEpisodes: {
          for (var i = 1; i <= 21; i++)
            i: [
              {'id': 1000 + i, 'episode_no': 1},
            ],
        },
        episodeLines: {
          for (var i = 1; i <= 21; i++)
            1000 + i: [
              {'chat_id': 5},
            ],
        },
      );
      addTearDown(transport.client.close);
      final client = _client(transport.client);
      final first = await client.catalog('channel:-100111', 1);
      expect(first.items.length, 20);
      expect(first.hasMore, isTrue);
      final second = await client.catalog('channel:-100111', 2);
      expect(second.items.length, 1);
      expect(second.items.single.id, '21');
      expect(second.hasMore, isFalse);
    });

    test('点硬编频道：插件没有时只调一次单同步，同步后重查到就出剧', () async {
      final transport = _PluginTransport(
        chatsBodies: [
          {'list': []},
          {
            'list': [
              chatRow(7, -1002753266064, 'jav_all', name: '日本精品av'),
            ],
          },
        ],
        showsPages: {
          1: {
            'list': [
              {'id': 20, 'name': '同步到的剧', 'ep_count': 5},
            ],
            'total': 1,
          },
        },
        showEpisodes: {
          20: [
            {'id': 201, 'episode_no': 1},
          ],
        },
        episodeLines: {
          201: [
            {'chat_id': 7},
          ],
        },
      );
      addTearDown(transport.client.close);
      final client = _client(transport.client);
      final page = await client.catalog('channel:jav_all', 1);
      expect(page.items.length, 1);
      expect(page.items.single.title, '同步到的剧');
      expect(transport.syncPosts.length, 1);
      expect(transport.syncPosts.single, {'tg_chat_id': -1002753266064});
      expect(transport.chatsCalls, 2);
      // 同一客户端再点同一频道（裸号键）：不再重复调同步。
      await client.catalog('channel:2753266064', 1);
      expect(transport.syncPosts.length, 1);
    });

    test('点硬编频道：同步后仍没有，抛“正在同步”', () async {
      final transport = _PluginTransport(
        chatsBodies: [
          {'list': []},
        ],
      );
      addTearDown(transport.client.close);
      await expectLater(
        _client(transport.client).catalog('channel:jav_all', 1),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('正在同步'),
          ),
        ),
      );
      expect(transport.syncPosts.length, 1);
      expect(transport.syncPosts.single, {'tg_chat_id': -1002753266064});
    });

    test('硬编外的频道键：不调同步，直接抛“不在当前账号里”', () async {
      final transport = _PluginTransport(
        chatsBodies: [
          {'list': []},
        ],
      );
      addTearDown(transport.client.close);
      await expectLater(
        _client(transport.client).catalog('channel:qqq_unknown', 1),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('不在当前账号里'),
          ),
        ),
      );
      expect(transport.syncPosts, isEmpty);
    });

    test('频道未启用：抛“未启用”，不扫剧', () async {
      final transport = _PluginTransport(
        chatsBodies: [
          {
            'list': [
              chatRow(5, -100111, 'juchang1', name: '剧场一号', enabled: 0),
            ],
          },
        ],
      );
      addTearDown(transport.client.close);
      await expectLater(
        _client(transport.client).catalog('channel:-100111', 1),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('未启用'),
          ),
        ),
      );
    });

    test('扫描第 1 页调不通：抛“TG影视库列表”，不回空假装没剧', () async {
      final transport = MockClient((request) async {
        if (request.url.path == '/api/chats') {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'list': [chatRow(5, -100111, 'juchang1', name: '剧场一号')],
              }),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('nope', 500);
      });
      addTearDown(transport.close);
      await expectLater(
        _client(transport).catalog('channel:-100111', 1),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('TG影视库列表'),
          ),
        ),
      );
    });

    test('isChannelItemId 只认 channel: 前缀', () {
      expect(TgdramaContentClient.isChannelItemId('channel:-100111'), isTrue);
      expect(TgdramaContentClient.isChannelItemId('channels'), isFalse);
      expect(TgdramaContentClient.isChannelItemId('123'), isFalse);
      expect(TgdramaContentClient.isChannelItemId(''), isFalse);
      expect(TgdramaContentClient.channelItemPrefix, 'channel:');
    });

    List<DramaSiteItem> shows(int count) => [
      for (var i = 1; i <= count; i++)
        DramaSiteItem(id: '$i', title: '剧$i', cover: '', remark: '共3集'),
    ];

    TgdramaContentClient loaderClient(
      Future<List<DramaSiteItem>> Function(String, int) loader, {
      _FakeService? service,
    }) {
      return TgdramaContentClient(
        httpClient: _jsonClient({}),
        service: service ?? _FakeService(),
        channelShowsLoader: loader,
      );
    }

    test('catalog(channel:id) 走注入的加载器，满 20 条 hasMore 为真', () async {
      final seen = <(String, int)>[];
      final client = loaderClient((channelKey, page) async {
        seen.add((channelKey, page));
        return shows(20);
      });
      final page = await client.catalog('channel:-100111', 1);
      expect(seen.single, ('-100111', 1));
      expect(page.items.length, 20);
      expect(page.items.first.id, '1');
      expect(page.hasMore, isTrue);
    });

    test('catalog(channel:id) 不满 20 条 hasMore 为假，页码透传', () async {
      final seen = <(String, int)>[];
      final client = loaderClient((channelKey, page) async {
        seen.add((channelKey, page));
        return shows(3);
      });
      final page = await client.catalog('channel:-100222', 2);
      expect(seen.single, ('-100222', 2));
      expect(page.items.length, 3);
      expect(page.hasMore, isFalse);
    });

    test('catalog(channel:id) 加载器返回空页：频道没剧，回空不报错', () async {
      final client = loaderClient((_, _) async => []);
      final page = await client.catalog('channel:-100111', 1);
      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
    });

    test('catalog(channel:id) 加载器抛错：原样抛 StateError，不回空假装没剧', () async {
      final client = loaderClient(
        (_, _) async => throw StateError('频道正在同步，稍后下拉刷新再进'),
      );
      await expectLater(
        client.catalog('channel:-100111', 1),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('正在同步'),
          ),
        ),
      );
    });

    test('catalog(channel:id) 服务未启动时先抛错，不调加载器', () async {
      var called = false;
      final client = loaderClient(
        (_, _) async {
          called = true;
          return [];
        },
        service: _FakeService(running: false, error: '本地服务未拉起'),
      );
      await expectLater(
        client.catalog('channel:-100111', 1),
        throwsA(isA<StateError>()),
      );
      expect(called, isFalse);
    });
  });

  group('catalog 列表解析', () {
    test('list 键 + total：条数与 hasMore 按 total 算', () async {
      final shows = [
        for (var i = 1; i <= 20; i++)
          {
            'id': i,
            'name': '剧$i',
            'cover_path': '/api/covers/$i',
            'total': 30,
          },
      ];
      final transport = _jsonClient({
        '/api/shows': {'list': shows, 'total': 45},
      });
      addTearDown(transport.close);
      final page = await _client(transport).catalog('all', 1);
      expect(page.items.length, 20);
      expect(page.items.first.id, '1');
      expect(page.items.first.title, '剧1');
      expect(page.items.first.remark, '共30集');
      expect(
        page.items.first.cover,
        'http://127.0.0.1:5278/api/covers/1',
      );
      expect(page.hasMore, isTrue);
    });

    test('shows 键 + total_count：封面相对路径补全、绝对地址不动', () async {
      final transport = _jsonClient({
        '/api/shows': {
          'shows': [
            {
              'show_id': 'a1',
              'title': '相对封面',
              'cover': 'covers/a1.jpg',
              'episode_count': 12,
            },
            {
              'id': 'a2',
              'name': '绝对封面',
              'poster': 'https://example.test/p.jpg',
            },
            {'id': '', 'name': '缺 id 跳过'},
            {'id': 'a3', 'name': ''},
          ],
          'total_count': 3,
        },
      });
      addTearDown(transport.close);
      final page = await _client(transport).catalog('all', 1);
      expect(page.items.length, 2);
      expect(
        page.items.first.cover,
        'http://127.0.0.1:5278/covers/a1.jpg',
      );
      expect(page.items.first.remark, '共12集');
      expect(page.items[1].cover, 'https://example.test/p.jpg');
      expect(page.hasMore, isFalse);
    });

    test('items 键 + episodes 长度拼集数', () async {
      final items = TgdramaContentClient.parseShows({
        'items': [
          {
            'id': 'b1',
            'name': '多集剧',
            'episodes': [
              {'id': 1},
              {'id': 2},
              {'id': 3},
            ],
          },
        ],
      });
      expect(items.length, 1);
      expect(items.first.remark, '共3集');
    });

    test('tag 参数：all 不带 tag，其他分类带 Url 编码后的 tag', () async {
      final seen = <Uri>[];
      final transport = _jsonClient({
        '/api/shows': {'list': [], 'total': 0},
      }, onRequest: (request) => seen.add(request.url));
      addTearDown(transport.close);
      final client = _client(transport);
      await client.catalog('all', 1);
      expect(seen.last.queryParameters.containsKey('tag'), isFalse);
      expect(seen.last.queryParameters['page'], '1');
      await client.catalog('动作片', 2);
      expect(seen.last.queryParameters['tag'], '动作片');
      expect(seen.last.queryParameters['page'], '2');
    });

    test('整包 JSON 解不出来抛带接口名的 StateError', () async {
      final transport = MockClient(
        (_) async => http.Response('{bad json', 200),
      );
      addTearDown(transport.close);
      await expectLater(
        _client(transport).catalog('all', 1),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('TG影视库列表'),
          ),
        ),
      );
    });
  });

  group('detail 详情解析', () {
    test('episode_no 排序、name 为空回退第N集、简介多键容错', () async {
      final transport = _jsonClient({
        '/api/shows/9': {
          'id': 9,
          'name': '测试剧',
          'cover_path': '/api/covers/9',
          'description': '剧情简介',
          'episodes': [
            {'id': 11, 'episode_no': 2, 'name': ''},
            {'id': 12, 'episode_no': 1, 'name': '首播'},
            {'id': '', 'episode_no': 3, 'name': '缺 id 跳过'},
          ],
        },
      });
      addTearDown(transport.close);
      final detail = await _client(transport).detail('9');
      expect(detail.title, '测试剧');
      expect(detail.cover, 'http://127.0.0.1:5278/api/covers/9');
      expect(detail.synopsis, '剧情简介');
      expect(detail.episodes.length, 2);
      expect(detail.episodes[0].videoId, '12');
      expect(detail.episodes[0].title, '首播');
      expect(detail.episodes[0].seriesId, '9');
      expect(detail.episodes[1].videoId, '11');
      expect(detail.episodes[1].title, '第2集');
    });

    test('episodeNo 驼峰键与无 episode_no 时按位置编号', () {
      final episodes = TgdramaContentClient.parseEpisodes([
        {'id': 'e1', 'episodeNo': 3},
        {'id': 'e2'},
      ], 's1');
      expect(episodes[0].videoId, 'e2');
      expect(episodes[0].title, '第2集');
      expect(episodes[1].videoId, 'e1');
      expect(episodes[1].title, '第3集');
    });

    test('没有分集抛“该剧未返回分集”', () async {
      final transport = _jsonClient({
        '/api/shows/9': {'id': 9, 'name': '空剧', 'total': 10},
      });
      addTearDown(transport.close);
      await expectLater(
        _client(transport).detail('9'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            '该剧未返回分集',
          ),
        ),
      );
    });
  });

  group('playSource 与 search', () {
    test('playSource 直接拼 HLS 直链', () async {
      final service = _FakeService();
      final transport = MockClient(
        (_) async => throw StateError('不应调任何接口'),
      );
      addTearDown(transport.close);
      final source = await _client(
        transport,
        service: service,
      ).playSource(const DramaSiteEpisode(videoId: '77', title: '第1集'));
      expect(
        source.url,
        'http://127.0.0.1:5278/api/episodes/77/hls/index.m3u8',
      );
      expect(service.calls, 1);
    });

    test('search 调对 q 参数、列表与 catalog 共用解析', () async {
      var query = '';
      final transport = _jsonClient({
        '/api/search': {
          'list': [
            {'id': 's1', 'name': '搜到的剧', 'cover_path': '/c/1'},
          ],
          'total': 1,
        },
      }, onRequest: (request) => query = request.url.queryParameters['q'] ?? '');
      addTearDown(transport.close);
      final items = await _client(transport).search('测试剧');
      expect(query, '测试剧');
      expect(items.length, 1);
      expect(items.first.id, 's1');
      expect(items.first.cover, 'http://127.0.0.1:5278/c/1');
    });
  });

  group('服务未启动', () {
    test('ensureRunning 回 false 就抛带 lastError 的 StateError', () async {
      final service = _FakeService(running: false, error: '本地服务未拉起');
      final transport = _jsonClient({
        '/api/shows': {'list': [], 'total': 0},
      });
      addTearDown(transport.close);
      final client = _client(transport, service: service);
      await expectLater(
        client.catalog('all', 1),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'TG影视库本地服务未启动：本地服务未拉起，请先到设置里登录 Telegram',
          ),
        ),
      );
      await expectLater(
        client.detail('9'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        client.search('x'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('站点注册', () {
    test('tgdrama 登记在 dramaSites、走新客户端、不进核心站表', () {
      expect(
        dramaSites.any((s) => s.id == 'tgdrama' && s.name == 'TG影视库'),
        isTrue,
      );
      expect(dramaSiteContentClient('tgdrama'), isA<TgdramaContentClient>());
      expect(coreVideoSiteIds.contains('tgdrama'), isFalse);
    });

    test('影视区切站表里有 tgdrama', () {
      expect(videoZoneSites().any((s) => s.id == 'tgdrama'), isTrue);
    });
  });
}
