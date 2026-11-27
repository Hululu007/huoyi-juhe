/// 网盘登录凭证的本机存储。
///
/// 诚实说明：树里没有安全存储机制（没有 flutter_secure_storage 依赖，
/// 也不能新增依赖），本实现用 SharedPreferences + 每安装随机密钥的
/// SHA-256 密钥流 XOR 混淆。这只是混淆，不是 Keystore 级加密存储：
/// 能防随手翻看，防不住拿到应用数据的攻击者。不要把它说成加密存储。
///
/// 凭证只存本机，不上传；可逐家清除。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一家网盘的登录凭证（字段含义各家不同，由各家客户端解释）。
class CloudCredentials {
  const CloudCredentials({
    required this.fields,
    required this.savedAtMs,
    this.label = '',
  });

  /// 凭证字段：115/夸克/百度以 `cookie` 为主；阿里以
  /// `refresh_token` / `access_token` / `drive_id` 为主。
  final Map<String, String> fields;

  /// 保存时间（毫秒时间戳）。
  final int savedAtMs;

  /// 账号显示名（有就显示，没有为空，不强求）。
  final String label;

  Map<String, dynamic> toJson() => {
    'fields': fields,
    'savedAtMs': savedAtMs,
    'label': label,
  };

  factory CloudCredentials.fromJson(Map<String, dynamic> json) {
    final raw = json['fields'];
    final fields = <String, String>{};
    if (raw is Map) {
      raw.forEach((key, value) {
        if (value is String) fields[key.toString()] = value;
      });
    }
    return CloudCredentials(
      fields: fields,
      savedAtMs: json['savedAtMs'] is int ? json['savedAtMs'] as int : 0,
      label: json['label'] as String? ?? '',
    );
  }

  /// 凭证是否非空（至少一个字段有值）。
  bool get isEmpty => fields.values.every((value) => value.isEmpty);
  bool get isNotEmpty => !isEmpty;
}

class CloudCredentialStore {
  CloudCredentialStore(this._prefs);

  final SharedPreferences _prefs;

  static const _keyPrefsKey = 'cloud_drive_obfs_key_v1';
  static String _credKey(String providerId) => 'cloud_cred_$providerId';

  /// 混淆密钥（每安装随机生成，存在同一份 SharedPreferences 里）。
  /// 密钥与密文放一起，这正是“混淆而非加密”的原因，已在文件头如实说明。
  /// 读不到（从未生成或已损坏）时返回 null，调用方按“无凭证”处理，
  /// 不在这里静默生成新密钥（否则旧凭证会被误判为可读）。
  List<int>? _readKey() {
    final stored = _prefs.getString(_keyPrefsKey);
    if (stored == null) return null;
    try {
      final bytes = base64Decode(stored);
      if (bytes.length == 32) return bytes;
    } catch (_) {
      // 损坏的密钥按没有处理。
    }
    return null;
  }

  /// 确保有密钥：没有就生成并落盘（保存凭证前调用）。
  Future<List<int>> _ensureKey() async {
    final existing = _readKey();
    if (existing != null) return existing;
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    await _prefs.setString(_keyPrefsKey, base64Encode(bytes));
    return bytes;
  }

  List<int> _keystream(List<int> key, int length) {
    final out = <int>[];
    var counter = 0;
    while (out.length < length) {
      final block = sha256.convert([...key, counter]).bytes;
      out.addAll(block);
      counter++;
    }
    return out.sublist(0, length);
  }

  String _obfuscate(List<int> key, String plain) {
    final bytes = utf8.encode(plain);
    final stream = _keystream(key, bytes.length);
    final cipher = List<int>.generate(
      bytes.length,
      (i) => bytes[i] ^ stream[i],
    );
    return base64Encode(cipher);
  }

  String? _deobfuscate(List<int> key, String stored) {
    try {
      final cipher = base64Decode(stored);
      final stream = _keystream(key, cipher.length);
      final plain = List<int>.generate(
        cipher.length,
        (i) => cipher[i] ^ stream[i],
      );
      return utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }

  /// 保存一家网盘的凭证（覆盖旧值）。
  Future<bool> save(String providerId, CloudCredentials credentials) async {
    final key = await _ensureKey();
    final json = jsonEncode(credentials.toJson());
    return _prefs.setString(_credKey(providerId), _obfuscate(key, json));
  }

  /// 读取一家网盘的凭证；没有、损坏或字段全空时返回 null。
  CloudCredentials? load(String providerId) {
    final stored = _prefs.getString(_credKey(providerId));
    if (stored == null || stored.isEmpty) return null;
    final key = _readKey();
    if (key == null) return null;
    final json = _deobfuscate(key, stored);
    if (json == null) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) return null;
      final creds = CloudCredentials.fromJson(decoded);
      return creds.isEmpty ? null : creds;
    } catch (_) {
      return null;
    }
  }

  /// 清除一家网盘的凭证。
  Future<bool> clear(String providerId) => _prefs.remove(_credKey(providerId));

  /// 当前存有凭证的网盘 id 列表。
  List<String> loggedInProviderIds(Iterable<String> providerIds) => [
    for (final id in providerIds)
      if (load(id) != null) id,
  ];
}
