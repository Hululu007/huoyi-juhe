import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/hongguo_sign.dart';
import 'package:fqapp/services/hongguo_tables.dart';

String _hex(List<int> bytes) {
  const chars = '0123456789abcdef';
  final out = StringBuffer();
  for (final b in bytes) {
    out.write(chars[(b >> 4) & 15]);
    out.write(chars[b & 15]);
  }
  return out.toString();
}

void main() {
  test('SM3 标准向量', () {
    expect(
      _hex(hongguoSm3(utf8.encode('abc'))),
      '66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0',
    );
    expect(
      _hex(hongguoSm3([])),
      '1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b',
    );
  });

  test('分支哈希 Go 向量（分支1与分支2）', () {
    List<int> hexDecode(String hex) {
      final out = <int>[];
      for (var i = 0; i < hex.length; i += 2) {
        out.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
      return out;
    }

    String hashFor(int kh) {
      final url =
          'https://api5-normal-sinfonlineb.fqnovel.com/reading/distribution/category/landpage/v/?_rticket=${kh}001&aid=8662&app_name=novelread&device_brand=Redmi&device_id=1234567890123456789&device_type=25053RT47C&iid=1234567890123456789&language=zh&os_version=16&version_code=73532&version_name=7.3.5.32';
      final query = url.split('?')[1];
      final querySm3 = hongguoSm3(utf8.encode(query));
      final bodyMd5 = hexDecode(md5.convert(utf8.encode('{"limit":20,"offset":0}')).toString());
      final tsBytes = <int>[
        kh & 255,
        (kh >> 8) & 255,
        (kh >> 16) & 255,
        (kh >> 24) & 255,
      ];
      return _hex(sixGodHashF13(querySm3, bodyMd5, tsBytes, kh, sixGodBranchOne()));
    }

    expect(hashFor(1760000002), '463e838e4244720766c3d6cedd93be4c56c2bcbb');
    expect(hashFor(1760000007), '1cb324d55650896704ce21fd681b3c812da5d02f');
  });

  test('Helios Go 黄金向量', () {
    expect(
      sixGodHelios(1760000000, 987654321),
      'sWjeOkjuCYGdqczEDPI6lyB6Tfhn/hzAr94ykTCXjznrDEmc',
    );
  });

  test('Medusa Go 黄金向量', () {
    const rawUrl =
        'https://api.hongguo.com/test/play/?_rticket=1760000000000&aid=8662&app_name=novelread&device_brand=Redmi&device_id=1234567890&device_type=25053RT47C&iid=abcdef&os_version=16&version_code=73532&version_name=7.3.5.32';
    final body = utf8.encode('{"mixed_video_id_map":{"1004":["1234567890"]}}');
    expect(
      sixGodGenMedusa(
        rawUrl,
        body,
        1760000000,
        protoRand: 111111111,
        launchTime: 110,
        processId: 10500,
        hashRand: 222222222,
        xmRand: 333333333,
        timeSec: 1760000000,
      ),
      'A3jnaPeQuJLXrztT1lIvGFe3hnCO1wAB4TUVQ84TAVQNGEjlal+MImbeu/RP2GQOasynKMOlViQckEZ5jG+No1ZJf4iins14ScJPALtKS6GMLrlqNmTjStfqzaxURosyYv1dr+1uViO+oxLI0wqBXvc2aFz/s5JWie8FjNExBmzFFGAMlg+eVhO43p8fnMJ/O4CsMhdhSFpTd/V1U7m4wu0QyRRDpO+wRggt5KF5fRy6HGwY0BGPXWCK2INJjNXp/PY9aBmJKsTTSK/vMoKlaOIM6KWnAU3OJLpW/2+VsoWgPX7Tp2gtx9SjNhG9YMOff6yLxVP6X2k3TTyzfrdaeiHZz2aYGwxjnwHckzaRFdztfsN3a0VKrakZWEe7v+IIVkd2pIbXyY2Ih6Eb8lAh2L/wCtAAiQfCyjUE89EU5HR8fF35hwCnC8ZKu+JqCuHnncTE5gHRwrACguLaOemj6HmCf1cXGgfBWiwRzaVlaUAb2ZzLNRvdcmr6Xd7FCFmd6gaYlXGHWkMPh9Isq2QAFwrryH1XFy+2Z7zgi+EOPWh+Zr/G7EKexJPZFxwEdYutVTAedU5AaIUzc/LJ56ECrdY87fYdTzcaQ+4t05aUQq5aur4YoAPxqCrLEJx7uKUEbX2NVISerbNdCVcBcrBmy6/fIzyY8QxoordO9z4dOCzgcTb+Fl/KcZxfExVUmA4qqQk9apQd+NbfnGzCthhmunVgNjsToxQgmHZxuFMfcO2/ApU6SaQ1vn8bDv9hDjrra9bvjZ6leMXxcNcYsZMPECjwrUnKiuX7xg7nnLlSTYlHCP9PxMAkWH+oSDY/Yjdk9ZA7vZzVqVl1EZTcEMpw6EzJKMopzEfV5QMlUELz/tp2NomESJRRd8Nf2hGvxgkq7KqQ1t+hSb0Pzf/+D83+vj4N',
    );
  });

  test('Medusa 三分支黄金向量', () {
    String urlFor(int kh) =>
        'https://api5-normal-sinfonlineb.fqnovel.com/reading/distribution/category/landpage/v/?_rticket=${kh}001&aid=8662&app_name=novelread&device_brand=Redmi&device_id=1234567890123456789&device_type=25053RT47C&iid=1234567890123456789&language=zh&os_version=16&version_code=73532&version_name=7.3.5.32';
    final body = utf8.encode('{"limit":20,"offset":0}');
    String medusaFor(int kh) => sixGodGenMedusa(
      urlFor(kh),
      body,
      kh,
      protoRand: 111111111,
      launchTime: 110,
      processId: 10500,
      hashRand: 222222222,
      xmRand: 333333333,
      timeSec: kh,
    );
    expect(
      medusaFor(1760000000),
      'A3jnaPeQuJLXrztT1lIvGFe3hnCO1wABbDUVR94bA7SKGLYbFHg5xfbKRI1dr2em0FA3/mfAHT1v5AfPCrebdMAxbMQ0ZI4PK00ydKWck4gJ+HMMvqfBD2/ITxUBarq/2j1miYkSpvqOzHdRlZmUHNquUJ5YoqS6FvjOoeKJT2Nivp+nRKKbctXkTSebAOV3X9QO49lKSQTvimcxpoEyOyuM8QQHdCXOj4OlIB5qkSnS4z3x77kYMwD5ZNHeIufwjE2SR/NQt4ua+v0YZYXhOO6PGY/4lJI6Hs2hKctVovXTr1zY+3D0L5ehKLYCBQONppsvJT4aPY7rFhwV+hp0qlkAkS3ikIZR15aB6eu85cLg7uNX9KvVAERQdBCSXlYDbBwyhXv57vioxJ++DDsbNKdwpGDPGCyOYLG0HFJNXFI7oIUXMl6fJMZ49zBtlz8MU4jgekxHNADNWc4ELpxS2lJPITU4NM/SDRyQVhMNlUZmqkSfn+FdxdVdYAl3tUL5pRcd0PlTaLogPmAY9D6eV5jdo04GcFPyv9ZWoVSgfmEY496DKIlvAzEDjJinSRNGH+wzdg+zZM6WjRj6AM9v4C6ewNfJUjC9CXS0ls8FmIlkO60BckkxiIcjsUpsfUTv0iqnWV3GlJ3749lpIwWbX2fY6RmAlkjj53+BSQeBxnyx4HUWCbYQ8BKYatU5aKZbDkrMyiv7AJcGRsjmTpRmoSkN0sOlsikbiMqBXm5wkqw7jfNdF6eHvtr+IQmlT+9r6qChE46zPVMaIWGy42MotTI7Xy2hwOUKePsJV5QFxAQyO9pqLs8e6QhsMlIWV/g6WoSUa0rp7hQ13cKeiVah6Wj4oJiTlCqQt80UvgGnq6UVJQ+g3e6q153BN73M//CU+ZYhblk2Xa82Cg2MtevHFlJVhBR+s0DlfyD//g/N//4OjT4N',
    );
    expect(
      medusaFor(1760000002),
      'AXjnaPWQuJLVrztT1FIvGFW3hnCO1wAB4RUVR94TA0eIOGvCH3MUhFejKSulPiHtzn24++AL+izK2dROhcrvRRXrd3a02rkQjmH2aOG2DFJYJCIyfo+A5X86CRc33X8QaPui0YcqZ/39cWocrA0tpYqDyEN+vjhaZ9MGEve076S2XiwaHOvZJ7k2P2BTjxNd2tJlvETbQt0u/R6vuutkdwA3pioBbElP9Aa6ex96jsjcr5gDEle5GLgFq0OTXoOXmWz1e80Z1zZfaEghE0MrKCbZDC6tC90vrVY83PsdzMo4IKKrpRZx5y5rXLiHWBbH0C3FxId2IwKjwCLUmlQmdgGW3d9BM7hXuf+oTwf5+e2LWv0rLYnt51PHu9kVK3634SRm3/2XH5mS9nSTiEwket5xhWioK1w+Fao7FZNclW2LXBL3ojosXZjD+BNzSNveWYrODRmcNyHLdrEAK7A+RZqglpegngLaHowFam8CEV06VY/2L81MsRnPsB1nKbbiyWFShA4g7j/2C5+aIRas7ltaUkjHYBLoLlTN+w3A2iSOigNSfXR7NpRhPP9M7dn08GFOIKCUjnxdYbBLNTG3LBAjLw2A0g/E49wXI8H+NXFAcsNLPnGkbDPiQx58wZHl1xhLTBGvI1kqIRyJ2TKInlxA1liZnRlivCpefEP2OXwkTKc0xi7rt0+pBqlGp8dtkKxVKLWx7C7n0k2m8SlUu4v265c+QicbiMqBXm5wkqw7jfNdF6eHvtr+IQmlT+9r6qChE46zPVMaIWGy42MotTI7Xy2hwOUKePsJV5QFxAQyO9pqLs8e6QhsMlIWV/g6WoSUa0rp7hQ13cKeiVah6Wj4oJiTlCqQt80UvgGnq6UVJQ+g3e6q153BN73M//CU+ZYhblk2Xa82Cg2MtevHFlJVhBR+s0Dlf6n//g/N//4OjT4N',
    );
    expect(
      medusaFor(1760000007),
      'BHjnaPCQuJLQrztT0VIvGFC3hnCO1wABvjUVQ94bA90KGE7jVLpdsTfR227JoNldi8R2YoILZth3xO5mHnrzZRaz9/gQhf39L3+n7iYCoGsjlurucA+23fwbDD59uKhYH6nOZi4Cw+jr9EmauS9NQANg3IZkJ65Awf+NvGWO6E9sxtMNTYCTFe6/n55UDTTn7N6zcIE9qnEpaI+zymjOozjXSgRaJzIoIGD38s1t3VTj9q6O2k4QfXSjQ4IlIFJKrJEUE+/gPjZmpfSdcrAFSpNerAXMpEqfK5EkwenaiAnZpbZKYtc79du4c8wcobeF/1A4QgwoTgMSagFDZ8z/wZ8o1k3syBIEQeooMkyyJNeBFR1tf92dKP11hHJx49Sqo8vH/12y1uzguqTRahmoSyvh1HIPLM21xquC21rISHcuZ6g5bp51M1DTQOZkJaN6RMajOo0JB9cMAlMjkExSKtXDwIZGuJnkdvF2+pwNHhoTXSSjHvFe7ZV38e8xaZpD2Lb9turRTRFgiR0Ad8q8skk2T9xugbQ+fmxcb1gehwhaSMECQUUuTQDQRaWX3ad3OrSaU8+ezXi8agmdKj/yHE7hW2x/TgpAwEHEOKrM/WWYuF0FIs9VKa7F4eJ5rfEyiTuEUyArFGS05sjuDuVpaAy4QfwXDSMjvOUgzpj2zNPK7gzXfFzSjI/QjbIhi4GDLTtkHAU48FEADJTO+0EdqdDaJ9XoqiobiMqBXm5wkqw7jfNdF6eHvtr+IQmlT+9r6qChE46zPVMaIWGy42MotTI7Xy2hwOUKePsJV5QFxAQyO9pqLs8e6QhsMlIWV/g6WoSUa0rp7hQ13cKeiVah6Wj4oJiTlCqQt80UvgGnq6UVJQ+g3e6q153BN73M//CU+ZYhblk2Xa82Cg2MtevHFlJVhBR+s0Dlf9P//g/N//4OjT4N',
    );
  });

  test('播放请求头确定性字段与 Argus/Ladon 向量', () {
    const url =
        'https://api5-normal-sinfonlineb.fqnovel.com/reading/distribution/category/landpage/v/?_rticket=1760000000000&aid=8662&app_name=novelread&device_brand=Redmi&device_id=1234567890123456789&device_type=25053RT47C&iid=1234567890123456789&language=zh&os_version=16&version_code=73532&version_name=7.3.5.32';
    final body = utf8.encode('{"limit":20,"offset":0}');
    final headers = hongguoPlayerHeaders(
      url: url,
      body: body,
      now: DateTime.fromMillisecondsSinceEpoch(1760000000000, isUtc: true),
    );
    expect(headers['X-Gorgon'], '8404401c0000c3fac915646fceab7022103fad22c96956d46737');
    expect(headers['X-Khronos'], '1760000000');
    expect(headers['X-SS-Req-Ticket'], '1760000000000');
    expect(headers['X-SS-STUB'], '76721596FCF213D0422C7F7FACD736F7');
    const query =
        '_rticket=1760000000000&aid=8662&app_name=novelread&device_brand=Redmi&device_id=1234567890123456789&device_type=25053RT47C&iid=1234567890123456789&language=zh&os_version=16&version_code=73532&version_name=7.3.5.32';
    expect(
      hongguoPlayerArgus(
        query,
        body,
        1760000000,
        '1234567890123456789',
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
      ),
      'PMxCQ5CfVq57oVFlznr1liDYRuaknW4PshepsYVTvZhv7BqsDVFIbfuh9NFfZ2FdTnNaWJmu4K5sHRQz/OvIq72irHkPC9LqKSWliWEl1nJYR+wF8TfWj70YjVqb+dHLBRcMcr4FYLOGid058j7e8uBKQwnjHXGN2VXflEtQH1QnFBESJU2bvqgHnduP5vQlS62ixOTCYJd+Gcix+LpbYKzCHlN6fuIBvE5lhyI22Xob8ATBMa93qd+40RWK+qu5xknySlBMO2Wr3l0dFILzFaLgwOtXsU1h/LB+9EHRufT6qw==',
    );
    expect(
      hongguoPlayerLadon('8662', 1760000000, [3, 4, 5, 6]),
      'AwQFBlRM+xZDXtNDpKFV6DraIyNhGBJewU7P4YM5/HQTETVT',
    );
  });
}
