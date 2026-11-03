import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/aes_cipher.dart';

List<int> _hex(String text) {
  final out = <int>[];
  for (var i = 0; i < text.length; i += 2) {
    out.add(int.parse(text.substring(i, i + 2), radix: 16));
  }
  return out;
}

String _hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('AES-128 NIST vector encrypt and decrypt', () {
    final key = _hex('000102030405060708090a0b0c0d0e0f');
    final plain = _hex('00112233445566778899aabbccddeeff');
    final cipher = _hex('69c4e0d86a7b0430d8cdb78070b4c55a');
    expect(_hexOf(aesEncryptBlock(plain, key)), _hexOf(cipher));
    expect(_hexOf(aesDecryptBlock(cipher, key)), _hexOf(plain));
  });

  test('AES-256 NIST vector decrypt', () {
    final key = _hex(
      '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
    );
    final cipher = _hex('8ea2b7ca516745bfeafc49904b496089');
    expect(
      _hexOf(
        aesDecryptBlock(cipher, key),
      ),
      '00112233445566778899aabbccddeeff',
    );
  });

  test('AES CBC roundtrip', () {
    final key = _hex('2b7e151628aed2a6abf7158809cf4f3c');
    final iv = _hex('000102030405060708090a0b0c0d0e0f');
    final plain = utf8.encode('hello aes cbc world');
    final encrypted = aesCbcEncrypt(plain, key, iv);
    expect(utf8.decode(aesCbcDecrypt(encrypted, key, iv)), 'hello aes cbc world');
  });

  test('Niuguo ECB fixture decrypts with request URI key', () {
    const encoded =
        'd/I5TwIMGn7d1tvbqM7QrLYiBgMkVJQl3Uj3tUEF9dkHfgvV/ZfFVuE/NLhAd/b1XsugnbdQT62TYZ1g2mFMxuXPF1lzAJpoY95A/6hdqSeGpHDrqLnWElFVu7L6e5whh5MKc7AGE7zcLb2WbQS9aXRaTXhzKkNU9JN7lBcmMqmnmeht+inJDlIATllbfw7BY65kYjTkgADlFRZPiRMFBT5h6Zs3DwxyACR2a+KtU8w=';
    final key = List<int>.filled(16, 0);
    final uri = utf8.encode('/list?class=&ord');
    key.setRange(0, uri.length, uri);
    final decoded = utf8.decode(aesEcbDecrypt(base64Decode(encoded), key));
    expect(decoded.contains('牛果样本'), isTrue);
    expect(decoded.contains('575258'), isTrue);
  });
}
