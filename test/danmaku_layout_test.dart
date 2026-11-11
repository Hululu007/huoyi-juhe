import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/danmaku_layout.dart';

void main() {
  group('DanmakuLayout.assign', () {
    test('empty input stays empty', () {
      expect(
        DanmakuLayout.assign(const [], lanes: 2, travelMs: 10000),
        isEmpty,
      );
    });

    test('a single item keeps its own time and lane 0', () {
      final out = DanmakuLayout.assign(
        const [DanmakuLayoutItem(id: 'a', text: '好看', timeMs: 1000)],
        lanes: 2,
        travelMs: 10000,
      );
      expect(out, hasLength(1));
      expect(out.first.startMs, 1000);
      expect(out.first.lane, 0);
      expect(out.first.endMs, 11000);
      expect(out.first.count, 1);
    });

    test('crowded items on one lane are delayed, never dropped', () {
      // 259 条同点弹幕、1 条轨道：旧实现只留 1 条，其余全丢。
      final items = List.generate(
        259,
        (i) => DanmakuLayoutItem(id: 'd$i', text: '弹幕$i', timeMs: 0),
      );
      final out = DanmakuLayout.assign(items, lanes: 1, travelMs: 10000);
      expect(out, hasLength(259));
      // 顺延上限 3 秒：再晚也不推迟到 3 秒之后。
      expect(out.every((item) => item.startMs <= 3000), isTrue);
      expect(out.every((item) => item.startMs >= 0), isTrue);
    });

    test('same text within 5s merges into one entry with a count', () {
      final out = DanmakuLayout.assign(
        const [
          DanmakuLayoutItem(id: 'a', text: '哈哈', timeMs: 1000),
          DanmakuLayoutItem(id: 'b', text: '哈哈', timeMs: 3000),
          DanmakuLayoutItem(id: 'c', text: '哈哈', timeMs: 5000),
        ],
        lanes: 2,
        travelMs: 10000,
      );
      expect(out, hasLength(1));
      expect(out.first.text, '哈哈 ×3');
      expect(out.first.count, 3);
      expect(out.first.startMs, 1000);
    });

    test('same text more than 5s apart stays separate', () {
      final out = DanmakuLayout.assign(
        const [
          DanmakuLayoutItem(id: 'a', text: '哈哈', timeMs: 1000),
          DanmakuLayoutItem(id: 'b', text: '哈哈', timeMs: 7000),
        ],
        lanes: 2,
        travelMs: 10000,
      );
      expect(out, hasLength(2));
      expect(out.map((item) => item.text), ['哈哈', '哈哈']);
    });

    test('duplicate ids are counted once', () {
      final out = DanmakuLayout.assign(
        const [
          DanmakuLayoutItem(id: 'a', text: '好看', timeMs: 1000),
          DanmakuLayoutItem(id: 'a', text: '好看', timeMs: 1000),
        ],
        lanes: 2,
        travelMs: 10000,
      );
      expect(out, hasLength(1));
    });

    test('lanes spread simultaneous items instead of stacking them', () {
      final out = DanmakuLayout.assign(
        const [
          DanmakuLayoutItem(id: 'a', text: '一', timeMs: 0),
          DanmakuLayoutItem(id: 'b', text: '二', timeMs: 0),
          DanmakuLayoutItem(id: 'c', text: '三', timeMs: 0),
        ],
        lanes: 3,
        travelMs: 10000,
      );
      expect(out.map((item) => item.lane).toSet(), {0, 1, 2});
      expect(out.every((item) => item.startMs == 0), isTrue);
    });

    test('zero lanes or zero travel returns empty', () {
      const items = [
        DanmakuLayoutItem(id: 'a', text: '好看', timeMs: 1000),
      ];
      expect(
        DanmakuLayout.assign(items, lanes: 0, travelMs: 10000),
        isEmpty,
      );
      expect(DanmakuLayout.assign(items, lanes: 2, travelMs: 0), isEmpty);
    });
  });

  group('DanmakuLayout.laneCountFor', () {
    test('uses height and text size', () {
      expect(
        DanmakuLayout.laneCountFor(
          heightPx: 800,
          textSizePx: 16,
          topPaddingPx: 0,
        ),
        greaterThan(1),
      );
    });

    test('degenerate input falls back to one lane', () {
      expect(
        DanmakuLayout.laneCountFor(
          heightPx: 0,
          textSizePx: 16,
          topPaddingPx: 0,
        ),
        1,
      );
      expect(
        DanmakuLayout.laneCountFor(
          heightPx: 800,
          textSizePx: 0,
          topPaddingPx: 0,
        ),
        1,
      );
    });

    test('caps at maxLanes', () {
      expect(
        DanmakuLayout.laneCountFor(
          heightPx: 100000,
          textSizePx: 12,
          topPaddingPx: 0,
          maxLanes: 12,
        ),
        12,
      );
    });
  });
}
