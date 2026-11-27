/// 纯 Dart 的 AES 实现（ECB/CBC，128/192/256 位密钥，PKCS7 填充）。
///
/// 树里没有 AES 加密依赖（`content_crypto.dart` 只有 AES-128-CBC 解密，
/// 且只认 128 位密钥），移动云盘的登录信封需要 AES-192-CBC 加密、
/// AES-128-ECB 加密与解密，所以这里自带一份最小实现，不新增依赖。
///
/// 算法按 FIPS-197 写：S 盒由 GF(2^8) 求逆 + 仿射变换实时生成（不硬抄
/// 表），密钥扩展支持 Nk=4/6/8。正确性由 `test/cloud_drive_139_test.dart`
/// 里的 FIPS-197 标准向量与 NIST CBC 向量覆盖。
library;

import 'dart:typed_data';

int _gmul(int a, int b) {
  var product = 0;
  var x = a;
  var y = b;
  for (var i = 0; i < 8; i++) {
    if (y & 1 != 0) product ^= x;
    final high = x & 0x80;
    x = (x << 1) & 0xFF;
    if (high != 0) x ^= 0x1B;
    y >>= 1;
  }
  return product;
}

int _gfInverse(int a) {
  if (a == 0) return 0;
  for (var x = 1; x < 256; x++) {
    if (_gmul(a, x) == 1) return x;
  }
  throw StateError('AES S 盒生成失败：$a 在 GF(2^8) 里没有逆元');
}

int _rotl8(int x, int n) => ((x << n) | (x >> (8 - n))) & 0xFF;

List<int> _buildSbox() {
  final sbox = List<int>.filled(256, 0);
  for (var x = 0; x < 256; x++) {
    final inverse = _gfInverse(x);
    sbox[x] =
        inverse ^
        _rotl8(inverse, 1) ^
        _rotl8(inverse, 2) ^
        _rotl8(inverse, 3) ^
        _rotl8(inverse, 4) ^
        0x63;
  }
  return sbox;
}

final List<int> _sbox = _buildSbox();

final List<int> _invSbox = () {
  final inverse = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    inverse[_sbox[i]] = i;
  }
  return inverse;
}();

const _rcon = [
  0x01,
  0x02,
  0x04,
  0x08,
  0x10,
  0x20,
  0x40,
  0x80,
  0x1B,
  0x36,
  0x6C,
  0xD8,
  0xAB,
  0x4D,
];

/// 密钥扩展：返回 Nr+1 个轮密钥（每轮 16 字节）。
List<List<int>> _expandKey(Uint8List key) {
  final nk = key.length ~/ 4;
  final nr = nk + 6;
  final words = List<int>.from(key);
  for (var i = nk; i < 4 * (nr + 1); i++) {
    var temp = words.sublist(4 * (i - 1), 4 * i);
    if (i % nk == 0) {
      temp = [
        _sbox[temp[1]] ^ _rcon[i ~/ nk - 1],
        _sbox[temp[2]],
        _sbox[temp[3]],
        _sbox[temp[0]],
      ];
    } else if (nk > 6 && i % nk == 4) {
      temp = [for (final byte in temp) _sbox[byte]];
    }
    for (var j = 0; j < 4; j++) {
      words.add(words[4 * (i - nk) + j] ^ temp[j]);
    }
  }
  return [
    for (var round = 0; round <= nr; round++)
      words.sublist(16 * round, 16 * round + 16),
  ];
}

void _checkKey(Uint8List key) {
  if (key.length != 16 && key.length != 24 && key.length != 32) {
    throw ArgumentError('AES 密钥长度必须是 16/24/32 字节，实际 ${key.length}');
  }
}

List<int> _addRoundKey(List<int> state, List<int> roundKey) =>
    [for (var i = 0; i < 16; i++) state[i] ^ roundKey[i]];

List<int> _shiftRows(List<int> state) {
  final out = List<int>.filled(16, 0);
  for (var row = 0; row < 4; row++) {
    for (var col = 0; col < 4; col++) {
      out[row + 4 * col] = state[row + 4 * ((col + row) % 4)];
    }
  }
  return out;
}

List<int> _invShiftRows(List<int> state) {
  final out = List<int>.filled(16, 0);
  for (var row = 0; row < 4; row++) {
    for (var col = 0; col < 4; col++) {
      out[row + 4 * col] = state[row + 4 * ((col - row) % 4)];
    }
  }
  return out;
}

List<int> _mixColumns(List<int> state) {
  final out = List<int>.filled(16, 0);
  for (var col = 0; col < 4; col++) {
    final a = state.sublist(4 * col, 4 * col + 4);
    out[4 * col + 0] = _gmul(a[0], 2) ^ _gmul(a[1], 3) ^ a[2] ^ a[3];
    out[4 * col + 1] = a[0] ^ _gmul(a[1], 2) ^ _gmul(a[2], 3) ^ a[3];
    out[4 * col + 2] = a[0] ^ a[1] ^ _gmul(a[2], 2) ^ _gmul(a[3], 3);
    out[4 * col + 3] = _gmul(a[0], 3) ^ a[1] ^ a[2] ^ _gmul(a[3], 2);
  }
  return out;
}

List<int> _invMixColumns(List<int> state) {
  final out = List<int>.filled(16, 0);
  for (var col = 0; col < 4; col++) {
    final a = state.sublist(4 * col, 4 * col + 4);
    out[4 * col + 0] =
        _gmul(a[0], 14) ^ _gmul(a[1], 11) ^ _gmul(a[2], 13) ^ _gmul(a[3], 9);
    out[4 * col + 1] =
        _gmul(a[0], 9) ^ _gmul(a[1], 14) ^ _gmul(a[2], 11) ^ _gmul(a[3], 13);
    out[4 * col + 2] =
        _gmul(a[0], 13) ^ _gmul(a[1], 9) ^ _gmul(a[2], 14) ^ _gmul(a[3], 11);
    out[4 * col + 3] =
        _gmul(a[0], 11) ^ _gmul(a[1], 13) ^ _gmul(a[2], 9) ^ _gmul(a[3], 14);
  }
  return out;
}

/// 加密一个 16 字节块（不填充）。
Uint8List aesEncryptBlock(Uint8List key, Uint8List block) {
  _checkKey(key);
  if (block.length != 16) {
    throw ArgumentError('AES 块长度必须是 16 字节，实际 ${block.length}');
  }
  final roundKeys = _expandKey(key);
  final nr = roundKeys.length - 1;
  var state = _addRoundKey(block.toList(), roundKeys[0]);
  for (var round = 1; round < nr; round++) {
    state = _addRoundKey(
      _mixColumns(
        _shiftRows([for (final byte in state) _sbox[byte]]),
      ),
      roundKeys[round],
    );
  }
  state = _addRoundKey(
    _shiftRows([for (final byte in state) _sbox[byte]]),
    roundKeys[nr],
  );
  return Uint8List.fromList(state);
}

/// 解密一个 16 字节块（不去填充）。
Uint8List aesDecryptBlock(Uint8List key, Uint8List block) {
  _checkKey(key);
  if (block.length != 16) {
    throw ArgumentError('AES 块长度必须是 16 字节，实际 ${block.length}');
  }
  final roundKeys = _expandKey(key);
  final nr = roundKeys.length - 1;
  var state = _addRoundKey(block.toList(), roundKeys[nr]);
  for (var round = nr - 1; round >= 1; round--) {
    state = _invMixColumns(
      _addRoundKey(
        _invShiftRows([for (final byte in state) _invSbox[byte]]),
        roundKeys[round],
      ),
    );
  }
  state = _addRoundKey(
    _invShiftRows([for (final byte in state) _invSbox[byte]]),
    roundKeys[0],
  );
  return Uint8List.fromList(state);
}

Uint8List _pad(Uint8List data) {
  final padLength = 16 - data.length % 16;
  final out = Uint8List(data.length + padLength);
  out.setAll(0, data);
  for (var i = data.length; i < out.length; i++) {
    out[i] = padLength;
  }
  return out;
}

Uint8List _unpad(Uint8List data) {
  if (data.isEmpty) throw const FormatException('AES 解密结果为空');
  final padLength = data.last;
  if (padLength < 1 || padLength > 16 || padLength > data.length) {
    throw const FormatException('AES 填充无效');
  }
  for (var i = data.length - padLength; i < data.length; i++) {
    if (data[i] != padLength) {
      throw const FormatException('AES 填充无效');
    }
  }
  return Uint8List.sublistView(data, 0, data.length - padLength);
}

void _checkDecryptLength(Uint8List data) {
  if (data.isEmpty || data.length % 16 != 0) {
    throw FormatException('AES 密文长度必须是 16 的倍数，实际 ${data.length}');
  }
}

/// ECB 加密（PKCS7 填充）。
Uint8List aesEcbEncrypt(Uint8List key, Uint8List data) {
  _checkKey(key);
  final padded = _pad(data);
  final out = Uint8List(padded.length);
  for (var off = 0; off < padded.length; off += 16) {
    final block = aesEncryptBlock(
      key,
      Uint8List.sublistView(padded, off, off + 16),
    );
    out.setAll(off, block);
  }
  return out;
}

/// ECB 解密（PKCS7 去填充；填充不对抛 [FormatException]）。
Uint8List aesEcbDecrypt(Uint8List key, Uint8List data) {
  _checkKey(key);
  _checkDecryptLength(data);
  final out = Uint8List(data.length);
  for (var off = 0; off < data.length; off += 16) {
    final block = aesDecryptBlock(
      key,
      Uint8List.sublistView(data, off, off + 16),
    );
    out.setAll(off, block);
  }
  return _unpad(out);
}

/// CBC 加密（PKCS7 填充，[iv] 16 字节）。
Uint8List aesCbcEncrypt(Uint8List key, Uint8List iv, Uint8List data) {
  _checkKey(key);
  if (iv.length != 16) {
    throw ArgumentError('AES CBC 的 IV 必须是 16 字节，实际 ${iv.length}');
  }
  final padded = _pad(data);
  final out = Uint8List(padded.length);
  var previous = iv;
  for (var off = 0; off < padded.length; off += 16) {
    final xored = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      xored[i] = padded[off + i] ^ previous[i];
    }
    final block = aesEncryptBlock(key, xored);
    out.setAll(off, block);
    previous = block;
  }
  return out;
}

/// CBC 解密（PKCS7 去填充；填充不对抛 [FormatException]）。
Uint8List aesCbcDecrypt(Uint8List key, Uint8List iv, Uint8List data) {
  _checkKey(key);
  if (iv.length != 16) {
    throw ArgumentError('AES CBC 的 IV 必须是 16 字节，实际 ${iv.length}');
  }
  _checkDecryptLength(data);
  final out = Uint8List(data.length);
  var previous = iv;
  for (var off = 0; off < data.length; off += 16) {
    final cipherBlock = Uint8List.sublistView(data, off, off + 16);
    final plain = aesDecryptBlock(key, cipherBlock);
    for (var i = 0; i < 16; i++) {
      out[off + i] = plain[i] ^ previous[i];
    }
    previous = cipherBlock;
  }
  return _unpad(out);
}
