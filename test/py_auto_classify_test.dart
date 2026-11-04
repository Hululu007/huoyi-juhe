import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/source_registry.dart';

SourceEntry _entry({
  required String id,
  required String name,
  Map<String, Object?> extra = const {},
}) {
  return SourceEntry(
    id: id,
    name: name,
    kind: SourceKind.pyImport,
    address: '$id.addr',
    detail: '',
    extra: extra,
  );
}

const _novelPy = '''
class Spider:
    def detailContent(self, ids):
        payload = "title,content"
        return {"list": [{"vod_play_from": "阅读", "vod_play_url": "正片\$novel://" + payload}]}
''';

const _comicPy = '''
class Spider:
    def detailContent(self, ids):
        imgs = ["http://x/1.jpg", "http://x/2.jpg"]
        return {"list": [{"vod_play_from": "查看", "vod_play_url": "查看\$pics://" + "&&".join(imgs)}]}
''';

const _audioPy = '''
class Spider:
    def playerContent(self, flag, id, vipFlags):
        return {"parse": 0, "url": "http://x/audio_url.mp3", "header": {}}
''';

const _audioFieldPy = '''
class Spider:
    def detailContent(self, ids):
        return {"list": [{"audio_url": "http://x/play?id=1"}]}
''';

const _videoPy = '''
class Spider:
    def playerContent(self, flag, id, vipFlags):
        return {"parse": 0, "url": "http://x/stream.m3u8", "header": {}}
''';

const _mixedPy = '''
class Spider:
    def detailContent(self, ids):
        return {"list": [
            {"vod_play_from": "在线播放", "vod_play_url": "正片\$http://x/v.m3u8"},
            {"vod_play_from": "阅读", "vod_play_url": "正片\$novel://payload"},
        ]}
''';

void main() {
  test('py 自动分类：小说、漫画、听书各归其类', () {
    expect(detectPyContentType(_novelPy), ContentType.novel);
    expect(detectPyContentType(_comicPy), ContentType.comic);
    expect(detectPyContentType(_audioPy), ContentType.audio);
    expect(detectPyContentType(_audioFieldPy), ContentType.audio);
  });

  test('py 自动分类：视频、混站、无标记都不改', () {
    expect(detectPyContentType(_videoPy), isNull);
    expect(detectPyContentType(_mixedPy), isNull);
    expect(detectPyContentType('$_novelPy$_comicPy'), isNull);
    expect(detectPyContentType(''), isNull);
    expect(detectPyContentType('class Spider:\n    pass\n'), isNull);
  });

  test('py 自动分类：大写视频扩展名同样认作视频', () {
    expect(detectPyContentType('url = "http://x/V.M3U8"'), isNull);
  });

  test('影视列表：小说、漫画、听书 py 不列，视频与综合列', () {
    final entries = [
      _entry(
        id: 'py:novel',
        name: '小说站',
        extra: {'contentType': 'novel'},
      ),
      _entry(
        id: 'py:comic',
        name: '漫画站',
        extra: {'contentType': 'comic'},
      ),
      _entry(
        id: 'py:audio',
        name: '听书站',
        extra: {'contentType': 'audio'},
      ),
      _entry(
        id: 'py:mixed',
        name: '综合站',
        extra: {'contentType': 'mixed'},
      ),
      _entry(
        id: 'py:video',
        name: '视频站',
        extra: {'contentType': 'video'},
      ),
    ];
    expect(
      videoPagePlayableSites(entries, true).map((e) => e.id),
      ['py:mixed', 'py:video'],
    );
  });
}
