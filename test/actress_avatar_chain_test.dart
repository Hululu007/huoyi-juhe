// 演员头像补全链测试（2026-11-27 追加口径）：
// 一级本地库地址（10 秒超时/失败回退，不许无限转圈）→
// 二级 JavDB 按名取头像 → 三级首字静态占位；补到落本地
// 缓存（归一化名＋id 双键）；后台预热按作品数降序、每轮
// 上限、间隔节流、可取消、只进缓存不写库。
// 全部假件：假 JavDB 取数/假头像取数/临时目录缓存。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_avatar.dart';
import 'package:fqapp/actress/actress_javdb_api.dart';

/// 1x1 PNG（解码得动的真图字节）。
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  int rounds = 40,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  group('有效口径判定（数据工点数对齐）', () {
    test('占位形态一律算没头像，真地址放行', () {
      // 空串。
      expect(actressAvatarUrlUsable(''), isFalse);
      expect(actressAvatarUrlUsable('   '), isFalse);
      // 站根地址（13,770 条，实测 404）。
      expect(actressAvatarUrlUsable('https://v.hersav.me/'), isFalse);
      expect(actressAvatarUrlUsable('https://v.hersav.me'), isFalse);
      // JavDB 通用未知人图（370 条）。
      expect(
        actressAvatarUrlUsable(
          'https://c0.jdbstatic.com/images/actor_unknow.jpg',
        ),
        isFalse,
      );
      // 相对路径默认图（1 条）。
      expect(
        actressAvatarUrlUsable('/public/images/default_actress_avatar.png'),
        isFalse,
      );
      // 真头像地址放行（含 hersav 的真图片路径、jdbstatic 真图）。
      expect(
        actressAvatarUrlUsable('https://v.hersav.me/abc/avatar.jpg'),
        isTrue,
      );
      expect(
        actressAvatarUrlUsable('https://c0.jdbstatic.com/actors/xyz.jpg'),
        isTrue,
      );
      expect(actressAvatarUrlUsable('https://img.test/av-a.jpg'), isTrue);
    });
  });

  group('缓存键与落盘', () {
    test('同名不同 id 键不同；无 id 退回名字键', () {
      expect(
        actressAvatarCacheKey('三雲彩葉', 'a1'),
        isNot(actressAvatarCacheKey('三雲彩葉', 'a2')),
      );
      expect(
        actressAvatarCacheKey('三雲 彩葉', ''),
        actressAvatarCacheKey('三雲彩葉', ''),
      );
    });

    test('写后读命中：id 键与名字键都读得到', () async {
      final dir = Directory.systemTemp.createTempSync('avatar_cache_');
      addTearDown(() => dir.delete(recursive: true));
      final cache = ActressAvatarCache(directoryOf: () async => dir);
      expect(await cache.read('三雲彩葉', id: 'a9'), isNull);
      await cache.write('三雲彩葉', id: 'a9', bytes: _png);
      expect(await cache.read('三雲彩葉', id: 'a9'), isNotNull);
      expect(await cache.read('三雲彩葉'), isNotNull);
      // 只进缓存目录，没往别处写。
      expect(dir.listSync().whereType<File>().length, 2);
    });
  });

  group('JavDB 按名查演员', () {
    test('逐页翻列表按归一化名精确命中，取头像字段与 id', () async {
      Future<String> fetch(String url) async {
        if (url.contains('page=2')) {
          return jsonEncode({
            'success': 1,
            'data': {
              'actors': [
                {
                  'id': 'a9',
                  'name': '三雲彩葉',
                  'avatar_url': 'https://tp.spfcas.com/a9.jpg',
                  'videos_count': 12,
                },
              ],
            },
          });
        }
        return jsonEncode({
          'success': 1,
          'data': {
            'actors': [
              {'id': 'a1', 'name': '别人', 'avatar_url': ''},
            ],
          },
        });
      }

      Future<String> post(String url, String body, String contentType) async =>
          jsonEncode({
            'success': 1,
            'data': {'access_token': 'tok'},
          });
      final client = JavdbApiClient(fetch: fetch, post: post);
      // 查询名带空格：归一化后仍精确命中。
      final actor = await client.actorByName('三雲 彩葉');
      expect(actor, isNotNull);
      expect(actor!.id, 'a9');
      expect(actor.avatarUrl, 'https://tp.spfcas.com/a9.jpg');
      // 查无此人回 null，不拿近似名冒充。
      expect(await client.actorByName('不存在的人'), isNull);
    });
  });

  group('后台预热', () {
    test('按作品数降序、每轮上限封顶、补到落缓存', () async {
      final dir = Directory.systemTemp.createTempSync('preheat_');
      addTearDown(() => dir.delete(recursive: true));
      final cache = ActressAvatarCache(directoryOf: () async => dir);
      final calls = <String>[];
      Future<({Uint8List bytes, String actorId})?> fetcher(String name) async {
        calls.add(name);
        return (bytes: _png, actorId: 'id-$name');
      }

      await actressAvatarPreheat(
        candidates: const [
          (name: '低作品', count: 5),
          (name: '高作品', count: 50),
          (name: '中作品', count: 20),
        ],
        fetcher: fetcher,
        cache: cache,
        perRound: 2,
        interval: Duration.zero,
      );
      // 热门先补、本轮只补 2 个。
      expect(calls, ['高作品', '中作品']);
      expect(await cache.read('高作品'), isNotNull);
      expect(await cache.read('中作品'), isNotNull);
      expect(await cache.read('低作品'), isNull);
    });

    test('缓存已有跳过不外取；取消后一个都不取', () async {
      final dir = Directory.systemTemp.createTempSync('preheat2_');
      addTearDown(() => dir.delete(recursive: true));
      final cache = ActressAvatarCache(directoryOf: () async => dir);
      await cache.write('已有', bytes: _png);
      var calls = 0;
      Future<({Uint8List bytes, String actorId})?> fetcher(String name) async {
        calls++;
        return (bytes: _png, actorId: 'x');
      }

      await actressAvatarPreheat(
        candidates: const [(name: '已有', count: 9)],
        fetcher: fetcher,
        cache: cache,
        interval: Duration.zero,
      );
      expect(calls, 0);

      final handle = ActressAvatarPreheatHandle()..cancel();
      await actressAvatarPreheat(
        candidates: const [(name: '新人', count: 9)],
        fetcher: fetcher,
        cache: cache,
        interval: Duration.zero,
        handle: handle,
      );
      expect(calls, 0);
    });
  });

  group('头像组件补全链', () {
    // widget 测试在 FakeAsync 区：建临时目录必须同步 API，
    // 异步 createTemp 永不回包（AGENTS 既有教训）。
    Future<ActressAvatarCache> tempCache() async {
      final dir = Directory.systemTemp.createTempSync('avatar_widget_');
      addTearDown(() => dir.delete(recursive: true));
      return ActressAvatarCache(directoryOf: () async => dir);
    }

    testWidgets('库地址已死 → JavDB 补到 → 出图并落缓存', (tester) async {
      final cache = await tempCache();
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 76,
            height: 76,
            child: ActressAvatar(
              name: '三雲彩葉',
              // 测试绑定默认回 400：死地址一级快速判死。
              avatarUrl: 'https://img.test/dead.jpg',
              cache: cache,
              avatarFetcher: (name) async =>
                  (bytes: _png, actorId: 'a9'),
            ),
          ),
        ),
      );
      await _until(
        tester,
        () => find.byType(Image).evaluate().isNotEmpty,
      );
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // 落缓存了：下次同名同 id 直接读盘。
      expect(await cache.read('三雲彩葉', id: 'a9'), isNotNull);
    });

    testWidgets('库里是站根占位地址 → 本地判定直接跳过、落 JavDB 补', (
      tester,
    ) async {
      final cache = await tempCache();
      var fetchCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 76,
            height: 76,
            child: ActressAvatar(
              name: '三雲彩葉',
              // 全库 13,770 条的占位值：不许拿它发请求等 404。
              avatarUrl: 'https://v.hersav.me/',
              cache: cache,
              avatarFetcher: (name) async {
                fetchCalls++;
                return (bytes: _png, actorId: 'a9');
              },
            ),
          ),
        ),
      );
      await _until(
        tester,
        () => find.byType(Image).evaluate().isNotEmpty,
      );
      expect(find.byType(Image), findsOneWidget);
      expect(fetchCalls, 1);
    });

    testWidgets('三级全空 → 首字静态占位，不转圈不留白', (tester) async {
      final cache = await tempCache();
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 76,
            height: 76,
            child: ActressAvatar(
              name: '無名氏',
              cache: cache,
              avatarFetcher: (name) async => null,
            ),
          ),
        ),
      );
      await _until(tester, () => find.text('無').evaluate().isNotEmpty);
      expect(find.text('無'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('无头像演员抽样 3 人：1 人 JavDB 补到、2 人占位收尾', (
      tester,
    ) async {
      final cache = await tempCache();
      // 抽样口径照用户实报：三雲彩葉（roe-492 演员卡）+ 另两名
      // 无头像演员。JavDB 只有三雲彩葉有头像数据。
      Future<({Uint8List bytes, String actorId})?> fetcher(
        String name,
      ) async {
        if (name == '三雲彩葉') return (bytes: _png, actorId: 'a9');
        return null;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Row(
            children: [
              for (final name in ['三雲彩葉', '演員乙', '演員丙'])
                SizedBox(
                  width: 76,
                  height: 76,
                  child: ActressAvatar(
                    name: name,
                    cache: cache,
                    avatarFetcher: fetcher,
                  ),
                ),
            ],
          ),
        ),
      );
      await _until(
        tester,
        () =>
            find.byType(Image).evaluate().length == 1 &&
            find.text('演').evaluate().length == 2,
      );
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('演'), findsNWidgets(2));
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
