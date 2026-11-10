import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/backend_service.dart';
import 'package:fqapp/services/backend_transport.dart';

/// Lifecycle tests for the Rust-backed [BackendService].
///
/// The Go/JNI/process assumptions of the previous suite are replaced by the
/// equivalent Rust guarantees: in-process initialization, idempotent start,
/// a health gate on the loopback adapter, generation-isolated stop/restart, and
/// runtime asset deployment that never clobbers the registered device pool.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  BackendService? created;

  BackendService createBackend({
    AssetBundle? assets,
    Duration timeout = const Duration(seconds: 2),
    Duration shutdownTimeout = const Duration(seconds: 3),
    Duration portFreeWait = const Duration(seconds: 5),
    BackendTransport? transport,
  }) {
    final backend = BackendService(
      assets: assets ?? _BackendAssets(),
      supportDirectory: () async => directory,
      transport: transport ?? _FakeRustTransport(),
      startupTimeout: timeout,
      shutdownTimeout: shutdownTimeout,
      portFreeWait: portFreeWait,
    );
    created = backend;
    return backend;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fqapp_backend_test_');
  });

  tearDown(() async {
    await created?.stop();
    // The log writer may still hold the file on Windows; a leaked temp
    // directory must not turn a passing test red.
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // ignored
    }
  });

  test('concurrent starts run one initialization and share the result', () async {
    final transport = _FakeRustTransport();
    final backend = createBackend(transport: transport);

    final first = backend.start();
    final second = backend.start();
    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);

    expect(transport.initCalls, 1);
    expect(backend.isRunning, isTrue);
    await backend.stop();
    expect(transport.stopCalls, 1);
    expect(backend.isRunning, isFalse);
  });

  test('a failed core initialization surfaces and leaves nothing running', () async {
    final transport = _FakeRustTransport(initResult: 'failed: listen busy');
    final backend = createBackend(transport: transport);

    await expectLater(backend.start(), throwsStateError);
    expect(backend.isRunning, isFalse);
    // A failed start performs its own cleanup so a retry is not blocked.
    transport.initResult = 'running';
    await backend.start();
    expect(backend.isRunning, isTrue);
    expect(transport.initCalls, 2);
    await backend.stop();
  });

  test('startup times out when the health endpoint never turns 200', () async {
    final transport = _FakeRustTransport(healthy: false);
    final backend = createBackend(
      transport: transport,
      timeout: const Duration(milliseconds: 200),
    );

    await expectLater(
      backend.start().timeout(const Duration(seconds: 3)),
      throwsStateError,
    );
    expect(backend.isRunning, isFalse);
    expect(transport.healthChecks, greaterThan(0));
  });

  test('a hung core initialization fails by the startup timeout and retries',
      () async {
    final transport = _FakeRustTransport(blockInit: true);
    final backend = createBackend(
      transport: transport,
      timeout: const Duration(milliseconds: 200),
    );

    // rustTransport.start() itself has no deadline of its own: a native init
    // that never returns must still fail the launch instead of spinning.
    await expectLater(
      backend.start().timeout(const Duration(seconds: 3)),
      throwsA(
        isA<StateError>().having(
          (error) => error.message.toString(),
          'message',
          contains('timeout'),
        ),
      ),
    );
    expect(backend.isRunning, isFalse);
    expect(transport.initCalls, 1);

    // The timed-out attempt must not wedge startup: the next one can succeed.
    transport.allowInit.complete();
    await backend.start();
    expect(backend.isRunning, isTrue);
    expect(transport.initCalls, 2);
    await backend.stop();
  });

  test('stop during deployment waits and shuts the core down', () async {
    final assets = _BackendAssets(blockFirstLoad: true);
    final transport = _FakeRustTransport();
    final backend = createBackend(assets: assets, transport: transport);

    final starting = backend.start();
    await assets.loadEntered.future;
    final stopping = backend.stop();
    assets.allowLoad.complete();
    await starting;
    await stopping;

    expect(transport.initCalls, 1);
    expect(transport.stopCalls, 1);
    expect(backend.isRunning, isFalse);
  });

  test('a start during shutdown waits and initializes a new core', () async {
    final transport = _FakeRustTransport(blockStop: true);
    final backend = createBackend(transport: transport);
    await backend.start();

    final stopping = backend.stop();
    await transport.stopEntered.future;
    final restarting = backend.start();
    transport.allowStop.complete();
    await stopping;
    await restarting;

    expect(transport.initCalls, 2);
    expect(transport.stopCalls, 1);
    expect(backend.isRunning, isTrue);
    await backend.stop();
  });

  test('stop is safe to call repeatedly and without a start', () async {
    final transport = _FakeRustTransport();
    final backend = createBackend(transport: transport);
    await backend.stop();
    await backend.stop();
    expect(transport.stopCalls, 0);
    expect(backend.isRunning, isFalse);
  });

  test('deploys nested runtime assets and keeps the registered device pool',
      () async {
    final transport = _FakeRustTransport();
    final backend = createBackend(transport: transport);
    await backend.start();

    for (final path in _BackendAssets.runtimeAssets) {
      final file = File(
        '${directory.path}/backend/${path.substring('assets/'.length)}',
      );
      expect(await file.readAsString(), '{}', reason: path);
    }

    // The pool holds real device credentials: a restart must not overwrite it.
    final pool = File('${directory.path}/backend/config/device_pool.json');
    await pool.writeAsString('registered-device');
    final pluginPage = File('${directory.path}/backend/plugins/player.html');
    await pluginPage.writeAsString('old plugin page');
    await backend.stop();

    await backend.start();
    expect(await pool.readAsString(), 'registered-device');
    expect(await pluginPage.readAsString(), '{}');
    await backend.stop();
  });

  test('the core is initialized with the deployed runtime paths', () async {
    final transport = _FakeRustTransport();
    final backend = createBackend(transport: transport);
    await backend.start();

    expect(transport.configPath, endsWith('/backend/config/config.json'));
    expect(transport.poolPath, endsWith('/backend/config/device_pool.json'));
    expect(transport.filterPath, endsWith('/backend/config/filter.json'));
    expect(transport.runtimeDir, endsWith('/backend'));
    await backend.stop();
  });

  test('the listener port comes from the deployed config.json', () async {
    final transport = _FakeRustTransport();
    final backend = createBackend(transport: transport);
    await backend.start();

    // config.json is the single source of truth, so the deployed copy decides
    // what the core binds rather than the transport constructor default.
    expect(transport.listenPort, 18921);
    await backend.stop();
  });

  test('a config.json without a usable port leaves the core default', () async {
    final transport = _FakeRustTransport();
    final assets = _BackendAssets(configPort: null);
    final backend = createBackend(assets: assets, transport: transport);
    await backend.start();

    expect(transport.listenPort, isNull);
    await backend.stop();
  });

  test(
    'an address-in-use bind on the configured port retries on port 0',
    () async {
      // The old process still holds 18921 after an overlay install: the
      // first bind fails exactly like the Rust core reports, and startup
      // must survive by binding an ephemeral port instead of dying.
      final transport = _FakeRustTransport(failWithAddressInUseOnPort: 18921);
      final backend = createBackend(transport: transport);
      await backend.start();

      expect(backend.isRunning, isTrue);
      expect(transport.listenPorts.last, 0);
      await backend.stop();
    },
  );

  test(
    'an address-in-use bind on every port still fails and stays retryable',
    () async {
      // Scratch port as the configured port so the probe outcome does not
      // depend on whether anything in the test environment holds 18921.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final transport = _FakeRustTransport(failAllWithAddressInUse: true);
      final assets = _BackendAssets(configPort: port);
      final backend = createBackend(assets: assets, transport: transport);

      await expectLater(
        backend.start(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message.toString(),
            'message',
            contains('Address already in use'),
          ),
        ),
      );
      expect(backend.isRunning, isFalse);
      // First start tried the configured port, then the ephemeral fallback.
      expect(transport.listenPorts, [port, 0]);

      transport.failAllWithAddressInUse = false;
      await backend.start();
      expect(backend.isRunning, isTrue);
      expect(transport.listenPorts, [port, 0, port]);
      await backend.stop();
    },
  );

  test('a port freed while waiting binds the configured port', () async {
    // A real listener stands in for the stale old process on a scratch
    // port; it exits mid-startup, so the core must take the configured
    // port instead of falling back.
    final holder = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = holder.port;
    addTearDown(() async {
      try {
        await holder.close();
      } catch (_) {}
    });
    final transport = _FakeRustTransport();
    final assets = _BackendAssets(configPort: port);
    final backend = createBackend(
      assets: assets,
      transport: transport,
      timeout: const Duration(seconds: 10),
      portFreeWait: const Duration(seconds: 5),
    );

    final starting = backend.start();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await holder.close();
    await starting;

    expect(backend.isRunning, isTrue);
    expect(transport.listenPorts, [port]);
    await backend.stop();
  });

  test(
    'a port still held after the wait falls back to an ephemeral port',
    () async {
      final holder = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = holder.port;
      addTearDown(() async {
        try {
          await holder.close();
        } catch (_) {}
      });
      final transport = _FakeRustTransport();
      final assets = _BackendAssets(configPort: port);
      final backend = createBackend(
        assets: assets,
        transport: transport,
        timeout: const Duration(seconds: 10),
        portFreeWait: const Duration(milliseconds: 300),
      );

      await backend.start();

      expect(backend.isRunning, isTrue);
      expect(transport.listenPorts, [0]);
      await backend.stop();
    },
  );
}

/// A [RustBackendTransport] with the FFI calls replaced by counters, so the
/// lifecycle can be verified without loading the shared library.
class _FakeRustTransport extends RustBackendTransport {
  _FakeRustTransport({
    this.initResult = 'running',
    this.healthy = true,
    this.blockStop = false,
    this.blockInit = false,
    this.failWithAddressInUseOnPort,
    this.failAllWithAddressInUse = false,
  });

  String initResult;
  bool healthy;
  final bool blockStop;
  /// Whether [start] holds until [allowInit] completes, standing in for a
  /// native init that hangs.
  final bool blockInit;

  /// When set, [start] throws the Rust core's address-in-use error for a
  /// bind on this port (a stale process still holding it).
  final int? failWithAddressInUseOnPort;

  /// When true, [start] throws the address-in-use error for any port.
  bool failAllWithAddressInUse;

  int initCalls = 0;
  int stopCalls = 0;
  int healthChecks = 0;
  String? configPath;
  String? poolPath;
  String? filterPath;
  String? runtimeDir;
  int? listenPort;
  final List<int?> listenPorts = [];
  bool lanShare = false;

  final stopEntered = Completer<void>();
  final allowStop = Completer<void>();
  final allowInit = Completer<void>();

  @override
  String get baseUrl => 'http://127.0.0.1:18921';

  @override
  Future<String> start({
    required String configPath,
    required String poolPath,
    required String filterPath,
    required String runtimeDir,
    int? listenPort,
    bool lanShare = false,
  }) async {
    initCalls += 1;
    this.configPath = configPath;
    this.poolPath = poolPath;
    this.filterPath = filterPath;
    this.runtimeDir = runtimeDir;
    this.listenPort = listenPort;
    listenPorts.add(listenPort);
    this.lanShare = lanShare;
    if (failAllWithAddressInUse ||
        (failWithAddressInUseOnPort != null &&
            listenPort == failWithAddressInUseOnPort)) {
      throw StateError(
        'Rust core failed: listen 127.0.0.1:18921: '
        'Address already in use (os error 98)',
      );
    }
    if (blockInit) await allowInit.future;
    return initResult;
  }

  @override
  Future<String> status() async => 'running';

  @override
  Future<void> stop() async {
    stopCalls += 1;
    if (blockStop) {
      if (!stopEntered.isCompleted) stopEntered.complete();
      await allowStop.future;
    }
  }

  @override
  Future<BackendResponse> send(
    String method,
    Uri url, {
    Uint8List? body,
    Duration? timeout,
    BackendRequest? request,
  }) async {
    if (url.path == '/health') {
      healthChecks += 1;
      if (!healthy) throw const SocketException('backend down');
      return BackendResponse(200, Uint8List(0), 'application/json');
    }
    return BackendResponse(404, Uint8List(0), 'application/json');
  }
}

class _BackendAssets extends CachingAssetBundle {
  _BackendAssets({this.blockFirstLoad = false, this.configPort = 18921});

  final bool blockFirstLoad;
  /// Port written into the deployed `config.json`; null omits the key.
  final int? configPort;
  final loadEntered = Completer<void>();
  final allowLoad = Completer<void>();
  static const runtimeAssets = [
    'assets/filters/book.js',
    'assets/plugins/player.html',
  ];

  @override
  Future<ByteData> load(String key) async {
    if (!loadEntered.isCompleted) {
      loadEntered.complete();
      if (blockFirstLoad) await allowLoad.future;
    }
    if (key == 'AssetManifest.bin') {
      return const StandardMessageCodec().encodeMessage({
        for (final path in runtimeAssets)
          path: [
            {'asset': path},
          ],
      })!;
    }
    if (key == 'assets/config/config.json') {
      final port = configPort;
      final body = port == null ? '{}' : '{"port":$port}';
      return ByteData.sublistView(Uint8List.fromList(utf8.encode(body)));
    }
    return ByteData.sublistView(Uint8List.fromList([123, 125]));
  }
}
