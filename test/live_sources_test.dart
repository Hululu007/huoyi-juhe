import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/live_platform.dart';
import 'package:fqapp/services/live_sources.dart';

void main() {
  test('m3u 解析：EXTINF 标题与分组、非 http 行跳过', () {
    const text = '''
#EXTM3U
#EXTINF:-1 group-title="卫视",央视一套
https://example.test/cctv1.m3u8
#EXTINF:-1,地方台
https://example.test/local.m3u8
notaurl
''';
    final channels = parseM3u(text);
    expect(channels.length, 2);
    expect(channels.first.title, '央视一套');
    expect(channels.first.group, '卫视');
    expect(channels.last.title, '地方台');
  });

  test('内置源：秀果、欲火聚合与百年直播为成人直播，用户 m3u 为内置频道表', () {
    expect(
      LiveSources.builtin.map((source) => source.id),
      ['xiuguo', 'maiyoux', 'bnzb', 'user_m3u'],
    );
    final userM3u = LiveSources.byId('user_m3u')!;
    expect(userM3u.endpoint, 'asset://assets/live/user_m3u.m3u');
    expect(userM3u.adult, true);
    expect(LiveSources.byId('xiuguo')!.paginated, false);
    expect(LiveSources.byId('bnzb')!.adult, true);
    expect(LiveSources.byId('bnzb')!.paginated, false);
    expect(userM3u.paginated, true);
  });

  test('聚合分类解析：失效分类剔除、计数取大', () {
    const body =
        '{"pingtai":[{"address":"cat1","title":"花名1","Number":"0",'
        '"xinimg":""},'
        '{"address":"weishizhibo","title":"卫视","Number":"99"},'
        '{"address":"cat1","title":"花名1","Number":"77"}]}';
    final platforms = parsePingtaiPlatforms(body, 'http://e1');
    expect(platforms.map((p) => p.id), ['cat1']);
    expect(platforms.first.count, 77);
  });

  test('聚合频道解析：央视跳过、rtmp 沉底、重名去重', () {
    const body =
        '{"zhubo":[{"title":"CCTV-1","address":"https://x/cctv.m3u8"},'
        '{"title":"主播A","address":"rtmp://x/a"},'
        '{"title":"主播B","address":"https://x/b.m3u8"},'
        '{"title":"主播B","address":"https://x/b2.m3u8"}]}';
    final source = LiveSources.byId('xiuguo')!;
    final channels = parsePingtaiChannels(
      source,
      const LivePlatform(id: 'cat1', name: '花名1'),
      body,
    );
    expect(channels.map((c) => c.title), ['主播B', '主播A']);
  });

  test('午夜源只含成人源', () {
    expect(
      LiveSources.midnightSources.map((source) => source.id),
      containsAll(['xiuguo', 'maiyoux']),
    );
    expect(
      LiveSources.midnightSources.any((source) => !source.adult),
      false,
    );
  });
}
