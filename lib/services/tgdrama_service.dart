import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'tgdrama_credentials.dart';

/// TG影视库插件（tgdrama-android）本地服务管理。
///
/// 插件是 Go 写的 ARM64 二进制，直连 Telegram，对外只暴露一个本地 HTTP
/// 服务（127.0.0.1:5278）。本服务只管二进制的落盘、启停、健康检查与重拉，
/// 不碰插件内部的收视频逻辑与账号体系。
///
/// 落盘：首次使用时把 asset 里的二进制拷到应用私有目录
/// `getApplicationSupportDirectory()/tgdrama/tgdrama-android`，MD5 对得上
/// 复用、对不上重拷自愈（做法同 jar_bridge 的 resolveBuiltinJarAsset），
/// 再 chmod 755、验执行位后用 `Process.start` 拉起来
/// （参数 `-port 5278 -bind 127.0.0.1`，工作目录钉在插件目录——
/// 插件的数据目录默认就是当前工作目录，session.json、config.yaml、
/// tgdrama.db 都在工作目录里找；不钉工作目录，预置会话白写不说，
/// 工作目录不可写时建库失败还会直接退出）。鸿蒙卓易通容器里直接执行受限
/// 时（chmod 完了仍不可执行），改走系统链接器 `/system/bin/linker64`
/// 兜底拉起（插件是动态链接的程序，链接器只需读文件就能跑）。
///
/// 诊断：进程的标准输出/错误输出实时收进内存尾巴（最多 4000 字）并
/// 写进插件目录的 plugin.log；进程退出时退出码与日志尾巴拼进
/// [lastError]，登录页直接显示，不再只报一句“进程已退出”。
///
/// 重拉：应用切后台被系统杀掉后，回到前台（resumed）时若之前启动过，
/// 自动再调一次 [ensureRunning]。
///
/// 本机（x86_64）跑不了这个 ARM64 二进制，测试一律用注入的假进程启动器
/// 与假 HTTP 客户端，不要真启动二进制、不要联网。
class TgdramaAuthStatus {
  const TgdramaAuthStatus({
    required this.authorized,
    required this.needPassword,
    this.message = '',
  });

  /// 是否已登录（扫码登录完成且会话有效）。
  final bool authorized;

  /// 是否卡在二步验证，需要提交密码。
  final bool needPassword;

  /// 服务端给出的提示（message/msg/error 字段，有的话）。
  final String message;
}

class TgdramaService with WidgetsBindingObserver {
  TgdramaService({
    http.Client? httpClient,
    Future<Process> Function(List<String> command, {String? workingDirectory})?
    processLauncher,
    Future<Directory> Function()? supportDirProvider,
    this._isAndroidProvider,
    Future<ByteData> Function(String assetPath)? assetLoader,
    bool Function(String path)? isExecutableChecker,
    Future<ProcessResult> Function(String executable, List<String> args)?
    chmodRunner,
  }) : _httpClient = httpClient ?? http.Client(),
       _processLauncher =
           processLauncher ?? _defaultProcessLauncher,
       _supportDirProvider =
           supportDirProvider ?? getApplicationSupportDirectory,
       _assetLoader = assetLoader ?? rootBundle.load,
       _isExecutableChecker =
           isExecutableChecker ?? _defaultIsExecutable,
       _chmodRunner = chmodRunner ?? Process.run {
    try {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    } catch (_) {
      // 测试里若绑定尚未初始化，观察者注册失败也不影响启停本身；
      // resumed 重拉只是附加能力，不是必经路径。
      _observing = false;
    }
  }

  static const baseUrl = 'http://127.0.0.1:5278';
  static const defaultPort = 5278;

  /// 打包进安装包的二进制 asset 路径。
  static const binaryAssetPath = 'assets/tgdrama/tgdrama-android';

  /// 预置登录会话 asset 路径（构建期由 Telethon 会话转换生成，
  /// 构建期临时文件，.gitignore 隔离、绝不提交）。
  /// 装包后首次启动时写到插件数据目录，插件一启动就是已登录。
  static const sessionAssetPath = 'assets/tgdrama_session.json';

  /// 插件本地库文件名：与二进制同目录的 tgdrama.db（插件内部数据，
  /// 蜘蛛不再直读库，只走插件接口）。只读，不写库。
  static const databaseFileName = 'tgdrama.db';

  /// 插件本地库路径：supportDir/tgdrama/tgdrama.db。只拼路径不碰
  /// 文件系统，文件不一定存在（插件没跑过/没同步过）。
  Future<String> databasePath() async {
    final supportDir = await _supportDirProvider();
    return '${supportDir.path}/$_binaryDirName/$databaseFileName';
  }

  /// 二进制 MD5（2.0.0 自写重建版，2026-11-06 实测，与
  /// ~/workspace/tgdrama_rebuild/tgdrama-android 一致，含新增的
  /// POST /api/chats/refresh）；落盘时校验，对不上重拷自愈。
  static const binaryMd5 = 'cd1ad61c28e2b14a4b93fed143064ad6';

  static const _binaryDirName = 'tgdrama';
  static const _binaryFileName = 'tgdrama-android';

  /// 系统链接器：鸿蒙卓易通容器里直接执行受限（chmod 755 后文件仍不可
  /// 执行），插件是动态链接的程序，链接器只需读文件就能跑，不用执行位。
  /// 直接启动被拒时改走它兜底拉起。
  static const linker64Path = '/system/bin/linker64';

  /// 授权用的 chmod 绝对路径：容器里 PATH 未必含 chmod，绝对路径优先。
  static const _chmodPath = '/system/bin/chmod';

  /// 进程日志尾巴最多留多少字（登录页展示 + plugin.log 之外，内存里只留尾巴）。
  static const _maxLogChars = 4000;

  /// 健康检查超时：与插件笔记一致，8 秒。
  static const _healthTimeout = Duration(seconds: 8);

  /// 健康检查轮询：每 500ms 一次，最多 16 次，约 8 秒。
  static const _healthPollAttempts = 16;
  static const _healthPollInterval = Duration(milliseconds: 500);

  static final TgdramaService _instance = TgdramaService();
  static TgdramaService get instance => _instance;

  final http.Client _httpClient;
  final Future<Process> Function(
    List<String> command, {
    String? workingDirectory,
  })
  _processLauncher;
  final Future<Directory> Function() _supportDirProvider;
  final bool Function()? _isAndroidProvider;
  final Future<ByteData> Function(String assetPath) _assetLoader;
  final bool Function(String path) _isExecutableChecker;
  final Future<ProcessResult> Function(String executable, List<String> args)
  _chmodRunner;

  Process? _process;
  bool _processExited = false;
  bool _everStarted = false;
  bool _observing = false;
  Future<bool>? _starting;
  String? _lastError;
  int? _lastExitCode;
  final StringBuffer _logBuffer = StringBuffer();
  IOSink? _logSink;

  /// 最近一次失败的原因（ensureRunning 失败时调用方拿去展示）。
  String? get lastError => _lastError;

  /// 进程最近的标准输出/错误输出尾巴（最多 4000 字）。
  String get lastLogTail => _logBuffer.toString();

  /// 进程最近一次的退出码（没退过为 null）。
  int? get lastExitCode => _lastExitCode;

  /// 进程对象非空且未退出。
  bool get isRunning => _process != null && !_processExited;

  bool get _isAndroid => _isAndroidProvider?.call() ?? Platform.isAndroid;

  static Future<Process> _defaultProcessLauncher(
    List<String> command, {
    String? workingDirectory,
  }) => Process.start(
    command.first,
    command.sublist(1),
    workingDirectory: workingDirectory,
  );

  /// 所有者执行位有没有真的加上（chmod 完了也不一定，容器里可能不生效）。
  static bool _defaultIsExecutable(String path) {
    try {
      return (File(path).statSync().mode & 0x40) != 0;
    } catch (_) {
      return false;
    }
  }

  /// 启动失败是不是“没权限”（errno 13 / Permission denied）。
  static bool _isPermissionDenied(Object error) {
    if (error is ProcessException) {
      if (error.errorCode == 13) return true;
      return error.message.toLowerCase().contains('permission denied');
    }
    return error.toString().toLowerCase().contains('permission denied');
  }

  /// 释放观察者（单例不需要调；测试里每个新建实例要在 tearDown 里调）。
  void dispose() {
    if (_observing) {
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (_) {}
      _observing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 应用切后台被杀、回应用重拉：之前启动过才重拉，没启动过不打扰。
    if (state == AppLifecycleState.resumed && _everStarted) {
      unawaited(ensureRunning());
    }
  }

  /// 确保本地服务在跑。进程活着且健康检查通过直接回 true；否则解压
  /// （MD5 校验）、chmod 755、验执行位、拉起进程（直接启动被拒时改走
  /// 系统链接器兜底），再轮询健康检查（每 500ms 一次，最多约 8 秒）。
  /// 失败不抛异常，回 false，原因写进 [lastError]。
  /// 并发调用共享同一次启动，不会重复拉起。
  Future<bool> ensureRunning() async {
    if (_starting != null) return _starting!;
    final starting = _ensureRunning();
    _starting = starting;
    try {
      return await starting;
    } finally {
      _starting = null;
    }
  }

  Future<bool> _ensureRunning() async {
    if (!_isAndroid) {
      _lastError = 'TG影视库本地服务仅支持 Android';
      return false;
    }
    if (isRunning) {
      if (await healthCheck()) return true;
      // 进程在但健康检查不通：先杀掉旧进程再重拉，避免端口被占。
      await stop();
    }
    _lastError = null;
    late final String binaryPath;
    try {
      binaryPath = await _resolveBinary();
    } catch (error) {
      _lastError = 'TG影视库二进制解压失败：$error';
      return false;
    }
    // 预置会话与凭证：首次启动把包里的 session.json 写到插件数据目录
    //（已登录就不覆盖），并补 config.yaml 的 Telegram API 凭证。
    // 全部 best-effort：失败不拦启动，登录页仍可扫码/输手机号重登。
    await _seedSessionAndConfig(File(binaryPath).parent);
    // 插件的数据目录默认就是当前工作目录：启动时必须把工作目录钉在
    // 插件目录，否则插件在别处建库/找配置，预置会话白写不说，工作
    // 目录不可写时建库失败还会直接退出——这就是 13 轮包“进程已退出”
    // 的主因（之前启动没传 workingDirectory）。
    final workDir = File(binaryPath).parent;
    // 授权分三档试：绝对路径 chmod 优先（容器里 PATH 未必含 chmod），
    // 再试 PATH 里的 chmod，最后 777；执行位还是没加上也不硬拦——
    // 链接器兜底不需要执行位，失败原因记进备注里。
    final execNote = await _ensureExecutable(binaryPath);
    // 容器里 chmod 完了执行位也可能没加上：先验一下，没加上就直接走
    // 链接器兜底，不浪费一次注定被拒的直接启动。
    final directExecutable = _isExecutableChecker(binaryPath);
    final launchArgs = <String>[
      '-port',
      '$defaultPort',
      '-bind',
      '127.0.0.1',
    ];
    var launched = false;
    if (directExecutable) {
      try {
        final process = await _processLauncher(
          [binaryPath, ...launchArgs],
          workingDirectory: workDir.path,
        );
        _trackProcess(process, workDir);
        launched = true;
      } catch (error) {
        if (!_isPermissionDenied(error)) {
          _lastError = 'TG影视库本地服务启动失败：$error'
              '${execNote == null ? '' : '（$execNote）'}';
          return false;
        }
        // 直接启动被拒（容器里执行受限）：改走系统链接器兜底。
      }
    }
    if (!launched) {
      try {
        final process = await _processLauncher(
          [linker64Path, binaryPath, ...launchArgs],
          workingDirectory: workDir.path,
        );
        _trackProcess(process, workDir);
      } catch (error) {
        _lastError = directExecutable
            ? 'TG影视库本地服务启动失败：直接启动被拒，链接器兜底也失败：$error'
            : 'TG影视库本地服务启动失败：链接器兜底启动失败：$error';
        if (execNote != null) _lastError = '$_lastError（$execNote）';
        return false;
      }
    }
    _everStarted = true;
    for (var attempt = 0; attempt < _healthPollAttempts; attempt++) {
      if (await healthCheck()) {
        _lastError = null;
        return true;
      }
      if (!isRunning) {
        _lastError = 'TG影视库本地服务进程已退出${_exitDetail()}';
        return false;
      }
      if (attempt < _healthPollAttempts - 1) {
        await Future.delayed(_healthPollInterval);
      }
    }
    _lastError = 'TG影视库本地服务健康检查超时（$baseUrl 未在 8 秒内就绪）${_exitDetail()}';
    return false;
  }

  /// 健康检查：GET /，8 秒超时，200 算通，其余（包括连不上）算不通。
  Future<bool> healthCheck() async {
    try {
      final response = await _httpClient
          .get(Uri.parse('$baseUrl/'))
          .timeout(_healthTimeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 登录状态：GET /api/auth/status。响应形状未完全确认，多键容错解析：
  /// authorized 字段试 authorized/logged_in/loggedIn/authenticated/
  /// is_authorized；status/phase/state 字符串为 authorized/ok/logged_in/
  /// authenticated 也算已登录；needPassword 试 need_password/needPassword/
  /// password_required，或 status/phase/state 为 need_password/password/
  /// password_required。解析失败或非 200 一律按未登录回，不抛异常。
  Future<TgdramaAuthStatus> authStatus() async {
    try {
      final response = await _httpClient
          .get(Uri.parse('$baseUrl/api/auth/status'))
          .timeout(_healthTimeout);
      if (response.statusCode != 200) {
        return TgdramaAuthStatus(
          authorized: false,
          needPassword: false,
          message: 'HTTP ${response.statusCode}',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const TgdramaAuthStatus(
          authorized: false,
          needPassword: false,
        );
      }
      return _parseAuthStatus(decoded);
    } catch (_) {
      return const TgdramaAuthStatus(authorized: false, needPassword: false);
    }
  }

  TgdramaAuthStatus _parseAuthStatus(Map<String, dynamic> body) {
    var authorized = false;
    for (final key in const [
      'authorized',
      'logged_in',
      'loggedIn',
      'authenticated',
      'is_authorized',
    ]) {
      if (body[key] == true) authorized = true;
    }
    var needPassword = false;
    for (final key in const [
      'need_password',
      'needPassword',
      'password_required',
    ]) {
      if (body[key] == true) needPassword = true;
    }
    final phase = _phaseString(body);
    if (phase != null) {
      if (const {
        'authorized',
        'ok',
        'logged_in',
        'loggedin',
        'authenticated',
      }.contains(phase)) {
        authorized = true;
      }
      if (const {
        'need_password',
        'password',
        'password_required',
      }.contains(phase)) {
        needPassword = true;
      }
    }
    final message = _firstString(body, const ['message', 'msg', 'error']);
    return TgdramaAuthStatus(
      authorized: authorized,
      needPassword: needPassword,
      message: message,
    );
  }

  /// status/phase/state 三个键，取到的字符串统一小写去空格。
  String? _phaseString(Map<String, dynamic> body) {
    final raw = _firstString(body, const ['status', 'phase', 'state']);
    if (raw.isEmpty) return null;
    return raw.trim().toLowerCase();
  }

  String _firstString(Map<String, dynamic> body, List<String> keys) {
    for (final key in keys) {
      final value = body[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return '';
  }

  /// 开始一次扫码登录会话：GET /api/auth/qr。200 即算成功，不解析返回体；
  /// 非 200 抛 StateError（带状态码）。
  Future<void> startQrLogin() async {
    final response = await _httpClient
        .get(Uri.parse('$baseUrl/api/auth/qr'))
        .timeout(_healthTimeout);
    if (response.statusCode != 200) {
      throw StateError(
        '扫码登录启动失败：HTTP ${response.statusCode}',
      );
    }
  }

  /// 扫码二维码图片地址；调用方拼 ?t=时间戳防缓存。
  String get qrImageUrl => '$baseUrl/api/auth/qr.png';

  /// 提交二步验证密码：POST /api/auth/password，JSON 体 {"password": ...}。
  /// 非 200 抛 StateError，带上状态码与体里 message/msg/error 字段（有的话）。
  Future<void> submitPassword(String password) async {
    final response = await _httpClient
        .post(
          Uri.parse('$baseUrl/api/auth/password'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'password': password}),
        )
        .timeout(_healthTimeout);
    if (response.statusCode == 200) return;
    var detail = '';
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        detail = _firstString(decoded, const ['message', 'msg', 'error']);
      }
    } catch (_) {}
    throw StateError(
      '二步验证密码提交失败：HTTP ${response.statusCode}'
      '${detail.isEmpty ? '' : '，$detail'}',
    );
  }

  /// 杀掉已启动的进程（若有）。进程不存在时什么也不做。
  Future<void> stop() async {
    final process = _process;
    _process = null;
    _processExited = false;
    if (process == null) {
      _closeLogSink();
      return;
    }
    try {
      process.kill();
    } catch (_) {}
    _closeLogSink();
  }

  void _trackProcess(Process process, Directory workDir) {
    _process = process;
    _processExited = false;
    _lastExitCode = null;
    _logBuffer.clear();
    try {
      _logSink = File(
        '${workDir.path}/plugin.log',
      ).openWrite(mode: FileMode.write);
    } catch (_) {
      _logSink = null;
    }
    void appendChunk(String chunk) {
      if (chunk.isEmpty) return;
      _logBuffer.write(chunk);
      if (_logBuffer.length > _maxLogChars) {
        final kept = _logBuffer.toString().substring(
          _logBuffer.length - _maxLogChars,
        );
        _logBuffer
          ..clear()
          ..write(kept);
      }
      try {
        _logSink?.write(chunk);
      } catch (_) {}
    }

    process.stdout.transform(utf8.decoder).listen(appendChunk, onError: (_) {});
    process.stderr.transform(utf8.decoder).listen(appendChunk, onError: (_) {});
    unawaited(
      process.exitCode.then((code) {
        _lastExitCode = code;
        if (identical(_process, process)) {
          _process = null;
          _processExited = true;
        }
        _closeLogSink();
      }),
    );
  }

  void _closeLogSink() {
    final sink = _logSink;
    _logSink = null;
    try {
      sink?.close();
    } catch (_) {}
  }

  /// 进程已退出/健康检查超时时，lastError 后面拼的诊断尾巴：
  /// 退出码 + 进程日志尾巴（有就拼，没有就空串）。
  String _exitDetail() {
    final parts = <String>[];
    if (_lastExitCode != null) parts.add('退出码 $_lastExitCode');
    final tail = lastLogTail.trim();
    if (tail.isNotEmpty) parts.add('进程日志：$tail');
    if (parts.isEmpty) return '';
    return '（${parts.join('；')}）';
  }

  /// 授权：三档试 chmod（绝对路径优先，容器里 PATH 未必含 chmod），
  /// 每档成功后验执行位；执行位加上即回 null。全部试完执行位仍
  /// 没加上时回备注（不抛错、不拦启动：链接器兜底不需要执行位，
  /// 备注拼进启动失败信息里）。
  Future<String?> _ensureExecutable(String binaryPath) async {
    const attempts = [
      (_chmodPath, '755'),
      ('chmod', '755'),
      (_chmodPath, '777'),
    ];
    for (final attempt in attempts) {
      try {
        final result = await _chmodRunner(attempt.$1, [attempt.$2, binaryPath]);
        if (result.exitCode != 0) continue;
      } catch (_) {
        continue;
      }
      if (_isExecutableChecker(binaryPath)) return null;
    }
    if (_isExecutableChecker(binaryPath)) return null;
    final mode = await _fileModeOctal(binaryPath);
    return '二进制文件未含执行位（mode $mode），已尝试链接器兜底启动';
  }

  Future<String> _fileModeOctal(String path) async {
    try {
      final stat = await File(path).stat();
      return (stat.mode & 0x1FF).toRadixString(8).padLeft(3, '0');
    } catch (_) {
      return '未知';
    }
  }

  /// 二进制落盘：应用私有目录 tgdrama/tgdrama-android；已存在且 MD5
  /// 对得上复用，对不上重拷自愈（同 jar_bridge 的 resolveBuiltinJarAsset）。
  Future<String> _resolveBinary() async {
    final supportDir = await _supportDirProvider();
    final dir = Directory('${supportDir.path}/$_binaryDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = File('${dir.path}/$_binaryFileName');
    if (await target.exists()) {
      try {
        final current = md5.convert(await target.readAsBytes()).toString();
        if (current == binaryMd5) return target.path;
      } catch (_) {
        // 读不到或算不出 MD5：当作损坏，重拷。
      }
    }
    final bytes = await _assetLoader(binaryAssetPath);
    await target.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    return target.path;
  }

  /// 预置会话与凭证（首次启动，best-effort，失败不拦插件启动）。
  ///
  /// ①会话：插件数据目录下还没有 session.json 时，把安装包里带的
  /// 预置 session.json（assets/tgdrama_session.json，构建期由用户
  /// 自己的 Telethon 会话转换生成）写进去，插件一启动就是已登录。
  /// 已有 session.json（用户已扫码/输手机号登过）绝不覆盖。
  /// ②凭证：config.yaml 缺失或无 api_id/api_hash 时，用构建期注入的
  /// 凭证写一份（见 TgdramaCredentials）。
  /// 会话文件只写进应用私有目录，不打印、不记日志。
  Future<void> _seedSessionAndConfig(Directory tgdramaDir) async {
    try {
      final sessionFile = File('${tgdramaDir.path}/session.json');
      if (!await sessionFile.exists()) {
        try {
          final bytes = await _assetLoader(sessionAssetPath);
          final raw = bytes.buffer.asUint8List(
            bytes.offsetInBytes,
            bytes.lengthInBytes,
          );
          if (_looksLikeSession(raw)) {
            await sessionFile.writeAsBytes(raw, flush: true);
          }
        } catch (_) {
          // 包里没打预置会话（构建期未生成）：跳过，登录页仍可扫码重登。
        }
      }
    } catch (_) {}
    try {
      await TgdramaCredentials.ensureConfigYaml(tgdramaDir);
    } catch (_) {}
  }

  bool _looksLikeSession(List<int> raw) {
    try {
      final decoded = jsonDecode(utf8.decode(raw));
      if (decoded is! Map<String, dynamic>) return false;
      if (decoded['Version'] != 1) return false;
      final data = decoded['Data'];
      if (data is! Map<String, dynamic>) return false;
      final authKey = data['AuthKey'];
      return authKey is String && authKey.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
