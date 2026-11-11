import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'aes_cipher.dart';
import 'hongguo_tables.dart';

int _u32(int v) => v & 0xFFFFFFFF;

int _rol32(int v, int s) {
  s %= 32;
  if (s == 0) return _u32(v);
  final x = _u32(v);
  return ((x << s) | (x >>> (32 - s))) & 0xFFFFFFFF;
}

int _ror32(int v, int c) {
  c %= 32;
  if (c == 0) return _u32(v);
  final x = _u32(v);
  return ((x >>> c) | (x << (32 - c))) & 0xFFFFFFFF;
}

int _rol64(int v, int s) {
  s %= 64;
  if (s < 0) s += 64;
  if (s == 0) return v;
  return (v << s) | (v >>> (64 - s));
}

int _ror64(int v, int c) {
  c %= 64;
  if (c == 0) return v;
  return (v >>> c) | (v << (64 - c));
}

int _rl8(int x, int k) {
  final s = k & 7;
  if (s == 0) return x & 0xFF;
  return ((x << s) | (x >>> (8 - s))) & 0xFF;
}

List<int> _u32le(int v) => [
  v & 0xFF,
  (v >>> 8) & 0xFF,
  (v >>> 16) & 0xFF,
  (v >>> 24) & 0xFF,
];

List<int> _u32be(int v) => [
  (v >>> 24) & 0xFF,
  (v >>> 16) & 0xFF,
  (v >>> 8) & 0xFF,
  v & 0xFF,
];

int _byteAt(List<int> data, int index) {
  if (index < 0 || index >= data.length) return 0;
  return data[index];
}

int _u32leAt(List<int> data, int offset) {
  return _byteAt(data, offset) |
      (_byteAt(data, offset + 1) << 8) |
      (_byteAt(data, offset + 2) << 16) |
      (_byteAt(data, offset + 3) << 24);
}

int _u32beAt(List<int> data, int offset) {
  return (_byteAt(data, offset) << 24) |
      (_byteAt(data, offset + 1) << 16) |
      (_byteAt(data, offset + 2) << 8) |
      _byteAt(data, offset + 3);
}

int _u64leAt(List<int> data, int offset) {
  return _u32leAt(data, offset) | (_u32leAt(data, offset + 4) << 32);
}

List<int> _md5(List<int> data) => md5.convert(data).bytes;

String _hexLower(List<int> data) {
  const chars = '0123456789abcdef';
  final out = StringBuffer();
  for (final b in data) {
    out.write(chars[(b >> 4) & 15]);
    out.write(chars[b & 15]);
  }
  return out.toString();
}

String _hexUpper(List<int> data) {
  const chars = '0123456789ABCDEF';
  final out = StringBuffer();
  for (final b in data) {
    out.write(chars[(b >> 4) & 15]);
    out.write(chars[b & 15]);
  }
  return out.toString();
}

List<int> _hexDecode(String s) {
  final out = <int>[];
  for (var i = 0; i + 1 < s.length; i += 2) {
    out.add(int.parse(s.substring(i, i + 2), radix: 16));
  }
  return out;
}

List<int> _xorBytes(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  return List<int>.generate(n, (i) => a[i] ^ b[i]);
}

List<int> _pkcs7Pad(List<int> data) {
  final padding = 16 - data.length % 16;
  return [...data, for (var i = 0; i < padding; i++) padding];
}

List<int> _cbcEncryptNoPad(List<int> data, List<int> key, List<int> iv) {
  if (data.length % 16 != 0) {
    throw StateError('cbc input length is not block aligned');
  }
  final out = <int>[];
  var previous = List<int>.from(iv);
  for (var offset = 0; offset < data.length; offset += 16) {
    final block = List<int>.generate(
      16,
      (i) => data[offset + i] ^ previous[i],
    );
    final encrypted = aesEncryptBlock(block, key);
    out.addAll(encrypted);
    previous = encrypted;
  }
  return out;
}

List<int> hongguoSm3(List<int> input) {
  return _sm3Compress(input);
}

List<int> _sm3Compress(List<int> input) {
  final length = input.length * 8;
  final data = [...input, 0x80];
  while (data.length % 64 != 56) {
    data.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    data.add((length >>> (i * 8)) & 0xFF);
  }
  var state = [
    0x7380166f,
    0x4914b2b9,
    0x172442d7,
    0xda8a0600,
    0xa96f30bc,
    0x163138aa,
    0xe38dee4d,
    0xb0fb0e4e,
  ];
  for (var offset = 0; offset < data.length; offset += 64) {
    final words = List<int>.filled(68, 0);
    for (var i = 0; i < 16; i++) {
      words[i] = _u32beAt(data, offset + i * 4);
    }
    for (var i = 16; i < words.length; i++) {
      final v = _u32(
        words[i - 16] ^
            words[i - 9] ^
            _rol32(words[i - 3], 15),
      );
      words[i] = _u32(
        v ^
            _rol32(v, 15) ^
            _rol32(v, 23) ^
            _rol32(words[i - 13], 7) ^
            words[i - 6],
      );
    }
    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];
    var f = state[5];
    var g = state[6];
    var h = state[7];
    for (var i = 0; i < 64; i++) {
      var t = 0x79cc4519;
      var ff = _u32(a ^ b ^ c);
      var gg = _u32(e ^ f ^ g);
      if (i >= 16) {
        t = 0x7a879d8a;
        ff = _u32((a & b) | (a & c) | (b & c));
        gg = _u32((e & f) | ((~e) & g));
      }
      final ss1 = _rol32(_u32(_rol32(a, 12) + e + _rol32(t, i)), 7);
      final tt1 = _u32(
        ff + d + _u32(ss1 ^ _rol32(a, 12)) + _u32(words[i] ^ words[i + 4]),
      );
      final tt2 = _u32(gg + h + ss1 + words[i]);
      final na = tt1;
      final nb = a;
      final nc = _rol32(b, 9);
      final nd = c;
      final ne = _u32(tt2 ^ _rol32(tt2, 9) ^ _rol32(tt2, 17));
      final nf = e;
      final ng = _rol32(f, 19);
      final nh = g;
      a = na;
      b = nb;
      c = nc;
      d = nd;
      e = ne;
      f = nf;
      g = ng;
      h = nh;
    }
    final next = [a, b, c, d, e, f, g, h];
    for (var i = 0; i < 8; i++) {
      state[i] = _u32(state[i] ^ next[i]);
    }
  }
  final out = <int>[];
  for (final v in state) {
    out.addAll(_u32be(v));
  }
  return out;
}

int _sixGodSumMd5(List<int> data) {
  var check = 0x20220420;
  for (var i = 0; i < 12; i++) {
    int temp;
    if (i % 2 == 0) {
      temp = _u32((check >>> 3) ^ check);
      check = _u32(_byteAt(data, i) ^ (check << 7));
    } else {
      temp = _u32((check >>> 5) ^ check);
      check = _u32(_byteAt(data, i) | (check << 11));
      check = _u32(~check);
    }
    check = _u32(check ^ temp);
  }
  check = _u32(check | 4);
  check = _u32(check ^ 0x1000000);
  return check;
}

List<int> _sixGodBlockDivide(List<int> block, int chunks) {
  final size = block.length ~/ chunks;
  return List<int>.generate(
    chunks,
    (i) => _u32leAt(block, i * size),
  );
}

int _sixGodFF(int a, int b, int c, int d, int m, int s, int t) {
  return _u32(b + _rol32(_u32(a + _u32((b & c) | ((~b) & d)) + m + t), s));
}

int _sixGodGG(int a, int b, int c, int d, int m, int s, int t) {
  return _u32(b + _rol32(_u32(a + _u32((b & d) | (c & (~d))) + m + t), s));
}

int _sixGodHH(int a, int b, int c, int d, int m, int s, int t) {
  return _u32(b + _rol32(_u32(a + _u32(b ^ c ^ d) + m + t), s));
}

int _sixGodII(int a, int b, int c, int d, int m, int s, int t) {
  return _u32(b + _rol32(_u32(a + _u32(c ^ (b | (~d))) + m + t), s));
}

List<int> _sixGodMD5SumV3(
  List<int> msg,
  int countV2,
  List<int> orders,
  int countV1,
) {
  final count = countV2 & 255;
  final sv = List<int>.generate(
    64,
    (i) => _ror32(sixGodSV2[i], countV1),
  );
  final start = [
    _ror32(0x79e0f2fb, count),
    _ror32(0xc8b52570, count),
    _ror32(0xebc2f8cd, count),
    _ror32(0x7c104d93, count),
  ];
  final endCount = (countV2 + 6) & 255;
  final end = [
    _ror32(0x19be4866, endCount),
    _ror32(0xe85986b4, endCount),
    _ror32(0xe19b326e, endCount),
    _ror32(0x71d1d7d4, endCount),
  ];
  final a = start[0];
  final bv = start[1];
  final c = start[2];
  final d = start[3];
  final state = [a, bv, c, d];
  var block = msg;
  if (block.length > 64) block = block.sublist(0, 64);
  final m = _sixGodBlockDivide(block, 16);
  final orderArr = [
    orders.sublist(0, 16),
    orders.sublist(16, 32),
    orders.sublist(32, 48),
    orders.sublist(48, 64),
  ];
  const shiftArr = [
    [7, 12, 17, 22],
    [5, 9, 14, 20],
    [4, 11, 16, 23],
    [6, 10, 15, 21],
  ];
  final funcArr = [_sixGodFF, _sixGodGG, _sixGodHH, _sixGodII];
  const targetSeq = [0, 3, 2, 1];
  for (var fg = 0; fg < 4; fg++) {
    for (var k = 0; k < 16; k++) {
      final t = targetSeq[k % 4];
      final args = [
        state[t],
        state[(t + 1) % 4],
        state[(t + 2) % 4],
        state[(t + 3) % 4],
      ];
      state[t] = funcArr[fg](
        args[0],
        args[1],
        args[2],
        args[3],
        m[orderArr[fg][k]],
        shiftArr[fg][k % 4],
        sv[fg * 16 + k],
      );
    }
  }
  final af = _u32((a + state[0]) ^ end[0]);
  final bf = _u32((bv + state[1]) ^ end[1]);
  final cf = _u32((c + state[2]) ^ end[2]);
  final df = _u32((d + state[3]) ^ end[3]);
  final result = <int>[];
  result.addAll(_u32le(af));
  result.addAll(_u32le(bf));
  result.addAll(_u32le(cf));
  result.addAll(_u32le(df));
  final s = _sixGodSumMd5(result);
  result.addAll(_u32le(s));
  return result;
}

int _sixGodGetIv(int iv, List<int> data) {
  var v = _u32(iv);
  for (var i = 0; i < data.length; i++) {
    if (i % 2 == 0) {
      v = _u32((v >>> 4) ^ v ^ (v << 6) ^ data[i]);
    } else {
      final inner = _u32((v >>> 7) ^ v ^ (data[i] | (v << 12)));
      v = _u32(~inner);
    }
    v = _u32(v);
  }
  return v;
}

List<int> _sixGodBranch0Xor(
  List<int> data,
  int base,
  List<int> di,
  List<int> tt03,
  int round,
  int x1,
  int x2,
  int x3,
  int x4,
  int x5,
  int x6,
  int x7,
  int x8,
  int x9,
  int x10,
) {
  var d = List<int>.from(data);
  for (var i = 0; i < round; i++) {
    var offset = _u32(base + i);
    final n0 = di[offset & 127];
    final n1 = _u32(((d[x3] ^ d[x4]) & d[x1]) ^ d[x3]);
    final n2 = _u32(
      _rol32(d[x1], 26) ^ _rol32(d[x1], 21) ^ _rol32(d[x1], 7),
    );
    offset = offset & 63;
    final n3 = tt03[offset];
    final n4 = _u32(n0 + n1 + n2 + n3 + d[x5]);
    final n5 = _u32(
      _rol32(d[x2], 30) ^ _rol32(d[x2], 19) ^ _rol32(d[x2], 10),
    );
    final n6 = _u32((d[x2] & d[x6]) | ((d[x2] | d[x6]) & d[x7]));
    final n7 = _u32(n5 + n6);
    final o = d[x9];
    final nd = [d[7], d[0], d[1], d[2], d[3], d[4], d[5], d[6]];
    d = nd;
    d[x10] = _u32(n7 + n4);
    d[x8] = _u32(o + n4);
  }
  return d;
}

List<int> _sixGodBranch0(
  int ivV0,
  int khronos,
  List<int> querySm3,
  List<int> bodyMd5Bytes,
  List<int> tsBytes,
) {
  const tt01 = [0xc4a78580, 0xb3c0fd39, 0xc58c5686, 0xc9aa3ba7, 0xf5a7adf2, 0x963c2ed1];
  final ivV1 = tt01[ivV0];
  final countV1 = _u32(ivV1 + khronos + 1) & 255;
  var countV2 = _u32(ivV1 + khronos);
  const tt02 = [
    0xebb64faf, 0x07aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8,
    0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51, 0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288,
    0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00, 0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e,
    0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83, 0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c,
    0x617ce2a6, 0xe423417e, 0x0a40e143, 0x544e4032, 0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x05b23bb3,
    0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50, 0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8,
    0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14,
    0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1, 0x6ca86f6e, 0x00284ba7, 0x08387cfa, 0x5fb37586,
  ];
  final tt03 = List<int>.generate(64, (i) => _ror32(tt02[i], countV1));
  final n0 = (countV2 + 2) & 7;
  final pad = <int>[];
  const seed = [0xfa, 0x45, 0x61, 0xd7];
  for (var i = 0; i < 4; i++) {
    var v = seed[i] | (seed[i] << 8);
    v = v >> n0;
    pad.add(v & 255);
  }
  countV2 = countV2 & 255;
  int rorC(int x) => _ror32(x, countV2);
  final initValue = [
    rorC(0x7aba4fc8),
    rorC(0x67166507),
    rorC(0x6403fa00),
    rorC(0x340f512f),
    rorC(984304912),
    rorC(3005047866),
    rorC(2874125293),
    rorC(2152413264),
  ];
  final data = <int>[];
  data.addAll(querySm3);
  data.addAll(bodyMd5Bytes);
  data.addAll(tsBytes);
  data.addAll(pad);
  data.addAll([0, 0, 0, 0, 0, 0, 1, 0xa0]);
  final di = <int>[];
  for (var i = 0; i < data.length ~/ 4; i++) {
    di.add(_u32beAt(data, i * 4));
  }
  var di0 = di[0];
  for (var i = 0; i < 112; i++) {
    final di1 = di[i + 1];
    final di14 = di[i + 14];
    final rDi1 = _u32(
      _rol32(di1, 14) ^ _rol32(di1, 25) ^ (di1 >>> 3),
    );
    final rDi2 = _u32(
      _rol32(di14, 13) ^ _rol32(di14, 15) ^ (di14 >>> 10),
    );
    di0 = _u32(di0 + di[i + 9] + rDi1 + rDi2);
    di.add(di0);
    di0 = di1;
  }
  List<int> vj;
  switch (ivV0) {
    case 5:
      vj = _sixGodBranch0Xor(initValue, ivV1, di, tt03, 100, 2, 0, 3, 5, 4, 6, 7, 2, 1, 5);
    case 4:
      vj = _sixGodBranch0Xor(initValue, ivV1, di, tt03, 96, 0, 5, 6, 7, 3, 1, 2, 5, 4, 4);
    case 3:
      vj = _sixGodBranch0Xor(initValue, ivV1, di, tt03, 99, 3, 6, 2, 4, 5, 1, 0, 0, 7, 6);
    case 2:
      vj = _sixGodBranch0Xor(initValue, ivV1, di, tt03, 96, 7, 6, 2, 1, 4, 0, 5, 4, 3, 5);
    case 1:
      vj = _sixGodBranch0Xor(initValue, ivV1, di, tt03, 96, 0, 6, 7, 5, 3, 2, 1, 5, 4, 4);
    default:
      vj = _sixGodBranch0Xor(initValue, ivV1, di, tt03, 101, 5, 7, 6, 3, 2, 1, 0, 5, 4, 3);
  }
  final ret = <int>[];
  for (var i = 0; i < 8; i++) {
    ret.addAll(_u32be(_u32(vj[i] + initValue[i])));
  }
  final first16 = ret.sublist(0, 16);
  final second16 = ret.sublist(16);
  final xored = _xorBytes(first16, second16);
  final s = _sixGodSumMd5(xored);
  xored.addAll(_u32le(s));
  return xored;
}

int Function(int) _sixGodBranch1TableF(int ivV0, List<int> branchOne) {
  final table = branchOne.sublist(ivV0 * 16384);
  return (int x) => _u64leAt(table, x);
}

int _sixGodR00(
  int r0,
  int r1,
  int r2,
  int r3,
  int r4,
  int r5,
  int r6,
  int r7,
  int tt,
  int Function(int) tableF,
) {
  var x = tableF((r0 >>> 56) * 8);
  r1 = (r1 >>> 45) & 2040;
  if (tt != 0) x = x ^ tt;
  x = x ^ tableF(r1 + 2048);
  r2 = (r2 >>> 37) & 2040;
  x = x ^ tableF(r2 + 4096);
  r3 = (r3 >>> 29) & 2040;
  x = x ^ tableF(r3 + 6144);
  r4 = (r4 >>> 21) & 2040;
  x = x ^ tableF(r4 + 8192);
  r5 = (r5 >>> 13) & 2040;
  x = x ^ tableF(r5 + 10240);
  r6 = (r6 >>> 8) & 255;
  x = x ^ tableF(r6 * 8 + 12288);
  r7 = r7 & 255;
  x = x ^ tableF(r7 * 8 + 14336);
  return x;
}

List<int> _sixGodSwapV0(
  List<int> src,
  List<int> srcXor,
  List<int> tt2,
  int Function(int) tableF,
  List<int> order1,
  List<int>? typ,
) {
  final da0 = List<int>.filled(8, 0);
  var ha0 = List<int>.from(srcXor);
  for (var i = 0; i < 8; i++) {
    da0[i] = src[order1[i]] ^ srcXor[i];
  }
  for (var round = 0; round < 10; round++) {
    final rr0 = _sixGodR00(ha0[0], ha0[1], ha0[2], ha0[3], ha0[4], ha0[5], ha0[6], ha0[7], 0, tableF);
    final rr1 = _sixGodR00(ha0[1], ha0[2], ha0[3], ha0[4], ha0[5], ha0[6], ha0[7], ha0[0], 0, tableF);
    final rr2 = _sixGodR00(ha0[2], ha0[3], ha0[4], ha0[5], ha0[6], ha0[7], ha0[0], ha0[1], 0, tableF);
    final rr3 = _sixGodR00(ha0[3], ha0[4], ha0[5], ha0[6], ha0[7], ha0[0], ha0[1], ha0[2], 0, tableF);
    final rr4 = _sixGodR00(ha0[4], ha0[5], ha0[6], ha0[7], ha0[0], ha0[1], ha0[2], ha0[3], 0, tableF);
    final rr5 = _sixGodR00(ha0[5], ha0[6], ha0[7], ha0[0], ha0[1], ha0[2], ha0[3], ha0[4], 0, tableF);
    final rr6 = _sixGodR00(ha0[6], ha0[7], ha0[0], ha0[1], ha0[2], ha0[3], ha0[4], ha0[5], 0, tableF);
    var rr7 = _sixGodR00(ha0[7], ha0[0], ha0[1], ha0[2], ha0[3], ha0[4], ha0[5], ha0[6], 0, tableF);
    rr7 = rr7 ^ tt2[round + 1];
    final d0 = da0[0];
    final d1 = da0[1];
    final d2 = da0[2];
    final d3 = da0[3];
    final d4 = da0[4];
    final d5 = da0[5];
    final d6 = da0[6];
    final d7 = da0[7];
    da0[0] = _sixGodR00(d0, d1, d2, d3, d4, d5, d6, d7, rr0, tableF);
    da0[1] = _sixGodR00(d1, d2, d3, d4, d5, d6, d7, d0, rr1, tableF);
    da0[2] = _sixGodR00(d2, d3, d4, d5, d6, d7, d0, d1, rr2, tableF);
    da0[3] = _sixGodR00(d3, d4, d5, d6, d7, d0, d1, d2, rr3, tableF);
    da0[4] = _sixGodR00(d4, d5, d6, d7, d0, d1, d2, d3, rr4, tableF);
    da0[5] = _sixGodR00(d5, d6, d7, d0, d1, d2, d3, d4, rr5, tableF);
    da0[6] = _sixGodR00(d6, d7, d0, d1, d2, d3, d4, d5, rr6, tableF);
    da0[7] = _sixGodR00(d7, d0, d1, d2, d3, d4, d5, d6, rr7, tableF);
    ha0 = [rr0, rr1, rr2, rr3, rr4, rr5, rr6, rr7];
  }
  if (typ == null) {
    src[0] = da0[0] ^ srcXor[0] ^ src[0];
    src[1] = da0[7] ^ srcXor[1] ^ src[1];
    src[2] = da0[6] ^ srcXor[2] ^ src[2];
    src[3] = da0[5] ^ srcXor[3] ^ src[3];
    src[4] = da0[4] ^ srcXor[4] ^ src[4];
    src[5] = da0[3] ^ srcXor[5] ^ src[5];
    src[6] = da0[2] ^ srcXor[6] ^ src[6];
    src[7] = da0[1] ^ srcXor[7] ^ src[7];
  } else {
    src[0] = da0[7] ^ typ[1];
    src[1] = da0[6] ^ typ[2];
    src[2] = da0[5] ^ typ[3];
    src[3] = da0[4] ^ typ[4];
    src[4] = da0[3] ^ typ[5];
    src[5] = da0[2] ^ typ[6];
    src[6] = da0[1] ^ typ[7] ^ src[7];
    src[7] = da0[0] ^ typ[0];
  }
  return src;
}

List<int> _sixGodBranch1(
  int ivV0,
  int khronos,
  List<int> querySm3,
  List<int> bodyMd5Bytes,
  List<int> tsBytes,
  List<int> branchOne,
) {
  const tt1a = [0x808a9c79, 0xf079807e, 0xbadf79c5, 0xa785d3ff, 0x82d8438c];
  final ivV1 = tt1a[ivV0];
  final cV1raw = _u32(ivV1 + khronos) & 255;
  final cV1 = _ror64(khronos, cV1raw);
  final orders = _hexDecode(
    '050701020400060300050204010307060507020401060300030002040607010504050003060201070000000000000000',
  );
  final order1 = orders.sublist(ivV0 * 8, ivV0 * 8 + 8);
  final ivV1b = _u32(ivV1 + khronos + 1) & 63;
  const tt1b = [
    0x87aeea5dab37cd6b,
    0x7ff48becb4f54087,
    0xb0724c06706bbd5d,
    0x1fe5dfb1143e328d,
    0x1a2331d00af4f1f2,
    0xcaff7131bb1e71ba,
    0x33385e1042752218,
    0xff01ed65d4a441fb,
    0xadb1ec8828c80e8,
    0x62475d12f4e06fe7,
    0xbd0b238da4fe72,
  ];
  final tt2 = List<int>.generate(11, (i) => _ror64(tt1b[i], ivV1b));
  final toSign = <int>[];
  toSign.addAll(querySm3);
  toSign.addAll(bodyMd5Bytes);
  toSign.addAll(tsBytes);
  toSign.addAll([0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  final src = <int>[];
  for (var i = 0; i < toSign.length ~/ 8; i++) {
    var v = 0;
    for (var j = 0; j < 8; j++) {
      v = (v << 8) | toSign[i * 8 + j];
    }
    src.add(v);
  }
  final srcXor = List<int>.filled(8, cV1);
  final tableF = _sixGodBranch1TableF(ivV0, branchOne);
  var swap = _sixGodSwapV0(src, srcXor, tt2, tableF, order1, null);
  final data = [0, 0, 0, 0, 0, 0, 0, 416];
  final srcXor2 = [
    swap[4],
    swap[3],
    swap[2],
    swap[1],
    swap[0],
    swap[7],
    swap[6],
    swap[5],
  ];
  swap = _sixGodSwapV0(data, srcXor2, tt2, tableF, order1, swap);
  final ret = <int>[];
  for (var i = 7; i >= 0; i--) {
    final vv = swap[i];
    final pp = List<int>.generate(8, (j) => (vv >>> (j * 8)) & 255);
    ret.addAll([pp[1], pp[3], pp[5], pp[6]]);
  }
  for (var i = 0; i < 16; i++) {
    ret[i] ^= ret[i + 16];
  }
  final trimmed = ret.sublist(0, 16);
  final s = _sixGodSumMd5(trimmed);
  trimmed.addAll(_u32le(s));
  return trimmed;
}

List<int> _sixGodBranch2(
  int iv,
  int khronos,
  List<int> querySm3,
  List<int> bodyMd5Bytes,
  List<int> tsBytes,
) {
  final ivV0 = ((iv & 15) * 171) >> 9;
  const t001 = [0x8980f29b, 0xeb549c7f, 0xb08726db, 0xd40cb5e6, 0xe8f559e4];
  final n1 = t001[ivV0];
  final countV1 = _u32(n1 + khronos + 1) & 255;
  final countV2 = _u32(n1 + khronos);
  final n0b = (countV2 + 5) & 7;
  final pad = <int>[];
  const seed = [0x84, 0x96, 0x77, 0x9d, 0xd4, 0x15, 0x0b, 0xf8];
  for (var i = 0; i < 8; i++) {
    var v = seed[i] | (seed[i] << 8);
    v = v >> n0b;
    pad.add(v & 255);
  }
  final data = <int>[];
  data.addAll(querySm3);
  data.addAll(bodyMd5Bytes);
  data.addAll(tsBytes);
  data.addAll(pad);
  data.addAll([0xa0, 0x01, 0, 0]);
  final idx = ivV0 * 64;
  return _sixGodMD5SumV3(
    data,
    countV2,
    sixGodB2Orders.sublist(idx, idx + 64),
    countV1,
  );
}

/// 公开仅供测试对照 Go 向量。
List<int> sixGodHashF13(
  List<int> querySm3,
  List<int> bodyMd5Bytes,
  List<int> tsBytes,
  int khronos,
  List<int> branchOne,
) {
  var iv = _sixGodGetIv(0x20230928, querySm3);
  iv = _sixGodGetIv(iv, bodyMd5Bytes);
  iv = _sixGodGetIv(iv, tsBytes);
  final ivV0 = ((iv & 15) * 171) >> 9;
  final branch = (iv & 15) - ((ivV0 * 3) & 255);
  switch (branch) {
    case 0:
      return _sixGodBranch0(ivV0, khronos, querySm3, bodyMd5Bytes, tsBytes);
    case 1:
      return _sixGodBranch1(
        ivV0,
        khronos,
        querySm3,
        bodyMd5Bytes,
        tsBytes,
        branchOne,
      );
    case 2:
      return _sixGodBranch2(iv, khronos, querySm3, bodyMd5Bytes, tsBytes);
    default:
      throw StateError('sixgod: unknown branch');
  }
}

String sixGodHelios(int khronos, int randValue) {
  var value = randValue;
  if (value == 0) {
    final bytes = List<int>.generate(4, (_) => Random.secure().nextInt(256));
    value = _u32leAt(bytes, 0);
    if (value == 0) value = 0x9e3779b9;
  }
  final seed = [..._u32le(value), ...utf8.encode('8662')];
  final digest = _md5(seed);
  final keys = _hexLower(digest);
  final keyBytes = utf8.encode(keys);
  int le64(List<int> b, int o) => _u64leAt(b, o);
  final table = [le64(keyBytes, 0)];
  var words = [
    le64(keyBytes, 0),
    le64(keyBytes, 8),
    le64(keyBytes, 16),
    le64(keyBytes, 24),
  ];
  var first = words[0];
  var second = words[1];
  words = words.sublist(2);
  for (var idx = 0; idx < 0x22; idx++) {
    var v2 = _ror64(second, 8);
    v2 = v2 + first;
    v2 = v2 ^ idx;
    words.add(v2);
    v2 = v2 ^ _ror64(first, 61);
    table.add(v2);
    first = v2;
    second = words[0];
    words = words.sublist(1);
  }
  final raw = utf8.encode('$khronos-1588093228-8662');
  final pad = 16 - (raw.length % 16);
  final padded = [...raw, for (var i = 0; i < pad; i++) pad];
  final output = <int>[];
  for (var off = 0; off < padded.length; off += 16) {
    var left = le64(padded, off);
    var right = le64(padded, off + 8);
    for (var idx = 0; idx < 0x22; idx++) {
      final newRight = table[idx] ^ (left + _ror64(right, 8));
      final newLeft = newRight ^ _ror64(left, 61);
      left = newLeft;
      right = newRight;
    }
    output.addAll(_u32le(left & 0xFFFFFFFF));
    output.addAll(_u32le((left >>> 32) & 0xFFFFFFFF));
    output.addAll(_u32le(right & 0xFFFFFFFF));
    output.addAll(_u32le((right >>> 32) & 0xFFFFFFFF));
  }
  return base64Encode([..._u32le(value), ...output]);
}

List<List<int>> _sixGodBytes2Matrix(List<int> text) {
  final out = <List<int>>[];
  for (var i = 0; i < text.length; i += 4) {
    final end = i + 4 > text.length ? text.length : i + 4;
    out.add(text.sublist(i, end));
  }
  return out;
}

int _reverse8(int x) {
  var v = x & 0xFF;
  var r = 0;
  for (var i = 0; i < 8; i++) {
    r = (r << 1) | (v & 1);
    v >>= 1;
  }
  return r;
}

int _sixGodXtime(int a) {
  if (a & 128 != 0) {
    return (((a << 1) ^ 0x1b) & 255);
  }
  return (a << 1) & 255;
}

List<List<int>> _sixGodAddRoundKey(
  List<List<int>> s,
  List<List<int>> k,
) {
  final out = [for (final row in s) List<int>.from(row)];
  for (var i = 0; i < 4; i++) {
    for (var j = 0; j < 4; j++) {
      out[i][j] ^= k[i][j];
    }
  }
  return out;
}

List<List<int>> _sixGodAddRoundKeyCon(
  List<List<int>> s,
  List<List<int>> k,
  List<int> con,
) {
  final out = [for (final row in s) List<int>.from(row)];
  for (var i = 0; i < 4; i++) {
    for (var j = 0; j < 4; j++) {
      out[i][j] ^= k[i][con[j]];
    }
  }
  return out;
}

void _sixGodMixSingleColumn(List<List<int>> s, int col) {
  final t = s[0][col] ^ s[1][col] ^ s[2][col] ^ s[3][col];
  final u = s[0][col];
  s[0][col] ^= t ^ _sixGodXtime(s[0][col] ^ s[1][col]);
  s[1][col] ^= t ^ _sixGodXtime(s[1][col] ^ s[2][col]);
  s[2][col] ^= t ^ _sixGodXtime(s[2][col] ^ s[3][col]);
  s[3][col] ^= t ^ _sixGodXtime(s[3][col] ^ u);
}

List<List<int>> _sixGodMatrixMixColumns(List<List<int>> s) {
  final out = [for (final row in s) List<int>.from(row)];
  for (var col = 0; col < 4; col++) {
    _sixGodMixSingleColumn(out, col);
  }
  return out;
}

class _SixGodAESV3 {
  _SixGodAESV3(List<int> aesKey, int khronos, List<int> sBoxFull) {
    wordSize = khronos & 3;
    sBox = sBoxFull.sublist(wordSize * 256, wordSize * 256 + 256);
    const rCon = [
      [1, 0, 2, 3],
      [1, 3, 0, 2],
      [0, 1, 3, 2],
      [1, 0, 2, 3],
    ];
    const rCon2 = [
      [1, 0, 2, 3],
      [2, 0, 3, 1],
      [0, 1, 3, 2],
      [1, 0, 2, 3],
    ];
    const rOrders = [
      [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
      [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
      [0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15],
      [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
    ];
    con = rCon[wordSize];
    con2 = rCon2[wordSize];
    order = rOrders[wordSize];
    masterKey = _expandKey(aesKey);
    keyMatrices = _sixGodBytes2Matrix(masterKey);
  }

  late final int wordSize;
  late final List<int> sBox;
  late final List<int> con;
  late final List<int> con2;
  late final List<int> order;
  late final List<int> masterKey;
  late final List<List<int>> keyMatrices;

  List<int> _expandKey(List<int> aesKey) {
    const initValues = [0xca025ddc, 0x823dc546, 0xc9420583, 0xc298225f];
    final initValue = initValues[wordSize];
    final mk = <int>[];
    for (var i = 0; i < 4; i++) {
      mk.addAll(_u32le(initValue));
    }
    for (var i = 0; i < mk.length; i++) {
      mk[i] ^= aesKey[i];
    }
    for (var i = 0; i < 32; i++) {
      mk.add(0);
    }
    var rounds = 8;
    for (var i = 4; i < 12; i++) {
      final idx = 4 * (i - 1);
      var k0 = mk[idx];
      var k1 = mk[idx + 1];
      var k2 = mk[idx + 2];
      var k3 = mk[idx + 3];
      if (i & 3 == 0) {
        final signed = initValue >= 0x80000000
            ? initValue - 0x100000000
            : initValue;
        final k00 = (signed >> (rounds & 24)) ^ sBox[k1];
        k1 = sBox[k2];
        k2 = sBox[k3];
        k3 = sBox[k0];
        k0 = k00 & 255;
      }
      rounds += 2;
      mk[idx + 4] = k0 ^ mk[idx - 12];
      mk[idx + 5] = k1 ^ mk[idx - 11];
      mk[idx + 6] = k2 ^ mk[idx - 10];
      mk[idx + 7] = k3 ^ mk[idx - 9];
    }
    return mk;
  }

  List<int> _sumData(List<int> data) {
    var padded = data;
    if (padded.length < 248) {
      padded = [...data, for (var i = data.length; i < 248; i++) 0];
    }
    final key = List<int>.filled(32, 0);
    for (var i = 0; i < 31; i++) {
      final idx = i * 8;
      final n0 = (padded[idx] >> 4) & 2;
      final n1 = n0 | (padded[idx + 1] & 64);
      final n2 = n1 | ((padded[idx + 2] >> 2) & 1);
      final n3 = n2 | ((padded[idx + 3] << 3) & -128);
      final n4 = n3 | ((padded[idx + 4] >> 1) & 4);
      final n5 = n4 | ((padded[idx + 5] << 3) & 16);
      final n6 = n5 | ((padded[idx + 6] << 5) & 32);
      final n7 = n6 | ((padded[idx + 7] >> 4) & 8);
      key[i] = n7 & 255;
    }
    key[31] = 1;
    return key;
  }

  List<int> _mixColumnsData(List<int> data, List<int> key) {
    var out = List<int>.from(data);
    if (out.length < 248) {
      out = [...out, for (var i = out.length; i < 248; i++) 0];
    }
    for (var i = 0; i < 31; i++) {
      final kk = key[i];
      final idx = i * 8;
      out[idx] = ((out[idx] & -33) | (((kk << 4) & 255) & 32)) & 255;
      out[idx + 1] = ((out[idx + 1] & -65) | (kk & 64)) & 255;
      out[idx + 2] = ((out[idx + 2] & -5) | ((kk * 4) & 4)) & 255;
      out[idx + 3] = ((out[idx + 3] & -17) | ((kk >> 3) & 16)) & 255;
      out[idx + 4] = ((out[idx + 4] & -9) | ((kk + kk) & 8)) & 255;
      out[idx + 5] = ((out[idx + 5] & -3) | ((kk >> 3) & 2)) & 255;
      out[idx + 6] = ((out[idx + 6] & -2) | ((kk >> 5) & 1)) & 255;
      out[idx + 7] = ((out[idx + 7] & 127) | (((kk << 4) & 255) & -128)) & 255;
    }
    return out;
  }

  List<List<int>> _subBytes(List<List<int>> s) {
    final out = [for (final row in s) List<int>.from(row)];
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) {
        out[i][j] = sBox[out[i][j]];
      }
    }
    final rows = [for (final row in out) List<int>.from(row)];
    out[0] = rows[con2[0]];
    out[1] = rows[con2[1]];
    out[2] = rows[con2[2]];
    out[3] = rows[con2[3]];
    return out;
  }

  List<List<int>> _shiftRows(List<List<int>> s) {
    final bs = <int>[];
    for (final row in s) {
      bs.addAll(row);
    }
    final out = [for (final row in s) List<int>.from(row)];
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) {
        out[i][j] = bs[order[i * 4 + j]];
      }
    }
    return out;
  }

  List<List<int>> _shiftRowsCon(List<List<int>> s, List<int> c) {
    final out = [for (final row in s) List<int>.from(row)];
    for (var i = 0; i < 4; i++) {
      final row = List<int>.from(s[i]);
      out[i][0] = row[c[0]];
      out[i][1] = row[c[1]];
      out[i][2] = row[c[2]];
      out[i][3] = row[c[3]];
    }
    return out;
  }

  List<int> _encryptBlock(List<int> plaintext) {
    var state = <List<int>>[];
    for (var i = 0; i < 4; i++) {
      state.add(plaintext.sublist(i * 4, i * 4 + 4));
    }
    state = _sixGodAddRoundKeyCon(state, keyMatrices.sublist(0, 4), con2);
    for (var i = 1; i < 3; i++) {
      state = _subBytes(state);
      state = _shiftRows(state);
      if (i == 1) {
        state = _shiftRowsCon(state, con2);
        state = _sixGodMatrixMixColumns(state);
      }
      state = _sixGodAddRoundKeyCon(
        state,
        keyMatrices.sublist(i * 4),
        con2,
      );
    }
    state = _sixGodAddRoundKey(state, keyMatrices.sublist(4));
    final out = <int>[];
    for (final row in state) {
      out.addAll(row);
    }
    return out;
  }

  List<int> encrypt(List<int> data, List<int> iv) {
    final plaintext = _sumData(data);
    final key = <int>[];
    var previous = List<int>.from(iv);
    for (var i = 0; i < plaintext.length; i += 16) {
      final blk = plaintext.sublist(i, i + 16);
      final x = _xorBytes(blk, previous);
      final block = _encryptBlock(x);
      key.addAll(block);
      previous = block;
    }
    final mixed = _mixColumnsData(data, key);
    return [key[key.length - 1], ...mixed];
  }
}

List<int> _sixGodVarint(int v) {
  final out = <int>[];
  var value = v;
  while (value < 0 || value > 127) {
    out.add((value & 127) | 128);
    value >>>= 7;
  }
  out.add(value);
  return out;
}

int _sixGodSint(int v) => (v << 1) ^ (v >> 63);

List<int> _sixGodPackFloat32(double v) {
  if (v == 0) return [0, 0, 0, 0];
  final bytes = ByteData(4);
  bytes.setFloat32(0, v, Endian.little);
  return bytes.buffer.asUint8List();
}

class _SixGodProtoBuilder {
  final out = <int>[];

  void sint(int field, int value) {
    if (value == 0) return;
    out.addAll(_sixGodVarint(field << 3));
    out.addAll(_sixGodVarint(_sixGodSint(value)));
  }

  void float(int field, double value) {
    if (value == 0) return;
    out.addAll(_sixGodVarint(field << 3 | 5));
    out.addAll(_sixGodPackFloat32(value));
  }

  void bytes(int field, List<int> value) {
    if (value.isEmpty) return;
    out.addAll(_sixGodVarint(field << 3 | 2));
    out.addAll(_sixGodVarint(value.length));
    out.addAll(value);
  }

  void str(int field, String value) {
    if (value.isEmpty) return;
    bytes(field, utf8.encode(value));
  }

  void msg(int field, List<int> value) {
    bytes(field, value);
  }
}

List<int> _sixGodXmxorTwo(List<int> data, List<int> key) {
  final encoded = List<int>.filled(data.length, 0);
  for (var i = 0; i < data.length; i++) {
    final position = (i * 4) & 28;
    final d0 = key[position];
    final d1 = key[position + 1];
    var d2 = (_rl8(data[i], 4) + d0) ^ d1;
    d2 = _rl8((~d2) & 255, 3);
    d2 = ((d2 + d1) & 255) ^ d0;
    encoded[data.length - 1 - i] = (~d2) & 255;
  }
  return encoded;
}

List<int> _sixGodXmxor(List<int> data, List<int> key) {
  final value = _sixGodXmxorTwo(data, key);
  final last = value.length - 1;
  final lastFlag = value[last] ^ value[last - 1];
  final data0 = value[0];
  value[0] = (((~lastFlag) + value[0]) & 255);
  value[1] = (((value[0] ^ value[last] ^ 254) + value[1]) & 255);
  value[2] = ((value[2] + ((lastFlag - data0) ^ _rl8(value[1], 3) ^ 2)) & 255);
  for (var index = 0; index < value.length - 4; index++) {
    final temp = _rl8(value[index + 2], 3) ^ value[index + 1] ^ (index + 3);
    value[index + 3] = (((~temp) + value[index + 3]) & 255);
  }
  value[last] ^= value[last - 1];
  var sum = 0;
  for (var index = 1; index < value.length; index++) {
    sum += value[index];
  }
  value[0] = (((value[0] ^ value[1]) + sum) & 255);
  return value;
}

(List<int>, List<int>) _sixGodGetKeyHash(List<int> key, int randValue) {
  final toHash = List<int>.filled(68, 0);
  toHash.setRange(0, 32, key);
  toHash.setRange(32, 36, _u32le(randValue));
  toHash.setRange(36, 68, key);
  final d1 = (randValue >>> 16) & 255;
  var d2 = ((d1 << 11) | (randValue >>> 24));
  d2 = _u32(d2 ^ (d1 >> 5) ^ d1);
  d2 = _u32(~d2);
  final digest = hongguoSm3(toHash);
  return (digest, _u32le(d2));
}

String? _queryFirst(String query, String key) {
  for (final part in query.split('&')) {
    if (part.isEmpty) continue;
    final eq = part.indexOf('=');
    final name = eq < 0 ? part : part.substring(0, eq);
    if (Uri.decodeQueryComponent(name) == key) {
      if (eq < 0) return '';
      return Uri.decodeQueryComponent(part.substring(eq + 1));
    }
  }
  return null;
}

({List<int> proto, List<int> querySm3, List<int> bodySm3}) _sixGodGenMedusaProto(
  String rawUrl,
  List<int> body,
  int khronos, {
  int protoRand = 0,
  int launchTime = 0,
  int processId = 0,
  int timeSec = 0,
}) {
  var query = '';
  final qIndex = rawUrl.indexOf('?');
  if (qIndex >= 0) {
    final rest = rawUrl.substring(qIndex + 1);
    final second = rest.indexOf('?');
    query = second >= 0 ? rest.substring(0, second) : rest;
  }
  String first(String key) => _queryFirst(query, key) ?? '';
  var bodyMd5Bytes = <int>[];
  if (body.isNotEmpty) {
    bodyMd5Bytes = _hexDecode(_hexLower(_md5(body)));
  }
  while (bodyMd5Bytes.length < 16) {
    bodyMd5Bytes.add(0);
  }
  final tsBytes = _u32le(khronos);
  final sm3 = hongguoSm3(utf8.encode(query));
  final querySm3 = List<int>.from(sm3);
  final bodyHashInput = <int>[];
  bodyHashInput.addAll(utf8.encode(query));
  bodyHashInput.addAll(bodyMd5Bytes);
  bodyHashInput.addAll(utf8.encode('none'));
  final bodyHash = hongguoSm3(bodyHashInput);
  final queryBodyHash = List<int>.from(bodyHash);

  var deviceId = first('device_id');
  if (deviceId.isEmpty) deviceId = first('did');
  var versionName = first('version_name');
  if (versionName.isEmpty) versionName = '7.1.3.32';
  final deviceModel = first('device_type');
  final brand = first('device_brand');
  final osVersion = first('os_version');
  var productDevice = first('device_manufacturer');
  if (productDevice.isEmpty) productDevice = brand;
  final random = Random.secure();
  var pr = protoRand;
  if (pr == 0) pr = _u32leAt(List<int>.generate(4, (_) => random.nextInt(256)), 0);
  var lt = launchTime;
  if (lt == 0) lt = 100 + _u32leAt(List<int>.generate(4, (_) => random.nextInt(256)), 0) % 21;
  var pid = processId;
  if (pid == 0) pid = 10001 + _u32leAt(List<int>.generate(4, (_) => random.nextInt(256)), 0) % 2000;
  const reportTs = 1728388016635;
  var reportTime = timeSec;
  if (reportTime == 0) reportTime = khronos;

  final device = _SixGodProtoBuilder();
  device.sint(1, 1);
  device.sint(2, 2);
  device.str(3, '8662');
  device.str(4, deviceId);
  device.str(5, '');
  device.str(6, '!noperm!');
  device.sint(7, -888888);
  device.sint(8, -888888);
  device.sint(9, 3);
  device.sint(10, -888888);
  device.str(11, '!notset!');
  device.str(12, 'Asia/Shanghai,8');
  device.str(13, 'zh_CN');
  device.sint(14, 4);
  device.float(16, 255.24993896484375);
  device.float(17, 35.58599090576172);
  device.float(18, 3.467449188232422);
  device.float(19, 3.467449188232422);
  device.float(20, 255.1754913330078);
  device.float(21, 42.17544174194336);
  device.str(22, osVersion);
  device.sint(23, 41);
  device.sint(24, 36);
  device.sint(25, reportTs);
  device.sint(26, reportTs);
  device.sint(27, reportTs);
  device.sint(28, reportTs + 2);
  device.sint(29, -1);
  device.str(30, deviceModel);
  device.str(31, brand);
  device.str(32, deviceModel);
  device.str(33, deviceModel);
  device.str(34, productDevice);
  device.str(35, brand);
  device.str(36, brand);
  device.sint(38, 31);

  final report = _SixGodProtoBuilder();
  report.sint(1, reportTime);
  report.sint(2, -2);
  report.sint(4, 200);
  report.sint(5, 0);
  report.sint(6, 0);

  final env = _SixGodProtoBuilder();
  env.sint(1, lt);
  env.sint(2, 146331399);
  env.sint(3, 146331396);
  env.sint(5, 7);
  env.str(6, 'v04.06.04.03-bugfix');
  env.sint(7, pid);
  env.msg(12, device.out);
  env.msg(13, report.out);
  env.str(14, versionName);

  final branchOne = sixGodBranchOne();
  final hash = sixGodHashF13(querySm3, bodyMd5Bytes, tsBytes, khronos, branchOne);
  final bodySm3 = hash;

  final request = _SixGodProtoBuilder();
  request.sint(1, 111);
  request.sint(2, 10);
  request.sint(3, 694367);
  request.sint(5, 586952199);

  final medusa = _SixGodProtoBuilder();
  medusa.bytes(1, _hexDecode('f7e85ffad7d7dc3bd62ac87057cf6118'));
  medusa.sint(2, 3);
  medusa.sint(3, pr);
  medusa.str(4, '8662');
  medusa.str(5, deviceId);
  medusa.str(6, '1588093228');
  medusa.str(7, versionName);
  medusa.str(8, 'v04.06.04-ml-android');
  medusa.sint(9, 67503104);
  medusa.bytes(10, [64, 1, 0, 0, 0, 0, 0, 0]);
  medusa.sint(12, khronos);
  medusa.bytes(13, hash);
  medusa.bytes(14, querySm3.sublist(0, 6));
  medusa.msg(15, request.out);
  medusa.str(16, '');
  medusa.sint(17, khronos);
  medusa.bytes(18, []);
  medusa.bytes(19, queryBodyHash);
  medusa.str(20, 'none');
  medusa.sint(21, 312);
  medusa.msg(23, env.out);
  medusa.str(
    24,
    '{"cmr":16777216,"cmr2":16777216,"un_h":1879194040,"vpn":0,"kd":0,"fkd":3672518972,"pd":-1872573247,"dyn":"","do":0,"tk":true}',
  );
  return (proto: medusa.out, querySm3: querySm3, bodySm3: bodySm3);
}

String sixGodGenMedusa(
  String rawUrl,
  List<int> body,
  int khronos, {
  int protoRand = 0,
  int launchTime = 0,
  int processId = 0,
  int hashRand = 0,
  int xmRand = 0,
  int timeSec = 0,
}) {
  final configKey = _hexDecode('f1593376766ea98d34f31b057a9d5be4');
  final configIv = _hexDecode('1fe109a4125283f418de9e051a969e12');
  final signKey = _hexDecode(
    '8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eaef71cb691f7aa8aa2f5',
  );
  final result = _sixGodGenMedusaProto(
    rawUrl,
    body,
    khronos,
    protoRand: protoRand,
    launchTime: launchTime,
    processId: processId,
    timeSec: timeSec,
  );
  final proto = result.proto;
  final querySm3 = result.querySm3;
  final random = Random.secure();
  var hr = hashRand;
  if (hr == 0) {
    hr = _u32leAt(List<int>.generate(4, (_) => random.nextInt(256)), 0);
  }
  var xr = xmRand;
  if (xr == 0) {
    xr = _u32leAt(List<int>.generate(4, (_) => random.nextInt(256)), 0);
  }
  final keyHash = _sixGodGetKeyHash(signKey, hr);
  final khKey = keyHash.$1;
  final khSeed = keyHash.$2;
  var mixed = _sixGodXmxor(proto, khKey);
  mixed = [64, 1, 0, 0, 0, 0, 0, 0, ...mixed];
  mixed = mixed.reversed.toList();
  for (var index = 0; index < mixed.length; index++) {
    mixed[index] ^= khSeed[(~index) & 3];
  }
  final hashBytes = _u32le(hr);
  final checkBit = _u32(
    ((querySm3[0] & 63) << 14) | 0x18000001 | ((result.bodySm3[0] & 63) << 8),
  );
  final out = <int>[0x35];
  out.addAll(_u32le(xr));
  out.addAll(_u32le(checkBit));
  out.addAll(mixed);
  out.addAll(hashBytes.sublist(2));
  final sBox = sixGodSBox();
  final aes = _SixGodAESV3(configKey, khronos, sBox);
  final encrypted = aes.encrypt(out, configIv);
  final version = _hexDecode('03000000f7e85ffad7d7dc3bd62ac87057cf6118');
  final versionOr = <int>[];
  for (var i = 0; i < 20; i += 4) {
    final v = _u32(_u32leAt(version, i) ^ khronos);
    versionOr.addAll(_u32le(v));
  }
  final finalBytes = <int>[];
  finalBytes.addAll(versionOr);
  finalBytes.addAll(hashBytes.sublist(0, 2));
  finalBytes.addAll([0, 1]);
  finalBytes.addAll(encrypted);
  return base64Encode(finalBytes);
}

/// 公开仅供测试对照 Go 向量。
String hongguoPlayerArgus(
  String query,
  List<int>? body,
  int timestamp,
  String deviceId,
  List<int> nonce,
) {
  final key = _hexDecode(
    'ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c',
  );
  final message = <int>[];
  void varint(int field, int value) {
    message.addAll(_sixGodVarint(field * 8));
    message.addAll(_sixGodVarint(value));
  }

  void bytesField(int field, List<int> value) {
    message.addAll(_sixGodVarint(field * 8 + 2));
    message.addAll(_sixGodVarint(value.length));
    message.addAll(value);
  }

  var bodyHash = hongguoSm3(List<int>.filled(16, 0));
  if (body != null) {
    final stub = _md5(body);
    bodyHash = hongguoSm3(stub);
  }
  final queryHash = hongguoSm3(utf8.encode(query));
  final counters = <int>[];
  void counterVarint(int field, int value) {
    counters.addAll(_sixGodVarint(field * 8));
    counters.addAll(_sixGodVarint(value));
  }

  counterVarint(1, 1);
  counterVarint(2, 1);
  counterVarint(3, 1);
  counterVarint(7, 3348294860);
  final environment = <int>[];
  void envBytes(int field, List<int> value) {
    environment.addAll(_sixGodVarint(field * 8 + 2));
    environment.addAll(_sixGodVarint(value.length));
    environment.addAll(value);
  }

  void envVarint(int field, int value) {
    environment.addAll(_sixGodVarint(field * 8));
    environment.addAll(_sixGodVarint(value));
  }

  envBytes(1, utf8.encode('25053RT47C'));
  envBytes(2, utf8.encode('16'));
  envBytes(3, utf8.encode('update_64'));
  envVarint(4, 2147483648);
  varint(1, 0x20200929 * 2);
  varint(2, 2);
  varint(3, _u32leAt(nonce, 6) & 0x7fffffff);
  bytesField(4, utf8.encode('8662'));
  bytesField(5, utf8.encode(deviceId));
  bytesField(6, utf8.encode('1611921764'));
  bytesField(7, utf8.encode('7.4.3.32'));
  bytesField(8, utf8.encode('v04.07.01-ml-android'));
  varint(9, 135135744);
  bytesField(10, List<int>.filled(8, 0));
  varint(11, 0);
  varint(12, timestamp * 2);
  bytesField(13, bodyHash.sublist(0, 6));
  bytesField(14, queryHash.sublist(0, 6));
  bytesField(15, counters);
  bytesField(16, []);
  bytesField(20, utf8.encode('none'));
  varint(21, 738);
  bytesField(23, environment);
  varint(25, 2);
  var data = _pkcs7Pad(message);
  final seed = <int>[];
  seed.addAll(key);
  seed.addAll([0x3c, 0xcc, 0x56, 0x7b]);
  seed.addAll(key);
  final derived = hongguoSm3(seed);
  final rounds = List<int>.filled(72, 0);
  for (var i = 0; i < 4; i++) {
    rounds[i] = _u64leAt(derived, i * 8);
  }
  for (var i = 4; i < rounds.length; i++) {
    var mixed = _rol64(rounds[i - 1], -3) ^ rounds[i - 3];
    mixed = mixed ^ _rol64(mixed, -1);
    rounds[i] =
        (~rounds[i - 4]) ^ mixed ^ ((0x3dc94c3a046d678b >> ((i - 4) % 62)) & 1) ^ 3;
  }
  for (var offset = 0; offset < data.length; offset += 16) {
    var left = _u64leAt(data, offset);
    var right = _u64leAt(data, offset + 8);
    for (final round in rounds) {
      final newLeft = right;
      final newRight =
          left ^ (_rol64(right, 1) & _rol64(right, 8)) ^ _rol64(right, 2) ^ round;
      left = newLeft;
      right = newRight;
    }
    data.setRange(offset, offset + 8, _u64le(left));
    data.setRange(offset + 8, offset + 16, _u64le(right));
  }
  const xor = [0xd0, 0x4f, 0xfd, 0xff, 0xd0, 0x4f, 0xfd, 0xff];
  for (var i = 0; i < data.length; i++) {
    data[i] ^= xor[i % 8];
  }
  data = [...xor, ...data];
  data = data.reversed.toList();
  var container = <int>[0xa6, 0xe7, 0x83, 0xee, 0x70, 0x01, 0x10, 0x09, 0x18];
  container.addAll(data);
  container = _pkcs7Pad([...container, 0x56, 0x7b]);
  final aesKey = _md5(key.sublist(0, 16));
  final iv = _md5(key.sublist(16));
  final encrypted = _cbcEncryptNoPad(container, aesKey, iv);
  return base64Encode([0x3c, 0xcc, ...encrypted]);
}

List<int> _u64le(int v) {
  final out = <int>[];
  for (var i = 0; i < 8; i++) {
    out.add((v >>> (i * 8)) & 0xFF);
  }
  return out;
}

/// 公开仅供测试对照 Go 向量。
String hongguoPlayerLadon(String aid, int timestamp, List<int> prefix) {
  final hash = _md5([...prefix, ...utf8.encode(aid)]);
  final digest = utf8.encode(_hexLower(hash));
  var left = _u64leAt(digest, 0);
  var right = _u64leAt(digest, 8);
  var queue = [_u64leAt(digest, 16), _u64leAt(digest, 24)];
  final keys = List<int>.filled(34, 0);
  for (var i = 0; i < keys.length; i++) {
    keys[i] = left;
    final mixed = (_rol64(right, -8) + left) ^ i;
    queue.add(mixed);
    left = mixed ^ _rol64(left, 3);
    right = queue.removeAt(0);
  }
  final payload = utf8.encode('$timestamp-1611921764-$aid');
  var data = _pkcs7Pad(payload);
  for (var offset = 0; offset < data.length; offset += 16) {
    var l = _u64leAt(data, offset);
    var r = _u64leAt(data, offset + 8);
    for (final k in keys) {
      r = k ^ (l + _rol64(r, -8));
      l = r ^ _rol64(l, 3);
    }
    data.setRange(offset, offset + 8, _u64le(l));
    data.setRange(offset + 8, offset + 16, _u64le(r));
  }
  return base64Encode([...prefix, ...data]);
}

Map<String, String> hongguoPlayerHeaders({
  required String url,
  List<int>? body,
  required DateTime now,
  List<int>? nonceOverride,
  int heliosRand = 0,
  String? rawQuery,
}) {
  rawQuery ??= Uri.parse(url).query;
  final stamp = now.millisecondsSinceEpoch ~/ 1000;
  final queryHash = _md5(utf8.encode(rawQuery));
  final payload = List<int>.filled(20, 0);
  payload.setRange(0, 4, queryHash.sublist(0, 4));
  String? stub;
  if (body != null) {
    final bodyHash = _md5(body);
    payload.setRange(4, 8, bodyHash.sublist(0, 4));
    stub = _hexUpper(bodyHash);
  }
  payload.setRange(12, 16, [0, 6, 11, 28]);
  payload.setRange(16, 20, _u32be(stamp));
  const keyBytes = [
    0x44, 0xb9, 0xb9, 0xd9, 0xa4, 0xae, 0xf9, 0xfc,
    0xa4, 0x93, 0xaa, 0x75, 0x7c, 0xa3, 0xc2, 0xc4,
    0xa4, 0x96, 0x93, 0x8f,
  ];
  for (var i = 0; i < payload.length; i++) {
    payload[i] ^= keyBytes[i];
  }
  for (var i = 0; i < payload.length; i++) {
    final mixed = _rl8(payload[i], 4) ^ payload[(i + 1) % payload.length];
    payload[i] = (_reverse8(mixed) ^ 0xff ^ payload.length) & 255;
  }
  final signature = [0x84, 0x04, 0x40, 0x1c, 0, 0, ...payload];
  final headers = <String, String>{
    'X-Khronos': stamp.toString(),
    'X-Gorgon': _hexLower(signature),
    'X-SS-Req-Ticket': now.millisecondsSinceEpoch.toString(),
  };
  if (stub != null) headers['X-SS-STUB'] = stub;
  final random = Random.secure();
  final nonce = nonceOverride ??
      List<int>.generate(11, (_) => random.nextInt(256));
  final deviceId = _queryFirst(rawQuery, 'device_id') ?? '';
  final aid = _queryFirst(rawQuery, 'aid') ?? '';
  headers['X-Argus'] = hongguoPlayerArgus(
    rawQuery,
    body,
    stamp,
    deviceId,
    nonce,
  );
  headers['X-Ladon'] = hongguoPlayerLadon(aid, stamp, nonce.sublist(2, 6));
  headers['X-Helios'] = sixGodHelios(stamp, heliosRand);
  try {
    headers['X-Medusa'] = sixGodGenMedusa(url, body ?? [], stamp);
  } catch (_) {
    // Go sets X-Medusa only when generation succeeds.
  }
  return headers;
}
