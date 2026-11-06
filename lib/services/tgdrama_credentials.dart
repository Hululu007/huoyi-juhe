import 'dart:io';

/// TG影视库的 Telegram API 凭证与插件配置文件生成。
///
/// 凭证来源：构建期注入（--dart-define=TG_API_ID / TG_API_HASH）。
/// CI 从 GitHub secrets 取，本地构建由构建脚本传；未注入时为空，
/// 手机号登录报不可用（扫码登录与预置会话不受影响）。
/// 凭证值只进内存与应用私有目录的 config.yaml，绝不打印、不进日志、
/// 不写进任何能提交的文件。
class TgdramaCredentials {
  const TgdramaCredentials._();

  /// 构建期注入的 Telegram API ID（--dart-define=TG_API_ID）。
  static const String apiId = String.fromEnvironment('TG_API_ID');

  /// 构建期注入的 Telegram API Hash（--dart-define=TG_API_HASH）。
  static const String apiHash = String.fromEnvironment('TG_API_HASH');

  /// 两项凭证都已注入。
  static bool get hasCredentials => apiId.isNotEmpty && apiHash.isNotEmpty;

  /// 拼插件 config.yaml 的文本。
  /// telegram 小节给凭证；data.dir 把插件数据目录钉在应用私有目录，
  /// 让插件的数据库、会话与配置文件都落在一个地方。
  static String buildConfigYaml({
    required String apiId,
    required String apiHash,
    required String dataDir,
  }) {
    return 'telegram:\n'
        '  api_id: $apiId\n'
        '  api_hash: $apiHash\n'
        'data:\n'
        '  dir: $dataDir\n';
  }

  /// 确保 tgdramaDir 下的 config.yaml 含有 Telegram API 凭证。
  /// 已有且含凭证时不动；缺失或无凭证且构建期凭证已注入时写一份；
  /// 构建期凭证也没注入时返回 false（调用方如实报不可用）。
  /// 返回：写完（或原有）后 config.yaml 是否含有凭证。
  static Future<bool> ensureConfigYaml(Directory tgdramaDir) async {
    final configFile = File('${tgdramaDir.path}/config.yaml');
    try {
      if (await configFile.exists()) {
        final text = await configFile.readAsString();
        final creds = _parseTelegramCredentials(text);
        if (creds.$1 != null &&
            creds.$1!.isNotEmpty &&
            creds.$2 != null &&
            creds.$2!.isNotEmpty) {
          return true;
        }
      }
    } catch (_) {
      // 读失败按缺失处理，继续往下写。
    }
    if (!hasCredentials) return false;
    try {
      await tgdramaDir.create(recursive: true);
      await configFile.writeAsString(
        buildConfigYaml(
          apiId: apiId,
          apiHash: apiHash,
          dataDir: tgdramaDir.path,
        ),
        flush: true,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 从 config.yaml 文本解析 telegram.api_id / api_hash（与
  /// TgdramaPhoneLoginService.parseTelegramCredentials 同一规则，
  /// 这里只做“有没有凭证”的判断，不作他用）。
  static (String?, String?) _parseTelegramCredentials(String yamlText) {
    String? apiId;
    String? apiHash;
    var inTelegramSection = false;
    for (final rawLine in yamlText.split('\n')) {
      final line = rawLine.split('#').first;
      if (line.trim().isEmpty) continue;
      final indent = line.length - line.trimLeft().length;
      final trimmed = line.trim();
      if (indent == 0 && trimmed.endsWith(':')) {
        inTelegramSection = trimmed == 'telegram:';
        continue;
      }
      final colon = trimmed.indexOf(':');
      if (colon <= 0) continue;
      final key = trimmed.substring(0, colon).trim();
      if (key != 'api_id' && key != 'api_hash') continue;
      final value = _unquote(trimmed.substring(colon + 1).trim());
      if (inTelegramSection) {
        if (key == 'api_id') {
          apiId = value;
        } else {
          apiHash = value;
        }
      } else if (indent == 0) {
        if (key == 'api_id' && apiId == null) apiId = value;
        if (key == 'api_hash' && apiHash == null) apiHash = value;
      }
    }
    return (apiId, apiHash);
  }

  static String _unquote(String value) {
    var v = value.trim();
    if (v.length >= 2) {
      if ((v.startsWith('"') && v.endsWith('"')) ||
          (v.startsWith("'") && v.endsWith("'"))) {
        v = v.substring(1, v.length - 1);
      }
    }
    return v.trim();
  }
}
