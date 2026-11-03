import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/nonvideo_play.dart';

void main() {
  test('播放地址分类：小说、图片、音频、视频', () {
    expect(classifyPlayUrl('novel://{"title":"t","content":"c"}'), PlayUrlKind.novel);
    expect(classifyPlayUrl('pics://a.jpg&&b.jpg'), PlayUrlKind.pics);
    expect(classifyPlayUrl('https://x.com/a.mp3'), PlayUrlKind.audio);
    expect(classifyPlayUrl('https://x.com/a.m4a?token=1'), PlayUrlKind.audio);
    expect(classifyPlayUrl('https://x.com/a.m3u8'), PlayUrlKind.video);
    expect(classifyPlayUrl('https://x.com/a.mp4'), PlayUrlKind.video);
  });

  test('小说载荷解析：标题与正文', () {
    final payload = parseNovelPayload('novel://{"title":"第一章","content":"正文"}');
    expect(payload.title, '第一章');
    expect(payload.content, '正文');
    expect(() => parseNovelPayload('novel://not-json'), throwsA(anything));
  });

  test('图片地址解析：按 && 拆分并去空', () {
    expect(
      parsePicsUrls('pics://a.jpg&&b.jpg&&'),
      ['a.jpg', 'b.jpg'],
    );
    expect(parsePicsUrls('pics://'), isEmpty);
  });
}
