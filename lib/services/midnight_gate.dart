import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 午夜区不再设门：口令与进门密码已移除，成人内容不再被隐藏。
/// 本类只保留兼容层：所有读到它的地方都视为已开启；旧的持久化键
/// 若还在，首次加载时清掉，避免旧值继续影响显示。
class MidnightGate {
  MidnightGate._();

  static const key = 'midnightActivated';

  static final ValueNotifier<bool> activated = ValueNotifier<bool>(true);
  static var _loaded = false;

  static Future<bool> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(key);
    } catch (_) {}
    activated.value = true;
    _loaded = true;
    return true;
  }

  static Future<void> ensureLoaded() async {
    if (!_loaded) await load();
  }

  static bool isAdultName(String name) => name.startsWith('🔞');
}
