import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/m3u_export_download.dart';

void main() {
  late HttpServer server;
  late String base;
  late Directory tempRoot;
  final seenHeaders = <String, String>{};

  setUpAll(() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      seenHeaders[request.uri.path] =
          request.headers.value('x-test') ?? '';
      final path = request.uri.path;
      if (path == '/video.mp4') {
        request.response.add([0, 1, 2, 3]);
      } else if (path == '/play.m3u8') {
        request.response.write('''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00000000000000000000000000000001
#EXTINF:10.0,
seg0.ts
#EXTINF:10.0,
seg1.ts
#EXT-X-ENDLIST
''');
      } else if (path == '/seg0.ts') {
        request.response.add([10, 11]);
      } else if (path == '/seg1.ts') {
        request.response.add([12, 13]);
      } else if (path == '/key.bin') {
        request.response.add(List<int>.filled(16, 7));
      } else if (path == '/master.m3u8') {
        request.response.write('''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1000
v1.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000
v2.m3u8
''');
      } else if (path == '/v1.m3u8') {
        request.response.write('''
#EXTM3U
#EXTINF:10.0,
only.ts
#EXT-X-ENDLIST
''');
      } else if (path == '/only.ts') {
        request.response.add([20]);
      } else if (path == '/sample.m3u8') {
        request.response.write('''
#EXTM3U
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.bin"
#EXTINF:10.0,
seg0.ts
''');
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('m3u_dl_');
  });

  tearDown(() async {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  VideoDownloader downloader() => HttpVideoDownloader();

  test('直链文件原样下载，请求头带上', () async {
    final target = Directory('${tempRoot.path}/v1');
    final path = await downloader().downloadVideo(
      url: '$base/video.mp4',
      headers: const {'x-test': 'yes'},
      targetDir: target,
    );
    expect(path.endsWith('video.mp4'), isTrue);
    expect(File(path).readAsBytesSync(), [0, 1, 2, 3]);
    expect(seenHeaders['/video.mp4'], 'yes');
  });

  test('m3u8 分片与 AES 密钥都落本地，清单位址改写成本地文件名', () async {
    final target = Directory('${tempRoot.path}/v1');
    final path = await downloader().downloadVideo(
      url: '$base/play.m3u8',
      headers: const {},
      targetDir: target,
    );
    expect(path.endsWith('index.m3u8'), isTrue);
    final playlist = File(path).readAsStringSync();
    expect(playlist, contains('seg_00000.ts'));
    expect(playlist, contains('seg_00001.ts'));
    expect(playlist, contains('key_0.key'));
    expect(playlist, isNot(contains('seg0.ts')));
    expect(playlist, isNot(contains('key.bin')));
    expect(File('${target.path}/seg_00000.ts').readAsBytesSync(), [10, 11]);
    expect(File('${target.path}/seg_00001.ts').readAsBytesSync(), [12, 13]);
    expect(
      File('${target.path}/key_0.key').readAsBytesSync(),
      List<int>.filled(16, 7),
    );
  });

  test('主播单跟首个清晰度', () async {
    final target = Directory('${tempRoot.path}/v1');
    final path = await downloader().downloadVideo(
      url: '$base/master.m3u8',
      headers: const {},
      targetDir: target,
    );
    final playlist = File(path).readAsStringSync();
    expect(playlist, contains('seg_00000.ts'));
    expect(File('${target.path}/seg_00000.ts').readAsBytesSync(), [20]);
  });

  test('SAMPLE-AES 离线播不了，算失败且清掉半截目录', () async {
    final target = Directory('${tempRoot.path}/v1');
    await expectLater(
      downloader().downloadVideo(
        url: '$base/sample.m3u8',
        headers: const {},
        targetDir: target,
      ),
      throwsUnsupportedError,
    );
    expect(target.existsSync(), isFalse);
  });

  test('取消时抛取消异常且清掉半截目录', () async {
    final target = Directory('${tempRoot.path}/v1');
    await expectLater(
      downloader().downloadVideo(
        url: '$base/play.m3u8',
        headers: const {},
        targetDir: target,
        isCancelled: () => true,
      ),
      throwsA(isA<M3uExportDownloadCancelled>()),
    );
    expect(target.existsSync(), isFalse);
  });

  test('分片 404 时抛错且清掉半截目录', () async {
    final target = Directory('${tempRoot.path}/v1');
    await expectLater(
      downloader().downloadVideo(
        url: '$base/missing.m3u8',
        headers: const {},
        targetDir: target,
      ),
      throwsA(isA<HttpException>()),
    );
    expect(target.existsSync(), isFalse);
  });
}
