import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'aes_cipher.dart';
import 'drama_playback.dart';
import 'drama_site_content.dart';
import 'drama_sites.dart';

const String _yeguoDefaultSite = 'https://analyze.buxefaex.cc';
const String _yeguoTransitSite = 'https://ygdj7.com';
const String _yeguoUserAgent =
    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
    'Chrome/120.0 Mobile Safari/537.36';

const List<String> _yeguoFilterFields = [
  'theme',
  'setting',
  'background',
  'time',
  'recommend',
];

class _YeguoAccess {
  _YeguoAccess({
    required this.base,
    required this.site,
    required this.key,
    required this.iv,
    required this.signKey,
    required this.identifier,
    required this.loadedAt,
  });

  final String base;
  final String site;
  final List<int> key;
  final List<int> iv;
  final List<int> signKey;
  final String identifier;
  final DateTime loadedAt;
}

List<int>? _yeguoPublicBytes(String value) {
  if (!value.contains('_')) return utf8.encode(value);
  final out = <int>[];
  for (final part in value.split('_')) {
    final number = int.tryParse(part);
    if (number == null || number < 0 || number > 255) return null;
    out.add(number);
  }
  return out;
}

_YeguoAccess? _parseYeguoConfig(String script) {
  final pattern = RegExp(
    '\\b(version|mode|padding|key|iv|sign_key)\\s*:\\s*'
    '(?:[A-Za-z_\$][A-Za-z0-9_\$]*\\(\\s*)?'
    '["\'`]([^\r\n"\'`\\\\]{1,512})["\'`]',
  );
  final fields = <String, String>{};
  for (final match in pattern.allMatches(script)) {
    fields[match.group(1)!] = match.group(2)!;
  }
  if (fields['version'] != 'v0' ||
      fields['mode'] != 'CBC' ||
      fields['padding'] != 'Pkcs7') {
    return null;
  }
  final key = _yeguoPublicBytes(fields['key'] ?? '');
  final iv = _yeguoPublicBytes(fields['iv'] ?? '');
  final signKey = _yeguoPublicBytes(fields['sign_key'] ?? '');
  if (key == null ||
      iv == null ||
      signKey == null ||
      (key.length != 16 && key.length != 24 && key.length != 32) ||
      iv.length != 16 ||
      signKey.isEmpty ||
      signKey.length > 128) {
    return null;
  }
  return _YeguoAccess(
    base: '',
    site: '',
    key: key,
    iv: iv,
    signKey: signKey,
    identifier: '',
    loadedAt: DateTime.now(),
  );
}

/// 从脚本里找 api.php 接口入口：站方主脚本以形如
/// https://www.yeguodj.com/api.php 的前端控制器为接口地址，
/// 路由拼在其后；脚本里有多个时取第一个。
String? _apiPhpUrl(String script) {
  final match =
      RegExp(r'''https?://[^\s"'`]+/api\.php''').firstMatch(script);
  return match?.group(0);
}

String _yeguoSignature(Map<String, dynamic> envelope, List<int> signKey) {
  final names = envelope.keys
      .where((name) => name != 'sign' && name != '_ver')
      .where((name) => envelope[name] != null)
      .toList()
    ..sort();
  final pieces = <String>[];
  for (final name in names) {
    final value = envelope[name];
    String field;
    if (value is String) {
      field = value;
    } else if (value is num) {
      field = value.toString();
    } else if (value is bool) {
      field = value ? 'true' : 'false';
    } else {
      throw StateError('野果接口响应校验或解码失败');
    }
    if (name == 'data') field = field.replaceAll(' ', '+');
    pieces.add('$name=$field');
  }
  final digest = sha256.convert([...utf8.encode(pieces.join('&')), ...signKey]);
  final hexDigest = digest.toString();
  return md5.convert(utf8.encode(hexDigest)).toString();
}

Map<String, dynamic> _decodeYeguoResponse(
  List<int> body,
  _YeguoAccess access,
) {
  final envelope = jsonDecode(utf8.decode(body));
  if (envelope is! Map<String, dynamic>) {
    throw StateError('野果接口响应校验或解码失败');
  }
  final signature = '${envelope['sign'] ?? ''}';
  if (signature.isNotEmpty) {
    final expected = _yeguoSignature(envelope, access.signKey);
    if (expected != signature.toLowerCase()) {
      throw StateError('野果接口响应校验或解码失败');
    }
  }
  final encoded = envelope['data'];
  if (encoded is String) {
    final cleaned = encoded.trim().replaceAll(' ', '+');
    final ciphertext = base64.decode(cleaned);
    if (ciphertext.isEmpty || ciphertext.length % 16 != 0) {
      throw StateError('野果接口响应校验或解码失败');
    }
    final plain = aesCbcDecrypt(ciphertext, access.key, access.iv);
    final inner = jsonDecode(utf8.decode(plain));
    if (inner is! Map<String, dynamic>) {
      throw StateError('野果接口响应校验或解码失败');
    }
    return inner;
  }
  return envelope;
}

class YeguoContentClient implements DramaSiteContentClient {
  YeguoContentClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  _YeguoAccess? _access;
  Future<_YeguoAccess>? _discovering;

  Future<String> _fetchText(String url, {String? referer}) async {
    final headers = <String, String>{'User-Agent': _yeguoUserAgent};
    if (referer != null) headers['Referer'] = referer;
    final response = await _client
        .get(Uri.parse(url), headers: headers)
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw StateError('HTTP ${response.statusCode}');
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  String? _nuxtApiBase(String html) {
    final scriptMatch = RegExp(
      r'<script[^>]*id="__NUXT_DATA__"[^>]*>(.*?)</script>',
      dotAll: true,
    ).firstMatch(html);
    if (scriptMatch == null) return null;
    try {
      final table = jsonDecode(scriptMatch.group(1)!);
      if (table is! List || table.length > 100000) return null;
      for (final entry in table) {
        if (entry is Map && entry['apiBaseURL'] is int) {
          final index = entry['apiBaseURL'] as int;
          if (index >= 0 && index < table.length && table[index] is String) {
            return (table[index] as String).trim();
          }
        }
      }
    } catch (_) {}
    return null;
  }

  String? _moduleScriptUrl(String html, String pageUrl) {
    final page = Uri.tryParse(pageUrl);
    if (page == null) return null;
    for (final tag in RegExp(r'<script[^>]*>').allMatches(html)) {
      final text = tag.group(0)!;
      if (!text.contains('type="module"') &&
          !text.contains("type='module'")) {
        continue;
      }
      final src = RegExp('src="([^"]+)"').firstMatch(text)?.group(1) ??
          RegExp("src='([^']+)'").firstMatch(text)?.group(1);
      if (src == null) continue;
      final resolved = page.resolve(src);
      if (resolved.scheme != page.scheme ||
          resolved.host != page.host ||
          !resolved.path.startsWith('/_nuxt/') ||
          !resolved.path.endsWith('.js')) {
        continue;
      }
      return resolved.toString();
    }
    return null;
  }

  Future<_YeguoAccess?> _discoverAt(String site) async {
    final pageUrl = '$site/';
    final html = await _fetchText(pageUrl, referer: pageUrl);
    // 站方首页的 __NUXT_DATA__ 已不再带 apiBaseURL（2026-11-05 实测：
    // 载荷里只有 img_base、brand_domain 等配置，没有接口地址字段）。
    // 接口地址改从脚本里找：站方主脚本以 api.php 前端控制器为接口
    // 入口（如 https://www.yeguodj.com/api.php），路由拼在其后；
    // 载荷里仍带 apiBaseURL 时沿用旧行为；两者都没有则整站判死。
    final foundApiBase = _nuxtApiBase(html);
    final entry = _moduleScriptUrl(html, pageUrl);
    if (entry == null) return null;
    final entryBody = await _fetchText(entry, referer: pageUrl);
    final importPattern = RegExp(
      r'''import\s*\{([^{};]+)\}\s*from\s*["'`]([^"'`]+)["'`]''',
    );
    final imports = importPattern.allMatches(entryBody).toList();
    imports.sort((a, b) {
      final aComma = a.group(1)!.contains(',');
      final bComma = b.group(1)!.contains(',');
      if (aComma == bComma) return 0;
      return aComma ? 1 : -1;
    });
    final seen = <String>{};
    _YeguoAccess? foundConfig;
    String? apiPhp;
    for (final imported in imports) {
      if (imported.group(1)!.length > 2400) continue;
      final entryUri = Uri.tryParse(entry);
      final ref = Uri.tryParse(imported.group(2)!);
      if (entryUri == null || ref == null) continue;
      final address = entryUri.resolveUri(ref);
      if (address.scheme != entryUri.scheme ||
          address.host != entryUri.host ||
          !address.path.startsWith('/_nuxt/') ||
          !address.path.endsWith('.js') ||
          !seen.add(address.toString())) {
        continue;
      }
      if (seen.length > 20) break;
      final body = await _fetchText(address.toString(), referer: pageUrl);
      apiPhp ??= _apiPhpUrl(body);
      final parsed = _parseYeguoConfig(body);
      if (parsed != null && foundConfig == null) foundConfig = parsed;
      if (foundConfig != null && apiPhp != null) break;
    }
    if (foundConfig == null) return null;
    final base = (foundApiBase != null && foundApiBase.isNotEmpty)
        ? foundApiBase
        : apiPhp;
    if (base == null || base.isEmpty) return null;
    final random = Random.secure();
    final idBytes = List<int>.generate(16, (_) => random.nextInt(256));
    final identifier =
        idBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return _YeguoAccess(
      base: base.trim().replaceAll(RegExp(r'/+$'), ''),
      site: site,
      key: foundConfig.key,
      iv: foundConfig.iv,
      signKey: foundConfig.signKey,
      identifier: identifier,
      loadedAt: DateTime.now(),
    );
  }

  List<String> _transitCandidates(String body) {
    final sites = <String>[];
    final seen = <String>{};
    void add(String site) {
      final uri = Uri.tryParse(site);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.path.isNotEmpty && uri.path != '/' ||
          (uri.query.isNotEmpty) ||
          site == _yeguoTransitSite ||
          !seen.add(site)) {
        return;
      }
      final host = uri.host.toLowerCase();
      if (host.endsWith('.buxefaex.cc') || host.endsWith('.fzchosdi.cc')) {
        sites.add('https://$host');
      }
    }

    var text = body;
    for (final match in RegExp(r'''Base64\.decode\(["']([A-Za-z0-9+/=]{128,})["']\)''')
        .allMatches(body)
        .take(4)) {
      try {
        text += '\n${utf8.decode(base64.decode(match.group(1)!))}';
      } catch (_) {}
    }
    for (final match in RegExp(r'https?://[a-z0-9-]+(?:\.[a-z0-9-]+)+/?')
        .allMatches(text)
        .take(32)) {
      add(match.group(0)!);
    }
    final wordsMatch =
        RegExp(r'''words\s*=\s*"([^"]+)"\s*\.split\(","\)''')
            .firstMatch(text);
    final words = <String>[];
    if (wordsMatch != null) {
      for (final word in wordsMatch.group(1)!.split(',')) {
        final cleaned = word.trim().toLowerCase();
        if (RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(cleaned)) {
          words.add(cleaned);
        }
      }
    }
    final seeds = words.isEmpty ? ['analyze'] : words;
    for (final match in RegExp(r'''\+?\s*["']\.([a-z0-9-]+(?:\.[a-z0-9-]+)+)["']''')
        .allMatches(text)
        .take(8)) {
      final suffix = match.group(1)!.trim().replaceAll(RegExp(r'^\.+'), '');
      for (final word in seeds.take(4)) {
        add('https://$word.$suffix');
      }
    }
    return sites;
  }

  Future<_YeguoAccess> _configuration() async {
    final cached = _access;
    if (cached != null &&
        DateTime.now().difference(cached.loadedAt) < const Duration(hours: 1)) {
      return cached;
    }
    if (_discovering != null) return _discovering!;
    final future = _discover();
    _discovering = future;
    try {
      final access = await future;
      _access = access;
      return access;
    } finally {
      _discovering = null;
    }
  }

  Future<_YeguoAccess> _discover() async {
    final sites = <String>[_yeguoDefaultSite];
    final seen = <String>{_yeguoDefaultSite};
    StateError? lastError;
    for (var i = 0; i < sites.length; i++) {
      final site = sites[i];
      try {
        final access = await _discoverAt(site);
        if (access != null) return access;
      } catch (error) {
        lastError = StateError('$error');
      }
      if (i == 0) {
        try {
          final transit = await _fetchText('$_yeguoTransitSite/');
          for (final candidate in _transitCandidates(transit)) {
            if (seen.add(candidate)) sites.add(candidate);
          }
        } catch (_) {}
      }
    }
    throw StateError('野果线路暂不可用，请稍后重试${lastError == null ? '' : '：$lastError'}');
  }

  Future<Map<String, dynamic>> _call(
    String route,
    Map<String, String> parameters, {
    bool isGet = false,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final access = await _configuration();
      final values = <String, String>{
        'bundleId': 'com.pwa.mater',
        'version': '1.3.2',
        'oauth_type': 'web',
        'language': 'zh',
        'via': 'pwa',
        'oauth_id': access.identifier,
        'trace_id': access.identifier,
        'token': '',
        ...parameters,
      };
      final uri = Uri.parse('${access.base}$route');
      http.Response response;
      if (isGet) {
        response = await _client
            .get(
              uri.replace(queryParameters: values),
              headers: {
                'User-Agent': _yeguoUserAgent,
                'Accept': 'application/json, text/plain, */*',
                'Origin': access.site,
                'Referer': '${access.site}/',
              },
            )
            .timeout(const Duration(seconds: 30));
      } else {
        response = await _client
            .post(
              uri,
              headers: {
                'User-Agent': _yeguoUserAgent,
                'Accept': 'application/json, text/plain, */*',
                'Content-Type': 'application/x-www-form-urlencoded',
                'Origin': access.site,
                'Referer': '${access.site}/',
              },
              body: Uri(queryParameters: values).query,
            )
            .timeout(const Duration(seconds: 30));
      }
      if (response.statusCode != 200) {
        throw StateError('野果请求失败：HTTP ${response.statusCode}');
      }
      Map<String, dynamic> payload;
      try {
        payload = _decodeYeguoResponse(response.bodyBytes, access);
      } catch (_) {
        if (attempt == 0) {
          if (identical(_access, access)) _access = null;
          continue;
        }
        rethrow;
      }
      if ('${payload['status'] ?? ''}' != '1') {
        if ('${payload['status'] ?? ''}' == '-1') {
          throw StateError('野果当前内容需要站源授权');
        }
        throw StateError('野果请求未完成：${payload['msg'] ?? '请稍后重试'}');
      }
      final data = payload['data'];
      if (data is! Map<String, dynamic>) {
        throw StateError('野果返回的数据格式无效');
      }
      return data;
    }
    throw StateError('野果接口响应校验或解码失败');
  }

  @override
  Future<List<DramaSiteCategory>> categories() async {
    final data = await _call('/api/home/contentOptions', const {}, isGet: true);
    final filters = data['video_filter'];
    if (filters is! Map) throw StateError('野果分类数据格式无效');
    final categories = <DramaSiteCategory>[];
    final seen = <String>{};
    for (final field in _yeguoFilterFields) {
      final filter = filters[field];
      if (filter is! Map) continue;
      final options = filter['list'];
      if (options is! List) continue;
      for (final option in options) {
        if (option is! Map) continue;
        final value = '${option['value'] ?? ''}';
        final name = '${option['name'] ?? ''}';
        if (value == '0' || value.isEmpty || name.isEmpty) continue;
        final id = '$field:$value';
        if (!seen.add(id)) continue;
        categories.add(DramaSiteCategory(id, name));
      }
    }
    if (categories.isEmpty) throw StateError('野果暂未返回分类');
    return categories;
  }

  List<DramaSiteItem> _mapItems(dynamic value, String site) {
    if (value is! Map) throw StateError('野果目录格式无效');
    final rows = value['list'];
    if (rows is! List) throw StateError('野果目录格式无效');
    final items = <DramaSiteItem>[];
    for (final entry in rows) {
      if (entry is! Map) continue;
      final id = '${entry['video_id'] ?? entry['id'] ?? ''}';
      final title = '${entry['title'] ?? ''}';
      if (id.isEmpty || title.isEmpty) continue;
      var count = 0;
      for (final key in ['episode_count', 'episodes', 'total_serial']) {
        final raw = entry[key];
        if (raw is num && raw.toInt() > count) count = raw.toInt();
      }
      final cover = '${entry['cover'] ?? ''}';
      items.add(
        DramaSiteItem(
          id: id,
          title: title,
          cover: cover.isEmpty
              ? ''
              : Uri.parse('$site/').resolve(cover).toString(),
          remark: count > 0 ? '$count集' : '',
        ),
      );
    }
    return items;
  }

  bool _hasMore(Map data, int page, List items) {
    if (data['has_more'] is bool) return data['has_more'] as bool;
    const limit = 20;
    if (data['total'] is num) {
      final total = (data['total'] as num).toInt();
      return page < (total + limit - 1) ~/ limit;
    }
    return items.length >= limit;
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    final params = {'page': '$page', 'limit': '20'};
    if (categoryId != 'all' && categoryId.isNotEmpty) {
      final cut = categoryId.indexOf(':');
      if (cut <= 0) throw StateError('野果分类无效');
      params[categoryId.substring(0, cut)] = categoryId.substring(cut + 1);
    }
    final data = await _call('/api/theater/exploreList', params);
    final items = _mapItems(data, _access?.site ?? _yeguoDefaultSite);
    return DramaSiteCatalogPage(
      items: items,
      hasMore: _hasMore(data, page, items),
    );
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final data = await _call('/api/search/result', {
      'keyword': query,
      'tab': 'video',
      'page': '1',
      'limit': '20',
    });
    return _mapItems(data, _access?.site ?? _yeguoDefaultSite);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final data = await _call('/api/playlet/detail', {
      'video_id': seriesId,
      'id': seriesId,
      'episode_id': '0',
      'related_limit': '0',
    });
    final site = _access?.site ?? _yeguoDefaultSite;
    final title = '${data['title'] ?? ''}';
    final cover = '${data['cover'] ?? ''}';
    final rows = data['episodes'];
    if (rows is! List) throw StateError('野果分集目录格式无效');
    final numbered = <({int number, DramaSiteEpisode episode})>[];
    final numbers = <int>{};
    for (final entry in rows) {
      if (entry is! Map) continue;
      if (entry['is_adv'] == true || entry['is_adv'] == '1') continue;
      final id = '${entry['id'] ?? ''}';
      final sort = entry['sort'];
      final number = sort is num ? sort.toInt() : -1;
      if (id.isEmpty || number < 1 || !numbers.add(number)) continue;
      final epTitle = '${entry['title'] ?? ''}';
      numbered.add(
        (
          number: number,
          episode: DramaSiteEpisode(
            videoId: id,
            title: epTitle.isEmpty ? '第 $number 集' : epTitle,
            seriesId: seriesId,
          ),
        ),
      );
    }
    numbered.sort((a, b) => a.number.compareTo(b.number));
    return DramaSiteDetail(
      id: seriesId,
      title: title,
      cover:
          cover.isEmpty ? '' : Uri.parse('$site/').resolve(cover).toString(),
      episodes: [for (final entry in numbered) entry.episode],
    );
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    final data = await _call('/api/playlet/play', {
      'playlet_id': episode.seriesId,
      'video_id': episode.seriesId,
      'episode_id': episode.videoId,
    });
    if ('${data['playlet_id'] ?? ''}' != episode.seriesId ||
        '${data['id'] ?? ''}' != episode.videoId) {
      throw StateError('野果返回的播放地址与请求分集不符');
    }
    if (data['is_adv'] == true || data['is_adv'] == '1') {
      throw StateError('野果未返回该集正片，请重试');
    }
    final site = _access?.site ?? _yeguoDefaultSite;
    final sort = data['episode_sort'];
    final number = sort is num ? sort.toInt() : 1;
    var referer = '$site/drama/video/${episode.seriesId}/';
    if (number > 1) referer += 'ep-$number/';
    final variants = <DramaPlayVariant>[];
    var height = 0;
    final resolution = '${data['resolution'] ?? ''}';
    final parts = resolution.toLowerCase().split('x');
    if (parts.length == 2) {
      final width = int.tryParse(parts[0]) ?? 0;
      final tall = int.tryParse(parts[1]) ?? 0;
      if (width > 0 && tall > 0) height = width < tall ? width : tall;
    }
    for (final field in ['video_url', 'video_url_h265']) {
      final raw = '${data[field] ?? ''}';
      if (raw.isEmpty) continue;
      final resolved = Uri.parse(referer).resolve(raw).toString();
      if (!variants.any((v) => v.url == resolved)) {
        variants.add(
          DramaPlayVariant(
            name: field == 'video_url' ? '原画' : 'H265',
            url: resolved,
            height: height,
          ),
        );
      }
    }
    if (variants.isEmpty) {
      throw StateError('野果未提供该集播放地址，请重试或确认站源权限');
    }
    return DramaPlaySource(
      url: variants.first.url,
      variants: variants.length > 1 ? variants : const [],
    );
  }
}
