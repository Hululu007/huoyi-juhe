import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/engine_reading_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('引擎书架续读：按站与书存取最后章节', () async {
    SharedPreferences.setMockInitialValues({});
    final store = EngineReadingStore.instance;
    expect(await store.lastIndex('site-a', 'book-1'), 0);
    await store.saveIndex('site-a', 'book-1', 7);
    expect(await store.lastIndex('site-a', 'book-1'), 7);
    expect(await store.lastIndex('site-a', 'book-2'), 0);
    expect(await store.lastIndex('site-b', 'book-1'), 0);
    expect(
      EngineReadingStore.keyFor('site-a', 'book-1'),
      'engine_last_chapter:site-a:book-1',
    );
  });
}
