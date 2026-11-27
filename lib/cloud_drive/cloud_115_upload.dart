/// 115 上传协议层：initupload 的签名/k_ec/AES 表单（p115cipher 的
/// make_upload_payload / ecdh_encode_token）+ 阿里云 OSS 分片上传
/// （p115oss 的 V1 签名）。协议事实按星辰115 的实测实现与公开实现
/// 落码；纯函数部分（CRC32、表单编码、k_ec、签名）有独立参考实现
/// （Python hashlib/binascii/hmac + openssl）生成的交叉向量背书，
/// 见 test/cloud_115_upload_test.dart。真上传要真账号，列手机终验。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import 'cloud_m115_crypto.dart';

/// 上传协议里写死的客户端版本：initupload 的 UA 与 token 签名公式
/// 都含它，改版本要两处一起改，所以只留这一份常量。
const pan115UploadAppVersion = '36.2.28';
const pan115UploadUserAgent =
    'Mozilla/5.0 115disk/$pan115UploadAppVersion '
    '115Browser/$pan115UploadAppVersion '
    '115wangpan_android/$pan115UploadAppVersion';

/// OSS 分片大小：10MB（115 侧惯例；OSS 最多 10000 片）。
const pan115OssPartSize = 10 * 1024 * 1024;

// ---------------------------------------------------------------------------
// CRC32（IEEE 反射版，与 java.util.zip.CRC32 / binascii.crc32 同一算法）
// ---------------------------------------------------------------------------

final List<int> _crc32Table = () {
  final table = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var j = 0; j < 8; j++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[i] = c;
  }
  return table;
}();

int pan115Crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc = _crc32Table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

// ---------------------------------------------------------------------------
// initupload 的签名与表单
// ---------------------------------------------------------------------------

/// 表单编码（Python quote_plus 语义）：字母数字与 `_.-~` 不转，
/// 空格转 `+`，其余按 UTF-8 逐字节转 %XX（大写）。Dart 的
/// Uri.encodeQueryComponent 语义不同（不转 `*`、转 `~` 等），
/// 服务端按 Python 语义验签，必须用这一份。
String pan115FormEncode(String value) {
  final buffer = StringBuffer();
  for (final byte in utf8.encode(value)) {
    final isUnreserved =
        (byte >= 0x61 && byte <= 0x7A) || // a-z
        (byte >= 0x41 && byte <= 0x5A) || // A-Z
        (byte >= 0x30 && byte <= 0x39) || // 0-9
        byte == 0x5F || // _
        byte == 0x2E || // .
        byte == 0x2D || // -
        byte == 0x7E; // ~
    if (isUnreserved) {
      buffer.writeCharCode(byte);
    } else if (byte == 0x20) {
      buffer.write('+');
    } else {
      buffer.write('%');
      buffer.write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return buffer.toString();
}

const _md5Salt = 'Qclm8MGWUv59TnrR0XPg';
const _crcSalt = '^j>WD3Kr?J2gLFjD4W2y@';

/// 固定的「假 ECDH」公钥（30 字节，协议常量）。
const _aesPubkey = <int>[
  0x1d, 0x03, 0x0e, 0x80, 0xa1, 0x78, 0xdc, 0xee,
  0xce, 0xcd, 0xa3, 0x77, 0xde, 0x12, 0x8d, 0x8e,
  0xd9, 0xdd, 0xcf, 0x55, 0xae, 0x61, 0xed, 0x46,
  0xea, 0x12, 0x1a, 0x1c, 0xfc, 0x81,
];

/// k_ec token：pubkey 前 15 + `00 73 00 00 00` + t（4 字节小端）+
/// pubkey 后 15 + `00 01 00 00 00` + CRC32（盐 + 前面全部字节，
/// 4 字节小端），整体 Base64。
String pan115EncodeToken(int timestampSeconds) {
  final out = BytesBuilder();
  out.add(_aesPubkey.sublist(0, 15));
  out.add(const [0x00, 0x73, 0x00, 0x00, 0x00]);
  final t = timestampSeconds & 0xFFFFFFFF;
  out.add([t & 0xFF, (t >> 8) & 0xFF, (t >> 16) & 0xFF, (t >> 24) & 0xFF]);
  out.add(_aesPubkey.sublist(15));
  out.add(const [0x00, 0x01, 0x00, 0x00, 0x00]);
  final prefix = out.toBytes();
  final crc = pan115Crc32([...utf8.encode(_crcSalt), ...prefix]);
  final full = Uint8List(prefix.length + 4);
  full.setAll(0, prefix);
  full[prefix.length] = crc & 0xFF;
  full[prefix.length + 1] = (crc >> 8) & 0xFF;
  full[prefix.length + 2] = (crc >> 16) & 0xFF;
  full[prefix.length + 3] = (crc >> 24) & 0xFF;
  return base64Encode(full);
}

/// initupload 的请求参数：k_ec 查询参数 + AES 加密后的表单字节。
class Pan115UploadPayload {
  const Pan115UploadPayload({required this.kEc, required this.body});

  final String kEc;
  final Uint8List body;
}

/// 构建 initupload 请求参数（纯函数，时间戳由调用方给，便于单测）。
/// [signKey]/[signVal] 是二次校验（status 7）时第二轮才传的，
/// 第一轮传空：空值不进表单，但 token 公式里照样按空串算。
Pan115UploadPayload buildPan115UploadPayload({
  required String userId,
  required String userKey,
  required String fileId,
  required String fileName,
  required int fileSize,
  required String target,
  String signKey = '',
  String signVal = '',
  required String appVersion,
  required int timestampSeconds,
}) {
  final t = '$timestampSeconds';
  // sig = 大写 SHA1(userkey 字节 + 小写 hex(SHA1(userid+fileid+target+"0")) + "000000")
  final inner = crypto.sha1
      .convert(utf8.encode('$userId$fileId${target}0'))
      .toString();
  final sig = crypto.sha1
      .convert([...utf8.encode(userKey), ...utf8.encode(inner), ...utf8.encode('000000')])
      .toString()
      .toUpperCase();
  // token = 小写 MD5(盐 + fileid+filesize+sign_key+sign_val+userid+t
  //   + 小写 hex(MD5(userid 的数字形式)) + appversion)
  final userIdNumber = int.tryParse(userId)?.toString() ?? userId;
  final userIdMd5 = crypto.md5.convert(utf8.encode(userIdNumber)).toString();
  final token = crypto.md5
      .convert(
        utf8.encode(
          '$_md5Salt$fileId$fileSize$signKey$signVal$userId$t'
          '$userIdMd5$appVersion',
        ),
      )
      .toString();
  final fields = <String, String>{
    'appversion': appVersion,
    'fileid': fileId,
    'filename': fileName,
    'filesize': '$fileSize',
    'sig': sig,
    if (signKey.isNotEmpty) 'sign_key': signKey,
    if (signVal.isNotEmpty) 'sign_val': signVal,
    't': t,
    'target': target,
    'token': token,
    'topupload': 'true',
    'userid': userId,
    'userkey': userKey,
  };
  final keys = fields.keys.toList()..sort();
  final form = keys
      .map((k) => '${pan115FormEncode(k)}=${pan115FormEncode(fields[k]!)}')
      .join('&');
  return Pan115UploadPayload(
    kEc: pan115EncodeToken(timestampSeconds),
    body: m115AesCbcEncrypt(utf8.encode(form)),
  );
}

// ---------------------------------------------------------------------------
// 阿里云 OSS（V1 签名 + 分片上传）
// ---------------------------------------------------------------------------

/// OSS 临时凭证（GET uplb.115.com/3.0/gettoken.php，不带鉴权取）。
class Pan115OssToken {
  const Pan115OssToken({
    required this.accessKeyId,
    required this.accessKeySecret,
    required this.securityToken,
  });

  final String accessKeyId;
  final String accessKeySecret;
  final String securityToken;
}

/// 一个已传分片（ETag 带引号原样保留，complete 时原样拼进 XML）。
class Pan115OssPart {
  const Pan115OssPart({required this.partNumber, required this.etag});

  final int partNumber;
  final String etag;
}

/// OSS 请求失败。[httpCode] 是服务端真实 HTTP 码（没有响应时为
/// null）；调用方按码判断（403 = 凭证过期要刷新），不靠文案匹配。
class Pan115OssException implements Exception {
  Pan115OssException(this.message, {this.httpCode});

  final String message;
  final int? httpCode;

  @override
  String toString() => message;
}

const _ossHost = 'oss-cn-shenzhen.aliyuncs.com';
const _ossSubresourceKeys = {'partNumber', 'uploadId', 'uploads', 'sequential'};

String pan115OssObjectUrl(String bucket, String objectKey) {
  final encoded = objectKey.split('/').map(pan115OssEncodePathSegment).join('/');
  return 'https://$bucket.$_ossHost/$encoded';
}

/// 路径段编码：unreserved 与路径安全字符（子定界符等）原样保留，
/// 合法的 %XX 保留、裸 % 编 %25，其余按 UTF-8 逐字节 %XX。
String pan115OssEncodePathSegment(String segment) {
  const safe = "!*'();:@&=+\$,";
  final buffer = StringBuffer();
  var i = 0;
  while (i < segment.length) {
    final ch = segment[i];
    if (ch == '%') {
      final hex1 = i + 1 < segment.length ? segment[i + 1] : '';
      final hex2 = i + 2 < segment.length ? segment[i + 2] : '';
      if (_isHexDigit(hex1) && _isHexDigit(hex2)) {
        buffer.write('%$hex1$hex2');
        i += 3;
      } else {
        buffer.write('%25');
        i++;
      }
      continue;
    }
    final code = ch.codeUnitAt(0);
    final isSafe =
        (code >= 0x61 && code <= 0x7A) ||
        (code >= 0x41 && code <= 0x5A) ||
        (code >= 0x30 && code <= 0x39) ||
        ch == '-' ||
        ch == '_' ||
        ch == '.' ||
        ch == '~' ||
        safe.contains(ch);
    if (isSafe) {
      buffer.write(ch);
    } else {
      for (final byte in utf8.encode(ch)) {
        buffer.write('%');
        buffer.write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
    }
    i++;
  }
  return buffer.toString();
}

bool _isHexDigit(String ch) {
  if (ch.length != 1) return false;
  final code = ch.codeUnitAt(0);
  return (code >= 0x30 && code <= 0x39) ||
      (code >= 0x61 && code <= 0x66) ||
      (code >= 0x41 && code <= 0x46);
}

/// RFC1123 GMT 时间（OSS 签名与 Date 头共用同一个字符串）。
String pan115Rfc1123(DateTime utc) {
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  String two(int v) => v.toString().padLeft(2, '0');
  return '${weekdays[utc.weekday - 1]}, ${two(utc.day)} '
      '${months[utc.month - 1]} ${utc.year} '
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} GMT';
}

/// OSS V1 签名：返回要带的全部请求头（authorization /
/// x-oss-security-token / date，键名小写）。纯函数，[date] 由
/// 调用方给（测试传固定值，线上用 [pan115Rfc1123] 现生成）。
Map<String, String> pan115OssSignHeaders({
  required Pan115OssToken token,
  required String method,
  required String url,
  Map<String, String> extraHeaders = const {},
  String contentType = '',
  required String date,
}) {
  final headers = <String, String>{
    for (final e in extraHeaders.entries) e.key.toLowerCase(): e.value,
    'x-oss-security-token': token.securityToken,
    'date': date,
  };
  // 规范查询串：只留子资源参数，按键排序，k=v 用 & 连。
  var query = '';
  final qIndex = url.indexOf('?');
  if (qIndex >= 0) {
    final pairs = <(String, String)>[];
    for (final item in url.substring(qIndex + 1).split('&')) {
      final eq = item.indexOf('=');
      if (eq < 0) continue;
      final key = item.substring(0, eq);
      if (_ossSubresourceKeys.contains(key)) {
        pairs.add((key, item.substring(eq + 1)));
      }
    }
    pairs.sort((a, b) => a.$1.compareTo(b.$1));
    query = pairs.map((p) => '${p.$1}=${p.$2}').join('&');
  }
  final afterScheme = url.substring(url.indexOf('://') + 3);
  final host = afterScheme.split('/').first;
  final bucket = host.split('.').first;
  var path = afterScheme.substring(host.length);
  final pathEnd = path.indexOf('?');
  if (pathEnd >= 0) path = path.substring(0, pathEnd);
  if (path.isEmpty) path = '/';
  final ossHeaderKeys = headers.keys.where((k) => k.startsWith('x-oss-')).toList()
    ..sort();
  final ossHeaders = ossHeaderKeys.map((k) => '$k:${headers[k]}').join('\n');
  final resource = '/$bucket$path${query.isEmpty ? '' : '?$query'}';
  final stringToSign =
      '${method.toUpperCase()}\n\n$contentType\n$date\n$ossHeaders\n$resource';
  final signature = base64Encode(
    crypto.Hmac(crypto.sha1, utf8.encode(token.accessKeySecret))
        .convert(utf8.encode(stringToSign))
        .bytes,
  );
  return {...headers, 'authorization': 'OSS ${token.accessKeyId}:$signature'};
}

String _ossErrorMessage(String body) {
  final message = RegExp(r'<Message>([^<]*)</Message>').firstMatch(body)?.group(1);
  final code = RegExp(r'<Code>([^<]*)</Code>').firstMatch(body)?.group(1);
  if (message != null && message.isNotEmpty && code != null && code.isNotEmpty) {
    return '$code：$message';
  }
  if (message != null && message.isNotEmpty) return message;
  return body.length > 200 ? body.substring(0, 200) : body;
}

String _callbackErrorMessage(String body) {
  final error = RegExp(r'"error"\s*:\s*"([^"]*)"').firstMatch(body)?.group(1);
  final message = RegExp(r'"message"\s*:\s*"([^"]*)"').firstMatch(body)?.group(1);
  if (error != null && error.isNotEmpty) return error;
  if (message != null && message.isNotEmpty) return message;
  return body.length > 200 ? body.substring(0, 200) : body;
}

/// OSS 分片上传客户端（走注入的 http.Client，便于单测）。
/// 单片重试与凭证刷新在调用方（Pan115Provider.uploadFile）编排，
/// 这里只做单次请求。
class Pan115OssClient {
  Pan115OssClient(this._client);

  final http.Client _client;

  Future<http.Response> _send(
    Pan115OssToken token,
    String method,
    String url, {
    List<int>? body,
    String contentType = '',
    Map<String, String> extraHeaders = const {},
    Duration timeout = const Duration(seconds: 60),
  }) {
    final signed = pan115OssSignHeaders(
      token: token,
      method: method,
      url: url,
      extraHeaders: extraHeaders,
      contentType: contentType,
      date: pan115Rfc1123(DateTime.now().toUtc()),
    );
    final request = http.Request(method, Uri.parse(url));
    request.headers.addAll(signed);
    if (contentType.isNotEmpty) {
      request.headers['content-type'] = contentType;
    }
    if (body != null) request.bodyBytes = body;
    return _client.send(request).then((streamed) => http.Response.fromStream(streamed)).timeout(timeout);
  }

  /// 初始化分片上传，返回 UploadId。
  Future<String> initMultipart(
    Pan115OssToken token,
    String bucket,
    String objectKey,
  ) async {
    final url = '${pan115OssObjectUrl(bucket, objectKey)}?sequential=1&uploads=1';
    final response = await _send(token, 'POST', url);
    final body = response.body;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Pan115OssException(
        '初始化上传失败（HTTP ${response.statusCode}）：${_ossErrorMessage(body)}',
        httpCode: response.statusCode,
      );
    }
    final uploadId = RegExp(
      r'<UploadId>([^<]+)</UploadId>',
    ).firstMatch(body)?.group(1);
    if (uploadId == null || uploadId.isEmpty) {
      throw Pan115OssException(
        '初始化上传失败：服务器没有返回 UploadId',
        httpCode: response.statusCode,
      );
    }
    return uploadId;
  }

  /// 上传一个分片，返回 ETag（带引号原样保留）。
  Future<String> uploadPart(
    Pan115OssToken token,
    String bucket,
    String objectKey,
    String uploadId,
    int partNumber,
    List<int> bytes,
  ) async {
    final url =
        '${pan115OssObjectUrl(bucket, objectKey)}?partNumber=$partNumber&uploadId=$uploadId';
    final response = await _send(
      token,
      'PUT',
      url,
      body: bytes,
      timeout: const Duration(seconds: 180),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Pan115OssException(
        '上传分片 $partNumber 失败（HTTP ${response.statusCode}）：${_ossErrorMessage(response.body)}',
        httpCode: response.statusCode,
      );
    }
    final etag = response.headers['etag'];
    if (etag == null || etag.isEmpty) {
      throw Pan115OssException(
        '上传分片 $partNumber 失败：服务器没有返回 ETag',
        httpCode: response.statusCode,
      );
    }
    return etag;
  }

  /// 完成分片上传（带 115 回调，OSS 靠它通知 115 登记文件）。
  /// HTTP 203 是 OSS 的「回调失败」：分片已合成对象但 115 没登记，
  /// 必须报错，不许当成功。
  Future<void> completeMultipart(
    Pan115OssToken token,
    String bucket,
    String objectKey,
    String uploadId,
    List<Pan115OssPart> parts,
    String callback,
    String callbackVar,
  ) async {
    final url = '${pan115OssObjectUrl(bucket, objectKey)}?uploadId=$uploadId';
    final sorted = [...parts]..sort((a, b) => a.partNumber.compareTo(b.partNumber));
    final xml = StringBuffer('<CompleteMultipartUpload>');
    for (final part in sorted) {
      xml.write(
        '<Part><PartNumber>${part.partNumber}</PartNumber>'
        '<ETag>${part.etag}</ETag></Part>',
      );
    }
    xml.write('</CompleteMultipartUpload>');
    final response = await _send(
      token,
      'POST',
      url,
      body: utf8.encode(xml.toString()),
      contentType: 'text/xml',
      extraHeaders: {
        'x-oss-callback': base64Encode(utf8.encode(callback)),
        'x-oss-callback-var': base64Encode(utf8.encode(callbackVar)),
      },
    );
    final body = response.body;
    if (response.statusCode == 203) {
      throw Pan115OssException(
        '完成上传失败：服务器回调返回错误（HTTP 203）：${_callbackErrorMessage(body)}',
        httpCode: 203,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Pan115OssException(
        '完成上传失败（HTTP ${response.statusCode}）：${_ossErrorMessage(body)}',
        httpCode: response.statusCode,
      );
    }
    if (RegExp(r'"state"\s*:\s*false').hasMatch(body)) {
      throw Pan115OssException(
        '完成上传失败：服务器回调返回错误：${_callbackErrorMessage(body)}',
        httpCode: response.statusCode,
      );
    }
  }

  /// 取消分片上传（收尾动作，失败不报错：分片在 OSS 上会自动过期）。
  Future<void> abortMultipart(
    Pan115OssToken token,
    String bucket,
    String objectKey,
    String uploadId,
  ) async {
    try {
      final url = '${pan115OssObjectUrl(bucket, objectKey)}?uploadId=$uploadId';
      await _send(token, 'DELETE', url, timeout: const Duration(seconds: 30));
    } catch (_) {
      // 收尾失败不报错。
    }
  }
}

// ---------------------------------------------------------------------------
// 上传字节来源：编排层（Pan115Provider 的上传链）只按三件事取内容——
// 全文件 SHA1、区间 SHA1、按区间读字节——内存与本地文件各一份实现。
// 文件实现全程流式：SHA1 边读边算、分片按需读，整文件不进内存。
// ---------------------------------------------------------------------------

/// 115 上传的内容来源。[readRange] 的调用粒度是 OSS 单片（10MB），
/// 任何实现一次最多交出一片的字节。
abstract class Pan115UploadSource {
  /// 内容总字节数。
  int get length;

  /// 全文件 SHA1（大写十六进制，initupload 的 fileid）。
  Future<String> sha1All();

  /// 闭区间 [start, endInclusive] 的 SHA1（大写，二次校验 sign_val）。
  Future<String> sha1Range(int start, int endInclusive);

  /// 读 [start, endExclusive) 区间的字节。
  Future<List<int>> readRange(int start, int endExclusive);
}

/// 内存字节来源（小内容与单测用）。
class MemoryPan115UploadSource implements Pan115UploadSource {
  MemoryPan115UploadSource(this.bytes);

  final List<int> bytes;

  @override
  int get length => bytes.length;

  @override
  Future<String> sha1All() async =>
      crypto.sha1.convert(bytes).toString().toUpperCase();

  @override
  Future<String> sha1Range(int start, int endInclusive) async => crypto.sha1
      .convert(bytes.sublist(start, endInclusive + 1))
      .toString()
      .toUpperCase();

  @override
  Future<List<int>> readRange(int start, int endExclusive) async =>
      bytes.sublist(start, endExclusive);
}

/// 本地文件流式来源：几个 GB 的文件也只占一片（10MB）的内存。
class FilePan115UploadSource implements Pan115UploadSource {
  FilePan115UploadSource(this.file, this.length);

  final File file;

  @override
  final int length;

  @override
  Future<String> sha1All() async {
    final digest = await crypto.sha1.bind(file.openRead()).first;
    return digest.toString().toUpperCase();
  }

  @override
  Future<String> sha1Range(int start, int endInclusive) async {
    final digest = await crypto.sha1
        .bind(file.openRead(start, endInclusive + 1))
        .first;
    return digest.toString().toUpperCase();
  }

  @override
  Future<List<int>> readRange(int start, int endExclusive) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(start, endExclusive)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
