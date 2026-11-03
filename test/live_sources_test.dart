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

  test('内置源顺序与火蚁TV一致，欲火直播走内置频道表', () {
    expect(
      LiveSources.builtin.map((source) => source.id),
      ['xiuguo', 'bilibili', 'huya', 'maiyoux', 'yuhuo_live'],
    );
    final yuhuo = LiveSources.byId('yuhuo_live')!;
    expect(yuhuo.endpoint, 'asset://assets/live/yuhuo_live.m3u');
    expect(yuhuo.group, '欲火直播');
    expect(LiveSources.byId('xiuguo')!.paginated, false);
    expect(yuhuo.paginated, true);
  });

  test('平台分类与房间解析：哔哩哔哩与虎牙样本', () {
    expect(
      livePlatformCategories('bilibili').map((p) => p.id),
      ['rec'],
    );
    expect(livePlatformCategories('huya').length, 15);
    const bilibiliBody =
        '{"data":{"recommend_room_list":[{"roomid":123,"uname":"主播A",'
        '"title":"午夜场","area_v2_parent_name":"娱乐","area_v2_name":"唱歌",'
        '"online":100,"cover":"https://x/cover.jpg"}]}}';
    final bRooms = liveParseRooms(
      'bilibili',
      const LivePlatform(id: 'rec', name: '热门推荐'),
      bilibiliBody,
    );
    expect(bRooms.length, 1);
    expect(bRooms.first.token, '123');
    expect(bRooms.first.subtitle, '主播A · 娱乐/唱歌 · 100 人气');
    const huyaBody =
        '{"data":{"datas":[{"profileRoom":"456","nick":"主播B",'
        '"introduction":"游戏夜","gameFullName":"王者荣耀",'
        '"screenshot":"https://x/shot.jpg"}]}}';
    final hRooms = liveParseRooms(
      'huya',
      const LivePlatform(id: '0', name: '全部'),
      huyaBody,
    );
    expect(hRooms.length, 1);
    expect(hRooms.first.token, '456');
    expect(hRooms.first.subtitle, '主播B · 王者荣耀');
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

  test('平台取流解析：哔哩哔哩 durl 与虎牙流列表样本', () {
    const bBody =
        '{"data":{"durl":[{"url":"https://x/play.m3u8"},'
        '{"url":"not-a-url"}]}}';
    expect(
      liveParsePlaybackUrls('bilibili', bBody),
      ['https://x/play.m3u8'],
    );
    const hBody =
        '{"gameStreamInfoList":[{"sHlsUrl":"https://h/x","sStreamName":"n",'
        '"sHlsUrlSuffix":"m3u8","sHlsAntiCode":"","iPCPriorityRate":2},'
        '{"sFlvUrl":"https://f/x","sStreamName":"n","sFlvUrlSuffix":"flv",'
        '"sFlvAntiCode":"","iPCPriorityRate":1}]}';
    final urls = liveParsePlaybackUrls('huya', hBody);
    expect(urls.first, 'https://h/x/n.m3u8');
    expect(urls, contains('https://f/x/n.flv'));
    expect(isPlayableLiveUrl('rtmp://x/a'), true);
    expect(isPlayableLiveUrl('not-a-url'), false);
  });

  test('直播主 tab 不含成人源，午夜源只含成人源', () {
    expect(
      LiveSources.mainTabSources.any((source) => source.adult),
      false,
    );
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
