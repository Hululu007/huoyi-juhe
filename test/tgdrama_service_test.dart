import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/tgdrama_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// TgdramaService 测试：全程假依赖，不联网、不真启动二进制。
///
/// - 进程启动器是假的（只记调用参数、不拉真进程）；
/// - HTTP 是 MockClient（按路径回固定响应）；
/// - 二进制 asset 由测试直接读树里的文件喂给服务（不走 flutter test 的
///   asset 打包）；
/// - 平台用 isAndroidProvider 强制为 Android（本机是 x86_64 Linux，
///   Platform.isAndroid 本来是 false，服务会直接拒绝启动）。
/// - 另验工作目录（启动时必须钉在插件目录）与进程日志/退出码抓取。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late List<TgdramaService> created;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fqapp_tgdrama_test_');
    created = [];
  });

  tearDown(() async {
    for (final service in created) {
      await service.stop();
      service.dispose();
    }
    try {
      await tempDir.delete(recursive: true);
    } on FileSystemException {
      // 忽略：临时目录残留不让测试变红。
    }
  });

  Future<ByteData> realBinaryBytes(String assetPath) async {
    if (assetPath == TgdramaService.sessionAssetPath) {
      // 预置会话：测试用假会话字节（不读树里真实的 session.json，
      // 不碰用户真会话；只验“原样写进去”与“已有不覆盖”）。
      const fakeSession =
          '{"Version":1,"Data":{"Config":{},"DC":5,"Addr":"1.2.3.4:443",'
          '"AuthKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==",'
          '"AuthKeyID":"AAAAAAAAAAA=","Salt":0}}';
      return ByteData.view(
        Uint8List.fromList(utf8.encode(fakeSession)).buffer,
      );
    }
    expect(assetPath, TgdramaService.binaryAssetPath);
    final bytes = await File(assetPath).readAsBytes();
    return ByteData.view(Uint8List.fromList(bytes).buffer);
  }

  TgdramaService createService({
    required MockClient client,
    _FakeProcess Function()? processFactory,
    Future<Process> Function(
      List<String> command, {
      String? workingDirectory,
    })?
    processLauncher,
    Future<ByteData> Function(String assetPath)? assetLoader,
    bool Function()? isAndroidProvider,
    bool Function(String path)? isExecutableChecker,
  }) {
    final launches = <List<String>>[];
    final launchDirs = <String?>[];
    final service = TgdramaService(
      httpClient: client,
      processLauncher: (command, {String? workingDirectory}) async {
        launches.add(List<String>.from(command));
        launchDirs.add(workingDirectory);
        if (processLauncher != null) {
          return processLauncher(command, workingDirectory: workingDirectory);
        }
        return processFactory?.call() ?? _FakeProcess();
      },
      supportDirProvider: () async => tempDir,
      isAndroidProvider: isAndroidProvider ?? () => true,
      assetLoader: assetLoader ?? realBinaryBytes,
      isExecutableChecker: isExecutableChecker,
    );
    serviceLaunches[service] = launches;
    serviceLaunchDirs[service] = launchDirs;
    created.add(service);
    return service;
  }

  MockClient clientFor({
    int healthStatus = 200,
    Map<String, dynamic>? authBody,
    int authStatusCode = 200,
    int qrStatus = 200,
    int passwordStatus = 200,
    Map<String, dynamic>? passwordBody,
  }) {
    return MockClient((http.Request request) async {
      final path = request.url.path;
      if (path == '/') {
        return http.Response('', healthStatus);
      }
      if (path == '/api/auth/status') {
        return http.Response(
          jsonEncode(authBody ?? {'authorized': true}),
          authStatusCode,
          headers: const {'content-type': 'application/json'},
        );
      }
      if (path == '/api/auth/qr') {
        return http.Response('', qrStatus);
      }
      if (path == '/api/auth/password') {
        // Response 默认 latin1 编码，中文体须走 bytes + utf8，否则构造时
        // 直接抛 ArgumentError。
        return http.Response.bytes(
          utf8.encode(jsonEncode(passwordBody ?? {'ok': true})),
          passwordStatus,
          headers: const {
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }
      return http.Response('not found', 404);
    });
  }

  test('未启动时 ensureRunning 解压+chmod+启动+健康检查通过，第二次不再重复启动',
      () async {
    final service = createService(client: clientFor());
    expect(await service.ensureRunning(), isTrue);
    expect(service.isRunning, isTrue);
    expect(service.lastError, isNull);

    final launches = serviceLaunches[service]!;
    expect(launches.length, 1);
    final binaryPath =
        '${tempDir.path}/tgdrama/tgdrama-android';
    expect(launches.single, [
      binaryPath,
      '-port',
      '5278',
      '-bind',
      '127.0.0.1',
    ]);
    // 工作目录钉在插件目录：插件的数据目录默认就是当前工作目录。
    expect(
      serviceLaunchDirs[service]!.single,
      '${tempDir.path}/tgdrama',
    );

    // 二进制已落盘，且 MD5 与打包的二进制一致。
    final binaryFile = File(binaryPath);
    expect(await binaryFile.exists(), isTrue);
    expect(
      md5.convert(await binaryFile.readAsBytes()).toString(),
      TgdramaService.binaryMd5,
    );

    // 已在跑：第二次 ensureRunning 直接回 true，不再拉进程。
    expect(await service.ensureRunning(), isTrue);
    expect(launches.length, 1);
  });

  test('已落盘且 MD5 对得上时复用，不重拷；对不上重拷自愈', () async {
    var binaryLoads = 0;
    var sessionLoads = 0;
    Future<ByteData> countingLoader(String assetPath) async {
      if (assetPath == TgdramaService.sessionAssetPath) {
        sessionLoads++;
      } else {
        binaryLoads++;
      }
      return realBinaryBytes(assetPath);
    }

    // 先放一份内容不对的旧文件。
    final dir = Directory('${tempDir.path}/tgdrama');
    await dir.create(recursive: true);
    await File('${dir.path}/tgdrama-android').writeAsBytes([1, 2, 3]);

    final service = createService(
      client: clientFor(),
      assetLoader: countingLoader,
    );
    expect(await service.ensureRunning(), isTrue);
    expect(binaryLoads, 1);
    // 首次启动：预置会话也从 asset 写一份（session.json 原先不存在）。
    expect(sessionLoads, 1);
    expect(
      md5
          .convert(
            await File('${dir.path}/tgdrama-android').readAsBytes(),
          )
          .toString(),
      TgdramaService.binaryMd5,
    );

    // 第二次：二进制 MD5 已对上、会话已存在，asset 不再加载。
    final second = createService(
      client: clientFor(),
      assetLoader: countingLoader,
    );
    expect(await second.ensureRunning(), isTrue);
    expect(binaryLoads, 1);
    expect(sessionLoads, 1);
  });

  test('首次启动把预置 session.json 写进插件目录，已有会话不覆盖', () async {
    final service = createService(client: clientFor());
    expect(await service.ensureRunning(), isTrue);
    final sessionFile = File('${tempDir.path}/tgdrama/session.json');
    expect(await sessionFile.exists(), isTrue);
    // 与测试注入的假会话字节一致（只比字节，不打印内容）。
    final written = await sessionFile.readAsString();
    expect(written, contains('"Version":1'));
    expect(written, contains('"DC":5'));

    // 已有会话：改写内容后重跑 ensureRunning，不应被覆盖。
    await sessionFile.writeAsBytes([7, 7, 7]);
    final second = createService(client: clientFor());
    expect(await second.ensureRunning(), isTrue);
    expect(await sessionFile.readAsBytes(), [7, 7, 7]);
  });

  test('包里没有预置会话时启动仍成功（best-effort，不拦插件）', () async {
    Future<ByteData> noSessionLoader(String assetPath) async {
      if (assetPath == TgdramaService.sessionAssetPath) {
        throw StateError('no session asset');
      }
      return realBinaryBytes(assetPath);
    }

    final service = createService(
      client: clientFor(),
      assetLoader: noSessionLoader,
    );
    expect(await service.ensureRunning(), isTrue);
    expect(
      await File('${tempDir.path}/tgdrama/session.json').exists(),
      isFalse,
    );
  });

  test('健康检查一直失败回 false 且 lastError 有内容', () async {
    final service = createService(client: clientFor(healthStatus: 500));
    expect(await service.ensureRunning(), isFalse);
    expect(service.lastError, isNotNull);
    expect(service.lastError, isNotEmpty);
    expect(serviceLaunches[service]!.length, 1);
  });

  test('进程启动后立刻退出回 false 且 lastError 说明进程已退出', () async {
    final process = _FakeProcess();
    final service = createService(
      client: clientFor(healthStatus: 500),
      processFactory: () => process,
    );
    final running = service.ensureRunning();
    // 进程在第一次健康检查前就退出：轮询应立刻收尾，不用等满 8 秒。
    process.exitNow(1);
    expect(await running, isFalse);
    expect(service.lastError, contains('已退出'));
    expect(service.lastError, contains('退出码 1'));
    expect(service.lastExitCode, 1);
  });

  test('进程退出时 lastError 带退出码与进程日志尾巴，plugin.log 落盘', () async {
    final process = _FakeProcess(
      stderrLines: ['linker: Permission denied'],
    );
    final service = createService(
      client: clientFor(healthStatus: 500),
      processFactory: () => process,
    );
    final running = service.ensureRunning();
    process.exitNow(1);
    expect(await running, isFalse);
    expect(service.lastError, contains('已退出'));
    expect(service.lastError, contains('退出码 1'));
    expect(service.lastError, contains('Permission denied'));
    expect(service.lastExitCode, 1);
    expect(service.lastLogTail, contains('Permission denied'));
    final logFile = File('${tempDir.path}/tgdrama/plugin.log');
    expect(await logFile.exists(), isTrue);
    // IOSink 关流是异步落盘，等一拍再读内容。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await logFile.readAsString(), contains('Permission denied'));
  });

  test('非 Android 直接回 false，lastError 写明仅支持 Android，不拉进程',
      () async {
    final service = createService(
      client: clientFor(),
      isAndroidProvider: () => false,
    );
    expect(await service.ensureRunning(), isFalse);
    expect(service.lastError, contains('仅支持 Android'));
    expect(serviceLaunches[service], isEmpty);
  });

  test('authStatus 多键解析：authorized 各形状都算已登录', () async {
    const bodies = [
      {'authorized': true},
      {'logged_in': true},
      {'loggedIn': true},
      {'authenticated': true},
      {'is_authorized': true},
      {'status': 'authorized'},
      {'status': 'ok'},
      {'status': 'logged_in'},
      {'phase': 'authorized'},
      {'state': 'logged_in'},
    ];
    for (final body in bodies) {
      final service = createService(client: clientFor(authBody: body));
      final status = await service.authStatus();
      expect(status.authorized, isTrue, reason: '$body');
      expect(status.needPassword, isFalse, reason: '$body');
    }
  });

  test('authStatus 多键解析：need_password 各形状都算需二步验证', () async {
    const bodies = [
      {'need_password': true},
      {'needPassword': true},
      {'password_required': true},
      {'status': 'need_password'},
      {'status': 'password'},
      {'phase': 'password_required'},
    ];
    for (final body in bodies) {
      final service = createService(client: clientFor(authBody: body));
      final status = await service.authStatus();
      expect(status.needPassword, isTrue, reason: '$body');
      expect(status.authorized, isFalse, reason: '$body');
    }
  });

  test('authStatus 未登录/解析失败/非 200 都按未登录回，不抛异常', () async {
    final empty = createService(client: clientFor(authBody: {}));
    final emptyStatus = await empty.authStatus();
    expect(emptyStatus.authorized, isFalse);
    expect(emptyStatus.needPassword, isFalse);

    final denied = createService(
      client: clientFor(authBody: {'authorized': false}),
    );
    expect((await denied.authStatus()).authorized, isFalse);

    final httpError = createService(
      client: clientFor(authStatusCode: 500, authBody: {'authorized': true}),
    );
    final httpErrorStatus = await httpError.authStatus();
    expect(httpErrorStatus.authorized, isFalse);
    expect(httpErrorStatus.message, contains('500'));

    final badJson = createService(
      client: MockClient((_) async => http.Response('not json', 200)),
    );
    expect((await badJson.authStatus()).authorized, isFalse);
  });

  test('submitPassword 非 200 抛 StateError，带状态码与服务端 message', () async {
    final service = createService(
      client: clientFor(
        passwordStatus: 401,
        passwordBody: {'message': '密码错误'},
      ),
    );
    await expectLater(
      service.submitPassword('wrong'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(contains('401'), contains('密码错误')),
        ),
      ),
    );
  });

  test('submitPassword 200 正常返回；startQrLogin 200 成功、非 200 抛错',
      () async {
    final service = createService(client: clientFor());
    await service.submitPassword('correct');
    await service.startQrLogin();

    final failing = createService(client: clientFor(qrStatus: 503));
    await expectLater(
      failing.startQrLogin(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('503'),
        ),
      ),
    );
  });

  test('stop 杀掉已启动的进程，isRunning 变 false', () async {
    final process = _FakeProcess();
    final service = createService(
      client: clientFor(),
      processFactory: () => process,
    );
    expect(await service.ensureRunning(), isTrue);
    expect(service.isRunning, isTrue);
    await service.stop();
    expect(process.killed, isTrue);
    expect(service.isRunning, isFalse);
  });

  test('stop 在未启动时什么也不做；qrImageUrl 拼对地址', () async {
    final service = createService(client: clientFor());
    await service.stop();
    expect(service.isRunning, isFalse);
    expect(
      service.qrImageUrl,
      '${TgdramaService.baseUrl}/api/auth/qr.png',
    );
    expect(TgdramaService.baseUrl, 'http://127.0.0.1:5278');
    expect(TgdramaService.defaultPort, 5278);
  });

  test('执行位没加上时直接走链接器兜底，不试直接启动', () async {
    final service = createService(
      client: clientFor(),
      isExecutableChecker: (_) => false,
    );
    expect(await service.ensureRunning(), isTrue);
    final launches = serviceLaunches[service]!;
    expect(launches.length, 1);
    expect(launches.single.first, TgdramaService.linker64Path);
    expect(launches.single[1], '${tempDir.path}/tgdrama/tgdrama-android');
    expect(launches.single.sublist(2), ['-port', '5278', '-bind', '127.0.0.1']);
    expect(
      serviceLaunchDirs[service]!.single,
      '${tempDir.path}/tgdrama',
    );
  });

  test('直接启动被拒时改走链接器兜底，仍能跑起来', () async {
    var directAttempts = 0;
    final service = createService(
      client: clientFor(),
      processLauncher: (command, {String? workingDirectory}) async {
        if (command.first == TgdramaService.linker64Path) {
          return _FakeProcess();
        }
        directAttempts++;
        throw ProcessException(
          command.first,
          command.sublist(1),
          'Permission denied',
          13,
        );
      },
    );
    expect(await service.ensureRunning(), isTrue);
    expect(directAttempts, 1);
    final launches = serviceLaunches[service]!;
    expect(launches.length, 2);
    expect(launches[1].first, TgdramaService.linker64Path);
    expect(launches[1][1], '${tempDir.path}/tgdrama/tgdrama-android');
  });

  test('直接被拒且链接器也失败时回 false，lastError 说明两处都失败', () async {
    final service = createService(
      client: clientFor(),
      processLauncher: (command, {String? workingDirectory}) async {
        throw ProcessException(
          command.first,
          command.sublist(1),
          'Permission denied',
          13,
        );
      },
    );
    expect(await service.ensureRunning(), isFalse);
    expect(service.lastError, contains('链接器'));
    expect(serviceLaunches[service]!.length, 2);
  });

  test('直接启动报非权限错时不走链接器兜底', () async {
    final service = createService(
      client: clientFor(),
      processLauncher: (command, {String? workingDirectory}) async {
        throw ProcessException(
          command.first,
          command.sublist(1),
          'No such file or directory',
          2,
        );
      },
    );
    expect(await service.ensureRunning(), isFalse);
    expect(service.lastError, contains('No such file or directory'));
    expect(serviceLaunches[service]!.length, 1);
  });

  test('databasePath 指向插件目录下的 tgdrama.db（只拼路径不碰文件）', () async {
    final service = createService(client: clientFor());
    expect(
      await service.databasePath(),
      '${tempDir.path}/tgdrama/${TgdramaService.databaseFileName}',
    );
    expect(TgdramaService.databaseFileName, 'tgdrama.db');
  });
}

/// 每个服务实例对应的启动记录（测试内共享，方便断言拉起次数与参数）。
final Map<TgdramaService, List<List<String>>> serviceLaunches = {};

/// 每个服务实例对应的启动工作目录记录（与 serviceLaunches 一一对应）。
final Map<TgdramaService, List<String?>> serviceLaunchDirs = {};

/// 假进程：不拉真进程，只记录 kill，并可由测试主动让它退出。
class _FakeProcess implements Process {
  _FakeProcess({List<String> stdoutLines = const [], List<String> stderrLines = const []})
    : _stdoutController = StreamController<List<int>>(),
      _stderrController = StreamController<List<int>>() {
    for (final line in stdoutLines) {
      _stdoutController.add(utf8.encode(line));
    }
    for (final line in stderrLines) {
      _stderrController.add(utf8.encode(line));
    }
  }

  final Completer<int> _exitCode = Completer<int>();
  final StreamController<List<int>> _stdoutController;
  final StreamController<List<int>> _stderrController;
  bool killed = false;

  @override
  Stream<List<int>> get stderr => _stderrController.stream;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  IOSink get stdin => IOSink(StreamController<List<int>>());

  @override
  int get pid => 12345;

  @override
  Future<int> get exitCode => _exitCode.future;

  /// 测试主动让进程退出（模拟应用切后台被系统杀掉等情况）。
  void exitNow(int code) {
    if (!_exitCode.isCompleted) _exitCode.complete(code);
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    exitNow(-signal.hashCode);
    return true;
  }
}
