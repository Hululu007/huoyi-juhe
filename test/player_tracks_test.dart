import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/player_tracks.dart';

void main() {
  group('外挂字幕归一 parseExternalSubtitles', () {
    test('标准字段 + 别名都认，同 url 去重保序', () {
      final subs = parseExternalSubtitles(<Object?>[
        <String, dynamic>{'url': 'https://x/a.srt', 'name': '简体中文', 'lang': 'zh', 'format': 'srt'},
        <String, dynamic>{'v': 'https://x/b.vtt', 'n': 'English', 'language': 'en', 'type': '.VTT'},
        <String, dynamic>{'src': 'https://x/a.srt', 'name': '重复'},
        <String, dynamic>{'address': 'https://x/c.ass', 'title': '繁體', 'lang': 'cht'},
      ]);
      expect(subs.length, 3);
      expect(subs[0].label, '简体中文');
      expect(subs[1].format, 'vtt');
      expect(subs[1].lang, 'en');
      expect(subs[2].format, 'ass');
    });

    test('格式由扩展名推断；不在白名单的丢弃；无 url 丢弃', () {
      final subs = parseExternalSubtitles(<Object?>[
        <String, dynamic>{'url': 'https://x/a.srt'},
        <String, dynamic>{'url': 'https://x/b.xyz'},
        <String, dynamic>{'name': '没地址'},
        'not-a-map',
      ]);
      expect(subs.length, 1);
      expect(subs.single.format, 'srt');
      expect(subs.single.label, '外挂字幕');
    });

    test('裸字符串元素也认（只有 url，格式靠扩展名推断）', () {
      final subs = parseExternalSubtitles(<Object?>[
        'https://x/plain.srt',
        '  ',
        'https://x/plain.srt',
      ]);
      expect(subs.length, 1);
      expect(subs.single.url, 'https://x/plain.srt');
      expect(subs.single.format, 'srt');
    });

    test('非列表回空', () {
      expect(parseExternalSubtitles(null), isEmpty);
      expect(parseExternalSubtitles('nope'), isEmpty);
    });
  });

  group('默认挂载 pickDefaultExternalSubtitle', () {
    test('偏好语言优先（lang 前缀匹配）', () {
      final pick = pickDefaultExternalSubtitle(<ExternalSubtitle>[
        const ExternalSubtitle(url: 'https://x/en.srt', lang: 'en', format: 'srt'),
        const ExternalSubtitle(url: 'https://x/zh.srt', lang: 'zho', format: 'srt'),
      ]);
      expect(pick?.url, 'https://x/zh.srt');
    });

    test('名字含简体次选；都没有取第一条；空表 null', () {
      final pick = pickDefaultExternalSubtitle(<ExternalSubtitle>[
        const ExternalSubtitle(url: 'https://x/a.srt', name: 'English', format: 'srt'),
        const ExternalSubtitle(url: 'https://x/b.srt', name: '简体中文', format: 'srt'),
      ]);
      expect(pick?.url, 'https://x/b.srt');
      final first = pickDefaultExternalSubtitle(<ExternalSubtitle>[
        const ExternalSubtitle(url: 'https://x/a.srt', name: 'English', format: 'srt'),
      ]);
      expect(first?.url, 'https://x/a.srt');
      expect(pickDefaultExternalSubtitle(const []), isNull);
    });
  });

  group('菜单模型', () {
    const embedded = PlayerTrackInfo(
      id: 'g1:t0',
      label: '',
      language: 'ja',
      formatId: 'embedded-1',
      selected: false,
    );
    const external = PlayerTrackInfo(
      id: 'g2:t0',
      label: '简体中文',
      formatId: 'ext:https://x/zh.srt',
      selected: true,
    );

    test('字幕菜单：首条关闭项，有轨被选中时关闭项不选中', () {
      final menu = buildSubtitleMenu(const [embedded, external]);
      expect(menu.length, 3);
      expect(menu[0].kind, TrackMenuKind.subtitleOff);
      expect(menu[0].id, subtitleOffTrackId);
      expect(menu[0].selected, isFalse);
      expect(menu[1].kind, TrackMenuKind.subtitleEmbedded);
      expect(menu[1].label, 'ja');
      expect(menu[2].kind, TrackMenuKind.subtitleExternal);
      expect(menu[2].selected, isTrue);
      expect(external.externalUrl, 'https://x/zh.srt');
    });

    test('字幕菜单：无轨被选中时关闭项选中', () {
      final menu = buildSubtitleMenu(const [embedded]);
      expect(menu[0].selected, isTrue);
    });

    test('音轨菜单：无关闭项，label 回落语言', () {
      final menu = buildAudioMenu(const [
        PlayerTrackInfo(id: 'g0:t0', label: '', language: 'zh', selected: true),
        PlayerTrackInfo(id: 'g0:t1', label: '粤语', selected: false),
      ]);
      expect(menu.length, 2);
      expect(menu[0].label, 'zh');
      expect(menu[1].label, '粤语');
      expect(menu.every((e) => e.kind == TrackMenuKind.audio), isTrue);
    });
  });
}
