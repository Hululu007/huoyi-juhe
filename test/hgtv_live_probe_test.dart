// 红果真接口探针：目录（签名 landpage）→详情（签名 video_detail）→
// 取流（网页播放页，失败退 360p 直链）→首分片验播。
//
// 默认跳过，只跑真网时显式跑：
//   flutter test test/hgtv_live_probe_test.dart --run-skipped
// 失败只代表当次出口/站方状态，不代表签名算法本身坏了；
// 报错信息里会写清卡在哪一步。
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:fqapp/services/hgtv_content.dart';

const _liveSkip = 'live network probe: run with --run-skipped';

String _resolveSegment(String playlistUrl, String line) {
  if (line.startsWith('http://') || line.startsWith('https://')) return line;
  final base = Uri.parse(playlistUrl);
  return base.resolve(line).toString();
}

Future<void> _verifyPlayable(String url, Map<String, String> headers) async {
  final client = http.Client();
  try {
    if (url.contains('.m3u8')) {
      final listResp = await client
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 60));
      // ignore: avoid_print
      print('LIVE playlist ${listResp.statusCode} '
          'type=${listResp.headers['content-type']} '
          'len=${listResp.bodyBytes.length}');
      expect(listResp.statusCode, 200);
      final text = listResp.body;
      expect(text.contains('#EXTM3U'), isTrue, reason: '播放清单不是 m3u8');
      String? segment;
      for (final line in text.split('\n')) {
        final item = line.trim();
        if (item.isNotEmpty && !item.startsWith('#')) {
          segment = item;
          break;
        }
      }
      expect(segment, isNotNull, reason: '播放清单里没有分片');
      final segmentUrl = _resolveSegment(url, segment!);
      // ignore: avoid_print
      print('LIVE first segment: $segmentUrl');
      final segResp = await client
          .get(
            Uri.parse(segmentUrl),
            headers: {'Range': 'bytes=0-1023', ...headers},
          )
          .timeout(const Duration(seconds: 60));
      // ignore: avoid_print
      print('LIVE segment ${segResp.statusCode} '
          'type=${segResp.headers['content-type']} '
          'len=${segResp.bodyBytes.length}');
      expect(segResp.statusCode, anyOf([200, 206]));
      expect(segResp.bodyBytes.isNotEmpty, isTrue);
      return;
    }
    final resp = await client
        .get(Uri.parse(url), headers: {'Range': 'bytes=0-1023', ...headers})
        .timeout(const Duration(seconds: 60));
    // ignore: avoid_print
    print('LIVE direct ${resp.statusCode} '
        'type=${resp.headers['content-type']} '
        'len=${resp.bodyBytes.length}');
    expect(resp.statusCode, anyOf([200, 206]));
    expect(resp.bodyBytes.length, greaterThan(8));
    if (resp.bodyBytes.length >= 8) {
      final box = String.fromCharCodes(resp.bodyBytes.sublist(4, 8));
      // ignore: avoid_print
      print('LIVE direct box=$box');
      expect(box, anyOf(['ftyp', 'moov', 'free', 'skip', 'mdat']));
    }
  } finally {
    client.close();
  }
}

void main() {
  test(
    '红果真链路：目录→详情→取流→首分片',
    () async {
      final client = HgtvContentClient();
      final page = await client
          .catalog('home', 1)
          .timeout(const Duration(seconds: 60));
      expect(page.items, isNotEmpty, reason: '签名 landpage 未返回剧集');
      final first = page.items.first;
      // ignore: avoid_print
      print('LIVE series: ${first.id} ${first.title}');
      final detail = await client
          .detail(first.id)
          .timeout(const Duration(seconds: 60));
      expect(detail.episodes, isNotEmpty, reason: '详情未返回分集');
      final episode = detail.episodes.first;
      // ignore: avoid_print
      print('LIVE episode: vid=${episode.videoId} '
          'seriesId=${episode.seriesId} title=${episode.title}');
      final source = await client
          .playSource(episode)
          .timeout(const Duration(seconds: 60));
      // ignore: avoid_print
      print('LIVE play url: ${source.url}');
      expect(source.url, isNotEmpty);
      final headers = Map<String, String>.from(source.headers);
      await _verifyPlayable(source.url, headers);
      if (source.variants.isNotEmpty) {
        // ignore: avoid_print
        print('LIVE variants: ${source.variants.map((v) => v.url).join(', ')}');
      }
    },
    skip: _liveSkip,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  // 搜索不进本探针：网页搜索接口 /api/search/result 在本机出口回 403，
  // 属站方拦出口，与签名链路无关；hongguoTV 那边搜索先走签名 App 接口，
  // 本侧 Dart 搜索没有这条签名兜底，见回报。
}
