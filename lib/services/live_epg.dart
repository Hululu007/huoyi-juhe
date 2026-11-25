import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'live_sources.dart';

/// 一条节目（XMLTV 的一个 programme）：频道 id、标题、起止时间
/// （已换算成本地时间）。
class LiveEpgProgramme {
  const LiveEpgProgramme({
    required this.channelId,
    required this.title,
    required this.start,
    required this.end,
  });

  final String channelId;
  final String title;
  final DateTime start;
  final DateTime end;

  bool contains(DateTime at) => !at.isBefore(start) && at.isBefore(end);
}

/// 一份解析好的节目单：按 XMLTV 频道 id 存节目，另存每个 id 的
/// 显示名（对台兜底按名匹配用）。
class LiveEpgGuide {
  const LiveEpgGuide({required this.byChannelId, required this.namesById});

  final Map<String, List<LiveEpgProgramme>> byChannelId;
  final Map<String, List<String>> namesById;

  static const empty = LiveEpgGuide(byChannelId: {}, namesById: {});

  bool get isEmpty => byChannelId.isEmpty;

  /// 找某个频道的节目表：先按 tvg-id 精确对台，对不上再按
  /// tvg-name / 频道名与节目单里的显示名对。
  List<LiveEpgProgramme> programmesFor(LiveChannel channel) {
    if (channel.tvgId.isNotEmpty) {
      final hit = byChannelId[channel.tvgId];
      if (hit != null && hit.isNotEmpty) return hit;
    }
    final wanted = {
      if (channel.tvgName.isNotEmpty) channel.tvgName,
      channel.title,
    };
    for (final entry in namesById.entries) {
      if (entry.value.any(wanted.contains)) {
        final hit = byChannelId[entry.key];
        if (hit != null && hit.isNotEmpty) return hit;
      }
    }
    return const [];
  }

  /// 某频道在 [at] 时刻正在播与紧接着的下一条；没有就返回 null。
  ({LiveEpgProgramme? now, LiveEpgProgramme? next}) nowNext(
    LiveChannel channel,
    DateTime at,
  ) {
    final list = programmesFor(channel);
    LiveEpgProgramme? now;
    LiveEpgProgramme? next;
    for (final item in list) {
      if (item.contains(at)) {
        now = item;
      } else if (item.start.isAfter(at)) {
        next = item;
        break;
      }
    }
    return (now: now, next: next);
  }
}

final _channelTag = RegExp(
  r'<channel\s+[^>]*?id="([^"]+)"[^>]*>(.*?)</channel>',
  dotAll: true,
);
final _displayName = RegExp(r'<display-name[^>]*>([^<]*)</display-name>');
final _programmeTag = RegExp(
  r'<programme\s+([^>]*)>(.*?)</programme>',
  dotAll: true,
);
final _titleTag = RegExp(r'<title[^>]*>([^<]*)</title>');
final _attrPattern = RegExp(r'(\w+)="([^"]*)"');

String _xmlUnescape(String text) => text
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (match) => String.fromCharCode(int.tryParse(match.group(1)!) ?? 0),
    )
    .replaceAll('&amp;', '&');

/// XMLTV 时间：`yyyyMMddHHmmss +0800`，时区可缺（缺了按本地时间）。
DateTime? _parseXmltvTime(String raw) {
  final text = raw.trim();
  if (text.length < 14) return null;
  try {
    final year = int.parse(text.substring(0, 4));
    final month = int.parse(text.substring(4, 6));
    final day = int.parse(text.substring(6, 8));
    final hour = int.parse(text.substring(8, 10));
    final minute = int.parse(text.substring(10, 12));
    final second = int.parse(text.substring(12, 14));
    final rest = text.substring(14).trim();
    if (rest.isEmpty) {
      return DateTime(year, month, day, hour, minute, second);
    }
    final sign = rest.startsWith('-') ? -1 : 1;
    final digits = rest.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 4) {
      return DateTime(year, month, day, hour, minute, second);
    }
    final offset = Duration(
      hours: int.parse(digits.substring(0, 2)),
      minutes: int.parse(digits.substring(2, 4)),
    );
    final utc = DateTime.utc(
      year,
      month,
      day,
      hour,
      minute,
      second,
    ).subtract(offset * sign);
    return utc.toLocal();
  } catch (_) {
    return null;
  }
}

/// 解析 XMLTV 文本（不依赖 XML 库：这类文件是机器生成的固定
/// 结构，正则扫描足够；解析不出的条目跳过，不整份失败）。
LiveEpgGuide parseXmltvGuide(String xml) {
  final names = <String, List<String>>{};
  for (final match in _channelTag.allMatches(xml)) {
    final id = match.group(1)!;
    final body = match.group(2)!;
    names[id] = [
      for (final name in _displayName.allMatches(body))
        _xmlUnescape(name.group(1)!).trim(),
    ]..removeWhere((name) => name.isEmpty);
  }
  final programmes = <String, List<LiveEpgProgramme>>{};
  for (final match in _programmeTag.allMatches(xml)) {
    final attrs = {
      for (final attr in _attrPattern.allMatches(match.group(1)!))
        attr.group(1)!: attr.group(2)!,
    };
    final channelId = attrs['channel'] ?? '';
    final start = _parseXmltvTime(attrs['start'] ?? '');
    final end = _parseXmltvTime(attrs['stop'] ?? '');
    if (channelId.isEmpty || start == null || end == null) continue;
    final titleMatch = _titleTag.firstMatch(match.group(2)!);
    final title = titleMatch == null
        ? ''
        : _xmlUnescape(titleMatch.group(1)!).trim();
    if (title.isEmpty) continue;
    programmes
        .putIfAbsent(channelId, () => [])
        .add(
          LiveEpgProgramme(
            channelId: channelId,
            title: title,
            start: start,
            end: end,
          ),
        );
  }
  for (final list in programmes.values) {
    list.sort((a, b) => a.start.compareTo(b.start));
  }
  return LiveEpgGuide(byChannelId: programmes, namesById: names);
}

/// 节目单拉取与缓存：同一缓存键内存里只留一份；落盘缓存 6 小时
/// 内不重拉，拉取失败时有旧缓存就先用旧的，不让节目单拖垮直播页。
/// 缓存键默认是节目单地址；按源加载（loadForSource）时键里带源
/// id，两个源共用同一节目单地址也不会串缓存。
class LiveEpgService {
  LiveEpgService._();

  static final LiveEpgService instance = LiveEpgService._();

  /// 测试注入：换掉真实网络拉取。
  static Future<List<int>> Function(String url)? debugFetcher;

  /// 测试注入：换掉缓存目录。
  static Directory? debugCacheDir;

  static const _freshFor = Duration(hours: 6);
  static const _maxBytes = 32 << 20;

  final Map<String, LiveEpgGuide> _memory = {};
  final Map<String, Future<LiveEpgGuide>> _inflight = {};

  Future<LiveEpgGuide> load(String url, {bool force = false}) {
    final key = url.trim();
    if (key.isEmpty) return Future.value(LiveEpgGuide.empty);
    return _loadKeyed(key, key, force: force);
  }

  /// 按直播源加载节目单：用源登记的 epg 地址拉取，源没登记 epg
  /// 时直接回空节目单（不发请求）。页面接线在后续包，这里只打通
  /// 「给定当前源 → 按源 epg 地址加载」的数据通路。
  Future<LiveEpgGuide> loadForSource(LiveSource source, {bool force = false}) {
    final url = source.epg.trim();
    if (url.isEmpty) return Future.value(LiveEpgGuide.empty);
    return _loadKeyed('${source.id}\u0000$url', url, force: force);
  }

  Future<LiveEpgGuide> _loadKeyed(
    String key,
    String url, {
    required bool force,
  }) {
    if (!force) {
      final cached = _memory[key];
      if (cached != null) return Future.value(cached);
      final inflight = _inflight[key];
      if (inflight != null) return inflight;
    }
    final future = _load(key, url, force: force);
    _inflight[key] = future;
    return future.whenComplete(() {
      if (identical(_inflight[key], future)) _inflight.remove(key);
    });
  }

  Future<LiveEpgGuide> _load(
    String key,
    String url, {
    required bool force,
  }) async {
    final file = await _cacheFile(key);
    if (!force && file != null && await file.exists()) {
      final stat = await file.stat();
      if (DateTime.now().difference(stat.modified) < _freshFor) {
        final guide = await _readGuide(file);
        if (guide != null) {
          _memory[key] = guide;
          return guide;
        }
      }
    }
    try {
      final bytes = await _fetchBytes(url);
      if (file != null) {
        try {
          await file.writeAsBytes(bytes, flush: true);
        } catch (_) {}
      }
      final guide = parseXmltvGuide(_decode(bytes));
      _memory[key] = guide;
      return guide;
    } catch (error) {
      // 拉不到时退回旧缓存（哪怕过期）：节目单是增强项，
      // 有旧的先顶着；连缓存都没有才把错误抛给调用方。
      if (file != null && await file.exists()) {
        final guide = await _readGuide(file);
        if (guide != null) {
          _memory[key] = guide;
          return guide;
        }
      }
      throw StateError('节目单拉取失败：$error');
    }
  }

  Future<LiveEpgGuide?> _readGuide(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final guide = parseXmltvGuide(_decode(bytes));
      return guide.isEmpty ? null : guide;
    } catch (_) {
      return null;
    }
  }

  String _decode(List<int> bytes) {
    var data = bytes;
    if (data.length > 2 && data[0] == 0x1f && data[1] == 0x8b) {
      data = GZipCodec().decode(data);
    }
    return utf8.decode(data, allowMalformed: true);
  }

  Future<List<int>> _fetchBytes(String url) async {
    final override = debugFetcher;
    if (override != null) return override(url);
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw StateError('节目单地址无效');
    }
    final response = await http.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('节目单返回 ${response.statusCode}');
    }
    if (response.bodyBytes.length > _maxBytes) {
      throw StateError('节目单数据过大');
    }
    return response.bodyBytes;
  }

  Future<File?> _cacheFile(String key) async {
    try {
      final dir = debugCacheDir ?? await _directory();
      // FNV-1a 哈希做文件名：键里什么字符都可能有，不能直接拼路径。
      var hash = 0x811c9dc5;
      for (final unit in key.codeUnits) {
        hash ^= unit;
        hash = (hash * 0x01000193) & 0xffffffff;
      }
      return File('${dir.path}/epg_${hash.toRadixString(16)}.xml');
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _directory() async {
    final documents = await getApplicationDocumentsDirectory();
    final dir = Directory('${documents.path}/epg_cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
