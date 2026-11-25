// who's.json 内置索引（懒加载单例）。
//
// 数据来源（只读，不写盘、不改库、不联网）：
//   assets/whos_video_catalog.txt.gz —— 视频目录，339,526 行，紧凑格式
//     `番号||标题||封面||播放地址`（播放地址已去掉 `正片$` 前缀）。
//   assets/whos_actress_map.txt.gz —— 番号→女优，431,165 行，紧凑格式
//     `番号||女优1;女优2`（2026-11-24 合并版：who's pairs + 名册 + 三站 +
//     v3 素人归属；`素人`行仍在文件里，解析时过滤——归到真女优名下的
//     番号已挂真名不受影响，剩下的素人番号走数据库的人物关联）。
// 生成脚本见工作目录 build_whos_resources.py；分隔符安全性已验
// （`||` / `;` 不与值冲突；标题里的 U+2028 行分隔符已换成空格）。
//
// 数据实话（2026-11-23 实测，写进设计里了）：
//   whos.json 是纯视频目录——番号/标题/封面/播放地址全是 100%，但演员
//   只有 4 条、导演 0 条、头像 0 条；type_name 全是 `日本AV` 只有一个值。
//   所以演员数据只能从 actress_map 来，分类只能走数据库 video_category。
//   详情页演员区：先查这里的索引，有就显示；没有就不显示（不编、不现取）。
//
// 内存：只常驻两张索引 + 演员映射里有的视频行（244,336 个番号，约 50MB 级）。
//   全量 339,526 行视频不常驻——没有女优的视频走演员索引本来也到不了，
//   封面/标题由数据库兜底。以后要全量再放开（资源已内置，只改加载范围）。
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

import 'actress_models.dart';

/// who's 视频目录里的一行（只保留演员映射里有的番号）。
class WhosVideo {
  const WhosVideo({
    required this.code,
    required this.title,
    required this.pic,
    required this.m3u8,
  });

  /// 番号，全大写标准写法。
  final String code;

  /// 标题。
  final String title;

  /// 封面地址（v.hersav.me）。
  final String pic;

  /// 播放地址（who's m3u8 直链，不过期）。
  final String m3u8;
}

/// who's.json 内置索引：番号↔演员双向索引 + 视频目录（懒加载单例）。
///
/// 查法（只读，全是 O(1) 的 Map 取，无全表扫）：
/// 1. `castForCode`：番号 → 演员名列表（女优在前、男优在后；这里只有女优，
///    男优由数据库 sex 字段与三站数据认，不在这里）。
/// 2. `codesForActor`：演员名 → 番号列表（已按原顺序，点卡直接取前 N 页）。
/// 3. `videoForCode`：番号 → 视频行（标题/封面/播放地址），只在演员映射
///    里有的番号才有；没有返回 null（由数据库兜底）。
/// 4. `match`：详情页匹配入口，沿用 JavCodeMeta.match 口径（先番号、再标题
///    兜底），但这里只有番号能命中标题索引（视频目录有标题）。
///
/// 失败回落：资源缺失/损坏时返回空索引（`isEmpty` 为真），绝不抛错、
/// 绝不挡页面；调用方按“没有 json 索引”走纯数据库模式。
class WhosJsonIndex {
  WhosJsonIndex._(this._codeToActors, this._actorToCodes, this._codeToVideo);

  /// 懒加载单例：首次调用时读两个 gz、解压、建索引；之后常驻内存。
  static WhosJsonIndex? _instance;
  static Future<WhosJsonIndex> get instance async {
    final existing = _instance;
    if (existing != null) return existing;
    final loaded = await _load();
    _instance = loaded;
    return loaded;
  }

  /// 测试/注入用：直接拿现成行建索引（不读资源）。
  factory WhosJsonIndex.fromLines({
    required Iterable<String> catalogLines,
    required Iterable<String> mapLines,
  }) {
    // 建双向索引：同一番号在多行出现时合并（不覆盖、不重复）。
    // 真实资源里番号唯一，但加载器要对重复行免疫。
    final codeToActorSets = <String, Set<String>>{};
    final actorToCodeSets = <String, Set<String>>{};
    for (final line in mapLines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split('||');
      if (parts.length != 2) continue;
      final code = parts[0].trim().toUpperCase();
      if (code.isEmpty) continue;
      final names = parts[1]
          .split(';')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty && s != '素人')
          .toList();
      if (names.isEmpty) continue;
      final actorSet = codeToActorSets.putIfAbsent(code, () => <String>{});
      for (final name in names) {
        // 同一番号+同一演员只记一次，番号列表不重复。
        if (actorSet.add(name)) {
          actorToCodeSets.putIfAbsent(name, () => <String>{}).add(code);
        }
      }
    }
    final codeToActors = <String, List<String>>{
      for (final e in codeToActorSets.entries) e.key: e.value.toList(),
    };
    final actorToCodes = <String, List<String>>{
      for (final e in actorToCodeSets.entries) e.key: e.value.toList(),
    };
    // 视频行只留演员映射里有的番号（点演员卡能到的视频）。
    final codeToVideo = <String, WhosVideo>{};
    for (final line in catalogLines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split('||');
      if (parts.length != 4) continue;
      final code = parts[0].trim().toUpperCase();
      if (code.isEmpty || !codeToActors.containsKey(code)) continue;
      codeToVideo[code] = WhosVideo(
        code: code,
        title: parts[1].trim(),
        pic: parts[2].trim(),
        m3u8: parts[3].trim(),
      );
    }
    return WhosJsonIndex._(codeToActors, actorToCodes, codeToVideo);
  }

  static const catalogAsset = 'assets/whos_video_catalog.txt.gz';
  static const mapAsset = 'assets/whos_actress_map.txt.gz';

  static Future<WhosJsonIndex> _load() async {
    try {
      final catalogBytes = await rootBundle.load(catalogAsset);
      final mapBytes = await rootBundle.load(mapAsset);
      final catalogText = utf8.decode(
        const GZipDecoder().decodeBytes(catalogBytes.buffer.asUint8List()),
      );
      final mapText = utf8.decode(
        const GZipDecoder().decodeBytes(mapBytes.buffer.asUint8List()),
      );
      return WhosJsonIndex.fromLines(
        catalogLines: catalogText.split('\n'),
        mapLines: mapText.split('\n'),
      );
    } catch (_) {
      // 资源缺失/损坏：空索引，调用方回落到纯数据库模式。
      return WhosJsonIndex._({}, {}, {});
    }
  }

  final Map<String, List<String>> _codeToActors;
  final Map<String, List<String>> _actorToCodes;
  final Map<String, WhosVideo> _codeToVideo;

  /// 索引是否为空（加载失败时为真）。
  bool get isEmpty => _codeToActors.isEmpty;

  /// 有演员关联的番号数。
  int get codeCount => _codeToActors.length;

  /// 有作品的演员数。
  int get actorCount => _actorToCodes.length;

  /// 有视频行的番号数（演员映射里有的番号）。
  int get videoCount => _codeToVideo.length;

  /// 番号 → 演员名列表；查不到返回空列表（不返回 null，调用方直接判空）。
  /// 传入的番号可以是小写/带下划线等写法，内部先归一化。
  List<String> castForCode(String code) {
    final key = code.trim().toUpperCase();
    if (key.isEmpty) return const [];
    return _codeToActors[key] ??
        _codeToActors[normalizeAvCode(key)] ??
        const [];
  }

  /// 演员名 → 番号列表；查不到返回空列表。
  /// 演员名去首尾空白后精确匹配（异体字不强行合并，各挂各的番号）。
  List<String> codesForActor(String name) {
    final key = name.trim();
    if (key.isEmpty) return const [];
    return _actorToCodes[key] ?? const [];
  }

  /// 番号 → 视频行（标题/封面/播放地址）；没有返回 null。
  WhosVideo? videoForCode(String code) {
    final key = code.trim().toUpperCase();
    if (key.isEmpty) return null;
    return _codeToVideo[key] ??
        _codeToVideo[normalizeAvCode(key)];
  }

  // —— 无库时 JSON 顶首页用（2026-11-26）：只读分页访问器 ——
  // 不改内存策略：仍只常驻演员映射里有的视频行；排序结果首次
  // 算完缓存，后续切页直接切片。

  List<({String name, int works})>? _actorsByWorksCache;

  /// 全部有作品的演员，按番号数倒序、同数按名字排（名单页用）。
  List<({String name, int works})> actorsByWorks() {
    final cached = _actorsByWorksCache;
    if (cached != null) return cached;
    final rows = <({String name, int works})>[
      for (final entry in _actorToCodes.entries)
        (name: entry.key, works: entry.value.length),
    ]..sort((a, b) {
      final byWorks = b.works.compareTo(a.works);
      return byWorks != 0 ? byWorks : a.name.compareTo(b.name);
    });
    _actorsByWorksCache = rows;
    return rows;
  }

  List<WhosVideo>? _videoListCache;

  /// 视频目录全量（目录原顺序），作品流分页用。
  List<WhosVideo> get _videoList =>
      _videoListCache ??= _codeToVideo.values.toList();

  /// 视频目录全量（目录原顺序）：本地库 asset 模式按厂牌分组用。
  List<WhosVideo> get allVideos => _videoList;

  /// 作品流一页：query 非空时按番号/标题包含过滤（大小写不敏感）。
  List<WhosVideo> videoPage({
    required int offset,
    required int limit,
    String query = '',
  }) {
    final q = query.trim().toLowerCase();
    final all = q.isEmpty
        ? _videoList
        : [
            for (final video in _videoList)
              if (video.code.toLowerCase().contains(q) ||
                  video.title.toLowerCase().contains(q))
                video,
          ];
    if (offset >= all.length) return const [];
    final end = (offset + limit).clamp(0, all.length);
    return all.sublist(offset, end);
  }

  /// 作品流总数（与 [videoPage] 同一过滤口径）。
  int videoTotal({String query = ''}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return _videoList.length;
    var n = 0;
    for (final video in _videoList) {
      if (video.code.toLowerCase().contains(q) ||
          video.title.toLowerCase().contains(q)) {
        n++;
      }
    }
    return n;
  }
}
