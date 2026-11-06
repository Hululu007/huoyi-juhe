import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/episode_source_cache.dart';

EpisodeSource _source(String id) =>
    EpisodeSource('https://example.invalid/$id.mp4', 'key-$id');

void main() {
  test('keyFor 同一部同集稳定、不同部隔离', () {
    expect(
      SharedEpisodePrefetch.keyFor('book-a', 'ep-1'),
      SharedEpisodePrefetch.keyFor('book-a', 'ep-1'),
    );
    expect(
      SharedEpisodePrefetch.keyFor('book-a', 'ep-1'),
      isNot(SharedEpisodePrefetch.keyFor('book-b', 'ep-1')),
    );
    expect(
      SharedEpisodePrefetch.keyFor('book-a', 'ep-1'),
      isNot(SharedEpisodePrefetch.keyFor('book-a', 'ep-2')),
    );
  });

  test('put 后 get 命中；同集不同部互不串', () {
    final store = SharedEpisodePrefetch.forTest(now: () => Duration.zero);
    store.put(bookId: 'book-a', itemId: 'ep-1', source: _source('a1'));
    store.put(bookId: 'book-b', itemId: 'ep-1', source: _source('b1'));
    expect(
      store.get(bookId: 'book-a', itemId: 'ep-1')?.url,
      _source('a1').url,
    );
    expect(
      store.get(bookId: 'book-b', itemId: 'ep-1')?.url,
      _source('b1').url,
    );
    expect(store.get(bookId: 'book-a', itemId: 'ep-2'), isNull);
    expect(store.get(bookId: 'book-c', itemId: 'ep-1'), isNull);
  });

  test('同键重写以后写的为准', () {
    final store = SharedEpisodePrefetch.forTest(now: () => Duration.zero);
    store.put(bookId: 'book-a', itemId: 'ep-1', source: _source('old'));
    store.put(bookId: 'book-a', itemId: 'ep-1', source: _source('new'));
    expect(
      store.get(bookId: 'book-a', itemId: 'ep-1')?.url,
      _source('new').url,
    );
  });

  test('TTL 10 分钟：9 分 59 秒命中、10 分钟过期', () {
    var now = Duration.zero;
    final store = SharedEpisodePrefetch.forTest(now: () => now);
    store.put(bookId: 'book-a', itemId: 'ep-1', source: _source('a1'));
    now = const Duration(minutes: 9, seconds: 59);
    expect(store.get(bookId: 'book-a', itemId: 'ep-1'), isNotNull);
    now = const Duration(minutes: 10);
    expect(store.get(bookId: 'book-a', itemId: 'ep-1'), isNull);
  });

  test('容量 12 条：写满后最旧的一条被淘汰', () {
    final store = SharedEpisodePrefetch.forTest(now: () => Duration.zero);
    for (var i = 0; i < SharedEpisodePrefetch.capacity + 1; i++) {
      store.put(
        bookId: 'book-$i',
        itemId: 'ep-1',
        source: _source('s$i'),
      );
    }
    expect(store.get(bookId: 'book-0', itemId: 'ep-1'), isNull);
    expect(
      store.get(bookId: 'book-1', itemId: 'ep-1')?.url,
      _source('s1').url,
    );
    expect(
      store.get(
        bookId: 'book-${SharedEpisodePrefetch.capacity}',
        itemId: 'ep-1',
      )?.url,
      _source('s${SharedEpisodePrefetch.capacity}').url,
    );
  });
}
