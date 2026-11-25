import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/hls_ad_filter.dart';

/// B1 去广告：用例对照魔蚁 Go 版 app_adfilter_test.go 移植，
/// 外加真实清单样本（非凡资源 mixed.m3u8，340 片同源）防误删。
void main() {
  const base = 'https://cdn.example.com/movie/2024/index.m3u8';

  String playlist(List<String> lines) => lines.join('\n');

  test('中段异目录插播 2 片：恰删 2 片，DISCONTINUITY 一并删', () {
    final text = playlist(<String>[
      '#EXTM3U',
      '#EXT-X-TARGETDURATION:10',
      for (var i = 0; i < 6; i++) ...<String>[
        '#EXTINF:10,',
        'https://cdn.example.com/movie/2024/seg$i.ts',
      ],
      '#EXT-X-DISCONTINUITY',
      '#EXTINF:5,',
      'https://ads.other.com/spot/1.ts',
      '#EXTINF:5,',
      'https://ads.other.com/spot/2.ts',
      '#EXT-X-DISCONTINUITY',
      for (var i = 6; i < 10; i++) ...<String>[
        '#EXTINF:10,',
        'https://cdn.example.com/movie/2024/seg$i.ts',
      ],
      '#EXT-X-ENDLIST',
    ]);
    final result = filterHlsAdSegments(text, base);
    expect(result.removed, 2);
    expect(result.text, isNot(contains('ads.other.com')));
    expect(result.text.split('#EXTINF').length - 1, 10);
  });

  test('相对地址全同源：不删', () {
    final text = playlist(<String>[
      '#EXTM3U',
      for (var i = 0; i < 5; i++) ...<String>['#EXTINF:8,', 'seg$i.ts'],
      '#EXT-X-ENDLIST',
    ]);
    final result = filterHlsAdSegments(text, base);
    expect(result.removed, 0);
    expect(result.text, text);
  });

  test('master 清单：不动', () {
    final text = playlist(<String>[
      '#EXTM3U',
      '#EXT-X-STREAM-INF:BANDWIDTH=1000000',
      'https://cdn.example.com/low/index.m3u8',
      '#EXT-X-STREAM-INF:BANDWIDTH=3000000',
      'https://cdn.example.com/high/index.m3u8',
    ]);
    expect(filterHlsAdSegments(text, base).removed, 0);
  });

  test('主指纹占比 33% < 40%：放弃清洗', () {
    final text = playlist(<String>[
      '#EXTM3U',
      '#EXTINF:10,',
      'https://a.example.com/x/1.ts',
      '#EXTINF:10,',
      'https://b.example.com/y/2.ts',
      '#EXTINF:10,',
      'https://c.example.com/z/3.ts',
    ]);
    expect(filterHlsAdSegments(text, base).removed, 0);
  });

  test('广告自带独立 KEY 连删，主 KEY 保留', () {
    final text = playlist(<String>[
      '#EXTM3U',
      '#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.com/movie/2024/key.bin"',
      for (var i = 0; i < 6; i++) ...<String>[
        '#EXTINF:10,',
        'https://cdn.example.com/movie/2024/seg$i.ts',
      ],
      '#EXT-X-KEY:METHOD=AES-128,URI="https://ads.other.com/adkey.bin"',
      '#EXTINF:5,',
      'https://ads.other.com/spot/1.ts',
      '#EXTINF:10,',
      'https://cdn.example.com/movie/2024/seg6.ts',
      '#EXT-X-ENDLIST',
    ]);
    final result = filterHlsAdSegments(text, base);
    expect(result.removed, 1);
    expect(result.text, contains('key.bin'));
    expect(result.text, isNot(contains('adkey.bin')));
  });

  test('贴片广告在最前：删片但保住头部标签', () {
    final text = playlist(<String>[
      '#EXTM3U',
      '#EXT-X-VERSION:3',
      '#EXT-X-TARGETDURATION:10',
      '#EXT-X-MEDIA-SEQUENCE:0',
      '#EXTINF:5,',
      'https://ads.other.com/pre/1.ts',
      for (var i = 0; i < 6; i++) ...<String>[
        '#EXTINF:10,',
        'https://cdn.example.com/movie/2024/seg$i.ts',
      ],
      '#EXT-X-ENDLIST',
    ]);
    final result = filterHlsAdSegments(text, base);
    expect(result.removed, 1);
    expect(result.text, contains('#EXT-X-TARGETDURATION:10'));
    expect(result.text, contains('#EXT-X-MEDIA-SEQUENCE:0'));
    expect(result.text, isNot(contains('ads.other.com')));
  });

  test('占比总闸：正片 6 + 异源 4（待删 40% > 35%）整单放行', () {
    final text = playlist(<String>[
      '#EXTM3U',
      for (var i = 0; i < 6; i++) ...<String>[
        '#EXTINF:10,',
        'https://cdn.example.com/movie/2024/seg$i.ts',
      ],
      for (var i = 0; i < 4; i++) ...<String>[
        '#EXTINF:5,',
        'https://ads.other.com/spot/$i.ts',
      ],
    ]);
    expect(filterHlsAdSegments(text, base).removed, 0);
  });

  test('时长总闸：待删 120 秒（占比仅 13%）也整单放行', () {
    final text = playlist(<String>[
      '#EXTM3U',
      for (var i = 0; i < 20; i++) ...<String>[
        '#EXTINF:10,',
        'https://cdn.example.com/movie/2024/seg$i.ts',
      ],
      for (var i = 0; i < 3; i++) ...<String>[
        '#EXTINF:40,',
        'https://ads.other.com/long/$i.ts',
      ],
    ]);
    expect(filterHlsAdSegments(text, base).removed, 0);
  });

  test('双 CDN 均分正片（待删 50%）被总闸拦住', () {
    final lines = <String>['#EXTM3U'];
    for (var i = 0; i < 5; i++) {
      lines.addAll(<String>[
        '#EXTINF:10,',
        'https://cdn-a.example.com/movie/2024/seg$i.ts',
        '#EXTINF:10,',
        'https://cdn-b.example.com/movie/2024/seg$i.ts',
      ]);
    }
    expect(filterHlsAdSegments(playlist(lines), base).removed, 0);
  });

  test('含 BYTERANGE：整单放行', () {
    final text = playlist(<String>[
      '#EXTM3U',
      '#EXTINF:10,',
      '#EXT-X-BYTERANGE:1000@0',
      'https://cdn.example.com/movie/2024/all.ts',
      '#EXTINF:5,',
      'https://ads.other.com/spot/1.ts',
      '#EXTINF:10,',
      '#EXT-X-BYTERANGE:1000@1000',
      'https://cdn.example.com/movie/2024/all.ts',
    ]);
    expect(filterHlsAdSegments(text, base).removed, 0);
  });

  test('LL-HLS（PART / PRELOAD-HINT）：整单放行', () {
    final withPart = playlist(<String>[
      '#EXTM3U',
      '#EXT-X-PART:DURATION=1.0,URI="https://cdn.example.com/movie/2024/p1.ts"',
      '#EXTINF:10,',
      'https://cdn.example.com/movie/2024/seg0.ts',
      '#EXTINF:5,',
      'https://ads.other.com/spot/1.ts',
    ]);
    expect(filterHlsAdSegments(withPart, base).removed, 0);
    final withHint = playlist(<String>[
      '#EXTM3U',
      '#EXT-X-PRELOAD-HINT:TYPE=PART,URI="https://cdn.example.com/movie/2024/p.ts"',
      '#EXTINF:10,',
      'https://cdn.example.com/movie/2024/seg0.ts',
      '#EXTINF:5,',
      'https://ads.other.com/spot/1.ts',
    ]);
    expect(filterHlsAdSegments(withHint, base).removed, 0);
  });

  test('非清单文本 / 空文本：原样返回', () {
    expect(filterHlsAdSegments('hello', base).removed, 0);
    expect(filterHlsAdSegments('', base).removed, 0);
  });

  group('真实样本 ffzy_mixed_real.m3u8（340 片同源）', () {
    final sample = File('test/fixtures/ffzy_mixed_real.m3u8').readAsStringSync();
    const sampleBase =
        'https://vod.ffzy-bofang.com/20260811/1859_537de305/3000k/hls/mixed.m3u8';

    test('原样喂入：一片不删（同源混编宁漏不误杀）', () {
      expect(sample.split('#EXTINF').length - 1, 340);
      final result = filterHlsAdSegments(sample, sampleBase);
      expect(result.removed, 0);
      expect(result.text, sample);
    });

    test('注入 2 片异源广告：恰删 2 片，340 片正片一片不少', () {
      final lines = sample.split('\n');
      // 在第一个正片分片（首个 #EXTINF + 其 URI）之后注入广告块。
      final firstExtinf = lines.indexWhere((l) => l.startsWith('#EXTINF'));
      final insertAt = firstExtinf + 2;
      final injected = <String>[
        ...lines.sublist(0, insertAt),
        '#EXT-X-DISCONTINUITY',
        '#EXTINF:5,',
        'https://ads.other.com/spot/1.ts',
        '#EXTINF:5,',
        'https://ads.other.com/spot/2.ts',
        '#EXT-X-DISCONTINUITY',
        ...lines.sublist(insertAt),
      ].join('\n');
      final result = filterHlsAdSegments(injected, sampleBase);
      expect(result.removed, 2);
      expect(result.text, isNot(contains('ads.other.com')));
      expect(result.text.split('#EXTINF').length - 1, 340);
    });
  });
}
