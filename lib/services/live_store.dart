import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'live_sources.dart';

/// 直播收藏本地存储：对齐火蚁TV 的 LiveStore。
///
/// 火蚁TV 的 LiveStore 只是 SharedPreferences 本地存取，不依赖账号：
/// key 是 live.favourites（另有 recent 列表，但直播界面不用它）。
/// 修仙版没有多 profile，按本树既有约定用 juhe_ 前缀的 key，
/// 同样只做本地存取、不新造账号逻辑。内嵌页与全屏页共用同一个单例。
class LiveStore extends ChangeNotifier {
  LiveStore._();

  static final LiveStore instance = LiveStore._();

  static const _key = 'juhe_live_favourites';

  final List<LiveChannel> _favourites = [];
  bool _ready = false;

  bool get ready => _ready;
  List<LiveChannel> get favourites => List.unmodifiable(_favourites);
  bool isFavourite(String key) =>
      _favourites.any((entry) => entry.key == key);

  Future<void> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_key);
      _favourites
        ..clear()
        ..addAll(_read(raw));
    } catch (_) {
      _favourites.clear();
    }
    _ready = true;
    notifyListeners();
  }

  Future<void> toggleFavourite(LiveChannel channel) async {
    if (isFavourite(channel.key)) {
      _favourites.removeWhere((entry) => entry.key == channel.key);
    } else {
      _favourites.insert(0, channel);
    }
    notifyListeners();
    await _write();
  }

  List<LiveChannel> _read(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map(
            (row) => LiveChannel.fromJson(Map<String, dynamic>.from(row)),
          )
          .whereType<LiveChannel>()
          .where((entry) => entry.key.isNotEmpty && entry.title.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _write() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _key,
        jsonEncode([for (final entry in _favourites) entry.toJson()]),
      );
    } catch (_) {}
  }
}
