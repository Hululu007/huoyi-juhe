/// Pure Dart AES (128/192/256) for sites whose API responses are
/// AES-encrypted (Niuguo ECB, Huangdou/Yeguo CBC). S-boxes are computed
/// from the GF(2^8) definition at first use, not copied tables, so a
/// typo in a table cannot silently break decryption.

int _gfMul(int a, int b) {
  var result = 0;
  var x = a;
  var y = b;
  while (y != 0) {
    if ((y & 1) != 0) result ^= x;
    final hi = x & 0x80;
    x = (x << 1) & 0xFF;
    if (hi != 0) x ^= 0x1B;
    y >>= 1;
  }
  return result;
}

int _gfPow(int a, int e) {
  var result = 1;
  var base = a;
  while (e > 0) {
    if ((e & 1) != 0) result = _gfMul(result, base);
    base = _gfMul(base, base);
    e >>= 1;
  }
  return result;
}

int _rotl8(int value, int shift) =>
    ((value << shift) | (value >> (8 - shift))) & 0xFF;

List<int>? _sBox;
List<int>? _invSBox;

void _ensureBoxes() {
  if (_sBox != null) return;
  final sBox = List<int>.filled(256, 0);
  final invSBox = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    final inv = i == 0 ? 0 : _gfPow(i, 254);
    final s =
        inv ^ _rotl8(inv, 1) ^ _rotl8(inv, 2) ^ _rotl8(inv, 3) ^ _rotl8(inv, 4) ^ 0x63;
    sBox[i] = s;
    invSBox[s] = i;
  }
  _sBox = sBox;
  _invSBox = invSBox;
}

List<int> _expandKey(List<int> key) {
  _ensureBoxes();
  final nk = key.length ~/ 4;
  final nr = nk + 6;
  final w = List<int>.filled(16 * (nr + 1), 0);
  for (var i = 0; i < nk; i++) {
    w[4 * i] = key[4 * i];
    w[4 * i + 1] = key[4 * i + 1];
    w[4 * i + 2] = key[4 * i + 2];
    w[4 * i + 3] = key[4 * i + 3];
  }
  var rcon = 1;
  for (var i = nk; i < 4 * (nr + 1); i++) {
    var temp0 = w[4 * (i - 1)];
    var temp1 = w[4 * (i - 1) + 1];
    var temp2 = w[4 * (i - 1) + 2];
    var temp3 = w[4 * (i - 1) + 3];
    if (i % nk == 0) {
      final t = temp0;
      temp0 = _sBox![temp1] ^ rcon;
      temp1 = _sBox![temp2];
      temp2 = _sBox![temp3];
      temp3 = _sBox![t];
      rcon = _gfMul(rcon, 2);
    } else if (nk > 6 && i % nk == 4) {
      temp0 = _sBox![temp0];
      temp1 = _sBox![temp1];
      temp2 = _sBox![temp2];
      temp3 = _sBox![temp3];
    }
    w[4 * i] = w[4 * (i - nk)] ^ temp0;
    w[4 * i + 1] = w[4 * (i - nk) + 1] ^ temp1;
    w[4 * i + 2] = w[4 * (i - nk) + 2] ^ temp2;
    w[4 * i + 3] = w[4 * (i - nk) + 3] ^ temp3;
  }
  return w;
}

void _addRoundKey(List<int> state, List<int> w, int round) {
  for (var c = 0; c < 4; c++) {
    for (var r = 0; r < 4; r++) {
      state[r + 4 * c] ^= w[round * 16 + r + 4 * c];
    }
  }
}

void _subBytes(List<int> state, List<int> box) {
  for (var i = 0; i < 16; i++) {
    state[i] = box[state[i]];
  }
}

void _shiftRows(List<int> state) {
  final old = List<int>.from(state);
  for (var r = 0; r < 4; r++) {
    for (var c = 0; c < 4; c++) {
      state[r + 4 * c] = old[r + 4 * ((c + r) % 4)];
    }
  }
}

void _invShiftRows(List<int> state) {
  final old = List<int>.from(state);
  for (var r = 0; r < 4; r++) {
    for (var c = 0; c < 4; c++) {
      state[r + 4 * c] = old[r + 4 * ((c - r + 4) % 4)];
    }
  }
}

void _mixColumns(List<int> state) {
  for (var c = 0; c < 4; c++) {
    final a0 = state[4 * c];
    final a1 = state[4 * c + 1];
    final a2 = state[4 * c + 2];
    final a3 = state[4 * c + 3];
    state[4 * c] =
        _gfMul(a0, 2) ^ _gfMul(a1, 3) ^ a2 ^ a3;
    state[4 * c + 1] =
        a0 ^ _gfMul(a1, 2) ^ _gfMul(a2, 3) ^ a3;
    state[4 * c + 2] =
        a0 ^ a1 ^ _gfMul(a2, 2) ^ _gfMul(a3, 3);
    state[4 * c + 3] =
        _gfMul(a0, 3) ^ a1 ^ a2 ^ _gfMul(a3, 2);
  }
}

void _invMixColumns(List<int> state) {
  for (var c = 0; c < 4; c++) {
    final a0 = state[4 * c];
    final a1 = state[4 * c + 1];
    final a2 = state[4 * c + 2];
    final a3 = state[4 * c + 3];
    state[4 * c] =
        _gfMul(a0, 14) ^ _gfMul(a1, 11) ^ _gfMul(a2, 13) ^ _gfMul(a3, 9);
    state[4 * c + 1] =
        _gfMul(a0, 9) ^ _gfMul(a1, 14) ^ _gfMul(a2, 11) ^ _gfMul(a3, 13);
    state[4 * c + 2] =
        _gfMul(a0, 13) ^ _gfMul(a1, 9) ^ _gfMul(a2, 14) ^ _gfMul(a3, 11);
    state[4 * c + 3] =
        _gfMul(a0, 11) ^ _gfMul(a1, 13) ^ _gfMul(a2, 9) ^ _gfMul(a3, 14);
  }
}

List<int> aesEncryptBlock(List<int> block, List<int> key) {
  if (block.length != 16) throw ArgumentError('AES block must be 16 bytes');
  if (key.length != 16 && key.length != 24 && key.length != 32) {
    throw ArgumentError('AES key must be 16, 24 or 32 bytes');
  }
  _ensureBoxes();
  final nr = key.length ~/ 4 + 6;
  final w = _expandKey(key);
  final state = List<int>.from(block);
  _addRoundKey(state, w, 0);
  for (var round = 1; round < nr; round++) {
    _subBytes(state, _sBox!);
    _shiftRows(state);
    _mixColumns(state);
    _addRoundKey(state, w, round);
  }
  _subBytes(state, _sBox!);
  _shiftRows(state);
  _addRoundKey(state, w, nr);
  return state;
}

List<int> aesDecryptBlock(List<int> block, List<int> key) {
  if (block.length != 16) throw ArgumentError('AES block must be 16 bytes');
  if (key.length != 16 && key.length != 24 && key.length != 32) {
    throw ArgumentError('AES key must be 16, 24 or 32 bytes');
  }
  _ensureBoxes();
  final nr = key.length ~/ 4 + 6;
  final w = _expandKey(key);
  final state = List<int>.from(block);
  _addRoundKey(state, w, nr);
  for (var round = nr - 1; round >= 1; round--) {
    _invShiftRows(state);
    _subBytes(state, _invSBox!);
    _addRoundKey(state, w, round);
    _invMixColumns(state);
  }
  _invShiftRows(state);
  _subBytes(state, _invSBox!);
  _addRoundKey(state, w, 0);
  return state;
}

List<int> _pkcs7Pad(List<int> data) {
  final pad = 16 - (data.length % 16);
  return [...data, ...List<int>.filled(pad, pad)];
}

List<int> _pkcs7Unpad(List<int> data) {
  if (data.isEmpty || data.length % 16 != 0) {
    throw StateError('ciphertext length is not block aligned');
  }
  final pad = data.last;
  if (pad < 1 || pad > 16) throw StateError('invalid PKCS7 padding');
  for (var i = 0; i < pad; i++) {
    if (data[data.length - 1 - i] != pad) {
      throw StateError('invalid PKCS7 padding');
    }
  }
  return data.sublist(0, data.length - pad);
}

List<int> aesEcbDecrypt(List<int> ciphertext, List<int> key) {
  if (ciphertext.length % 16 != 0) {
    throw StateError('ciphertext length is not block aligned');
  }
  final out = <int>[];
  for (var offset = 0; offset < ciphertext.length; offset += 16) {
    out.addAll(
      aesDecryptBlock(ciphertext.sublist(offset, offset + 16), key),
    );
  }
  return _pkcs7Unpad(out);
}

List<int> aesCbcDecrypt(List<int> ciphertext, List<int> key, List<int> iv) {
  if (ciphertext.length % 16 != 0) {
    throw StateError('ciphertext length is not block aligned');
  }
  if (iv.length != 16) throw ArgumentError('AES IV must be 16 bytes');
  final out = <int>[];
  var previous = List<int>.from(iv);
  for (var offset = 0; offset < ciphertext.length; offset += 16) {
    final block = ciphertext.sublist(offset, offset + 16);
    final decrypted = aesDecryptBlock(block, key);
    for (var i = 0; i < 16; i++) {
      out.add(decrypted[i] ^ previous[i]);
    }
    previous = block;
  }
  return _pkcs7Unpad(out);
}

List<int> aesCbcEncrypt(List<int> plaintext, List<int> key, List<int> iv) {
  if (iv.length != 16) throw ArgumentError('AES IV must be 16 bytes');
  final padded = _pkcs7Pad(plaintext);
  final out = <int>[];
  var previous = List<int>.from(iv);
  for (var offset = 0; offset < padded.length; offset += 16) {
    final block = List<int>.generate(
      16,
      (i) => padded[offset + i] ^ previous[i],
    );
    final encrypted = aesEncryptBlock(block, key);
    out.addAll(encrypted);
    previous = encrypted;
  }
  return out;
}
