import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MidnightGate {
  MidnightGate._();

  static const key = 'midnightActivated';

  static final ValueNotifier<bool> activated = ValueNotifier<bool>(false);
  static var _loaded = false;

  static Future<bool> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final value = preferences.getBool(key) ?? false;
      activated.value = value;
      _loaded = true;
      return value;
    } catch (_) {
      return activated.value;
    }
  }

  static Future<void> ensureLoaded() async {
    if (!_loaded) await load();
  }

  static Future<void> save(bool value) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(key, value);
    } catch (_) {}
    activated.value = value;
  }

  static bool isAdultName(String name) => name.startsWith('🔞');
}
