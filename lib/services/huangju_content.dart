import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'drama_playback.dart';
import 'drama_site_content.dart';
import 'drama_sites.dart';
import 'local_media_proxy.dart';

const String _huangjuApiBase = 'https://api.huangju.net';
const String _huangjuSite = 'https://huangju.net';
const String _huangjuUserAgent =
    'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36';

String _huangjuUuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = bytes[6] & 0x0f | 0x40;
  bytes[8] = bytes[8] & 0x3f | 0x80;
  final hex =
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

dynamic _huangjuPayload(dynamic value) {
  if (value is Map<String, dynamic> &&
      value['data'] != null &&
      value['id'] == null &&
      value['items'] == null &&
      value['url'] == null) {
    return value['data'];
  }
  return value;
}

Map<String, String> huangjuSignedCookies(String setCookieHeader) {
  final cookies = <String, String>{};
  final pattern = RegExp(
    r'(?:^|[,;\s])CloudFront-(Policy|Signature|Key-Pair-Id)\s*=\s*([^;,\s]+)',
  );
  for (final match in pattern.allMatches(setCookieHeader)) {
    cookies['CloudFront-${match.group(1)}'] = match.group(2)!;
  }
  return cookies;
}

class HuangjuContentClient implements DramaSiteContentClient {
  HuangjuContentClient({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;
  String _deviceId = '';
  String _token = '';

  Map<String, String> get _headers => {
        'User-Agent': _huangjuUserAgent,
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Referer': '$_huangjuSite/',
        'Origin': _huangjuSite,
      };

  Future<String> _guestToken() async {
    if (_token.isNotEmpty) return _token;
    if (_deviceId.isEmpty) _deviceId = _huangjuUuid();
    final response = await _client
        .post(
          Uri.parse('$_huangjuApiBase/auth/guest'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({'deviceId': _deviceId}),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('剧果访客授权失败：HTTP ${response.statusCode}');
    }
    final row = jsonDecode(utf8.decode(response.bodyBytes));
    var token = '';
    if (row is Map) {
      token = '${row['token'] ?? ''}';
      if (token.isEmpty && row['data'] is Map) {
        token = '${(row['data'] as Map)['token'] ?? ''}';
      }
    }
    final valid = token.isNotEmpty &&
        token.length <= 8192 &&
        token.runes.every((r) => r > 32 && r < 127);
    if (!valid) throw StateError('剧果未返回有效的访客授权');
    _token = token;
    return token;
  }

  Future<({dynamic value, Map<String, String> headers})> _get(
    String route,
    Map<String, String> query,
  ) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await _guestToken();
      final uri = Uri.parse('$_huangjuApiBase$route').replace(
        queryParameters: query.isEmpty ? null : query,
      );
      final response = await _client
          .get(uri, headers: {..._headers, 'Authorization': 'Bearer $token'})
          .timeout(const Duration(seconds: 15));
      final authFailed =
          response.statusCode == 401 || response.statusCode == 403;
      if (attempt == 0 && authFailed) {
        try {
          jsonDecode(utf8.decode(response.bodyBytes));
          _token = '';
          continue;
        } catch (_) {}
      }
      if (response.statusCode != 200) {
        throw StateError('剧果请求失败：HTTP ${response.statusCode}');
      }
      return (
        value: _huangjuPayload(jsonDecode(utf8.decode(response.bodyBytes))),
        headers: response.headers,
      );
    }
    throw StateError('剧果访客授权已失效，请重试');
  }

  @override
  Future<List<DramaSiteCategory>> categories() async {
    final result = await _get('/categories', const {});
    final rows = result.value;
    if (rows is! List) throw StateError('剧果分类数据格式无效');
    final categories = [const DramaSiteCategory('@new', '最新')];
    final seen = {'@new'};
    for (final entry in rows) {
      if (entry is! Map) continue;
      final slug = '${entry['slug'] ?? ''}';
      final name = '${entry['name'] ?? ''}';
      if (slug == 'hot' || slug.isEmpty || name.isEmpty || seen.contains(slug)) {
        continue;
      }
      seen.add(slug);
      categories.add(DramaSiteCategory(slug, name));
    }
    return categories;
  }

  List<DramaSiteItem> _mapItems(dynamic value) {
    final row = value is Map<String, dynamic> ? value : null;
    if (row == null) throw StateError('剧果目录数据格式无效');
    final rows = row['items'];
    if (rows is! List) throw StateError('剧果目录数据格式无效');
    final items = <DramaSiteItem>[];
    for (final entry in rows) {
      if (entry is! Map) continue;
      final id = '${entry['id'] ?? ''}';
      final slug = '${entry['slug'] ?? ''}';
      final title = '${entry['title'] ?? ''}';
      if (id.isEmpty || slug.isEmpty || title.isEmpty) continue;
      final cover = '${entry['coverUrl'] ?? ''}';
      items.add(
        DramaSiteItem(
          id: '$slug-$id',
          title: title,
          cover: cover.isEmpty
              ? ''
              : Uri.parse(_huangjuSite).resolve(cover).toString(),
          remark: '${entry['totalEpisodes'] ?? ''}',
        ),
      );
    }
    return items;
  }

  int _pageSize(dynamic row) {
    if (row is Map && row['pageSize'] is num) {
      return (row['pageSize'] as num).toInt();
    }
    return 20;
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    final query = {'page': '$page'};
    if (categoryId == '@new') {
      query['sort'] = 'new';
    } else if (categoryId == 'all' || categoryId.isEmpty) {
      query['sort'] = 'hot';
    } else {
      query['category'] = categoryId;
    }
    final result = await _get('/dramas', query);
    final items = _mapItems(result.value);
    final row = result.value is Map ? result.value as Map : null;
    var hasMore = items.length >= _pageSize(row);
    if (row != null && row['total'] is num) {
      final total = (row['total'] as num).toInt();
      hasMore = page < (total + _pageSize(row) - 1) ~/ _pageSize(row);
    }
    return DramaSiteCatalogPage(items: items, hasMore: hasMore);
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final result = await _get('/dramas', {'q': query, 'page': '1'});
    return _mapItems(result.value);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final escaped = Uri.encodeComponent(seriesId);
    final result = await _get('/dramas/$escaped', const {});
    final row = result.value;
    if (row is! Map) throw StateError('剧果详情数据格式无效');
    final title = '${row['title'] ?? ''}';
    final cover = '${row['coverUrl'] ?? ''}';
    final rows = row['episodes'];
    if (rows is! List) throw StateError('剧果分集目录格式无效');
    final numbered = <({int number, DramaSiteEpisode episode})>[];
    final numbers = <int>{};
    for (var i = 0; i < rows.length; i++) {
      final episode = rows[i];
      if (episode is! Map) continue;
      if (episode['playable'] is bool && episode['playable'] == false) {
        continue;
      }
      final id = '${episode['id'] ?? ''}';
      if (id.isEmpty) continue;
      var number = i + 1;
      if (episode['epNo'] is num) {
        number = (episode['epNo'] as num).toInt();
        if (number == 0) number = i + 1;
      }
      if (!numbers.add(number)) continue;
      numbered.add(
        (
          number: number,
          episode: DramaSiteEpisode(
            videoId: id,
            title: '第 $number 集',
            seriesId: seriesId,
          ),
        ),
      );
    }
    numbered.sort((a, b) => a.number.compareTo(b.number));
    final episodes = [for (final entry in numbered) entry.episode];
    return DramaSiteDetail(
      id: seriesId,
      title: title,
      cover: cover.isEmpty
          ? ''
          : Uri.parse(_huangjuSite).resolve(cover).toString(),
      episodes: episodes,
    );
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    final escaped = Uri.encodeComponent(episode.videoId);
    final result = await _get('/play/$escaped', const {});
    final row = result.value;
    if (row is! Map) throw StateError('剧果播放数据格式无效');
    final address = '${row['url'] ?? ''}';
    if (address.isEmpty) throw StateError('剧果未返回播放地址');
    final setCookie = result.headers['set-cookie'] ?? '';
    final cookies = huangjuSignedCookies(setCookie);
    for (final name in [
      'CloudFront-Policy',
      'CloudFront-Signature',
      'CloudFront-Key-Pair-Id',
    ]) {
      final value = cookies[name] ?? '';
      if (value.isEmpty ||
          value.length > 8192 ||
          value.contains(RegExp(r'[,;"\\]')) ||
          value.runes.any((r) => r <= 32 || r >= 127)) {
        throw StateError('剧果未返回完整的媒体凭证，请重试');
      }
    }
    final expiresAt = row['expiresAt'];
    if (expiresAt != null) {
      DateTime? expiry;
      if (expiresAt is num) {
        final stamp = expiresAt.toInt();
        expiry = stamp > 100000000000
            ? DateTime.fromMillisecondsSinceEpoch(stamp)
            : DateTime.fromMillisecondsSinceEpoch(stamp * 1000);
      } else if (expiresAt is String) {
        expiry = DateTime.tryParse(expiresAt);
      }
      if (expiry != null && !DateTime.now().isBefore(expiry)) {
        throw StateError('剧果媒体凭证已过期，请检查设备时间后重试');
      }
    }
    final cookie = [
      'CloudFront-Policy=${cookies['CloudFront-Policy']}',
      'CloudFront-Signature=${cookies['CloudFront-Signature']}',
      'CloudFront-Key-Pair-Id=${cookies['CloudFront-Key-Pair-Id']}',
    ].join('; ');
    final proxyUrl = await LocalMediaProxy.instance.register(
      targetUrl: address,
      headers: {
        'Cookie': cookie,
        'Referer': '$_huangjuSite/',
        'User-Agent': _huangjuUserAgent,
      },
    );
    return DramaPlaySource(url: proxyUrl);
  }
}
