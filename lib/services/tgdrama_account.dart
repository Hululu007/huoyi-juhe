import 'package:shared_preferences/shared_preferences.dart';

/// TG 账号显示标签的本地存取：手机号登录成功那一刻存下的脱敏手机号，
/// 我的页 TG 那一行显示用。
///
/// 插件接口不回用户名：内嵌网页 JS 只从 `/api/auth/status` 读
/// authorized/phase/message，从 `/api/bootstrap` 只读 shows/tags/
/// favorite_total/continue_list/total；插件库（tgdrama.db）也没有账号表
/// （11 张表里无 users/self，kv 只有 tgdrama.filled、tgdrama.home.v1、
/// tgdrama.speed）。所以名字拿不到，只存用户在登录页亲手输的手机号
/// （脱敏后），不编假名字。扫码登录 / 预置会话没有手机号可存，标签为空，
/// 我的页只显示“已登录”。
class TgdramaAccountStore {
  TgdramaAccountStore({SharedPreferences? prefs}) : _prefsOverride = prefs;

  static const _labelKey = 'tgdrama_account_label';

  final SharedPreferences? _prefsOverride;
  SharedPreferences? _prefs;

  Future<SharedPreferences> _instance() async {
    final override = _prefsOverride;
    if (override != null) return override;
    return _prefs ??= await SharedPreferences.getInstance();
  }

  Future<String?> readLabel() async {
    try {
      return (await _instance()).getString(_labelKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveLabel(String label) async {
    if (label.isEmpty) return;
    try {
      await (await _instance()).setString(_labelKey, label);
    } catch (_) {}
  }

  Future<void> clearLabel() async {
    try {
      await (await _instance()).remove(_labelKey);
    } catch (_) {}
  }

  /// 手机号脱敏：+86 13812345678 → +86 138****5678；
  /// 无区号 13812345678 → 138****5678；太短原样返回。
  static String maskPhone(String phone) {
    final trimmed = phone.trim();
    final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length == 13 && digits.startsWith('86')) {
      final local = digits.substring(2);
      return '+86 ${local.substring(0, 3)}****${local.substring(7)}';
    }
    if (digits.length >= 7) {
      final head = digits.substring(0, 3);
      final tail = digits.substring(digits.length - 4);
      final plus = trimmed.startsWith('+') ? '+' : '';
      return '$plus$head****$tail';
    }
    return trimmed;
  }
}
