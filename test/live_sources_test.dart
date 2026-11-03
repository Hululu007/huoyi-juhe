import 'package:flutter_test/flutter_test.dart';
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
