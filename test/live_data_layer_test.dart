// 直播数据层（第 2 包）测试：
// - parseM3u 新属性：tvg-id/tvg-name、catchup（全源默认+频道覆盖）、
//   #EXTVLCOPT 请求头、#KODIPROP 授权键/类型/清单类型；
// - parseTxtList：分组行、设置行、多线路、地址后请求头、分组清设置；
// - LiveChannel 新字段的 toJson/fromJson 往返与旧 JSON 默认值；
// - XMLTV 解析 + now/next 查询、EPG 服务（gzip、注入拉取/缓存目录、
//   按源加载入口）；
// - 回看地址生成（append/default/timestamp）；
// - DRM 判定分类（服务器型/ClearKey/Kodi 模板段/drm_legacy）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/live_catchup.dart';
import 'package:fqapp/services/live_drm.dart';
import 'package:fqapp/services/live_epg.dart';
import 'package:fqapp/services/live_sources.dart';

void main() {
  group('parseM3u 新属性', () {
    const sample =
        '#EXTM3U catchup="append" '
        'catchup-source="?playseek=\${(b)yyyyMMddHHmmss}-\${(e)yyyyMMddHHmmss}" '
        'catchup-replace="/PLTV/,/TVOD/"\n'
        '#EXTINF:-1 tvg-id="cctv1" tvg-name="CCTV-1" tvg-chno="1" '
        'group-title="央视",CCTV-1\n'
        '#EXTVLCOPT:http-user-agent=Mozilla/5.0 TestUA\n'
        '#EXTVLCOPT:http-referrer=https://example.com/\n'
        '#EXTVLCOPT:http-origin=https://origin.example.com\n'
        '#EXTVLCOPT:http-cookie=session=abc\n'
        'http://example.com/PLTV/cctv1.m3u8\n'
        '#EXTINF:-1 tvg-id="hnws" group-title="卫视",湖南卫视\n'
        '#KODIPROP:inputstream.adaptive.license_type=com.widevine.alpha\n'
        '#KODIPROP:inputstream.adaptive.license_key=https://example.com/license\n'
        '#KODIPROP:inputstream.adaptive.manifest_type=mpd\n'
        'http://example.com/hnws.mpd\n';

    test('tvg-id/tvg-name/频道号落位', () {
      final channels = parseM3u(sample);
      expect(channels, hasLength(2));
      expect(channels.first.tvgId, 'cctv1');
      expect(channels.first.tvgName, 'CCTV-1');
      expect(channels.first.number, '001');
      expect(channels.first.title, 'CCTV-1');
      expect(channels.last.tvgId, 'hnws');
    });

    test('#EXTVLCOPT 附加行落成播放请求头、下一频道不继承', () {
      final channels = parseM3u(sample);
      final cctv = channels.first;
      expect(cctv.headers['User-Agent'], 'Mozilla/5.0 TestUA');
      expect(cctv.headers['Referer'], 'https://example.com/');
      expect(cctv.headers['Origin'], 'https://origin.example.com');
      expect(cctv.headers['Cookie'], 'session=abc');
      expect(channels.last.headers, isEmpty);
    });

    test('回看：全源默认被频道继承', () {
      final channels = parseM3u(sample);
      final cctv = channels.first;
      expect(cctv.catchup, isNotNull);
      expect(cctv.catchup!.type, 'append');
      expect(
        cctv.catchup!.source,
        '?playseek=\${(b)yyyyMMddHHmmss}-\${(e)yyyyMMddHHmmss}',
      );
      expect(cctv.catchup!.replace, '/PLTV/,/TVOD/');
    });

    test('#EXTINF 上的回看覆盖全源默认', () {
      const own =
          '#EXTM3U catchup="append" catchup-source="?global=1"\n'
          '#EXTINF:-1 catchup="default" '
          'catchup-source="https://example.com/vod/\${(b)timestamp}.m3u8",台一\n'
          'http://example.com/a.m3u8\n';
      final channels = parseM3u(own);
      expect(channels.single.catchup!.type, 'default');
      expect(
        channels.single.catchup!.source,
        'https://example.com/vod/\${(b)timestamp}.m3u8',
      );
    });

    test('#KODIPROP 授权键与清单类型解析存储', () {
      final channels = parseM3u(sample);
      final hnws = channels.last;
      expect(hnws.licenseType, 'com.widevine.alpha');
      expect(hnws.licenseKey, 'https://example.com/license');
      expect(hnws.format, 'mpd');
      expect(hnws.hasDrm, isTrue);
      expect(channels.first.hasDrm, isFalse);
    });

    test('#EXTINF 的 http-user-agent 属性落 User-Agent', () {
      const text =
          '#EXTM3U\n'
          '#EXTINF:-1 http-user-agent="AttrUA/1.0",台一\n'
          'http://example.com/a.m3u8\n';
      final channels = parseM3u(text);
      expect(channels.single.headers['User-Agent'], 'AttrUA/1.0');
    });
  });

  group('parseTxtList', () {
    const sample =
        '央视,#genre#\n'
        'ua=Mozilla/5.0 TestUA\n'
        'CCTV-1,http://example.com/c1.m3u8#http://example.com/c1b.m3u8'
        '|Referer=http://example.com/\n'
        'CCTV-2,http://example.com/c2.m3u8\n'
        '卫视,#genre#\n'
        '湖南卫视,http://example.com/hn.m3u8\n';

    test('分组/频道/多线路（# 分隔）', () {
      final channels = parseTxtList(sample);
      expect(channels, hasLength(3));
      expect(channels.map((c) => c.group), ['央视', '央视', '卫视']);
      final cctv1 = channels.first;
      expect(cctv1.urls, [
        'http://example.com/c1.m3u8',
        'http://example.com/c1b.m3u8',
      ]);
      expect(cctv1.url, 'http://example.com/c1.m3u8');
      expect(cctv1.number, '001');
    });

    test('设置行作用于其后频道、| 后请求头落位', () {
      final channels = parseTxtList(sample);
      final cctv1 = channels.first;
      expect(cctv1.headers['User-Agent'], 'Mozilla/5.0 TestUA');
      expect(cctv1.headers['Referer'], 'http://example.com/');
    });

    test('分组行清掉前一组的设置行', () {
      final channels = parseTxtList(sample);
      expect(channels.last.headers, isEmpty);
    });

    test('同组同名频道合并线路、元信息行跳过', () {
      const text =
          '更新时间: 2026-11-25,#genre#\n'
          '分组,#genre#\n'
          '台一,http://example.com/a.m3u8\n'
          '台一,http://example.com/b.m3u8\n';
      final channels = parseTxtList(text);
      expect(channels, hasLength(1));
      expect(channels.single.urls, [
        'http://example.com/a.m3u8',
        'http://example.com/b.m3u8',
      ]);
    });
  });

  group('LiveChannel 新字段 JSON', () {
    test('toJson/fromJson 往返不丢字段', () {
      final channel = LiveChannel(
        title: '台一',
        url: 'http://example.com/a.m3u8',
        group: '央视',
        sourceId: 's1',
        number: '007',
        tvgId: 'cctv1',
        tvgName: 'CCTV-1',
        headers: const {'User-Agent': 'UA'},
        catchup: const LiveCatchup(
          type: 'append',
          source: '?s=\${(b)timestamp}',
          replace: '/a/,/b/',
        ),
        licenseKey: 'https://example.com/license',
        licenseType: 'com.widevine.alpha',
        format: 'mpd',
      );
      final back = LiveChannel.fromJson(channel.toJson())!;
      expect(back.tvgId, 'cctv1');
      expect(back.tvgName, 'CCTV-1');
      expect(back.headers, {'User-Agent': 'UA'});
      expect(back.catchup!.type, 'append');
      expect(back.catchup!.replace, '/a/,/b/');
      expect(back.licenseKey, 'https://example.com/license');
      expect(back.licenseType, 'com.widevine.alpha');
      expect(back.format, 'mpd');
    });

    test('旧收藏 JSON 缺新字段时全默认', () {
      final back = LiveChannel.fromJson({
        'title': '旧台',
        'url': 'http://example.com/old.m3u8',
      })!;
      expect(back.tvgId, '');
      expect(back.tvgName, '');
      expect(back.headers, isEmpty);
      expect(back.catchup, isNull);
      expect(back.licenseKey, '');
      expect(back.format, '');
      expect(back.hasDrm, isFalse);
    });
  });

  group('XMLTV 节目单', () {
    const xml =
        '<?xml version="1.0" encoding="UTF-8"?>\n<tv>\n'
        '<channel id="cctv1"><display-name>CCTV-1综合</display-name></channel>\n'
        '<channel id="hnws"><display-name>湖南卫视</display-name></channel>\n'
        '<programme start="20261125070000 +0800" stop="20261125080000 +0800" '
        'channel="cctv1"><title>朝闻天下</title></programme>\n'
        '<programme start="20261125080000 +0800" stop="20261125090000 +0800" '
        'channel="cctv1"><title>新闻直播间</title></programme>\n'
        '<programme start="20261125090000 +0800" stop="20261125100000 +0800" '
        'channel="cctv1"><title>今日说法</title></programme>\n'
        '</tv>';

    test('解析出节目并按 tvg-id 对台取正在/下一条', () {
      final guide = parseXmltvGuide(xml);
      final channel = LiveChannel(
        title: 'CCTV-1',
        url: 'http://example.com/a.m3u8',
        tvgId: 'cctv1',
      );
      final list = guide.programmesFor(channel);
      expect(list.map((item) => item.title), ['朝闻天下', '新闻直播间', '今日说法']);
      final at = list[1].start.add(const Duration(minutes: 10));
      final hit = guide.nowNext(channel, at);
      expect(hit.now?.title, '新闻直播间');
      expect(hit.next?.title, '今日说法');
    });

    test('tvg-id 对不上时按显示名兜底对台', () {
      final guide = parseXmltvGuide(xml);
      final byTitle = LiveChannel(
        title: 'CCTV-1综合',
        url: 'http://example.com/a.m3u8',
      );
      expect(guide.programmesFor(byTitle), hasLength(3));
      final byTvgName = LiveChannel(
        title: '随便什么名',
        url: 'http://example.com/a.m3u8',
        tvgName: 'CCTV-1综合',
      );
      expect(guide.programmesFor(byTvgName), hasLength(3));
    });

    test('服务：gzip 内容能解、走注入的拉取与缓存目录', () async {
      final dir = Directory.systemTemp.createTempSync('epg_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      LiveEpgService.debugCacheDir = dir;
      LiveEpgService.debugFetcher = (_) async =>
          GZipCodec().encode(utf8.encode(xml));
      addTearDown(() {
        LiveEpgService.debugCacheDir = null;
        LiveEpgService.debugFetcher = null;
      });
      final guide = await LiveEpgService.instance.load(
        'https://example.com/epg.xml.gz',
        force: true,
      );
      expect(guide.byChannelId['cctv1'], hasLength(3));
      expect(
        dir.listSync().where((file) => file.path.contains('epg_')),
        hasLength(1),
      );
    });

    test('服务入口按源加载：无 epg 的源回空、带 epg 的源按源键缓存', () async {
      final dir = Directory.systemTemp.createTempSync('epg_src_');
      addTearDown(() => dir.deleteSync(recursive: true));
      LiveEpgService.debugCacheDir = dir;
      var fetches = 0;
      LiveEpgService.debugFetcher = (_) async {
        fetches++;
        return utf8.encode(xml);
      };
      addTearDown(() {
        LiveEpgService.debugCacheDir = null;
        LiveEpgService.debugFetcher = null;
      });
      const noEpg = LiveSource(
        id: 'no_epg',
        name: '无节目单源',
        description: '',
        protocol: LiveProtocol.list,
      );
      expect((await LiveEpgService.instance.loadForSource(noEpg)).isEmpty, isTrue);
      expect(fetches, 0);
      const withEpg = LiveSource(
        id: 'with_epg',
        name: '带节目单源',
        description: '',
        protocol: LiveProtocol.list,
        epg: 'https://example.com/epg-by-source.xml',
      );
      final guide = await LiveEpgService.instance.loadForSource(withEpg);
      expect(guide.byChannelId['cctv1'], hasLength(3));
      // 同源再加载走内存缓存，不重复拉取。
      await LiveEpgService.instance.loadForSource(withEpg);
      expect(fetches, 1);
    });
  });

  group('回看地址生成', () {
    test('append：先 replace 改地址再拼模板', () {
      final url = formatLiveCatchupUrl(
        catchup: const LiveCatchup(
          type: 'append',
          source: '?playseek=\${(b)yyyyMMddHHmmss}-\${(e)yyyyMMddHHmmss}',
          replace: '/PLTV/,/TVOD/',
        ),
        liveUrl: 'http://example.com/PLTV/cctv1.m3u8',
        start: DateTime(2026, 11, 25, 8),
        end: DateTime(2026, 11, 25, 9),
      );
      expect(
        url,
        'http://example.com/TVOD/cctv1.m3u8'
        '?playseek=20261125080000-20261125090000',
      );
    });

    test('append：地址已有查询串时模板的 ? 换 &', () {
      final url = formatLiveCatchupUrl(
        catchup: const LiveCatchup(
          type: 'append',
          source: '?playseek=\${(b)timestamp}',
        ),
        liveUrl: 'http://example.com/a.m3u8?token=<redacted>',
        start: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        end: DateTime.fromMillisecondsSinceEpoch(1700003600000),
      );
      expect(url, 'http://example.com/a.m3u8?token=<redacted>&playseek=1700000000');
    });

    test('default：模板本身就是回看地址', () {
      final start = DateTime(2026, 11, 25, 8);
      final url = formatLiveCatchupUrl(
        catchup: const LiveCatchup(
          type: 'default',
          source: 'https://example.com/vod/\${(b)timestamp}.m3u8',
        ),
        liveUrl: 'http://example.com/live.m3u8',
        start: start,
        end: DateTime(2026, 11, 25, 9),
      );
      expect(
        url,
        'https://example.com/vod/${start.millisecondsSinceEpoch ~/ 1000}.m3u8',
      );
    });

    test('模板为空回 null', () {
      expect(
        formatLiveCatchupUrl(
          catchup: const LiveCatchup(),
          liveUrl: 'http://example.com/a.m3u8',
          start: DateTime(2026),
          end: DateTime(2026),
        ),
        isNull,
      );
    });
  });

  group('DRM 判定分类', () {
    LiveChannel channel({String licenseKey = '', String licenseType = ''}) {
      return LiveChannel(
        title: '测试台',
        url: 'https://example.com/live.mpd',
        licenseKey: licenseKey,
        licenseType: licenseType,
      );
    }

    test('Widevine 服务器型：地址 + 许可证请求头拆分', () {
      final info = liveDrmForChannel(
        channel(
          licenseKey:
              'https://lic.example/wv|Authorization=Bearer <redacted>&X-Id=7',
          licenseType: 'com.widevine.alpha',
        ),
      );
      expect(info, isNotNull);
      expect(info!.kind, LiveDrmKind.widevine);
      expect(info.key, 'https://lic.example/wv');
      expect(info.headers, {'Authorization': 'Bearer <redacted>', 'X-Id': '7'});
      expect(info.isServer, isTrue);
    });

    test('Kodi 模板段（R{SSM} 等）不被当成请求头', () {
      final info = liveDrmForChannel(
        channel(
          licenseKey: 'https://lic.example/wv||R{SSM}|R',
          licenseType: 'com.widevine.alpha',
        ),
      );
      expect(info, isNotNull);
      expect(info!.key, 'https://lic.example/wv');
      expect(info.headers, isEmpty);
    });

    test('PlayReady 服务器型分类', () {
      final info = liveDrmForChannel(
        channel(
          licenseKey: 'https://lic.example/pr',
          licenseType: 'com.microsoft.playready',
        ),
      );
      expect(info!.kind, LiveDrmKind.playReady);
    });

    test('type 为空归一化不出（不猜体系）', () {
      expect(
        liveDrmForChannel(channel(licenseKey: 'https://lic.example/wv')),
        isNull,
      );
      expect(liveDrmForChannel(channel()), isNull);
    });

    test('Widevine 给本地键（非地址）归一化不出', () {
      expect(
        liveDrmForChannel(
          channel(
            licenseKey:
                '00112233445566778899aabbccddeeff:'
                '000102030405060708090a0b0c0d0e0f',
            licenseType: 'com.widevine.alpha',
          ),
        ),
        isNull,
      );
    });

    test('ClearKey 十六进制 kid:key 转 JWK、字节往返一致', () {
      const kidHex = '000102030405060708090a0b0c0d0e0f';
      const keyHex = '00112233445566778899aabbccddeeff';
      final info = liveDrmForChannel(
        channel(licenseKey: '$kidHex:$keyHex', licenseType: 'org.w3.clearkey'),
      );
      expect(info, isNotNull);
      expect(info!.kind, LiveDrmKind.clearKey);
      expect(info.isServer, isFalse);
      final jwk = jsonDecode(info.key) as Map<String, dynamic>;
      expect(jwk['type'], 'temporary');
      final keys = jwk['keys'] as List;
      expect(keys, hasLength(1));
      final entry = keys.single as Map<String, dynamic>;
      expect(entry['kty'], 'oct');
      List<int> decode(String value) {
        var padded = value;
        while (padded.length % 4 != 0) {
          padded += '=';
        }
        return base64Url.decode(padded);
      }

      List<int> hexBytes(String hex) {
        final out = <int>[];
        for (var i = 0; i < hex.length; i += 2) {
          out.add(int.parse(hex.substring(i, i + 2), radix: 16));
        }
        return out;
      }

      expect(decode(entry['kid'] as String), hexBytes(kidHex));
      expect(decode(entry['k'] as String), hexBytes(keyHex));
    });

    test('drm_legacy 整行（类型|键）能还原', () {
      const kidHex = '000102030405060708090a0b0c0d0e0f';
      const keyHex = '00112233445566778899aabbccddeeff';
      final info = liveDrmForChannel(
        channel(
          licenseKey: 'org.w3.clearkey|$kidHex:$keyHex',
          licenseType: 'org.w3.clearkey',
        ),
      );
      expect(info, isNotNull);
      expect(info!.type, 'org.w3.clearkey');
      final jwk = jsonDecode(info.key) as Map<String, dynamic>;
      expect(jwk['keys'] as List, hasLength(1));
    });
  });
}
