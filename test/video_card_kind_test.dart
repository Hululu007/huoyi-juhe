import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';

void main() {
  group('videoCardKindForSite', () {
    test('JAV Verse 按影视站算，不下标短剧', () {
      expect(
        videoCardKindForSite('zakajavverse', '🆕🔞JAV Verse┃资料库+双线路'),
        'film',
      );
      expect(videoCardKindForSite('zakajavverse', ''), 'film');
    });

    test('短剧站仍走 video', () {
      expect(videoCardKindForSite('hgdj', '🔞黄果短剧'), 'video');
      expect(videoCardKindForSite('original', '番茄短剧'), 'video');
      expect(videoCardKindForSite('huangdou_yh', '黄豆短剧'), 'video');
    });

    test('非短剧影视站走 film', () {
      expect(videoCardKindForSite('91sanji', '🔞91三级'), 'film');
      expect(videoCardKindForSite('guzhuang', '🔞古装AI'), 'film');
    });
  });

  group('film kind 标签', () {
    test('film 下标影视，video 仍下标短剧', () {
      expect(homeKindLabel('film'), '影视');
      expect(homeKindLabel('video'), '短剧');
      expect(homeKindLabel('manju'), '漫剧');
    });

    test('film 同走视频链路', () {
      expect(isVideoKind('film'), isTrue);
      expect(isVideoKind('video'), isTrue);
      expect(isVideoKind('book'), isFalse);
    });
  });

  group('dramaSiteNameOrNull', () {
    test('短剧站表里查得到名字', () {
      expect(dramaSiteNameOrNull('hgdj'), '🔞黄果短剧');
    });

    test('表外站回 null，不回落首站名字', () {
      expect(dramaSiteNameOrNull('zakajavverse'), isNull);
      expect(dramaSiteNameOrNull('__no_such_site__'), isNull);
    });
  });
}
