import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/tdlib_service.dart';
import '../services/tgdrama_phone_login.dart';
import '../services/tgdrama_service.dart';

/// 设置 → Telegram 登录：TG影视库的登录页，三种方式并列。
///
/// ①扫码登录：走插件原生接口（开始扫码 → 二维码图 → 每 2 秒轮询状态）。
/// ②手机号登录：插件里没有这个接口，靠 Go 助手程序走 MTProto
/// （见 [TgdramaPhoneLoginService]）；助手或凭证缺失时如实报错，不假装发码。
/// ③TDLib 应用内登录：不走插件进程，TDLib 直接在应用里登录
/// （见 [TdlibService]）。手机号是主路（用户只有一个手机，扫不了码），
/// 扫码留着备用；首次用要重新登录一次（插件的预置会话转不过来），
/// 登录态存在 TDLib 自己的数据库目录，重启不用重登。
///
/// 验证码与二步验证密码一律用弹窗输入（照官方 Telegram 登录的样子），
/// 页面里不放验证码/密码输入框，只留按钮与状态。弹窗能取消：
/// 取消即停掉当前这步、回登录页状态；输错码/密码时错误显示在弹窗里，
/// 可重输，不闪退。
class TgdramaLoginPage extends StatefulWidget {
  const TgdramaLoginPage({
    super.key,
    this.service,
    this.phoneLoginService,
    this.tdlibService,
  });

  /// 供测试注入的假服务；不传时用单例。
  final TgdramaService? service;

  /// 供测试注入的假手机号登录服务；不传时新建默认实例。
  final TgdramaPhoneLoginService? phoneLoginService;

  /// 供测试注入的假 TDLib 服务；不传时用单例。
  final TdlibService? tdlibService;

  @override
  State<TgdramaLoginPage> createState() => _TgdramaLoginPageState();
}

class _TgdramaLoginPageState extends State<TgdramaLoginPage> {
  TgdramaService get _service => widget.service ?? TgdramaService.instance;
  TgdramaPhoneLoginService get _phoneLogin =>
      widget.phoneLoginService ?? TgdramaPhoneLoginService();
  TdlibService get _tdlib => widget.tdlibService ?? TdlibService.instance;

  final _phoneController = TextEditingController();

  bool _starting = true;
  bool _serviceRunning = false;
  bool _authorized = false;
  bool _loginSuccess = false;
  String? _statusError;

  // 扫码登录
  bool _qrActive = false;
  bool _qrBusy = false;
  String? _qrError;
  int _qrTimestamp = 0;
  Timer? _pollTimer;
  int _pollCount = 0;
  bool _passwordDialogOpen = false;

  // 手机号登录
  PhoneLoginAvailability? _phoneAvailability;
  bool _phoneBusy = false;
  String? _phoneMessage;
  bool _codeSent = false;

  // TDLib 应用内登录（与插件路并列，懒启动：点按钮才碰通道，
  // 页面打开时不初始化，避免影响原有两路的测试与状态）。
  // 手机号是主路（用户只有一个手机，扫不了码），扫码是备用。
  StreamSubscription<TdlibAuthState>? _tdlibSubscription;
  TdlibAuthState? _tdlibState;
  bool _tdlibBusy = false;
  String? _tdlibError;
  String? _tdlibUserName;
  bool _tdlibLoggedIn = false;
  final _tdlibPhoneController = TextEditingController();
  bool _tdlibPhoneBusy = false;
  bool _tdlibCodeSent = false;
  String? _tdlibCodePhone;
  bool _tdlibCodeDialogOpen = false;
  final _tdlibCodeState = ValueNotifier<TdlibAuthState?>(null);
  bool _tdlibRegisterDialogOpen = false;
  final _tdlibQrBytes = ValueNotifier<Uint8List?>(null);
  bool _tdlibQrDialogOpen = false;
  bool _tdlibQrDismissed = false;
  bool _tdlibPasswordDialogOpen = false;
  final _tdlibPasswordState = ValueNotifier<TdlibAuthState?>(null);

  static const _pollInterval = Duration(seconds: 2);
  static const _maxPolls = 150; // 2 秒一次，最多 5 分钟

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    _refreshPhoneAvailability();
  }

  @override
  void dispose() {
    _stopPolling();
    _tdlibSubscription?.cancel();
    _tdlibPhoneController.dispose();
    _tdlibCodeState.dispose();
    _tdlibQrBytes.dispose();
    _tdlibPasswordState.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    setState(() {
      _starting = true;
      _statusError = null;
    });
    final running = await _service.ensureRunning();
    if (!mounted) return;
    if (!running) {
      setState(() {
        _starting = false;
        _serviceRunning = false;
        _statusError = _service.lastError ?? '本地服务未启动';
      });
      return;
    }
    final status = await _service.authStatus();
    if (!mounted) return;
    setState(() {
      _starting = false;
      _serviceRunning = true;
      _authorized = status.authorized;
      _statusError = null;
    });
  }

  Future<void> _refreshPhoneAvailability() async {
    final availability = await _phoneLogin.checkAvailability();
    if (!mounted) return;
    setState(() => _phoneAvailability = availability);
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _startQr() async {
    setState(() {
      _qrBusy = true;
      _qrError = null;
      _loginSuccess = false;
    });
    try {
      await _service.startQrLogin();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _qrBusy = false;
        _qrError = _plainError(e);
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _qrBusy = false;
      _qrActive = true;
      _qrTimestamp = DateTime.now().millisecondsSinceEpoch;
      _pollCount = 0;
    });
    _startPolling();
  }

  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollOnce());
  }

  Future<void> _pollOnce() async {
    if (!mounted || !_qrActive) return;
    _pollCount++;
    if (_pollCount > _maxPolls) {
      _stopPolling();
      if (!mounted) return;
      setState(() {
        _qrActive = false;
        _qrError = '扫码已超时（5 分钟），请点“重新生成”再扫一次';
      });
      return;
    }
    TgdramaAuthStatus status;
    try {
      status = await _service.authStatus();
    } catch (e) {
      _stopPolling();
      if (!mounted) return;
      setState(() {
        _qrActive = false;
        _qrError = '轮询登录状态出错：${_plainError(e)}';
      });
      return;
    }
    if (!mounted || !_qrActive) return;
    if (status.authorized) {
      _stopPolling();
      setState(() {
        _qrActive = false;
        _authorized = true;
        _loginSuccess = true;
        _qrError = null;
      });
      return;
    }
    if (status.needPassword && !_passwordDialogOpen) {
      _showPasswordDialog(forQr: true);
    }
  }

  void _cancelQr() {
    _stopPolling();
    setState(() {
      _qrActive = false;
      _qrError = null;
    });
  }

  /// 二步验证密码弹窗（扫码登录与手机号登录共用）。
  /// 取消：停掉当前这步（扫码时同时停轮询）、回登录页状态。
  /// 密码错：在弹窗里显示错误，可重输。
  Future<void> _showPasswordDialog({required bool forQr, String? phoneCode}) async {
    if (_passwordDialogOpen) return;
    _passwordDialogOpen = true;
    final controller = TextEditingController();
    var dialogError = '';
    var submitting = false;
    try {
      final submitted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('二步验证'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('该账号开启了二步验证，请输入 Telegram 二步验证密码。'),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('tgdrama_password_field'),
                  controller: controller,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: '二步验证密码',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) {
                    if (!submitting) {
                      _submitPasswordFromDialog(
                        dialogContext,
                        controller.text,
                        forQr: forQr,
                        phoneCode: phoneCode,
                        setDialogState: setDialogState,
                        setError: (value) => dialogError = value,
                        setSubmitting: (value) => submitting = value,
                      );
                    }
                  },
                ),
                if (dialogError.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    dialogError,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  // 取消即停掉当前这步：扫码时停轮询，手机号时不再继续登录。
                  if (forQr) _cancelQr();
                  Navigator.of(dialogContext).pop(false);
                },
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: submitting
                    ? null
                    : () => _submitPasswordFromDialog(
                          dialogContext,
                          controller.text,
                          forQr: forQr,
                          phoneCode: phoneCode,
                          setDialogState: setDialogState,
                          setError: (value) => dialogError = value,
                          setSubmitting: (value) => submitting = value,
                        ),
                child: const Text('提交'),
              ),
            ],
          ),
        ),
      );
      if (submitted == true && mounted) {
        if (forQr) {
          // 密码已交，继续轮询等服务端确认。
          if (_qrActive) _startPolling();
        } else {
          await _refreshStatus();
        }
      }
    } finally {
      _passwordDialogOpen = false;
      controller.dispose();
    }
  }

  Future<void> _submitPasswordFromDialog(
    BuildContext dialogContext,
    String password, {
    required bool forQr,
    String? phoneCode,
    required void Function(void Function()) setDialogState,
    required void Function(String value) setError,
    required void Function(bool value) setSubmitting,
  }) async {
    if (password.isEmpty) {
      setDialogState(() => setError('请先输入二步验证密码'));
      return;
    }
    setDialogState(() {
      setSubmitting(true);
      setError('');
    });
    try {
      if (forQr) {
        await _service.submitPassword(password);
      } else {
        await _phoneLogin.verifyCode(
          phone: _phoneController.text,
          code: phoneCode ?? '',
          password: password,
        );
      }
    } catch (e) {
      if (!dialogContext.mounted) return;
      setDialogState(() {
        setSubmitting(false);
        setError(_plainError(e));
      });
      return;
    }
    if (!dialogContext.mounted) return;
    Navigator.of(dialogContext).pop(true);
  }

  /// 手机号登录：点“发送验证码”。成功后弹验证码输入框
  /// （照官方 Telegram 登录的样子）；失败在页内原样显示原因。
  Future<void> _sendPhoneCode() async {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) {
      setState(() => _phoneMessage = '请先输入手机号');
      return;
    }
    setState(() {
      _phoneBusy = true;
      _phoneMessage = null;
    });
    try {
      await _phoneLogin.sendCode(phone);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phoneBusy = false;
        _phoneMessage = _plainError(e);
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _phoneBusy = false;
      _codeSent = true;
      _phoneMessage = '验证码已发送到 $phone，请在弹窗里输入';
    });
    await _showCodeDialog();
  }

  /// 短信验证码弹窗（照官方 Telegram 登录的样子）：
  /// 弹窗里输码、确认/取消；输错在弹窗里显示错误，可重输；
  /// 需要二步验证时关掉本框、改弹密码框。
  Future<void> _showCodeDialog() async {
    final controller = TextEditingController();
    var dialogError = '';
    var submitting = false;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('输入验证码'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('验证码已发送到 ${_phoneController.text.trim()}，请在下方输入。'),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('tgdrama_code_field'),
                  controller: controller,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: '短信验证码',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) {
                    if (!submitting) {
                      _submitCodeFromDialog(
                        dialogContext,
                        controller.text,
                        setDialogState: setDialogState,
                        setError: (value) => dialogError = value,
                        setSubmitting: (value) => submitting = value,
                      );
                    }
                  },
                ),
                if (dialogError.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    dialogError,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: submitting
                    ? null
                    : () => _submitCodeFromDialog(
                          dialogContext,
                          controller.text,
                          setDialogState: setDialogState,
                          setError: (value) => dialogError = value,
                          setSubmitting: (value) => submitting = value,
                        ),
                child: const Text('登录'),
              ),
            ],
          ),
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _submitCodeFromDialog(
    BuildContext dialogContext,
    String code, {
    required void Function(void Function()) setDialogState,
    required void Function(String value) setError,
    required void Function(bool value) setSubmitting,
  }) async {
    if (code.trim().isEmpty) {
      setDialogState(() => setError('请先输入短信验证码'));
      return;
    }
    setDialogState(() {
      setSubmitting(true);
      setError('');
    });
    try {
      await _phoneLogin.verifyCode(
        phone: _phoneController.text,
        code: code,
      );
    } catch (e) {
      final message = _plainError(e);
      if (!dialogContext.mounted) return;
      if (_looksLikePasswordNeeded(message)) {
        // 需要二步验证：关掉验证码框，改弹密码框。
        Navigator.of(dialogContext).pop();
        await _showPasswordDialog(forQr: false, phoneCode: code);
        return;
      }
      setDialogState(() {
        setSubmitting(false);
        setError(message);
      });
      return;
    }
    if (!dialogContext.mounted) return;
    Navigator.of(dialogContext).pop();
    if (!mounted) return;
    setState(() {
      _phoneMessage = null;
      _loginSuccess = true;
    });
    await _refreshStatus();
  }

  bool _looksLikePasswordNeeded(String message) {
    final lower = message.toLowerCase();
    return message.contains('二步') ||
        lower.contains('password') ||
        lower.contains('session_password_needed') ||
        lower.contains('2fa');
  }

  String _plainError(Object e) {
    if (e is StateError) return e.message;
    return e.toString();
  }

  // ---------- TDLib 应用内登录（手机号主路，扫码备用） ----------

  /// 初始化 TDLib（凭证走构建期注入，登录态走 TDLib 自己的数据库目录），
  /// 订阅状态流。已登录过时状态机直接到 Ready，不用再登录；
  /// 上次已退出时重建客户端再开始。
  Future<TdlibAuthState?> _ensureTdlibStarted() async {
    _tdlibSubscription ??= _tdlib.stateStream.listen(
      _onTdlibState,
      onError: (Object e) {
        if (!mounted) return;
        setState(() => _tdlibError = _plainError(e));
      },
    );
    try {
      final state = await _tdlib.initialize();
      if (!mounted) return null;
      _onTdlibState(state);
      return state;
    } catch (e) {
      if (!mounted) return null;
      setState(() => _tdlibError = _plainError(e));
      return null;
    }
  }

  /// 手机号登录（主路）：输手机号 → 收短信验证码 → 弹窗输码 → 登上。
  /// 号码只拼 +86 前缀发给 TDLib（TDLib 要国际格式）。
  Future<void> _sendTdlibCode() async {
    final phone = _tdlibPhoneController.text.trim();
    if (phone.isEmpty) {
      setState(() => _tdlibError = '请先输入手机号');
      return;
    }
    if (_tdlibPhoneBusy) return;
    setState(() {
      _tdlibPhoneBusy = true;
      _tdlibError = null;
    });
    final started = await _ensureTdlibStarted();
    if (started == null) {
      if (mounted) setState(() => _tdlibPhoneBusy = false);
      return;
    }
    try {
      final action = await _tdlib.sendPhoneCode('+86$phone');
      if (!mounted) return;
      setState(() {
        _tdlibPhoneBusy = false;
        _tdlibCodeSent = true;
        _tdlibCodePhone = '+86$phone';
        if (action == 'resent') {
          _tdlibError = '验证码已重新发送到原号码（换号请点“换个手机号”）';
        }
      });
      // 等码状态经事件流推过来，码框自动弹。
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tdlibPhoneBusy = false;
        _tdlibError = _plainError(e);
      });
    }
  }

  /// 换个手机号：重建 TDLib 客户端回到等登录方式，清空已发码状态。
  /// （等码时 TDLib 只认原号码，重建是唯一换号办法；登录前重建不丢东西。）
  Future<void> _changeTdlibPhone() async {
    setState(() {
      _tdlibCodeSent = false;
      _tdlibCodePhone = null;
      _tdlibError = null;
    });
    try {
      await _tdlib.restart();
    } catch (e) {
      if (!mounted) return;
      setState(() => _tdlibError = _plainError(e));
    }
  }

  /// 扫码登录（备用）：初始化后明确要二维码。
  Future<void> _startTdlibQr() async {
    if (_tdlibBusy) return;
    setState(() {
      _tdlibBusy = true;
      _tdlibError = null;
      _tdlibQrDismissed = false;
    });
    final started = await _ensureTdlibStarted();
    if (started == null) {
      if (mounted) setState(() => _tdlibBusy = false);
      return;
    }
    try {
      await _tdlib.requestQrCode();
    } catch (e) {
      if (!mounted) return;
      setState(() => _tdlibError = _plainError(e));
    }
    if (!mounted) return;
    setState(() => _tdlibBusy = false);
  }

  void _onTdlibState(TdlibAuthState state) {
    if (!mounted) return;
    setState(() => _tdlibState = state);
    switch (state.status) {
      case TdlibAuthStatus.waitPhoneNumber:
        break;
      case TdlibAuthStatus.showQr:
        _tdlibQrBytes.value = state.qrPngBytes;
        if (!_tdlibQrDismissed && !_tdlibQrDialogOpen) {
          _showTdlibQrDialog();
        }
      case TdlibAuthStatus.waitCode:
        _closeTdlibQrDialog();
        _tdlibCodeState.value = state;
        if (state.phoneNumber != null) _tdlibCodePhone = state.phoneNumber;
        if (!_tdlibCodeDialogOpen) _showTdlibCodeDialog();
      case TdlibAuthStatus.waitPassword:
        _closeTdlibQrDialog();
        _closeTdlibCodeDialog();
        _tdlibPasswordState.value = state;
        if (!_tdlibPasswordDialogOpen) _showTdlibPasswordDialog(state);
      case TdlibAuthStatus.waitRegistration:
        _closeTdlibQrDialog();
        _closeTdlibCodeDialog();
        if (!_tdlibRegisterDialogOpen) _showTdlibRegisterDialog();
      case TdlibAuthStatus.ready:
        _closeTdlibQrDialog();
        _closeTdlibCodeDialog();
        _closeTdlibPasswordDialog();
        _closeTdlibRegisterDialog();
        _loadTdlibUser();
      case TdlibAuthStatus.error:
        _closeTdlibQrDialog();
        _closeTdlibCodeDialog();
        _closeTdlibPasswordDialog();
        _closeTdlibRegisterDialog();
        setState(() => _tdlibError = state.error ?? 'TDLib 登录失败');
      case TdlibAuthStatus.loggedOut:
        _closeTdlibQrDialog();
        _closeTdlibCodeDialog();
        _closeTdlibPasswordDialog();
        _closeTdlibRegisterDialog();
        setState(() {
          _tdlibLoggedIn = false;
          _tdlibUserName = null;
          _tdlibQrBytes.value = null;
          _tdlibCodeSent = false;
          _tdlibCodePhone = null;
        });
      case TdlibAuthStatus.initializing:
      case TdlibAuthStatus.signingOut:
        break;
    }
  }

  Future<void> _loadTdlibUser() async {
    try {
      final user = await _tdlib.getMe();
      if (!mounted) return;
      setState(() {
        _tdlibLoggedIn = true;
        _tdlibUserName = user.displayName;
        _tdlibError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tdlibLoggedIn = true;
        _tdlibUserName = null;
        _tdlibError = null;
      });
    }
  }

  /// TDLib 二维码弹窗大图（260）：码由 Kotlin 侧 ZXing 生成，
  /// 链接刷新时图跟着换；点取消只关弹窗，登录流程本身不停。
  Future<void> _showTdlibQrDialog() async {
    if (_tdlibQrDialogOpen) return;
    _tdlibQrDialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('扫码登录（TDLib）'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<Uint8List?>(
                valueListenable: _tdlibQrBytes,
                builder: (context, bytes, _) {
                  if (bytes == null) {
                    return const SizedBox(
                      width: 260,
                      height: 260,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  return Image.memory(
                    bytes,
                    width: 260,
                    height: 260,
                    errorBuilder: (context, error, stackTrace) =>
                        const SizedBox(
                      width: 260,
                      height: 260,
                      child: Center(child: Text('二维码加载失败，请点“重新生成”重试')),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              const Text('用手机 Telegram 扫码（设置 → 设备 → 关联桌面设备）。'),
              const SizedBox(height: 4),
              const Text('二维码过期会自动刷新，不用手动重生成。'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                _tdlibQrDismissed = true;
                Navigator.of(dialogContext).pop();
              },
              child: const Text('取消'),
            ),
          ],
        ),
      );
    } finally {
      _tdlibQrDialogOpen = false;
    }
  }

  void _closeTdlibQrDialog() {
    if (!_tdlibQrDialogOpen || !mounted) return;
    _tdlibQrDialogOpen = false;
    _tdlibQrDismissed = true;
    Navigator.of(context).pop();
  }

  /// 关 TDLib 密码弹窗（登录成功/失败时由状态流驱动；先改标志再 pop，
  /// 避免同一帧里两次关把页面也弹掉）。
  void _closeTdlibPasswordDialog() {
    if (!_tdlibPasswordDialogOpen || !mounted) return;
    _tdlibPasswordDialogOpen = false;
    Navigator.of(context).pop();
  }

  void _closeTdlibCodeDialog() {
    if (!_tdlibCodeDialogOpen || !mounted) return;
    _tdlibCodeDialogOpen = false;
    Navigator.of(context).pop();
  }

  void _closeTdlibRegisterDialog() {
    if (!_tdlibRegisterDialogOpen || !mounted) return;
    _tdlibRegisterDialogOpen = false;
    Navigator.of(context).pop();
  }

  /// TDLib 短信验证码弹窗（照官方 Telegram 登录的样子，码框只在弹窗里，
  /// 不埋页面）：输码登录；码错/过期时错误更新在弹窗里，可重输；
  /// 点“重新发送”重发一遍；取消回登录页状态。
  Future<void> _showTdlibCodeDialog() async {
    if (_tdlibCodeDialogOpen) return;
    _tdlibCodeDialogOpen = true;
    final controller = TextEditingController();
    var dialogError = '';
    var submitting = false;
    var resending = false;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('输入验证码'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _tdlibCodePhone == null
                      ? '验证码已发送到你的手机，请在下方输入。'
                      : '验证码已发送到 $_tdlibCodePhone，请在下方输入。',
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('tdlib_code_field'),
                  controller: controller,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: '短信验证码',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) {
                    if (!submitting) {
                      _submitTdlibCode(
                        dialogContext,
                        controller.text,
                        setDialogState: setDialogState,
                        setError: (value) => dialogError = value,
                        setSubmitting: (value) => submitting = value,
                      );
                    }
                  },
                ),
                ValueListenableBuilder<TdlibAuthState?>(
                  valueListenable: _tdlibCodeState,
                  builder: (context, codeState, _) {
                    final message = dialogError.isNotEmpty
                        ? dialogError
                        : (codeState?.error ?? '');
                    if (message.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        message,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: resending
                    ? null
                    : () async {
                        setDialogState(() => resending = true);
                        try {
                          await _tdlib.resendCode();
                        } catch (e) {
                          if (!dialogContext.mounted) return;
                          setDialogState(() {
                            resending = false;
                            dialogError = _plainError(e);
                          });
                          return;
                        }
                        if (!dialogContext.mounted) return;
                        setDialogState(() {
                          resending = false;
                          dialogError = '';
                        });
                      },
                child: Text(resending ? '发送中…' : '重新发送'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: submitting
                    ? null
                    : () => _submitTdlibCode(
                          dialogContext,
                          controller.text,
                          setDialogState: setDialogState,
                          setError: (value) => dialogError = value,
                          setSubmitting: (value) => submitting = value,
                        ),
                child: const Text('登录'),
              ),
            ],
          ),
        ),
      );
    } finally {
      _tdlibCodeDialogOpen = false;
      controller.dispose();
    }
  }

  Future<void> _submitTdlibCode(
    BuildContext dialogContext,
    String code, {
    required void Function(void Function()) setDialogState,
    required void Function(String value) setError,
    required void Function(bool value) setSubmitting,
  }) async {
    if (code.trim().isEmpty) {
      setDialogState(() => setError('请先输入短信验证码'));
      return;
    }
    setDialogState(() {
      setSubmitting(true);
      setError('');
    });
    try {
      await _tdlib.checkCode(code.trim());
    } catch (e) {
      if (!dialogContext.mounted) return;
      setDialogState(() {
        setSubmitting(false);
        setError(_plainError(e));
      });
      return;
    }
    // 提交成功不直接关弹窗：等状态流——码对了走到 Ready（二步验证时
    // 改弹密码框），码错了重发带错误的 WaitCode，错误更新在弹窗里。
    if (!dialogContext.mounted) return;
    setDialogState(() => setSubmitting(false));
  }

  /// 未注册的手机号：填名字完成注册（名必填，姓可空）。
  Future<void> _showTdlibRegisterDialog() async {
    if (_tdlibRegisterDialogOpen) return;
    _tdlibRegisterDialogOpen = true;
    final firstNameController = TextEditingController();
    final lastNameController = TextEditingController();
    var dialogError = '';
    var submitting = false;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('完善资料'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('该手机号还没注册过 Telegram，请填名字完成注册。'),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('tdlib_first_name_field'),
                  controller: firstNameController,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '名字',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('tdlib_last_name_field'),
                  controller: lastNameController,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: '姓氏（可选）',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (dialogError.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    dialogError,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: submitting
                    ? null
                    : () async {
                        final firstName = firstNameController.text.trim();
                        if (firstName.isEmpty) {
                          setDialogState(
                            () => dialogError = '请先输入名字',
                          );
                          return;
                        }
                        setDialogState(() {
                          submitting = true;
                          dialogError = '';
                        });
                        try {
                          await _tdlib.register(
                            firstName: firstName,
                            lastName: lastNameController.text.trim(),
                          );
                        } catch (e) {
                          if (!dialogContext.mounted) return;
                          setDialogState(() {
                            submitting = false;
                            dialogError = _plainError(e);
                          });
                          return;
                        }
                        // 注册完状态流走到 Ready 关弹窗；失败时状态流推错误。
                        if (!dialogContext.mounted) return;
                        setDialogState(() => submitting = false);
                      },
                child: const Text('完成注册'),
              ),
            ],
          ),
        ),
      );
    } finally {
      _tdlibRegisterDialogOpen = false;
      firstNameController.dispose();
      lastNameController.dispose();
    }
  }

  /// TDLib 二步验证密码弹窗（照官方 Telegram 登录的样子）：
  /// 取消回登录页状态；密码错时状态流重发带错误的 WaitPassword，
  /// 错误直接更新在弹窗里，可重输；密码对了状态流走到 Ready 关弹窗。
  Future<void> _showTdlibPasswordDialog(TdlibAuthState state) async {
    if (_tdlibPasswordDialogOpen) return;
    _tdlibPasswordDialogOpen = true;
    _tdlibPasswordState.value = state;
    final controller = TextEditingController();
    var dialogError = '';
    var submitting = state.checking;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('二步验证'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('该账号开启了二步验证，请输入 Telegram 二步验证密码。'),
                ValueListenableBuilder<TdlibAuthState?>(
                  valueListenable: _tdlibPasswordState,
                  builder: (context, passwordState, _) {
                    final hint = passwordState?.hint;
                    if (hint == null || hint.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('密码提示：$hint'),
                    );
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('tdlib_password_field'),
                  controller: controller,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: '二步验证密码',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) {
                    if (!submitting) {
                      _submitTdlibPassword(
                        dialogContext,
                        controller.text,
                        setDialogState: setDialogState,
                        setError: (value) => dialogError = value,
                        setSubmitting: (value) => submitting = value,
                      );
                    }
                  },
                ),
                ValueListenableBuilder<TdlibAuthState?>(
                  valueListenable: _tdlibPasswordState,
                  builder: (context, passwordState, _) {
                    final message = dialogError.isNotEmpty
                        ? dialogError
                        : (passwordState?.error ?? '');
                    if (message.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        message,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: submitting
                    ? null
                    : () => _submitTdlibPassword(
                          dialogContext,
                          controller.text,
                          setDialogState: setDialogState,
                          setError: (value) => dialogError = value,
                          setSubmitting: (value) => submitting = value,
                        ),
                child: const Text('提交'),
              ),
            ],
          ),
        ),
      );
    } finally {
      _tdlibPasswordDialogOpen = false;
      controller.dispose();
    }
  }

  Future<void> _submitTdlibPassword(
    BuildContext dialogContext,
    String password, {
    required void Function(void Function()) setDialogState,
    required void Function(String value) setError,
    required void Function(bool value) setSubmitting,
  }) async {
    if (password.isEmpty) {
      setDialogState(() => setError('请先输入二步验证密码'));
      return;
    }
    setDialogState(() {
      setSubmitting(true);
      setError('');
    });
    try {
      await _tdlib.submitPassword(password);
    } catch (e) {
      if (!dialogContext.mounted) return;
      setDialogState(() {
        setSubmitting(false);
        setError(_plainError(e));
      });
      return;
    }
    // 提交成功不直接关弹窗：等状态流——密码对了走到 Ready 关弹窗，
    // 密码错了重发带错误的 WaitPassword，错误更新在弹窗里。
    if (!dialogContext.mounted) return;
    setDialogState(() => setSubmitting(false));
  }

  Future<void> _tdlibLogOut() async {
    try {
      await _tdlib.logOut();
    } catch (e) {
      if (!mounted) return;
      setState(() => _tdlibError = _plainError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Telegram 登录')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildStatusCard(context),
          const SizedBox(height: 16),
          _buildQrSection(context),
          const SizedBox(height: 16),
          _buildTdlibSection(context),
          const SizedBox(height: 16),
          _buildPhoneSection(context),
        ],
      ),
    );
  }

  Widget _buildStatusCard(BuildContext context) {
    final theme = Theme.of(context);
    late final String title;
    late final String subtitle;
    late final IconData icon;
    if (_starting) {
      title = '正在检查本地服务…';
      subtitle = '';
      icon = Icons.hourglass_empty;
    } else if (!_serviceRunning) {
      title = '本地服务未启动';
      subtitle = _statusError ?? 'TG影视库本地服务未启动';
      icon = Icons.cloud_off;
    } else if (_authorized) {
      title = '已登录';
      subtitle = '登录态存在插件本地，重启不用重登';
      icon = Icons.check_circle;
    } else {
      title = '未登录';
      subtitle = '请用下面的扫码或手机号登录';
      icon = Icons.account_circle;
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                if (!_starting && !_serviceRunning)
                  TextButton(
                    onPressed: _refreshStatus,
                    child: const Text('重试'),
                  ),
              ],
            ),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(subtitle),
            ],
            if (_loginSuccess) ...[
              const SizedBox(height: 4),
              Text(
                '登录成功',
                style: TextStyle(color: theme.colorScheme.primary),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildQrSection(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('扫码登录', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('用手机 Telegram 扫码（设置 → 设备 → 关联桌面设备）。'),
            const SizedBox(height: 12),
            if (_qrActive) ...[
              Center(
                child: Image.network(
                  '${_service.qrImageUrl}?t=$_qrTimestamp',
                  width: 220,
                  height: 220,
                  errorBuilder: (context, error, stackTrace) => const SizedBox(
                    width: 220,
                    height: 220,
                    child: Center(
                      child: Text('二维码加载失败，请点“重新生成”重试'),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Center(child: Text('等待扫码…（最多 5 分钟）')),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: _cancelQr,
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: _qrBusy ? null : _startQr,
                    child: const Text('重新生成'),
                  ),
                ],
              ),
            ] else ...[
              FilledButton(
                onPressed: _qrBusy ? null : _startQr,
                child: Text(_qrBusy ? '正在开始…' : '开始扫码'),
              ),
            ],
            if (_qrError != null) ...[
              const SizedBox(height: 8),
              Text(
                _qrError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTdlibSection(BuildContext context) {
    final state = _tdlibState;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '手机号登录（TDLib 应用内）',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              '不走插件进程，应用内直接登录 Telegram。手机号是主路'
              '（一个手机扫不了码），扫码在下面备用。首次用要重新登录一次'
              '（插件的预置会话转不过来），登完重启不用重登。',
            ),
            const SizedBox(height: 12),
            if (_tdlibLoggedIn) ...[
              Row(
                children: [
                  const Icon(Icons.check_circle),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _tdlibUserName == null
                          ? 'TDLib 已登录'
                          : 'TDLib 已登录：$_tdlibUserName',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _tdlibLogOut,
                    child: const Text('退出登录'),
                  ),
                ],
              ),
            ] else ...[
              TextField(
                key: const ValueKey('tdlib_phone_field'),
                controller: _tdlibPhoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: '手机号',
                  prefixText: '+86 ',
                  hintText: '11 位手机号',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton(
                    onPressed: _tdlibPhoneBusy ? null : _sendTdlibCode,
                    child: Text(_tdlibPhoneBusy ? '发送中…' : '发送验证码（TDLib）'),
                  ),
                  if (_tdlibCodeSent) ...[
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: () => _showTdlibCodeDialog(),
                      child: const Text('输入验证码'),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: _changeTdlibPhone,
                      child: const Text('换个手机号'),
                    ),
                  ],
                ],
              ),
              if (_tdlibCodeSent && _tdlibCodePhone != null) ...[
                const SizedBox(height: 8),
                Text('验证码已发到 $_tdlibCodePhone，请在弹窗里输入。'),
              ],
              const SizedBox(height: 16),
              Text(
                '扫码登录（备用）',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (state?.status == TdlibAuthStatus.showQr) ...[
                const Text('二维码已在弹窗里打开，等待扫码…'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () {
                    _tdlibQrDismissed = false;
                    _showTdlibQrDialog();
                  },
                  child: const Text('查看二维码'),
                ),
              ] else if (state?.status == TdlibAuthStatus.waitPassword) ...[
                const Text('已扫码，该账号开了二步验证，请在弹窗里输入密码。'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => _showTdlibPasswordDialog(state!),
                  child: const Text('输入二步验证密码'),
                ),
              ] else ...[
                OutlinedButton(
                  onPressed: _tdlibBusy ? null : _startTdlibQr,
                  child: Text(_tdlibBusy ? '正在开始…' : '开始扫码（TDLib）'),
                ),
              ],
            ],
            if (_tdlibError != null) ...[
              const SizedBox(height: 8),
              Text(
                _tdlibError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPhoneSection(BuildContext context) {
    final availability = _phoneAvailability;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('手机号登录', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('输手机号收短信验证码登录。验证码与二步验证密码都在弹窗里输入。'),
            if (availability != null && !availability.available) ...[
              const SizedBox(height: 8),
              Text(
                availability.reason,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('tgdrama_phone_field'),
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: '手机号',
                prefixText: '+86 ',
                hintText: '11 位手机号',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  onPressed: _phoneBusy ? null : _sendPhoneCode,
                  child: Text(_phoneBusy ? '发送中…' : '发送验证码'),
                ),
                if (_codeSent) ...[
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: _showCodeDialog,
                    child: const Text('输入验证码'),
                  ),
                ],
              ],
            ),
            if (_phoneMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                _phoneMessage!,
                style: TextStyle(
                  color: _phoneMessage!.startsWith('验证码已发送')
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
