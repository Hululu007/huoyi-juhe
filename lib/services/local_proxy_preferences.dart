import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted switch for the local proxy service (FongMiTV-style).
///
/// FongMiTV has no switch for its local proxy: the Nano server starts with
/// the config load and stays up. The equivalent here is "on by default".
/// Turning it off stops the listener; in-flight proxied streams break once
/// (same wording as the LAN-share restart note), and later
/// [LocalMediaProxy.register] calls fall back to the direct target URL
/// while [LocalMediaProxy.registerHandler] reports an honest error instead
/// of silently starting the server back up.
class LocalProxyPreferences {
  LocalProxyPreferences._();

  static final LocalProxyPreferences instance = LocalProxyPreferences._();

  static const key = 'local_proxy_enabled';

  /// On until [load] reads otherwise: FongMiTV's local proxy is always on.
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      enabled.value = sp.getBool(key) ?? true;
    } catch (_) {
      // A broken optional preference reads as its default.
    }
  }

  /// Forgets the loaded state so the next [load] re-reads SharedPreferences.
  ///
  /// Only for tests: `_loaded` is a process-wide one-shot guard, so a value
  /// swapped in by `setMockInitialValues` is not picked up otherwise.
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    enabled.value = true;
  }

  /// Writes the new value and persists it; a failed write keeps the in-session
  /// value so the switch still reflects what the user chose.
  Future<void> setEnabled(bool value) async {
    enabled.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(key, value);
    } catch (_) {
      // The in-session value still applies; only persistence failed.
    }
  }
}
