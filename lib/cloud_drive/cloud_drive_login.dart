/// 网盘登录共享层（修仙版）：对某一家网盘发起登录的统一入口，
/// 网盘页（cloud_drive_screen）与登入中心（红果账号页的网盘账号
/// 区）共用，不各写一套弹窗。
///
/// 包含：扫码登录弹窗、移动云盘短信登录弹窗、滑块验证内嵌页，
/// 以及三个共享动作——[startCloudDriveLogin]（按 provider 能力
/// 分发：移动云盘走短信、其余走扫码）、[startCloudDriveManualLogin]
/// （手动粘贴凭证）、[refreshCloudDriveCredentials]（移动云盘刷新）。
/// 登录成功统一落盘 + [CloudDriveStations.refresh] 刷新网盘站表；
/// 返回 true 表示已登录成功，失败/取消返回 false，失败原因由
/// 函数经 [onError] 回调交给调用方显示（不在这里弹 SnackBar，
/// 两个调用方的提示口径各自保留）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';

import 'cloud_credential_store.dart';
import 'cloud_drive_factory.dart';
import 'cloud_drive_stations.dart';
import 'cloud_provider_139.dart';
import 'cloud_providers.dart';
import 'qr_code_widget.dart';

/// 对某一家网盘发起登录：移动云盘走短信登录，其余走扫码登录。
/// 成功落盘并刷新站表后返回 true。
Future<bool> startCloudDriveLogin(
  BuildContext context, {
  required CloudDriveProvider provider,
  required http.Client client,
  required CloudCredentialStore store,
  void Function(String message)? onError,
}) async {
  CloudCredentials? credentials;
  if (provider is Yun139Provider) {
    credentials = await showDialog<CloudCredentials>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          CloudSmsLoginDialog(provider: provider, client: client),
    );
  } else {
    QrLoginSession session;
    try {
      session = await provider.startQrLogin(client);
    } catch (e) {
      onError?.call(cloudDriveErrorMessage(e, '获取二维码失败，请检查网络后重试'));
      return false;
    }
    if (!context.mounted) return false;
    credentials = await showDialog<CloudCredentials>(
      context: context,
      barrierDismissible: false,
      builder: (context) => CloudQrLoginDialog(
        provider: provider,
        session: session,
        client: client,
      ),
    );
  }
  if (credentials == null) return false;
  await store.save(provider.id, credentials);
  await CloudDriveStations.refresh(store);
  return true;
}

/// 手动粘贴凭证登录（扫码之外的兜底）：阿里粘 refresh_token
/// 换凭证，其余粘整串 Cookie。成功返回 true；失败经 [onError]
/// 报原因，空输入/取消返回 false 不报错。
Future<bool> startCloudDriveManualLogin(
  BuildContext context, {
  required CloudDriveProvider provider,
  required http.Client client,
  required CloudCredentialStore store,
  void Function(String message)? onError,
}) async {
  final controller = TextEditingController();
  final isAliyun = provider.id == 'aliyun';
  final pasted = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('手动登录${provider.displayName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isAliyun
                ? '粘贴 refresh_token（从阿里云盘网页版登录态里取）。'
                : '粘贴登录后的 Cookie（从浏览器/抓包里取整串 Cookie）。',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            maxLines: 4,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '粘贴到这里',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  if (pasted == null || pasted.isEmpty) return false;
  try {
    if (isAliyun) {
      final aliyun = provider as AliyunProvider;
      final credentials = await aliyun.credentialsFromRefreshToken(
        client,
        pasted,
      );
      if (credentials == null) {
        throw CloudDriveException('refresh_token 无效，换取凭证失败');
      }
      await store.save(provider.id, credentials);
    } else {
      await store.save(
        provider.id,
        CloudCredentials(
          fields: {'cookie': pasted},
          savedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
  } catch (e) {
    onError?.call('保存失败：$e');
    return false;
  }
  await CloudDriveStations.refresh(store);
  return true;
}

/// 移动云盘刷新登录态。成功返回 true；失败经 [onError] 报原因。
Future<bool> refreshCloudDriveCredentials({
  required Yun139Provider provider,
  required http.Client client,
  required CloudCredentialStore store,
  void Function(String message)? onError,
}) async {
  final current = store.load(provider.id);
  if (current == null) return false;
  try {
    final refreshed = await provider.refreshCredentials(client, current);
    await store.save(provider.id, refreshed);
    await CloudDriveStations.refresh(store);
    return true;
  } catch (e) {
    onError?.call('刷新失败：$e，请清除后重新登录');
    return false;
  }
}

/// 退出一家网盘：清凭证 + 刷新站表。确认弹窗由调用方负责。
Future<void> logoutCloudDrive(
  CloudCredentialStore store,
  String providerId,
) async {
  await store.clear(providerId);
  await CloudDriveStations.refresh(store);
}
/// 扫码流程里给用户看的错误文案：网盘侧抛的中文说明（[CloudDriveException]，
/// 文案是写死的中文、不含地址）直接显示；其余异常一律用干净的通用文案，
/// 绝不把异常原文（可能含完整请求地址与凭证参数）显示出来。
String cloudDriveErrorMessage(Object error, String fallback) =>
    error is CloudDriveException ? error.message : fallback;

/// 扫码登录弹窗：二维码 + 轮询 + 过期重取 + 内容链接复制。
class CloudQrLoginDialog extends StatefulWidget {
  const CloudQrLoginDialog({
    super.key,
    required this.provider,
    required this.session,
    required this.client,
  });

  final CloudDriveProvider provider;
  final QrLoginSession session;
  final http.Client client;

  @override
  State<CloudQrLoginDialog> createState() => CloudQrLoginDialogState();
}

class CloudQrLoginDialogState extends State<CloudQrLoginDialog> {
  /// 连续瞬时网络失败达到这么多次才判失败（轮询间隔 2 秒，5 次约
  /// 10 秒，盖住一次网络抖动；超过就是真断网，没必要再等）。
  static const _maxConsecutivePollFailures = 5;

  Timer? _timer;
  String _status = '';
  bool _expired = false;
  bool _failed = false;
  QrLoginSession? _currentSession;
  int _consecutivePollFailures = 0;

  /// 一次轮询请求在途时跳过后续 tick：请求超时 20 秒、tick 间隔
  /// 2 秒，不加这个网络一挂就会叠起一串并发请求。
  bool _pollInFlight = false;

  @override
  void initState() {
    super.initState();
    _currentSession = widget.session;
    _status = widget.session.message;
    _startPolling();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _timer?.cancel();
    _consecutivePollFailures = 0;
    _pollInFlight = false;
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _pollOnce());
  }

  Future<void> _pollOnce() async {
    final session = _currentSession;
    if (session == null || _pollInFlight) return;
    if (DateTime.now().isAfter(session.expiresAt)) {
      _timer?.cancel();
      if (mounted) {
        setState(() {
          _expired = true;
          _status = '二维码已过期，请重新获取';
        });
      }
      return;
    }
    _pollInFlight = true;
    QrPollResult result;
    try {
      result = await widget.provider.pollQrLogin(widget.client, session);
    } catch (e) {
      if (!mounted) return;
      // 瞬时网络错（连接被断/重置/超时）不终结轮询：继续等下一个
      // tick，只提示“正在重试”；连续失败到上限才判失败。一次抖动
      // 就停轮询是 2026-11-18 用户手机上 115 扫码报障的根因。
      if (_isTransientPollError(e)) {
        _consecutivePollFailures++;
        if (_consecutivePollFailures >= _maxConsecutivePollFailures) {
          _timer?.cancel();
          setState(() {
            _failed = true;
            _status = '网络不稳定，获取扫码状态失败，请重新获取';
          });
        } else {
          setState(() {
            _status = '网络波动，正在重试…';
          });
        }
        return;
      }
      _timer?.cancel();
      setState(() {
        _failed = true;
        _status = cloudDriveErrorMessage(e, '获取扫码状态失败，请重新获取');
      });
      return;
    } finally {
      _pollInFlight = false;
    }
    if (!mounted) return;
    // 拿到任何一次正常结果都清零：只数“连续”失败。
    _consecutivePollFailures = 0;
    switch (result.status) {
      case QrPollStatus.success:
        _timer?.cancel();
        Navigator.of(context).pop(result.credentials);
      case QrPollStatus.expired:
        _timer?.cancel();
        setState(() {
          _expired = true;
          _status = result.message;
        });
      case QrPollStatus.failed:
        _timer?.cancel();
        setState(() {
          _failed = true;
          _status = result.message;
        });
      case QrPollStatus.scanned:
        setState(() => _status = '已扫码，请在 ${widget.provider.appName} 内确认登录');
      case QrPollStatus.waiting:
        setState(() => _status = result.message);
    }
  }

  /// 轮询里可重试的瞬时网络错：连接被断/重置（http 客户端包成
  /// [http.ClientException]，用户截图里就是这一种）、Socket/Http 层
  /// 错误、请求超时。其余异常（返回解析失败、不支持的操作等）不是
  /// 网络抖动，不重试，立即判失败。
  bool _isTransientPollError(Object error) {
    return error is TimeoutException ||
        error is SocketException ||
        error is HttpException ||
        error is http.ClientException;
  }

  Future<void> _refreshQr() async {
    setState(() {
      _expired = false;
      _failed = false;
      _status = '正在获取二维码…';
    });
    try {
      final session = await widget.provider.startQrLogin(widget.client);
      if (!mounted) return;
      setState(() {
        _currentSession = session;
        _status = session.message;
      });
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _status = cloudDriveErrorMessage(e, '获取二维码失败，请检查网络后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _currentSession ?? widget.session;
    final qr = session.qrImageUrl.isNotEmpty
        ? Image.network(
            session.qrImageUrl,
            width: 220,
            height: 220,
            errorBuilder: (_, _, _) => const SizedBox(
              width: 220,
              height: 220,
              child: Center(child: Text('二维码图片加载失败')),
            ),
          )
        : QrCodeWidget(
            content: session.qrContent,
            size: 220,
            fallback: const SizedBox(
              width: 220,
              height: 220,
              child: Center(child: Text('二维码内容过长，无法生成图片，请复制链接')),
            ),
          );
    return AlertDialog(
      title: Text('${widget.provider.displayName}扫码登录'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            qr,
            const SizedBox(height: 12),
            Text(_status, textAlign: TextAlign.center),
            if (session.qrContent.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                session.qrContent,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: session.qrContent));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('二维码链接已复制')),
                  );
                },
                child: const Text('复制二维码链接'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_expired || _failed)
          TextButton(onPressed: _refreshQr, child: const Text('重新获取')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

/// 移动云盘短信登录弹窗：手机号 + 获取验证码 + 验证码 + 登录。
///
/// 触发风控时打开内嵌滑块页（[CloudCaptchaWebViewPage]），用户在页内完成
/// 滑块后返回本弹窗等短信、输验证码登录；登录时带上发短信时返回的
/// 滑块头。发短信后 60 秒内不重复发送，避免连点刷接口。
class CloudSmsLoginDialog extends StatefulWidget {
  const CloudSmsLoginDialog({super.key, required this.provider, required this.client});

  final Yun139Provider provider;
  final http.Client client;

  @override
  State<CloudSmsLoginDialog> createState() => CloudSmsLoginDialogState();
}

class CloudSmsLoginDialogState extends State<CloudSmsLoginDialog> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  Timer? _cooldownTimer;
  int _cooldownSeconds = 0;
  bool _busy = false;
  bool _smsSent = false;
  String _status = '输入手机号获取验证码，触发验证时会打开滑块页。';
  Map<String, String> _sliderHeaders = const {};

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldownSeconds = 60);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_cooldownSeconds <= 1) {
        timer.cancel();
        setState(() => _cooldownSeconds = 0);
      } else {
        setState(() => _cooldownSeconds--);
      }
    });
  }

  Future<void> _sendSms() async {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) {
      setState(() => _status = '请先输入手机号');
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在发送验证码…';
    });
    Yun139SmsResult result;
    try {
      result = await widget.provider.sendSms(widget.client, phone);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '发送失败：$e';
      });
      return;
    }
    if (!mounted) return;
    if (result.requiresCaptcha) {
      setState(() {
        _busy = false;
        _status = '需要完成滑块验证，正在打开验证页…';
      });
      final completed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => CloudCaptchaWebViewPage(url: result.captchaUrl),
        ),
      );
      if (!mounted) return;
      if (completed == true) {
        setState(() {
          _sliderHeaders = result.sliderHeaders;
          _smsSent = true;
          _status = '滑块已完成，请查收短信验证码并输入，60 秒后可重发。';
        });
        _startCooldown();
      } else {
        setState(() => _status = '滑块验证未完成，请重新获取验证码。');
      }
      return;
    }
    setState(() {
      _busy = false;
      _smsSent = true;
      _status = result.message;
    });
    _startCooldown();
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _status = '正在登录…';
    });
    try {
      final credentials = await widget.provider.loginWithSms(
        widget.client,
        _phoneController.text,
        _codeController.text,
        sliderHeaders: _sliderHeaders,
      );
      if (!mounted) return;
      Navigator.of(context).pop(credentials);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '登录失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('移动云盘短信登录'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '手机号',
                hintText: '11 位移动手机号',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _codeController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: '短信验证码',
                      hintText: '6 位数字',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: (_busy || _cooldownSeconds > 0) ? null : _sendSms,
                  child: Text(
                    _cooldownSeconds > 0 ? '$_cooldownSeconds 秒后重发' : '获取验证码',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(_status),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: (_busy || !_smsSent) ? null : _login,
          child: const Text('登录'),
        ),
      ],
    );
  }
}

/// 滑块验证内嵌页：最小 WebView（与清关桥同款 WebViewController 用法，
/// 不复用清关页——那页绑的是 cf_clearance 回填逻辑，与滑块无关）。
///
/// 滑块完成没有可监听的可靠信号（源头前端也是 iframe + 用户自行返回
/// 等短信），所以这里不猜“完成了”：用户在页内完成滑块后自己点
/// “我已完成验证”返回；点返回不代表服务端已通过，短信没来就重发。
class CloudCaptchaWebViewPage extends StatefulWidget {
  const CloudCaptchaWebViewPage({super.key, required this.url});

  final String url;

  @override
  State<CloudCaptchaWebViewPage> createState() => CloudCaptchaWebViewPageState();
}

class CloudCaptchaWebViewPageState extends State<CloudCaptchaWebViewPage> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted);
    unawaited(_controller.loadRequest(Uri.parse(widget.url)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('滑块验证')),
      body: Column(
        children: [
          Expanded(child: WebViewWidget(controller: _controller)),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('请在上方页面内完成滑块验证，完成后点下面按钮返回，等待短信验证码。'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('我已完成验证'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 登入中心的网盘账号区：五家各一行（显示名 + 状态 + 登录/退出钮）。
///
/// 状态现读凭证存储：未登录 / 已登录（凭证带 label 昵称时显示
/// 昵称）。登录走 [startCloudDriveLogin] 共享入口，退出走
/// [logoutCloudDrive]（清凭证 + 刷新站表）；动作后重读状态自刷新。
/// 存储与 provider 列表可注入（单测用假存储渲染未登录态）。
class CloudDriveAccountSection extends StatefulWidget {
  const CloudDriveAccountSection({
    super.key,
    this.store,
    this.providers,
    this.titleStyle,
    this.textColor,
    this.subTextColor,
  });

  /// 注入凭证存储（单测用）；为空时走 [CloudDriveFactory] 单例。
  final CloudCredentialStore? store;

  /// 注入网盘列表（单测用）；为空时用五家真实 provider。
  final List<CloudDriveProvider>? providers;

  final TextStyle? titleStyle;
  final Color? textColor;
  final Color? subTextColor;

  @override
  State<CloudDriveAccountSection> createState() =>
      _CloudDriveAccountSectionState();
}

class _CloudDriveAccountSectionState extends State<CloudDriveAccountSection> {
  final _client = http.Client();
  late final List<CloudDriveProvider> _providers =
      widget.providers ?? createCloudDriveProviders();
  CloudCredentialStore? _store;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _init() async {
    final store = widget.store ?? await CloudDriveFactory.credentialStore();
    if (!mounted) return;
    setState(() {
      _store = store;
      _loading = false;
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _login(CloudDriveProvider provider) async {
    final store = _store;
    if (store == null) return;
    final ok = await startCloudDriveLogin(
      context,
      provider: provider,
      client: _client,
      store: store,
      onError: _snack,
    );
    if (!mounted) return;
    if (ok) _snack('${provider.displayName}登录成功，已加入站源列表');
    setState(() {});
  }

  Future<void> _logout(CloudDriveProvider provider) async {
    final store = _store;
    if (store == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('退出${provider.displayName}？'),
        content: const Text('退出后该网盘会从站源列表里消失，文件本身不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await logoutCloudDrive(store, provider.id);
    if (!mounted) return;
    _snack('已退出${provider.displayName}');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: Text(
            '网盘账号',
            style:
                widget.titleStyle ??
                const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
          ),
        ),
        if (_loading || store == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          for (final provider in _providers)
            _row(provider, store.load(provider.id)),
      ],
    );
  }

  Widget _row(CloudDriveProvider provider, CloudCredentials? credentials) {
    final loggedIn = credentials != null;
    final label = credentials?.label ?? '';
    final textColor = widget.textColor ?? Colors.white;
    final subColor = widget.subTextColor ?? Colors.white70;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  provider.displayName,
                  style: TextStyle(color: textColor, fontSize: 15),
                ),
                const SizedBox(height: 2),
                Text(
                  loggedIn
                      ? (label.isNotEmpty ? '已登录 · $label' : '已登录')
                      : '未登录',
                  style: TextStyle(color: subColor, fontSize: 13),
                ),
              ],
            ),
          ),
          if (loggedIn)
            OutlinedButton(
              onPressed: () => _logout(provider),
              child: const Text('退出'),
            )
          else
            FilledButton(
              onPressed: () => _login(provider),
              child: const Text('登录'),
            ),
        ],
      ),
    );
  }
}
