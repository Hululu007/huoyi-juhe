/// 115 下载接口（POST webapi.115.com/files/download）的加密层，通称 m115。
///
/// 协议事实来自公开逆向实现 p115cipher / p115client / 115driver（三套互相
/// 交叉验证；星辰115 的同名实现另有一份 Java 版跑过 56 个 p115cipher
/// 测试向量）。本文件按协议事实自己实现，不依赖任何加密包：
/// - 请求体：明文 JSON 先经两轮 XOR 混淆（固定 4 字节 key + 12 字节
///   key，前置 16 字节全零随机数槽位），再做 RSA 裸运算加密：模数是
///   115 写死的 1024 位公钥，填充不是标准 PKCS#1 v1.5——填充字节固定
///   0x02 而非随机数，所以用 [BigInt.modPow] 裸算，每块 117 字节明文
///   → 128 字节密文。结果 Base64 后作表单 `data` 字段发出。
/// - 响应 `data` 字段：同一套 RSA 逆运算解开（解开后前 16 字节是
///   randkey，用它现算 XOR 密钥解余下部分）。
/// - 响应外层 body 若不是明文 JSON，先 AES-128-CBC 解密（固定 key/iv，
///   所谓 ecdh_aes 的固定密钥对）再 LZ4 解压。
///
/// 加解密不是互逆的：两边都用公钥指数运算，私钥在服务器侧。所以
/// 本模块的正确性靠公开算法的独立实现交叉向量验（见
/// test/cloud_m115_crypto_test.dart，向量由一份独立 Python 实现按
/// 同一公开算法生成，两边逐字节对答案），不能靠自加密自解密往返验。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'cloud_aes.dart';

// ---------------------------------------------------------------------------
// 常量（p115cipher 公开常量）
// ---------------------------------------------------------------------------

final BigInt _rsaN = BigInt.parse(
  '8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b8602'
  '136477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad6'
  '338c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e'
  '9f10a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb7'
  '1683',
  radix: 16,
);
final BigInt _rsaE = BigInt.from(0x10001);
const _rsaBlock = 128; // 1024 位 RSA，一块 128 字节
const _rsaDataChunk = 117; // 128 - 11

const _gKts = <int>[
  0xF0,
  0xE5,
  0x69,
  0xAE,
  0xBF,
  0xDC,
  0xBF,
  0x8A,
  0x1A,
  0x45,
  0xE8,
  0xBE,
  0x7D,
  0xA6,
  0x73,
  0xB8,
  0xDE,
  0x8F,
  0xE7,
  0xC4,
  0x45,
  0xDA,
  0x86,
  0xC4,
  0x9B,
  0x64,
  0x8B,
  0x14,
  0x6A,
  0xB4,
  0xF1,
  0xAA,
  0x38,
  0x01,
  0x35,
  0x9E,
  0x26,
  0x69,
  0x2C,
  0x86,
  0x00,
  0x6B,
  0x4F,
  0xA5,
  0x36,
  0x34,
  0x62,
  0xA6,
  0x2A,
  0x96,
  0x68,
  0x18,
  0xF2,
  0x4A,
  0xFD,
  0xBD,
  0x6B,
  0x97,
  0x8F,
  0x4D,
  0x8F,
  0x89,
  0x13,
  0xB7,
  0x6C,
  0x8E,
  0x93,
  0xED,
  0x0E,
  0x0D,
  0x48,
  0x3E,
  0xD7,
  0x2F,
  0x88,
  0xD8,
  0xFE,
  0xFE,
  0x7E,
  0x86,
  0x50,
  0x95,
  0x4F,
  0xD1,
  0xEB,
  0x83,
  0x26,
  0x34,
  0xDB,
  0x66,
  0x7B,
  0x9C,
  0x7E,
  0x9D,
  0x7A,
  0x81,
  0x32,
  0xEA,
  0xB6,
  0x33,
  0xDE,
  0x3A,
  0xA9,
  0x59,
  0x34,
  0x66,
  0x3B,
  0xAA,
  0xBA,
  0x81,
  0x60,
  0x48,
  0xB9,
  0xD5,
  0x81,
  0x9C,
  0xF8,
  0x6C,
  0x84,
  0x77,
  0xFF,
  0x54,
  0x78,
  0x26,
  0x5F,
  0xBE,
  0xE8,
  0x1E,
  0x36,
  0x9F,
  0x34,
  0x80,
  0x5C,
  0x45,
  0x2C,
  0x9B,
  0x76,
  0xD5,
  0x1B,
  0x8F,
  0xCC,
  0xC3,
  0xB8,
  0xF5,
];
const _gKeyL = <int>[
  0x78,
  0x06,
  0xAD,
  0x4C,
  0x33,
  0x86,
  0x5D,
  0x18,
  0x4C,
  0x01,
  0x3F,
  0x46,
];
const _rsaKey = <int>[0x8D, 0xA5, 0xA5, 0x8D];
final _aesKey = Uint8List.fromList(const [
  0xFB,
  0x1A,
  0x19,
  0xD6,
  0x52,
  0xF5,
  0xAA,
  0xF7,
  0xBC,
  0x65,
  0x1D,
  0x0F,
  0x69,
  0xBF,
  0x42,
  0x2F,
]);
final _aesIv = Uint8List.fromList(const [
  0x69,
  0xBF,
  0x42,
  0x2F,
  0x49,
  0x96,
  0x05,
  0x50,
  0xA0,
  0xAD,
  0x44,
  0xEC,
  0x34,
  0x46,
  0xCB,
  0x4C,
]);

// ---------------------------------------------------------------------------
// XOR 混淆（不是普通循环异或）
// ---------------------------------------------------------------------------

/// 头部 len%4 个字节对 key 的前几个字节；正文按 key 长度分块，
/// 每块都从 key[0] 重新开始。
Uint8List m115Xor(List<int> src, List<int> key) {
  final out = Uint8List(src.length);
  final head = src.length & 3;
  for (var i = 0; i < head; i++) {
    out[i] = src[i] ^ key[i];
  }
  var num = 0;
  for (var j = head; j < src.length; j++) {
    out[j] = src[j] ^ key[num % key.length];
    num++;
  }
  return out;
}

/// 由 randkey 现算 XOR 密钥（rsa_gen_key）。
Uint8List m115RsaGenKey(List<int> randKey, int skLen) {
  final xorKey = Uint8List(skLen);
  var length = skLen * (skLen - 1);
  var index = 0;
  for (var i = 0; i < skLen; i++) {
    final x = (randKey[i] + _gKts[index]) & 0xFF;
    xorKey[i] = _gKts[length] ^ x;
    length -= skLen;
    index += skLen;
  }
  return xorKey;
}

// ---------------------------------------------------------------------------
// RSA 裸运算
// ---------------------------------------------------------------------------

BigInt _bytesToBigInt(List<int> bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte & 0xFF);
  }
  return value;
}

Uint8List _bigIntToBytes(BigInt value, {int? fixedLength}) {
  if (value == BigInt.zero) {
    return fixedLength == null ? Uint8List(0) : Uint8List(fixedLength);
  }
  var hex = value.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(hex.substring(2 * i, 2 * i + 2), radix: 16);
  }
  if (fixedLength == null || bytes.length == fixedLength) return bytes;
  if (bytes.length > fixedLength) {
    return Uint8List.sublistView(bytes, bytes.length - fixedLength);
  }
  final out = Uint8List(fixedLength);
  out.setAll(fixedLength - bytes.length, bytes);
  return out;
}

/// m^e mod n，定长 128 字节输出。
Uint8List _rsaPow(List<int> block128) {
  final c = _bytesToBigInt(block128).modPow(_rsaE, _rsaN);
  return _bigIntToBytes(c, fixedLength: _rsaBlock);
}

/// 填充：0x00 || 0x02 * (128-2-len) || 0x00 || 数据（固定 0x02）。
Uint8List _padBlock(List<int> msg) {
  final data = Uint8List(_rsaBlock);
  for (var i = 1; i < _rsaBlock - 1 - msg.length; i++) {
    data[i] = 0x02;
  }
  data[_rsaBlock - 1 - msg.length] = 0;
  data.setAll(_rsaBlock - msg.length, msg);
  return data;
}

Uint8List m115RsaEncryptWithPubkey(List<int> data) {
  final out = BytesBuilder();
  var off = 0;
  while (off < data.length) {
    final len = _rsaDataChunk < data.length - off
        ? _rsaDataChunk
        : data.length - off;
    out.add(_rsaPow(_padBlock(data.sublist(off, off + len))));
    off += len;
  }
  return out.toBytes();
}

Uint8List m115RsaDecryptWithPubkey(List<int> cipher) {
  if (cipher.length % _rsaBlock != 0) {
    throw const FormatException('m115 RSA 密文长度不是 128 的倍数');
  }
  final out = BytesBuilder();
  for (var off = 0; off < cipher.length; off += _rsaBlock) {
    final p = _bytesToBigInt(
      cipher.sublist(off, off + _rsaBlock),
    ).modPow(_rsaE, _rsaN);
    final b = _bigIntToBytes(p);
    // 找第一个 0x00 分隔符，取它后面的部分（前导零在最小表示里已不存在，
    // 与参考实现先跳前导零再找分隔符等价）。
    var sep = -1;
    for (var i = 0; i < b.length; i++) {
      if (b[i] == 0) {
        sep = i;
        break;
      }
    }
    if (sep < 0) {
      throw const FormatException('m115 RSA 块里没有零分隔符');
    }
    out.add(Uint8List.sublistView(b, sep + 1));
  }
  return out.toBytes();
}

Uint8List _reversed(List<int> a) {
  final out = Uint8List(a.length);
  for (var i = 0; i < a.length; i++) {
    out[i] = a[a.length - 1 - i];
  }
  return out;
}

/// 加密下载请求体，返回 Base64 文本（当 `data` 表单字段发）。
/// 随机数槽位固定 16 个零字节，所以同一明文的密文是确定的。
String m115RsaEncrypt(List<int> data) {
  final tmp = _reversed(m115Xor(data, _rsaKey));
  final xored = m115Xor(tmp, _gKeyL);
  final xorData = Uint8List(16 + xored.length);
  xorData.setAll(16, xored);
  return base64Encode(m115RsaEncryptWithPubkey(xorData));
}

/// 解密响应 `data` 字段（Base64 文本），返回明文字节（JSON）。
Uint8List m115RsaDecrypt(String cipherB64) {
  final data = m115RsaDecryptWithPubkey(base64Decode(cipherB64));
  if (data.length < 12) {
    throw FormatException('m115 RSA 解密结果太短：${data.length}');
  }
  final randKey = data.sublist(0, 16);
  final keyL = m115RsaGenKey(randKey, 12);
  final rest = data.length > 16 ? data.sublist(16) : Uint8List(0);
  final tmp = _reversed(m115Xor(rest, keyL));
  return m115Xor(tmp, _rsaKey);
}

// ---------------------------------------------------------------------------
// AES-128-CBC（固定 key/iv）+ LZ4
// ---------------------------------------------------------------------------

/// AES-128-CBC 解密 + 标准 PKCS#7 去填充。密文长度不是 16 的倍数时
/// 先截到 16 的倍数（与参考实现一致）；填充字节对不上时原样返回。
Uint8List m115AesCbcDecrypt(List<int> cipher) {
  final len = cipher.length & ~15;
  if (len == 0) return Uint8List(0);
  final out = Uint8List(len);
  var previous = _aesIv;
  for (var off = 0; off < len; off += 16) {
    final block = Uint8List.fromList(cipher.sublist(off, off + 16));
    final plain = aesDecryptBlock(_aesKey, block);
    for (var i = 0; i < 16; i++) {
      out[off + i] = plain[i] ^ previous[i];
    }
    previous = block;
  }
  if (out.isEmpty) return out;
  final pad = out[out.length - 1];
  if (pad >= 1 && pad <= 16 && pad <= out.length) {
    var ok = true;
    for (var i = out.length - pad; i < out.length; i++) {
      if (out[i] != pad) {
        ok = false;
        break;
      }
    }
    if (ok) return Uint8List.sublistView(out, 0, out.length - pad);
  }
  return out;
}

/// 上传 initupload 的 body 加密：与下载同一把 key/iv 的 AES-128-CBC，
/// 但填充是 p115cipher 的非标准版（_pad）：padSize = -len & 15，
/// 已对齐时不补块，填充字节值就是 padSize 本身。解密侧
/// [m115AesCbcDecrypt] 按标准 PKCS#7 去填充：padSize 在 1..15 时
/// 两边兼容，padSize=0 时本来就没有填充块、也无可去，往返成立。
Uint8List m115AesCbcEncrypt(List<int> plain) {
  final padSize = (-plain.length) & 15;
  final padded = Uint8List(plain.length + padSize);
  padded.setAll(0, plain);
  for (var i = plain.length; i < padded.length; i++) {
    padded[i] = padSize;
  }
  final out = Uint8List(padded.length);
  var previous = _aesIv;
  for (var off = 0; off < padded.length; off += 16) {
    final block = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      block[i] = padded[off + i] ^ previous[i];
    }
    final encrypted = aesEncryptBlock(_aesKey, block);
    out.setAll(off, encrypted);
    previous = encrypted;
  }
  return out;
}

/// LZ4 block 解压。
Uint8List m115Lz4BlockDecompress(List<int> src) {
  final dest = <int>[];
  var srcPtr = 0;
  final srcLen = src.length;
  while (srcPtr < srcLen) {
    final token = src[srcPtr++];
    var litLen = token >> 4;
    if (litLen == 15) {
      var extra = 0;
      while (srcPtr < srcLen && src[srcPtr] == 0xFF) {
        extra += 255;
        srcPtr++;
      }
      if (srcPtr < srcLen) {
        extra += src[srcPtr];
        srcPtr++;
      }
      litLen += extra;
    }
    if (litLen > 0) {
      final end = srcPtr + litLen > srcLen ? srcLen : srcPtr + litLen;
      for (var i = srcPtr; i < end; i++) {
        dest.add(src[i]);
      }
      srcPtr += litLen;
    }
    if (srcPtr >= srcLen) break;
    if (srcPtr + 1 >= srcLen) {
      throw const FormatException('LZ4 块在偏移处截断');
    }
    final offset = src[srcPtr] | (src[srcPtr + 1] << 8);
    srcPtr += 2;
    var matchLen = token & 0x0F;
    if (matchLen == 15) {
      var extra = 0;
      while (srcPtr < srcLen && src[srcPtr] == 0xFF) {
        extra += 255;
        srcPtr++;
      }
      if (srcPtr < srcLen) {
        extra += src[srcPtr];
        srcPtr++;
      }
      matchLen += extra;
    }
    matchLen += 4;
    final matchPos = dest.length - offset;
    if (matchPos < 0) {
      throw const FormatException('LZ4 块偏移越界');
    }
    // 逐字节复制：match 可能与写入区重叠，后面的字节要读刚写进去的。
    for (var i = 0; i < matchLen; i++) {
      dest.add(dest[matchPos + i]);
    }
  }
  return Uint8List.fromList(dest);
}

/// LZ4 帧解压：[2 字节小端长度][block] 循环。
Uint8List m115Lz4Decompress(List<int> source) {
  final out = BytesBuilder();
  var off = 0;
  while (source.length - off > 2) {
    final len = source[off] | (source[off + 1] << 8);
    if (len == 0) break;
    final end = off + 2 + len > source.length ? source.length : off + 2 + len;
    out.add(m115Lz4BlockDecompress(source.sublist(off + 2, end)));
    off += len + 2;
  }
  return out.toBytes();
}

/// ecdh_aes 解密：AES-128-CBC + LZ4。
Uint8List m115EcdhAesDecrypt(List<int> cipher) =>
    m115Lz4Decompress(m115AesCbcDecrypt(cipher));

/// 外层响应解密：body 是明文 JSON 就原样返回，否则按 AES-CBC + LZ4 解。
Uint8List m115ContentMaybeDecrypt(List<int> content) {
  if (content.length >= 2) {
    final first = content[0];
    final last = content[content.length - 1];
    const braceL = 0x7B, braceR = 0x7D; // { }
    const brackL = 0x5B, brackR = 0x5D; // [ ]
    const quote = 0x22; // "
    if ((first == braceL && last == braceR) ||
        (first == brackL && last == brackR) ||
        (first == quote && last == quote)) {
      return Uint8List.fromList(content);
    }
  }
  return m115EcdhAesDecrypt(content);
}
