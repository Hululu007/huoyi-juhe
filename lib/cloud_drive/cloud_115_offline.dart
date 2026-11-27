// 115 离线下载（云下载）接入：演员库作品详情页「磁力自动
// 离线 115 + 本页播放」的底座（2026-11-26）。
//
// 接口参照：用户发来的星辰115 源码（com.lin.pan115，
// Pan115Repository 云下载段 + ApiModels.toOfflineTask +
// data/CodeExtractor.kt）逐字对照落，只学接口不搬代码；
// 它同时是本 App 一期/二期 115 修复（qandroid 登录绑定、
// m115 加密取链）的参照源，离线与取链共用同一套 RSA 底座
// （cloud_m115_crypto）。
// - 提交任务：POST https://clouddownload.115.com/lixianssp/
//   表单只有一个字段 data = m115RsaEncrypt(JSON{url,
//   wp_path_id, ac:"add_task_url", app_ver})，ac 在加密载荷
//   里、不在 URL 上，所有值转字符串；UA 用客户端格式
//   Mozilla/5.0 115disk/{ver} 115Browser/{ver}
//   115wangpan_android/{ver}，ver=36.2.28。响应先
//   contentMaybeDecrypt，root.state 为真才算成功，data 是
//   RSA 加密字符串时再解一次拿 info_hash。wp_path_id：先
//   读默认云下载目录（GET webapi.115.com/offine/downpath，
//   offine 是站方原拼写）的 id，读不到回落 "0"（星辰重试
//   路的同款兜底）。
// - 任务列表：GET https://clouddownload.115.com/web/
//   ?ac=task_lists&page=1&page_size=30&stat=0（明文 web
//   路）；tasks 在响应顶层（不在 data 里）。任务字段照
//   toOfflineTask：info_hash / name / size / url / status
//   （0 等待、1 下载中、2 已完成、-1 失败）/ percentDone
//   （0-100，可为字符串）/ wp_path_id。
// - 配额：GET https://clouddownload.115.com/?ac=
//   get_quota_info，总/已用键名多路兜底（星辰同款），凑不
//   齐一对当没查到，不拿猜的数字糊弄。
// - 删任务（本件不用，备查）：POST /web/ {hash[0]…, flag:0,
//   ac:"task_del"}，flag 固定 0（1 连源文件一起删）。
// - 番号匹配：文件名先过提码（pan115ExtractCode，照
//   CodeExtractor.kt 的制式与屏蔽前缀表移植），提码与详情
//   番号归一后精确相等才算命中；提不出码的文件退回文件
//   名包含匹配（弱一档，见 pan115FileForCode）。
// 会话复用 App 既有 115 登录（qandroid cookie，存于
// CloudCredentialStore 的 pan115 凭证），不另起登录。
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cloud_drive_types.dart';
import 'cloud_m115_crypto.dart';

/// 离线任务一条（任务列表宽容解析后的形状）。
class Pan115OfflineTask {
  const Pan115OfflineTask({
    required this.infoHash,
    required this.name,
    required this.percent,
    required this.done,
    this.failed = false,
  });

  /// infohash（小写）；接口没给时为空。
  final String infoHash;

  final String name;

  /// 进度 0..1。
  final double percent;

  /// 是否已完成（进度满格或状态字段明示完成）。
  final bool done;

  /// 是否已失败（状态字段 -1）：磁力播放等待状态机据此
  /// 收尾，不让用户对着死任务干等。
  final bool failed;
}

/// 从磁力链接里取 infohash（btih 值，小写）；取不到回空。
String pan115InfoHashOf(String url) {
  final match = RegExp(r'btih:([A-Za-z0-9]+)').firstMatch(url);
  if (match == null) return '';
  return match.group(1)!.toLowerCase();
}

/// 番号归一键（与演员库 actressCodeKey 同规则：去非字母数字
/// 后大写）——云盘文件名/任务名含番号的匹配用。
String pan115CodeKeyOf(String text) =>
    text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// 明显不是番号的字母前缀（分辨率/编码/发布组词，照
/// CodeExtractor 的屏蔽表逐字抄录）。
const _pan115CodeBlacklist = {
  'H264', 'H265', 'X264', 'X265', 'HEVC', 'AVC', 'AAC', 'MP4', 'MKV',
  'WEB', 'DL', 'BD', 'HD', 'SD', 'FHD', 'UHD', 'FPS', 'GB', 'MB',
  'VOL', 'PART', 'CD', 'XVID', 'DIVX', 'BLURAY', 'DTS', 'AC3',
  'SDR', 'HDR', 'DV', 'HLG', 'DDP', 'EAC3', 'TRUEHD', 'ATMOS',
  'DOLBY', 'REMUX', 'AV1', 'VVC',
};

bool _pan115CodeBlocked(String prefix) =>
    _pan115CodeBlacklist.contains(prefix) ||
    _pan115CodeBlacklist.contains(prefix.replaceAll(RegExp(r'\d+$'), ''));

/// 全角转半角（照 CodeExtractor：全角 ASCII 区平移、全角
/// 空格/句点/中点归一）。
String _pan115HalfWidth(String input) {
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buffer.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3000) {
      buffer.write(' ');
    } else if (rune == 0x3002 || rune == 0x30FB || rune == 0x00B7) {
      buffer.write('.');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// 找第一个「前一字符不落在禁用集里」的匹配（等价于原规则
/// 的后视断言 (?<![A-Z0-9]) / (?<!\d)，Dart 正则后视支持
/// 不稳，用逐个候选校验前一字符实现）。
RegExpMatch? _pan115GuardedFirst(
  RegExp pattern,
  String name, {
  required bool digitGuard,
}) {
  for (final match in pattern.allMatches(name)) {
    if (match.start == 0) return match;
    final prev = name[match.start - 1];
    final blocked = digitGuard
        ? RegExp(r'\d').hasMatch(prev)
        : RegExp(r'[A-Z0-9]').hasMatch(prev);
    if (!blocked) return match;
  }
  return null;
}

/// 从文件名提番号（照星辰115 CodeExtractor.kt 逐条移植：
/// FC2-PPV / FC2 / HEYZO / 日期型 8 位与 6 位 / Heydouga /
/// 数字开头型 / 标准型 / 前缀带数字型 / 无分隔符型 /
/// Tokyo-Hot，顺序与校验同原实现；每条只看第一个候选、
/// 校验不过落到下一条制式）。提不到回 null。
String? pan115ExtractCode(String fileName) {
  var name = _pan115HalfWidth(fileName);
  final dot = name.lastIndexOf('.');
  if (dot >= 0) name = name.substring(0, dot);
  name = name.toUpperCase();
  name = name
      .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
      .replaceAll(RegExp(r'【[^】]*】'), ' ')
      .replaceAll(RegExp(r'\((?:19|20)\d{2}\)'), ' ');
  name = name.replaceAllMapped(
    RegExp(r'\s*([-_])\s*(?=\d{3})'),
    (m) => m.group(1)!,
  );
  name = name.replaceAllMapped(
    RegExp(r'(\d{4})-(\d{2})-(\d{2})-(\d{2,3})(?!\d)'),
    (m) => '${m.group(1)}${m.group(2)}${m.group(3)}-${m.group(4)}',
  );
  RegExpMatch? match;
  match = RegExp(r'FC2[-_ ]?PPV[-_ ]?(\d{5,7})').firstMatch(name);
  if (match != null) return 'FC2-PPV-${match.group(1)}';
  match = _pan115GuardedFirst(
    RegExp(r'FC2[-_ ]?(\d{5,7})(?!\d)'),
    name,
    digitGuard: false,
  );
  if (match != null) return 'FC2-PPV-${match.group(1)}';
  match = RegExp(r'HEYZO[-_ ]?(\d{3,5})(?!\d)').firstMatch(name);
  if (match != null) return 'HEYZO-${match.group(1)}';
  match = _pan115GuardedFirst(
    RegExp(r'(\d{8})[-_](\d{2,3})(?!\d)'),
    name,
    digitGuard: true,
  );
  if (match != null) {
    final head = match.group(1)!;
    final mm = int.parse(head.substring(4, 6));
    final dd = int.parse(head.substring(6, 8));
    if (mm >= 1 && mm <= 12 && dd >= 1 && dd <= 31) {
      return '$head-${match.group(2)}';
    }
  }
  match = _pan115GuardedFirst(
    RegExp(r'(\d{6})[-_](\d{2,3})(?!\d)'),
    name,
    digitGuard: true,
  );
  if (match != null) {
    final head = match.group(1)!;
    final mm = int.parse(head.substring(0, 2));
    final dd = int.parse(head.substring(2, 4));
    if (mm >= 1 && mm <= 12 && dd >= 1 && dd <= 31) {
      return '$head-${match.group(2)}';
    }
  }
  match = _pan115GuardedFirst(
    RegExp(r'(\d{4})[-_](\d{3})(?!\d)'),
    name,
    digitGuard: true,
  );
  if (match != null) {
    final head = match.group(1)!;
    if (!head.startsWith('19') && !head.startsWith('20')) {
      return '$head-${match.group(2)}';
    }
  }
  match = _pan115GuardedFirst(
    RegExp(r'(\d{2}[A-Z]{2,4})[-_](\d{2,5})(?!\d)'),
    name,
    digitGuard: false,
  );
  if (match != null) return '${match.group(1)}-${match.group(2)}';
  match = _pan115GuardedFirst(
    RegExp(r'([A-Z]{2,6})([-_. ])(\d{1,6})(?!\d)'),
    name,
    digitGuard: false,
  );
  if (match != null) {
    final prefix = match.group(1)!;
    final sep = match.group(2)!;
    final digits = match.group(3)!;
    final yearLike =
        (sep == '.' || sep == ' ') &&
        digits.length == 4 &&
        (digits.startsWith('19') || digits.startsWith('20'));
    final bitLike = name.substring(match.end).startsWith('BIT');
    if (!_pan115CodeBlocked(prefix) && !yearLike && !bitLike) {
      return '$prefix-$digits';
    }
  }
  match = _pan115GuardedFirst(
    RegExp(r'([A-Z]{1,4}\d{1,2})[-_](\d{2,5})(?!\d)'),
    name,
    digitGuard: false,
  );
  if (match != null && !_pan115CodeBlocked(match.group(1)!)) {
    return '${match.group(1)}-${match.group(2)}';
  }
  match = _pan115GuardedFirst(
    RegExp(r'([A-Z]{2,6})(\d{3,5})(?!\d)'),
    name,
    digitGuard: false,
  );
  if (match != null && !_pan115CodeBlocked(match.group(1)!)) {
    return '${match.group(1)}-${match.group(2)}';
  }
  match = _pan115GuardedFirst(
    RegExp(r'([NK])(\d{4})(?!\d)'),
    name,
    digitGuard: false,
  );
  if (match != null) return '${match.group(1)}${match.group(2)}';
  return null;
}

/// 在搜到的文件里按番号挑可播文件（非文件夹、视频类）：
/// 第一档——文件名提码（pan115ExtractCode）与详情番号归一
/// 后精确相等；第二档（弱）——提不出码的文件退回文件名归
/// 一包含匹配。两档都找不到回 null，不拿别片冒充。
CloudDriveFile? pan115FileForCode(List<CloudDriveFile> files, String code) {
  final key = pan115CodeKeyOf(code);
  if (key.isEmpty) return null;
  CloudDriveFile? fallback;
  for (final file in files) {
    if (file.isFolder || file.kind != CloudFileKind.video) continue;
    final extracted = pan115ExtractCode(file.name);
    if (extracted != null) {
      if (pan115CodeKeyOf(extracted) == key) return file;
      continue;
    }
    if (fallback == null && pan115CodeKeyOf(file.name).contains(key)) {
      fallback = file;
    }
  }
  return fallback;
}

/// 提交结果：成功与否 + 任务 info_hash（响应 data 解密后
/// 拿得到才有，拿不到为空——成功本身不靠它判断，照星辰
/// 口径）。
class Pan115SubmitResult {
  const Pan115SubmitResult({required this.ok, this.infoHash = ''});

  final bool ok;
  final String infoHash;
}

/// ssp 提交响应解析（照星辰 addOfflineTask）：先
/// contentMaybeDecrypt（没加密的明文原样过），root.state
/// 为真才算成功；data 是 RSA 加密字符串时再解一次取
/// info_hash，是对象时直取。解析不了按失败，不猜。
/// [decrypt] 默认现行 m115RsaDecrypt（与取链响应同一条解
/// 密路，已有夹具测试覆盖）；测试注入替身验分支。
Pan115SubmitResult pan115SubmitResultOf(
  List<int> bodyBytes, {
  List<int> Function(String cipher) decrypt = m115RsaDecrypt,
}) {
  try {
    final plain = m115ContentMaybeDecrypt(bodyBytes);
    final decoded = jsonDecode(utf8.decode(plain, allowMalformed: true));
    if (decoded is! Map) return const Pan115SubmitResult(ok: false);
    if (decoded['state'] != true) return const Pan115SubmitResult(ok: false);
    var infoHash = '';
    final data = decoded['data'];
    if (data is Map) {
      infoHash = (data['info_hash'] ?? '').toString();
    } else if (data is String && data.isNotEmpty) {
      try {
        final inner = jsonDecode(
          utf8.decode(decrypt(data), allowMalformed: true),
        );
        if (inner is Map) infoHash = (inner['info_hash'] ?? '').toString();
      } catch (_) {
        // data 解不开不影响成功判定（星辰同款）。
      }
    }
    return Pan115SubmitResult(ok: true, infoHash: infoHash.toLowerCase());
  } catch (_) {
    return const Pan115SubmitResult(ok: false);
  }
}

/// ssp 提交载荷 JSON（照星辰 addOfflineTask 的 payload：
/// ac 在加密载荷里、所有值转字符串、app_ver 与其
/// APP_VERSION 对齐 36.2.28；jar 版还多带 app:"android"，
/// 星辰版没有，此处以星辰为准不带）。
String pan115SubmitPayloadOf(String url, String wpPathId) => jsonEncode({
  'url': url,
  'wp_path_id': wpPathId,
  'ac': 'add_task_url',
  'app_ver': '36.2.28',
});

/// 配额（get_quota_info）：总/已用/剩余键名多路兜底（照
/// 星辰 fetchCloudQuota 的键表），凑不齐总数就回 null，
/// 不拿猜的数字糊弄。
({int total, int used})? pan115QuotaOf(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    final scopes = [
      if (decoded['data'] is Map) decoded['data'] as Map,
      decoded,
    ];
    int pick(List<String> keys) {
      for (final scope in scopes) {
        for (final key in keys) {
          final value = scope[key];
          final parsed = value is num
              ? value.toInt()
              : int.tryParse(value?.toString() ?? '') ?? 0;
          if (parsed > 0) return parsed;
        }
      }
      return 0;
    }

    var total = pick(const ['quota', 'total', 'total_count', 'total_num', 'count_all']);
    var used = pick(const ['used', 'used_count', 'used_num', 'use_num', 'use']);
    final remain = pick(const ['surplus', 'remain', 'remaining', 'residue', 'left']);
    if (total == 0 && used > 0 && remain > 0) total = used + remain;
    if (used == 0 && total > 0 && remain > 0) used = total - remain;
    if (total <= 0) return null;
    return (total: total, used: used);
  } catch (_) {
    return null;
  }
}

/// 默认云下载目录 id（downpath 响应宽容解析：第一个条目的
/// file_id/cid/id；拿不到回空，提交时回落 "0"）。
String pan115DownpathIdOf(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final data = decoded['data'];
      final rows = data is List
          ? data
          : (data is Map ? [data] : const <dynamic>[]);
      for (final row in rows) {
        if (row is Map) {
          for (final key in const ['file_id', 'cid', 'id']) {
            final value = row[key]?.toString() ?? '';
            if (value.isNotEmpty) return value;
          }
        }
      }
    }
  } catch (_) {
    // 解析不了回空。
  }
  return '';
}

double _pan115PercentOf(Map<dynamic, dynamic> item) {
  // 真实字段 percentDone（0-100，数字或字符串）；其余键名
  // 是别形状兜底。
  for (final key in const ['percentDone', 'percent_done', 'percent', 'progress']) {
    final raw = item[key];
    if (raw is num) return (raw > 1 ? raw / 100 : raw.toDouble()).clamp(0, 1);
    if (raw is String) {
      final value = double.tryParse(raw.replaceAll('%', '').trim());
      if (value != null) return (value > 1 ? value / 100 : value).clamp(0, 1);
    }
  }
  return 0;
}

/// 任务列表响应 → 任务（信封多路兜底：tasks 直挂 / data.tasks
/// / data 本体列表；字段名多路兜底，坏行跳过）。
List<Pan115OfflineTask> pan115TasksOf(String body) {
  final List<dynamic> rows;
  try {
    final decoded = jsonDecode(body);
    if (decoded is List) {
      rows = decoded;
    } else if (decoded is Map) {
      final data = decoded['data'];
      if (data is List) {
        rows = data;
      } else if (data is Map && data['tasks'] is List) {
        rows = data['tasks'] as List;
      } else if (decoded['tasks'] is List) {
        rows = decoded['tasks'] as List;
      } else {
        return const [];
      }
    } else {
      return const [];
    }
  } catch (_) {
    return const [];
  }
  final tasks = <Pan115OfflineTask>[];
  for (final row in rows) {
    if (row is! Map) continue;
    final percent = _pan115PercentOf(row);
    // 真实状态字段 status（int）：0 等待、1 下载中、2 已
    // 完成、-1 失败（照 OfflineTask 模型）；进度满格与文案
    // 含「完成」是别形状兜底。
    final statusCode = row['status'] is num
        ? (row['status'] as num).toInt()
        : int.tryParse((row['status'] ?? '').toString());
    final done =
        statusCode == 2 ||
        percent >= 1 ||
        (row['state_text'] ?? '').toString().contains('完成');
    tasks.add(
      Pan115OfflineTask(
        infoHash: (row['info_hash'] ?? row['infoHash'] ?? '')
            .toString()
            .toLowerCase(),
        name: (row['name'] ?? row['file_name'] ?? '').toString(),
        percent: percent,
        done: done,
        failed: statusCode == -1,
      ),
    );
  }
  return tasks;
}

/// 默认下载目录名（downpath 响应宽容解析：取第一个带名字的
/// 条目；拿不到回空，不编）。
String pan115DownpathNameOf(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final data = decoded['data'];
      final rows = data is List
          ? data
          : (data is Map ? [data] : const <dynamic>[]);
      for (final row in rows) {
        if (row is Map) {
          for (final key in const ['file_name', 'name', 'path_name']) {
            final value = row[key]?.toString() ?? '';
            if (value.isNotEmpty) return value;
          }
        }
      }
    }
  } catch (_) {
    // 解析不了回空。
  }
  return '';
}

/// 传输注入点（测试用）：给方法、网址、可选表单与 UA，
/// 返回响应体字节（ssp 响应要过 contentMaybeDecrypt，必须
/// 拿原始字节）。
typedef Pan115OfflineSend =
    Future<List<int>> Function(
      String method,
      Uri url, {
      Map<String, String>? form,
      String? userAgent,
    });

/// 115 客户端 UA（云下载 ssp 通道用，照星辰 appVersionUa，
/// ver 与其 APP_VERSION 对齐 36.2.28）。
const pan115CloudUserAgent =
    'Mozilla/5.0 115disk/36.2.28 115Browser/36.2.28 '
    '115wangpan_android/36.2.28';

/// 115 离线客户端：只认 cookie 会话（外部传入），不持有登录
/// 逻辑。网络/接口失败抛错，由网关层兜底成「没提交/没任务」。
class Pan115OfflineClient {
  Pan115OfflineClient({
    required http.Client client,
    required String cookie,
    Pan115OfflineSend? send,
    String wpPathId = '',
  }) : _wpPathId = wpPathId,
       _send =
           send ??
           ((method, url, {form, userAgent}) async {
             final headers = {
               'Cookie': cookie,
               'User-Agent':
                   userAgent ??
                   'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
                       '(KHTML, like Gecko) Chrome/122.0 Mobile Safari/537.36',
             };
             final response = method == 'GET'
                 ? await client.get(url, headers: headers)
                 : await client.post(url, headers: headers, body: form);
             return response.bodyBytes;
           });

  final Pan115OfflineSend _send;

  /// 保存目录 id：构造时给定优先；为空时首次提交前读默认
  /// 云下载目录（downpath），再读不到回落 "0"。
  String _wpPathId;

  static final Uri _sspUrl = Uri.parse('https://clouddownload.115.com/lixianssp/');
  static final Uri _listUrl = Uri.parse(
    'https://clouddownload.115.com/web/?ac=task_lists&page=1&page_size=30&stat=0',
  );
  static final Uri _quotaUrl = Uri.parse(
    'https://clouddownload.115.com/?ac=get_quota_info',
  );
  static final Uri _downpathUrl = Uri.parse(
    'https://webapi.115.com/offine/downpath',
  );

  Future<String> _resolveWpPathId() async {
    if (_wpPathId.isNotEmpty) return _wpPathId;
    var resolved = '0';
    try {
      final body = await _send('GET', _downpathUrl);
      final id = pan115DownpathIdOf(utf8.decode(body, allowMalformed: true));
      if (id.isNotEmpty) resolved = id;
    } catch (_) {
      // 读不到默认目录就回落 "0"（星辰重试路同款兜底）。
    }
    _wpPathId = resolved;
    return resolved;
  }

  /// 提交一条离线任务（磁力/ed2k/http），ssp RSA 通道（照
  /// 星辰 addOfflineTask）：表单只有 data 一个字段，值是
  /// RSA 加密的 JSON{url, wp_path_id, ac, app_ver}。
  /// [encrypt] 默认现行 m115RsaEncrypt（与取链请求同一条
  /// 加密路，已有夹具测试覆盖）；测试注入替身验载荷。
  Future<Pan115SubmitResult> submitOffline(
    String url, {
    String Function(List<int> data) encrypt = m115RsaEncrypt,
  }) async {
    final payload = pan115SubmitPayloadOf(url, await _resolveWpPathId());
    final encrypted = encrypt(utf8.encode(payload));
    final bytes = await _send(
      'POST',
      _sspUrl,
      form: {'data': encrypted},
      userAgent: pan115CloudUserAgent,
    );
    return pan115SubmitResultOf(bytes);
  }

  /// 当前离线任务列表（第一页 30 条，stat=0 全部，明文
  /// web 路）。
  Future<List<Pan115OfflineTask>> listTasks() async {
    final body = await _send('GET', _listUrl);
    return pan115TasksOf(utf8.decode(body, allowMalformed: true));
  }

  /// 云下载配额（总/已用）；读不齐回 null。
  Future<({int total, int used})?> quota() async {
    final body = await _send('GET', _quotaUrl);
    return pan115QuotaOf(utf8.decode(body, allowMalformed: true));
  }

  /// 默认云下载目录名（备查；提交不带目录即落这里）。
  Future<String> downpathName() async {
    final body = await _send('GET', _downpathUrl);
    return pan115DownpathNameOf(utf8.decode(body, allowMalformed: true));
  }
}
