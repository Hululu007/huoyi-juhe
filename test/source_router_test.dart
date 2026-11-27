import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/source_router.dart';

Uri _u(String path) => Uri.parse('http://127.0.0.1:18921$path');

void main() {
  group('classify', () {
    final cases = <String, SourceGroup>{
      // 小说正文
      '/api/v1/chapters/123': SourceGroup.novelContent,
      '/api/v1/chapters/batch?item_ids=1,2': SourceGroup.novelContent,
      '/api/v1/chapters/full?book_id=1&item_ids=2': SourceGroup.novelContent,
      '/api/v1/chapters/123/novel': SourceGroup.novelContent,
      '/api/v1/chapters/123/toutiao': SourceGroup.novelContent,
      // 小说元数据
      '/api/v1/books/123': SourceGroup.novelMeta,
      '/api/v1/books/123/detail': SourceGroup.novelMeta,
      '/api/v1/books/123/directory': SourceGroup.novelMeta,
      '/api/v1/books/123/reviews': SourceGroup.novelMeta,
      '/api/v1/books/123/chapters/summary': SourceGroup.novelMeta,
      '/api/v1/chapters/123/reviews': SourceGroup.novelMeta,
      '/api/v1/chapters/123/paragraphs/4/reviews': SourceGroup.novelMeta,
      '/api/v1/chapters/123/paragraphs/4/short-reviews': SourceGroup.novelMeta,
      '/api/v1/comments/9/replies': SourceGroup.novelMeta,
      '/api/v1/novels/55': SourceGroup.novelMeta,
      '/api/v1/items/1,2': SourceGroup.novelMeta,
      '/api/v1/authors/7': SourceGroup.novelMeta,
      '/api/v1/forum-id': SourceGroup.novelMeta,
      // 听书
      '/api/v1/audio/books/123': SourceGroup.audio,
      '/api/v1/audio/books/123/chapters/456': SourceGroup.audio,
      '/api/v1/audio/play?book_id=1&item_ids=2': SourceGroup.audio,
      '/api/v1/audio/wkcontent/123': SourceGroup.audio,
      '/api/v1/chapters/123/timeline': SourceGroup.audio,
      '/api/v1/chapters/123/timepoints': SourceGroup.audio,
      '/api/v1/books/123/tones': SourceGroup.audio,
      // 漫画
      '/api/v1/manga/123': SourceGroup.manga,
      '/api/v1/manga/videos/9': SourceGroup.manga,
      // 短剧
      '/api/v1/videos/123': SourceGroup.drama,
      '/api/v1/series/123': SourceGroup.drama,
      '/api/v1/series/123/comments': SourceGroup.drama,
      '/api/v1/videos/123/danmaku': SourceGroup.drama,
      '/api/v1/comments/9/digg': SourceGroup.drama,
      '/api/v1/comments/9/reply': SourceGroup.drama,
      '/api/v1/books/123/video-match': SourceGroup.novelMeta,
      // 搜索推荐
      '/api/v1/search?query=x': SourceGroup.discovery,
      '/api/v1/search/fanqie?query=x': SourceGroup.discovery,
      '/api/v1/search/cue': SourceGroup.discovery,
      '/api/v1/search/hot': SourceGroup.discovery,
      '/api/v1/recommend/homepage': SourceGroup.discovery,
      '/api/v1/recommend/series-feed': SourceGroup.discovery,
      '/api/v1/category?category_tab=1': SourceGroup.discovery,
      '/api/v1/rank/3': SourceGroup.discovery,
      // 书旗（整组，含正文）
      '/api/v1/shuqi/search?key=x': SourceGroup.shuqi,
      '/api/v1/shuqi/book?book_id=1': SourceGroup.shuqi,
      '/api/v1/shuqi/toc?book_id=1': SourceGroup.shuqi,
      '/api/v1/shuqi/chapter?book_id=1&chapter_id=2': SourceGroup.shuqi,
      // 账号
      '/api/v1/account/fanqie/library': SourceGroup.account,
      '/api/v1/account/fanqie/history': SourceGroup.account,
      // 系统
      '/health': SourceGroup.system,
      '/src/manga/abc.jpg': SourceGroup.system,
      // 未识别
      '/api/v1/what-is-this': SourceGroup.unclassified,
      '/somewhere/else': SourceGroup.unclassified,
    };
    for (final entry in cases.entries) {
      test('${entry.key} -> ${entry.value.name}', () {
        expect(SourceRouter.classify(_u(entry.key)), entry.value);
      });
    }
  });

  group('default config', () {
    final router = SourceRouter();

    test('every group resolves to local', () {
      for (final group in SourceGroup.values) {
        expect(
          router.config.configuredBackendFor(group),
          SourceBackend.local,
          reason: group.name,
        );
      }
    });

    test('representative paths all resolve to local and pass the guard', () {
      const paths = [
        '/api/v1/chapters/123',
        '/api/v1/books/123',
        '/api/v1/audio/books/123/chapters/456',
        '/api/v1/manga/123',
        '/api/v1/videos/123',
        '/api/v1/search?query=x',
        '/api/v1/shuqi/chapter?book_id=1&chapter_id=2',
        '/api/v1/account/fanqie/library',
        '/health',
        '/src/x.mp4',
      ];
      for (final path in paths) {
        expect(router.backendFor(_u(path)), SourceBackend.local, reason: path);
        expect(() => router.requireLocal(_u(path)), returnsNormally);
      }
    });
  });

  group('pinned local groups', () {
    final router = SourceRouter(
      config: const SourceRouterConfig(
        backends: {
          SourceGroup.account: SourceBackend.remote,
          SourceGroup.system: SourceBackend.remote,
          SourceGroup.drama: SourceBackend.remote,
        },
        remoteBaseUrl: 'https://example.invalid',
      ),
    );

    test('account stays local even when configured remote', () {
      final url = _u('/api/v1/account/fanqie/library');
      expect(router.backendFor(url), SourceBackend.local);
      expect(() => router.requireLocal(url), returnsNormally);
    });

    test('system stays local even when configured remote', () {
      for (final path in ['/health', '/src/manga/abc.jpg']) {
        final url = _u(path);
        expect(router.backendFor(url), SourceBackend.local, reason: path);
        expect(() => router.requireLocal(url), returnsNormally);
      }
    });

    test('a non-pinned group can be switched to remote by config', () {
      final url = _u('/api/v1/videos/123');
      expect(router.backendFor(url), SourceBackend.remote);
      expect(() => router.requireLocal(url), throwsStateError);
    });

    test('switching one group leaves the others local', () {
      final url = _u('/api/v1/chapters/123');
      expect(router.backendFor(url), SourceBackend.local);
      expect(() => router.requireLocal(url), returnsNormally);
    });
  });
}
