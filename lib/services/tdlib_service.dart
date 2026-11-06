import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'tgdrama_credentials.dart';

/// TDLib 登录状态（照 TeleTV 的 AuthState，Dart 侧对一份；手机号登录加状态）。
enum TdlibAuthStatus {
  initializing,
  waitPhoneNumber,
  showQr,
  waitCode,
  waitPassword,
  waitRegistration,
  ready,
  error,
  signingOut,
  loggedOut,
}

/// 一次登录状态快照：状态 + 该状态下要显示的东西（二维码/密码提示/报错）。
class TdlibAuthState {
  const TdlibAuthState({
    required this.status,
    this.link,
    this.qrPngBytes,
    this.phoneNumber,
    this.timeout,
    this.hint,
    this.error,
    this.checking = false,
  });

  final TdlibAuthStatus status;
  final String? link;
  final Uint8List? qrPngBytes;
  final String? phoneNumber;
  final int? timeout;
  final String? hint;
  final String? error;
  final bool checking;

  bool get isReady => status == TdlibAuthStatus.ready;

  factory TdlibAuthState.fromMap(Map<dynamic, dynamic> map) {
    final rawStatus = map['state'] as String? ?? 'initializing';
    final status = TdlibAuthStatus.values.firstWhere(
      (value) => value.name == rawStatus,
      orElse: () => TdlibAuthStatus.initializing,
    );
    Uint8List? qrBytes;
    final qrBase64 = map['qrPngBase64'] as String?;
    if (qrBase64 != null && qrBase64.isNotEmpty) {
      try {
        qrBytes = base64Decode(qrBase64);
      } catch (_) {
        qrBytes = null;
      }
    }
    return TdlibAuthState(
      status: status,
      link: map['link'] as String?,
      qrPngBytes: qrBytes,
      phoneNumber: map['phoneNumber'] as String?,
      timeout: (map['timeout'] as num?)?.toInt(),
      hint: map['hint'] as String?,
      error: map['message'] as String? ?? map['error'] as String?,
      checking: map['checking'] as bool? ?? false,
    );
  }

  static const initializing =
      TdlibAuthState(status: TdlibAuthStatus.initializing);
}

/// TDLib `getMe` 回来的当前用户（给“我的”页显示名字用）。
class TdlibUser {
  const TdlibUser({
    required this.id,
    required this.firstName,
    required this.lastName,
    this.username,
    this.phoneNumber,
  });

  final int id;
  final String firstName;
  final String lastName;
  final String? username;
  final String? phoneNumber;

  /// 显示名：名 + 姓，空时退回 @用户名，再空退回“已登录”。
  String get displayName {
    final name = '$firstName $lastName'.trim();
    if (name.isNotEmpty) return name;
    if (username != null && username!.isNotEmpty) return '@$username';
    return '已登录';
  }

  factory TdlibUser.fromMap(Map<dynamic, dynamic> map) {
    return TdlibUser(
      id: (map['id'] as num?)?.toInt() ?? 0,
      firstName: map['firstName'] as String? ?? '',
      lastName: map['lastName'] as String? ?? '',
      username: map['username'] as String?,
      phoneNumber: map['phoneNumber'] as String?,
    );
  }
}

/// TDLib 登录服务：Dart 门面，对着 `fqapp/tdlib` MethodChannel 与
/// `fqapp/tdlib/events` EventChannel。
///
/// 登录态存在 TDLib 自己的数据库目录
/// （`getApplicationSupportDirectory()/tdlib`），不用 session.json；
/// 凭证从 [TgdramaCredentials] 的构建期注入取，经 MethodChannel 传给
/// Kotlin，不写死、不打印、不进 git。
class TdlibService {
  TdlibService({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    Future<Directory> Function()? supportDirProvider,
  })  : _methodChannel =
            methodChannel ?? const MethodChannel('fqapp/tdlib'),
        _eventChannel =
            eventChannel ?? const EventChannel('fqapp/tdlib/events'),
        _supportDirProvider =
            supportDirProvider ?? getApplicationSupportDirectory;

  static final TdlibService instance = TdlibService();

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final Future<Directory> Function() _supportDirProvider;

  Stream<TdlibAuthState>? _stateStream;
  TdlibAuthState _lastState = TdlibAuthState.initializing;
  bool _initialized = false;

  /// 最近一次收到的登录状态（初始化前为 initializing）。
  TdlibAuthState get lastState => _lastState;

  /// 登录状态流（Initializing/WaitPhoneNumber/ShowQr/WaitCode/
  /// WaitPassword/WaitRegistration/Ready/Error/LoggedOut）。
  /// 订阅即开始收 Kotlin 侧推的状态变化。
  Stream<TdlibAuthState> get stateStream {
    _stateStream ??= _eventChannel
        .receiveBroadcastStream()
        .map((event) => _stateFromEvent(event))
        .handleError(
          (Object e) => TdlibAuthState(
            status: TdlibAuthStatus.error,
            error: e.toString(),
          ),
        );
    return _stateStream!;
  }

  TdlibAuthState _stateFromEvent(Object? event) {
    if (event is Map) {
      _lastState = TdlibAuthState.fromMap(event);
      return _lastState;
    }
    return _lastState;
  }

  /// 初始化 TDLib 并开始登录状态机。已初始化时直接回当前状态；
  /// 上次已退出时重建客户端再开始。凭证未注入时抛 [StateError]（调用方如实报不可用）。
  Future<TdlibAuthState> initialize() async {
    if (_initialized) {
      if (_lastState.status == TdlibAuthStatus.loggedOut) {
        return restart();
      }
      return getState();
    }
    if (!TgdramaCredentials.hasCredentials) {
      throw StateError('缺少 Telegram 凭证，TDLib 扫码登录不可用');
    }
    final apiId = int.tryParse(TgdramaCredentials.apiId);
    if (apiId == null || apiId == 0) {
      throw StateError('缺少 Telegram 凭证，TDLib 扫码登录不可用');
    }
    final supportDir = await _supportDirProvider();
    final databaseDir = Directory('${supportDir.path}/tdlib');
    final filesDir = Directory('${supportDir.path}/tdlib-files');
    final raw = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'initialize',
      <String, dynamic>{
        'apiId': apiId,
        'apiHash': TgdramaCredentials.apiHash,
        'databaseDir': databaseDir.path,
        'filesDir': filesDir.path,
        'applicationVersion': '1.0.0',
      },
    );
    _initialized = true;
    if (raw != null) _lastState = TdlibAuthState.fromMap(raw);
    return _lastState;
  }

  /// 取当前登录状态（不推流，只问一次）。
  Future<TdlibAuthState> getState() async {
    final raw = await _methodChannel
        .invokeMethod<Map<dynamic, dynamic>>('getState');
    if (raw != null) _lastState = TdlibAuthState.fromMap(raw);
    return _lastState;
  }

  /// 关掉旧客户端、按上次初始化的参数重建一个（换手机号、退出后重登用）。
  /// 没初始化过时抛 [StateError]。
  Future<TdlibAuthState> restart() async {
    final raw = await _methodChannel
        .invokeMethod<Map<dynamic, dynamic>>('restart');
    _initialized = true;
    if (raw != null) _lastState = TdlibAuthState.fromMap(raw);
    return _lastState;
  }

  /// 手机号登录（主路）：发短信验证码。返回 'sent'（新发）或
  /// 'resent'（已在等码，重发到原号码）。号码格式等问题抛 [PlatformException]。
  Future<String> sendPhoneCode(String phone) async {
    final raw = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'sendPhoneCode',
      <String, dynamic>{'phone': phone},
    );
    return (raw?['action'] as String?) ?? 'sent';
  }

  /// 提交短信验证码。成功后状态机经事件流走到 Ready（或二步验证）；
  /// 码错/过期时状态机重发带错误的 WaitCode。
  Future<void> checkCode(String code) async {
    await _methodChannel.invokeMethod<void>(
      'checkCode',
      <String, dynamic>{'code': code},
    );
  }

  /// 验证码重发一遍（只能在等验证码时调）。
  Future<void> resendCode() async {
    await _methodChannel.invokeMethod<void>('resendCode');
  }

  /// 未注册的手机号填名字完成注册。
  Future<void> register({
    required String firstName,
    String lastName = '',
  }) async {
    await _methodChannel.invokeMethod<void>(
      'register',
      <String, dynamic>{'firstName': firstName, 'lastName': lastName},
    );
  }

  /// 重新要二维码（只在等登录方式或等二步验证密码时有效；正在显示
  /// 二维码时链接由 TDLib 自动刷新，直接回当前状态）。
  Future<TdlibAuthState> requestQrCode() async {
    final raw = await _methodChannel
        .invokeMethod<Map<dynamic, dynamic>>('requestQrCode');
    if (raw != null) _lastState = TdlibAuthState.fromMap(raw);
    return _lastState;
  }

  /// 提交二步验证密码。成功后状态机经事件流走到 Ready；
  /// 密码错时状态机重发带错误的 WaitPassword。
  Future<void> submitPassword(String password) async {
    await _methodChannel.invokeMethod<void>(
      'submitPassword',
      <String, dynamic>{'password': password},
    );
  }

  /// 退出登录：TDLib 清掉自己的本地数据库，状态机走 SigningOut -> LoggedOut。
  Future<void> logOut() async {
    await _methodChannel.invokeMethod<void>('logOut');
  }

  /// 取当前用户（名字/用户名）。未登录时抛 [PlatformException]。
  Future<TdlibUser> getMe() async {
    final raw = await _methodChannel
        .invokeMethod<Map<dynamic, dynamic>>('getMe');
    if (raw == null) throw StateError('取当前用户失败');
    return TdlibUser.fromMap(raw);
  }
}
