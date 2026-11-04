import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/homepage_page.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/m3u_export.dart';
import 'package:fqapp/services/m3u_export_db.dart';
import 'package:fqapp/services/original_site_content.dart';

MediaItem feedItem(String id, String title) => MediaItem(
  id: id,
  title: title,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'video',
);

void main() {
  test('番茄短剧分类：没有导航分类，只给全部', () async {
    final client = OriginalContentClient();
    final categories = await client.categories();
    expect(categories.map((c) => c.id), ['all']);
    expect(categories.single.name, '全部');
  });

  test('番茄短剧目录：按游标顺序翻页，到流尾回空页不再请求', () async {
    final calls = <String>[];
    final client = OriginalContentClient(
      homepageLoader: ({int offset = 0, String? sessionId}) async {
        calls.add('$offset/${sessionId ?? ''}');
        if (offset == 0) {
          return HomepagePage(
            items: [feedItem('s1', '剧一'), feedItem('s2', '剧二')],
            nextOffset: 20,
            sessionId: 's1',
          );
        }
        return const HomepagePage(items: [], nextOffset: null, sessionId: null);
      },
    );
    final first = await client.catalog('all', 1);
    expect(first.items.map((item) => item.id), ['s1', 's2']);
    expect(first.hasMore, isTrue);
    final second = await client.catalog('all', 2);
    expect(second.items, isEmpty);
    expect(second.hasMore, isFalse);
    final third = await client.catalog('all', 3);
    expect(third.items, isEmpty);
    expect(calls, ['0/', '20/s1']);
  });

  test('番茄短剧目录：跳页不回错页数据', () async {
    final client = OriginalContentClient(
      homepageLoader: ({int offset = 0, String? sessionId}) async {
        return HomepagePage(
          items: [feedItem('s1', '剧一')],
          nextOffset: 20,
          sessionId: 's1',
        );
      },
    );
    await client.catalog('all', 1);
    expect(() => client.catalog('all', 3), throwsStateError);
  });

  test('番茄短剧详情：目录成选集，书详情宽松取标题封面简介', () async {
    final client = OriginalContentClient(
      directoryLoader: (_) async => [
        [
          Chapter(itemId: 'c1', title: '第1集', volumeName: ''),
          Chapter(itemId: 'c2', title: '第2集', volumeName: ''),
        ],
      ],
      detailLoader: (_) async => {
        'data': {'book_name': '剧名', 'cover': 'cover.jpg', 'abstract': '简介'},
      },
    );
    final detail = await client.detail('s1');
    expect(detail.title, '剧名');
    expect(detail.cover, 'cover.jpg');
    expect(detail.synopsis, '简介');
    expect(
      detail.episodes.map((e) => e.videoId),
      ['\u0001c1', '\u0001c2'],
    );
    expect(detail.episodes.map((e) => e.title), ['第1集', '第2集']);
  });

  test('番茄短剧详情：书详情拿不到也不影响目录与选集', () async {
    final client = OriginalContentClient(
      directoryLoader: (_) async => [
        [Chapter(itemId: 'c1', title: '第1集', volumeName: '')],
      ],
      detailLoader: (_) async => throw StateError('详情挂了'),
    );
    final detail = await client.detail('s1');
    expect(detail.title, isEmpty);
    expect(detail.episodes.length, 1);
  });

  test('番茄短剧取流：章节 itemId 走 content，地址与清晰度原样回', () async {
    final client = OriginalContentClient(
      contentLoader: (_) async => {
        'data': {
          'video_url': 'https://cdn.example.com/v.m3u8',
          'key_hex': 'aabbcc',
          'variants': [
            {
              'name': '高清',
              'url': 'https://cdn.example.com/v_hd.m3u8',
              'key_hex': 'ddeeff',
              'height': 720,
            },
          ],
        },
      },
    );
    final source = await client.playSource(
      const DramaSiteEpisode(videoId: '\u0001c1', title: '第1集'),
    );
    expect(source.url, 'https://cdn.example.com/v.m3u8');
    expect(source.keyHex, 'aabbcc');
    expect(source.variants.single.name, '高清');
    expect(source.variants.single.url, 'https://cdn.example.com/v_hd.m3u8');
    expect(source.variants.single.height, 720);
    expect(
      () => client.playSource(
        const DramaSiteEpisode(videoId: 'c1', title: '第1集'),
      ),
      throwsStateError,
    );
  });

  test('番茄短剧导出：适配器直插导出流，地址进库', () async {
    final client = OriginalContentClient(
      homepageLoader: ({int offset = 0, String? sessionId}) async {
        if (offset == 0) {
          return HomepagePage(
            items: [feedItem('s1', '剧一'), feedItem('s2', '剧二')],
            nextOffset: 20,
            sessionId: 's1',
          );
        }
        return const HomepagePage(items: [], nextOffset: null, sessionId: null);
      },
      contentLoader: (itemId) async => {
        'data': {'video_url': 'https://cdn.example.com/$itemId.m3u8'},
      },
    );
    final db = MemoryM3uExportDb();
    final result = await exportSiteToLocalDb(
      siteId: 'original',
      siteName: '番茄短剧',
      client: client,
      dbSink: db,
      gateOpen: true,
      allowNonM3u8: true,
    );
    expect(result.successCount, 2);
    final rows = await db.listVideos(gateOpen: true);
    expect(
      rows.map((row) => row.url).toSet(),
      {
        'https://cdn.example.com/s1.m3u8',
        'https://cdn.example.com/s2.m3u8',
      },
    );
  });
}
