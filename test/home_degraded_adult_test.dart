import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_provider.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  MediaItem item(String id, String title, String kind) => MediaItem(
    id: id,
    title: title,
    cover: '',
    author: '',
    badge: '',
    ep: '',
    kind: kind,
  );

  test('推荐流失败走兜底时成人卡仍在最前面，翻页不重复', () async {
    final container = ProviderContainer(
      overrides: [
        homeProvider.overrideWith(
          () => HomeNotifier(
            homepageLoader:
                ({
                  int tabType = 2,
                  int offset = 0,
                  String? sessionId,
                }) async {
                  throw StateError('推荐流挂了');
                },
            searchLoader: (query, {int page = 1}) async {
              if (page != 1) return const [];
              if (query == '短剧') {
                return [
                  SearchTab(
                    title: '短剧',
                    items: [item('v1', '短剧作品', 'video')],
                    hasMore: false,
                  ),
                ];
              }
              if (query == '听书') {
                return [
                  SearchTab(
                    title: '听书',
                    items: [item('a1', '听书作品', 'audio')],
                    hasMore: false,
                  ),
                ];
              }
              return const [];
            },
            adultRecommendationsLoader: () async => [
              item('adult-novel', '成人小说', 'book'),
              item('adult-comic', '成人漫画', 'manga'),
            ],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(homeProvider.notifier).load();
    final items = container.read(homeProvider).items;
    expect(items.length, greaterThanOrEqualTo(4));
    expect(items[0].title, '成人小说');
    expect(items[1].title, '成人漫画');
    expect(
      items.map((entry) => entry.title),
      containsAll(['短剧作品', '听书作品']),
    );
    await container.read(homeProvider.notifier).loadMore();
    final after = container.read(homeProvider).items;
    expect(
      after.where((entry) => entry.title == '成人小说').length,
      1,
    );
    expect(
      after.where((entry) => entry.title == '成人漫画').length,
      1,
    );
  });
}
