import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/engine_site_content.dart';

void main() {
  test('片库详情键名归一：vod_ 前缀字段补出页面读的短键，值一字不差', () {
    final detail = parseTvboxDetail({
      'list': [
        {
          'vod_id': '12345',
          'vod_name': '归一测试片',
          'vod_pic': 'https://x.example/cover.jpg',
          'vod_content': '这是一段简介',
          'vod_play_url': '第1集\$https://x.example/1.m3u8',
          'vod_play_from': '线路甲',
          'vod_actor': '张三,李四',
          'vod_director': '王五',
          'vod_year': '2025',
          'vod_area': '中国大陆',
          'vod_remarks': '更新至第8集',
          'vod_type_name': '动作片',
          'vod_class': '动作,科幻,热血',
        },
      ],
    });
    expect(detail.extra['actor'], '张三,李四');
    expect(detail.extra['director'], '王五');
    expect(detail.extra['year'], '2025');
    expect(detail.extra['area'], '中国大陆');
    expect(detail.extra['remarks'], '更新至第8集');
    expect(detail.extra['category'], '动作片');
    expect(detail.extra['tags'], '动作,科幻,热血');
    expect(detail.extra['play_from'], '线路甲');
  });

  test('片库详情键名归一：vod_ 原键仍保留', () {
    final detail = parseTvboxDetail({
      'list': [
        {
          'vod_id': '12345',
          'vod_name': '归一测试片',
          'vod_pic': 'https://x.example/cover.jpg',
          'vod_content': '这是一段简介',
          'vod_play_url': '第1集\$https://x.example/1.m3u8',
          'vod_play_from': '线路甲',
          'vod_actor': '张三,李四',
          'vod_director': '王五',
          'vod_year': '2025',
          'vod_area': '中国大陆',
          'vod_remarks': '更新至第8集',
          'vod_type_name': '动作片',
          'vod_class': '动作,科幻,热血',
        },
      ],
    });
    expect(detail.extra['vod_actor'], '张三,李四');
    expect(detail.extra['vod_director'], '王五');
    expect(detail.extra['vod_year'], '2025');
    expect(detail.extra['vod_area'], '中国大陆');
    expect(detail.extra['vod_remarks'], '更新至第8集');
    expect(detail.extra['vod_type_name'], '动作片');
    expect(detail.extra['vod_class'], '动作,科幻,热血');
    expect(detail.extra['vod_play_from'], '线路甲');
  });

  test('片库详情键名归一：回包已带短键时不被 vod_ 长键覆盖', () {
    final detail = parseTvboxDetail({
      'list': [
        {
          'vod_id': '12345',
          'vod_name': '归一测试片',
          'vod_pic': 'https://x.example/cover.jpg',
          'vod_content': '这是一段简介',
          'vod_play_url': '第1集\$https://x.example/1.m3u8',
          'vod_play_from': '线路甲',
          'actor': '短键演员',
          'vod_actor': '长键演员',
          'vod_director': '王五',
          'vod_year': '2025',
          'vod_area': '中国大陆',
          'vod_remarks': '更新至第8集',
          'vod_type_name': '动作片',
          'vod_class': '动作,科幻,热血',
        },
      ],
    });
    expect(detail.extra['actor'], '短键演员');
    expect(detail.extra['vod_actor'], '长键演员');
  });

  test('片库详情键名归一：值为空的字段不进扩展列，短键也不造', () {
    final detail = parseTvboxDetail({
      'list': [
        {
          'vod_id': '12345',
          'vod_name': '归一测试片',
          'vod_pic': 'https://x.example/cover.jpg',
          'vod_content': '这是一段简介',
          'vod_play_url': '第1集\$https://x.example/1.m3u8',
          'vod_play_from': '线路甲',
          'vod_actor': '张三,李四',
          'vod_director': '王五',
          'vod_year': '2025',
          'vod_area': '中国大陆',
          'vod_remarks': '更新至第8集',
          'vod_type_name': '动作片',
          'vod_class': '动作,科幻,热血',
          'vod_lang': '',
          'vod_score': '   ',
          'vod_actress': '',
        },
      ],
    });
    expect(detail.extra.containsKey('vod_lang'), isFalse);
    expect(detail.extra.containsKey('lang'), isFalse);
    expect(detail.extra.containsKey('vod_score'), isFalse);
    expect(detail.extra.containsKey('score'), isFalse);
    expect(detail.extra.containsKey('vod_actress'), isFalse);
    expect(detail.extra.containsKey('actress'), isFalse);
  });
}
