import 'dart:async';

import 'package:flutter/material.dart';

import '../services/tgdrama_phone_login.dart';
import '../services/tgdrama_service.dart';

/// 设置 → Telegram 登录：TG影视库的登录页，两种方式并列。
///
/// ①扫码登录：走插件原生接口（开始扫码 → 二维码图 → 每 2 秒轮询状态）。
/// ②手机号登录：插件里没有这个接口，靠 Go 助手程序走 MTProto
/// （见 [TgdramaPhoneLoginService]）；助手或凭证缺失时如实报错，不假装发码。
///
/// 验证码与二步验证密码一律用弹窗输入（照官方 Telegram 登录的样子），
/// 页面里不放验证码/密码输入框，只留按钮与状态。弹窗能取消：
/// 取消即停掉当前这步、回登录页状态；输错码/密码时错误显示在弹窗里，
/// 可重输，不闪退。
class TgdramaLoginPage extends StatefulWidget {
  const TgdramaLoginPage({super.key, this.service, this.phoneLoginService});

  /// 供测试注入的假服务；不传时用单例。
  final TgdramaService? service;

  /// 供测试注入的假手机号登录服务；不传时新建默认实例。
  final TgdramaPhoneLoginService? phoneLoginService;

  @override
  State<TgdramaLoginPage> createState() => _TgdramaLoginPageState();
}

class _TgdramaLoginPageState extends State<TgdramaLoginPage> {
  TgdramaService get _service => widget.service ?? TgdramaService.instance;
  TgdramaPhoneLoginService get _phoneLogin =>
      widget.phoneLoginService ?? TgdramaPhoneLoginService();

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
