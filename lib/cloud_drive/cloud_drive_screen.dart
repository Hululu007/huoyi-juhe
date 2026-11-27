/// 网盘页（修仙版）：五家网盘登录 + 凭证管理。
/// 115 登录后另有账号信息位（昵称/ID/会员/容量，接口真返回才显示）
/// 与上传入口（选本地文件流式上传到根目录，进度弹窗如实反馈）。
///
/// 自魔蚁 cloud_drive_screen 移植，修仙版适配差异：
/// - 魔蚁的 LocalStore 换成轻量 [CloudDriveSettings]
///   （SharedPreferences 只存 showSuspectedAdVideos 一个布尔）；
/// - 115 上传选文件由 file_picker 换成修仙版已有的 file_selector；
/// - 登录弹窗与发起登录的共享函数抽到 cloud_drive_login.dart，
///   本页与登入中心共用；登录/退出后调 CloudDriveStations.refresh
///   刷新网盘站表并自刷新；
/// - 魔蚁版没有跳其它页面的入口，此处同样没有，无删改。
/// 主体抽成 [CloudDriveBody]：独立页 [CloudDriveScreen] 与首页
/// 「网盘」档共用同一份主体。
///
/// 115/夸克/阿里/百度走扫码登录，移动云盘走手机号 + 短信验证码登录
/// （触发风控时在内嵌页里完成滑块验证）。凭证只存本机（混淆存储，
/// 见 CloudCredentialStore 文件头说明），可逐家清除；登录后网盘作为
/// 站源进站点列表，全局通用。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'cloud_credential_store.dart';
import 'cloud_drive_factory.dart';
import 'cloud_pan115_offline_page.dart';
import 'cloud_drive_login.dart';
import 'cloud_drive_settings.dart';
import 'cloud_drive_stations.dart';
import 'cloud_provider_139.dart';
import 'cloud_providers.dart';

/// 各家验证到哪一步（诚实口径，界面上直接展示，不夸大）。
const _verifyNotes = <String, String>{
  'pan115': '扫码接口已实测；文件浏览与播放需真账号验证',
  'quark': '扫码接口已实测；文件浏览与播放需真账号验证',
  'aliyun': '扫码接口已实测；文件浏览与播放需真账号验证',
  'baidu': '扫码接口已实测；文件浏览与播放需真账号验证',
  'yun139': '短信登录；文件浏览与播放需真账号验证',
};

/// 115 上传的选文件结果：本地路径 + 显示名（路径拿不到时为空串）。
typedef Pan115UploadPick = ({String path, String name});

/// 独立网盘页：Scaffold + 标题栏 + [CloudDriveBody] 主体。
class CloudDriveScreen extends StatelessWidget {
  const CloudDriveScreen({super.key, this.settings, this.providers});

  /// 注入设置（单测用）；为空时主体自己按 [CloudDriveSettings.load] 取。
  final CloudDriveSettings? settings;

  /// 注入网盘列表（单测用）；为空时用五家真实 provider。
  final List<CloudDriveProvider>? providers;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('网盘登录')),
      body: CloudDriveBody(settings: settings, providers: providers),
    );
  }
}

/// 网盘页主体（可嵌入）：首页「网盘」档与独立页共用。
class CloudDriveBody extends StatefulWidget {
  const CloudDriveBody({
    super.key,
    this.settings,
    this.providers,
    this.uploadPicker,
    this.embedded = false,
  });

  /// 嵌入模式（首页「网盘」档）：外层已有滚动容器，主体改用
  /// shrinkWrap + 不自滚的列表贴进 sliver，不套娃滚动。
  final bool embedded;

  /// 注入设置（单测用）；为空时按 [CloudDriveSettings.load] 取单例。
  final CloudDriveSettings? settings;

  /// 注入网盘列表（单测用假 provider；不传则用五家真实 provider）。
  final List<CloudDriveProvider>? providers;

  /// 注入 115 上传的选文件动作（单测/预览用；不传走系统文件选择器）。
  final Future<Pan115UploadPick?> Function()? uploadPicker;

  @override
  State<CloudDriveBody> createState() => _CloudDriveBodyState();
}

class _CloudDriveBodyState extends State<CloudDriveBody> {
  final _client = http.Client();
  late final _providers = widget.providers ?? createCloudDriveProviders();
  CloudCredentialStore? _credentialStore;
  CloudDriveSettings? _settings;
  Set<String> _loggedIn = {};
  bool _loading = true;

  /// 115 账号信息位的状态：账号与容量各自独立成败，拉到哪个显示
  /// 哪个；两个都失败才落 [_pan115InfoError] 显示原因。
  Pan115AccountInfo? _pan115Account;
  Pan115SpaceInfo? _pan115Space;
  String? _pan115InfoError;
  bool _pan115InfoLoading = false;

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
    final store = await CloudDriveFactory.credentialStore();
    final settings = widget.settings ?? await CloudDriveSettings.load();
    if (!mounted) return;
    setState(() {
      _credentialStore = store;
      _settings = settings;
      _loggedIn = store.loggedInProviderIds(_providers.map((p) => p.id)).toSet();
      _loading = false;
    });
    unawaited(_loadPan115Info());
  }

  Future<void> _refreshStations() async {
    final store = _credentialStore;
    if (store == null) return;
    await CloudDriveStations.refresh(store);
    if (!mounted) return;
    setState(() {
      _loggedIn = store.loggedInProviderIds(_providers.map((p) => p.id)).toSet();
    });
    unawaited(_loadPan115Info());
  }

  /// 拉 115 账号/容量信息（账号信息位用）：未登录就清空；账号与
  /// 容量各自独立成败，失败原因如实落字，不编数据。
  Future<void> _loadPan115Info() async {
    final store = _credentialStore;
    if (store == null || _pan115InfoLoading) return;
    Pan115Provider? pan115;
    for (final provider in _providers) {
      if (provider is Pan115Provider) {
        pan115 = provider;
        break;
      }
    }
    if (pan115 == null) return;
    if (!_loggedIn.contains(pan115.id)) {
      if (_pan115Account != null ||
          _pan115Space != null ||
          _pan115InfoError != null) {
        setState(() {
          _pan115Account = null;
          _pan115Space = null;
          _pan115InfoError = null;
        });
      }
      return;
    }
    final credentials = store.load(pan115.id);
    if (credentials == null) return;
    setState(() => _pan115InfoLoading = true);
    Pan115AccountInfo? account;
    Pan115SpaceInfo? space;
    String? error;
    try {
      account = await pan115.accountInfo(_client, credentials);
    } catch (e) {
      error = cloudDriveErrorMessage(e, '账号信息获取失败，请检查网络后重试');
    }
    try {
      space = await pan115.spaceInfo(_client, credentials);
    } catch (e) {
      error ??= cloudDriveErrorMessage(e, '容量信息获取失败，请检查网络后重试');
    }
    if (!mounted) return;
    setState(() {
      _pan115InfoLoading = false;
      if (account != null) _pan115Account = account;
      if (space != null) _pan115Space = space;
      _pan115InfoError = (account == null && space == null) ? error : null;
    });
  }

  /// 115 上传入口：选本地文件 → 流式上传到网盘根目录，进度与成败
  /// 在弹窗里如实反馈（失败原因显示 provider 给的中文说明）。
  Future<void> _startPan115Upload(Pan115Provider provider) async {
    final store = _credentialStore;
    if (store == null) return;
    final credentials = store.load(provider.id);
    if (credentials == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先登录 115 网盘')),
      );
      return;
    }
    Pan115UploadPick? pick;
    try {
      pick = await (widget.uploadPicker?.call() ?? _pickUploadFile());
    } catch (_) {
      pick = null;
    }
    if (!mounted) return;
    if (pick == null) return; // 用户取消选文件，不打扰。
    if (pick.path.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没能拿到所选文件的路径，请换个文件再试')),
      );
      return;
    }
    final picked = pick;
    final done = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _Pan115UploadDialog(
        provider: provider,
        client: _client,
        credentials: credentials,
        file: File(picked.path),
        fileName: picked.name,
        targetFolderId: provider.rootFolderId,
      ),
    );
    if (done == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('上传完成，文件已存入 115 网盘根目录')),
      );
    }
  }

  Future<Pan115UploadPick?> _pickUploadFile() async {
    // 修仙版适配：file_selector 的 openFile，取消选择回 null。
    final file = await openFile();
    if (file == null) return null;
    return (path: file.path, name: file.name);
  }

  Future<void> _clear(CloudDriveProvider provider) async {
    final store = _credentialStore;
    if (store == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('清除${provider.displayName}登录？'),
        content: const Text('清除后该网盘会从站源列表里消失，文件本身不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await store.clear(provider.id);
    await _refreshStations();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已清除${provider.displayName}登录')),
      );
    }
  }

  /// 发起登录（共享层 cloud_drive_login.dart 按 provider 能力
  /// 分发扫码/短信；本页只负责成功提示与自刷新）。
  Future<void> _startLogin(CloudDriveProvider provider) async {
    final store = _credentialStore;
    if (store == null) return;
    final ok = await startCloudDriveLogin(
      context,
      provider: provider,
      client: _client,
      store: store,
      onError: (message) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
      },
    );
    if (!ok || !mounted) return;
    await _refreshStations();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${provider.displayName}登录成功，已加入站源列表')),
      );
    }
  }

  Future<void> _refreshYun139(Yun139Provider provider) async {
    final store = _credentialStore;
    if (store == null) return;
    final ok = await refreshCloudDriveCredentials(
      provider: provider,
      client: _client,
      store: store,
      onError: (message) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
      },
    );
    if (ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('移动云盘登录已刷新')),
      );
    }
  }

  Future<void> _manualLogin(CloudDriveProvider provider) async {
    final store = _credentialStore;
    if (store == null) return;
    final ok = await startCloudDriveManualLogin(
      context,
      provider: provider,
      client: _client,
      store: store,
      onError: (message) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
      },
    );
    if (!ok || !mounted) return;
    await _refreshStations();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${provider.displayName}已保存，打开站源列表验证是否可用')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
              shrinkWrap: widget.embedded,
              physics: widget.embedded
                  ? const NeverScrollableScrollPhysics()
                  : null,
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  '登录一次全局通用：登录后的网盘会作为站源出现在站源列表、搜索里。凭证只存本机，可随时清除。',
                ),
                const SizedBox(height: 16),
                for (final provider in _providers)
                  _providerCard(provider),
                const SizedBox(height: 24),
                const Text(
                  '广告视频过滤',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                SwitchListTile(
                  title: const Text('显示疑似广告视频'),
                  subtitle: const Text(
                    '默认隐藏小文件、极短、文件名带推广信息的疑似广告视频；打开后全部显示并标注“疑似广告”。只过滤显示，绝不删文件。判定是经验规则，可能误判。',
                  ),
                  value: _settings?.showSuspectedAdVideos ?? false,
                  onChanged: (value) async {
                    await _settings?.setShowSuspectedAdVideos(value);
                    if (mounted) setState(() {});
                  },
                ),
              ],
            );
  }

  Widget _providerCard(CloudDriveProvider provider) {
    final loggedIn = _loggedIn.contains(provider.id);
    final yun139 = provider is Yun139Provider;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    provider.displayName,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                Chip(
                  label: Text(loggedIn ? '已登录' : '未登录'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _verifyNotes[provider.id] ?? '',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (provider is Pan115Provider && loggedIn) ...[
              const SizedBox(height: 8),
              _pan115InfoBlock(),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                if (!loggedIn && yun139)
                  FilledButton(
                    onPressed: () => _startLogin(provider),
                    child: const Text('短信登录'),
                  ),
                if (!loggedIn && !yun139)
                  FilledButton(
                    onPressed: () => _startLogin(provider),
                    child: const Text('扫码登录'),
                  ),
                if (!loggedIn && !yun139)
                  OutlinedButton(
                    onPressed: () => _manualLogin(provider),
                    child: const Text('手动粘贴凭证'),
                  ),
                if (loggedIn && yun139)
                  OutlinedButton(
                    onPressed: () => _refreshYun139(provider),
                    child: const Text('刷新登录'),
                  ),
                if (loggedIn && provider is Pan115Provider)
                  OutlinedButton(
                    onPressed: () => _startPan115Upload(provider),
                    child: const Text('上传文件到根目录'),
                  ),
                if (loggedIn && provider is Pan115Provider)
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const CloudPan115OfflinePage(),
                      ),
                    ),
                    child: const Text('离线任务'),
                  ),
                if (loggedIn)
                  OutlinedButton(
                    onPressed: () => _clear(provider),
                    child: const Text('清除登录'),
                  ),
              ],
            ),
            if (provider is Pan115Provider) ...[
              const SizedBox(height: 4),
              SwitchListTile(
                key: const ValueKey('cloud-drive-auto-offline-switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('详情页自动离线'),
                subtitle: const Text(
                  '打开演员库详情页拿到下载链接后，自动把最优一条提交到 115 离线下载（已有/已交过的自动跳过）；关掉后回到点按磁力手动提交。',
                ),
                value: _settings?.actressAutoOffline ?? true,
                onChanged: (value) async {
                  await _settings?.setActressAutoOffline(value);
                  if (mounted) setState(() {});
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 115 账号信息位：只展示接口真拿到的字段；昵称/ID 没返回就写
  /// “未返回”，容量没拉到写“未获取到”，不编数据。两个接口都失败
  /// 时显示失败原因 + 重试。
  Widget _pan115InfoBlock() {
    final account = _pan115Account;
    final space = _pan115Space;
    if (account == null && space == null) {
      if (_pan115InfoError != null) {
        return Row(
          children: [
            Expanded(child: Text('账号信息获取失败：$_pan115InfoError')),
            TextButton(
              onPressed: () => unawaited(_loadPan115Info()),
              child: const Text('重试'),
            ),
          ],
        );
      }
      return const Text('正在读取账号信息…');
    }
    String two(int v) => v.toString().padLeft(2, '0');
    String vipExpireText = '';
    if (account != null && !account.vipForever && account.vipExpireSeconds > 0) {
      final d = DateTime.fromMillisecondsSinceEpoch(
        account.vipExpireSeconds * 1000,
      );
      vipExpireText = '${d.year}-${two(d.month)}-${two(d.day)}';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (account != null && account.avatarUrl.isNotEmpty) ...[
              CircleAvatar(
                radius: 14,
                backgroundImage: NetworkImage(account.avatarUrl),
                onBackgroundImageError: (_, _) {},
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                account == null
                    ? '账号：未获取到'
                    : '昵称：${account.nickname.isEmpty ? '未返回' : account.nickname}',
              ),
            ),
          ],
        ),
        if (account != null) ...[
          Text('账号 ID：${account.userId.isEmpty ? '未返回' : account.userId}'),
          if (account.vipForever)
            const Text('会员：永久会员')
          else if (account.vipExpireSeconds > 0)
            Text('会员到期：$vipExpireText'),
        ],
        Text(
          space == null
              ? '容量：未获取到'
              : '容量：已用 ${_formatBytes(space.usedBytes)} / '
                    '共 ${_formatBytes(space.totalBytes)}'
                    '（剩余 ${_formatBytes(space.remainBytes)}）',
        ),
        if (_pan115InfoLoading) const Text('正在刷新账号信息…'),
      ],
    );
  }
}

/// 字节数显示（账号信息位的容量、上传进度共用）。
String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

/// 115 上传进度弹窗：打开即开始上传（流式读本地文件），进度按已发
/// 字节走；成功/失败都如实落字，失败显示 provider 给的中文原因，
/// 其余异常只给干净的通用文案（异常原文可能带请求地址）。
class _Pan115UploadDialog extends StatefulWidget {
  const _Pan115UploadDialog({
    required this.provider,
    required this.client,
    required this.credentials,
    required this.file,
    required this.fileName,
    required this.targetFolderId,
  });

  final Pan115Provider provider;
  final http.Client client;
  final CloudCredentials credentials;
  final File file;
  final String fileName;
  final String targetFolderId;

  @override
  State<_Pan115UploadDialog> createState() => _Pan115UploadDialogState();
}

class _Pan115UploadDialogState extends State<_Pan115UploadDialog> {
  int _sent = 0;
  int _total = 0;
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      await widget.provider.uploadLocalFile(
        widget.client,
        widget.credentials,
        file: widget.file,
        fileName: widget.fileName,
        targetFolderId: widget.targetFolderId,
        onProgress: (sent, total) {
          if (!mounted) return;
          setState(() {
            _sent = sent;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() => _done = true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is CloudDriveException ? e.message : '上传失败，请检查网络后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('上传到 115 网盘'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.fileName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          if (_error != null)
            Text(
              '上传失败：$_error',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            )
          else if (_done)
            const Text('上传完成，文件已存入网盘根目录。')
          else ...[
            LinearProgressIndicator(
              value: _total > 0 ? _sent / _total : null,
            ),
            const SizedBox(height: 8),
            Text(
              _total > 0
                  ? '正在上传：${_formatBytes(_sent)} / ${_formatBytes(_total)}'
                  : '正在准备上传（校验文件、判断秒传）…',
            ),
          ],
        ],
      ),
      actions: [
        if (_error != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('关闭'),
          ),
        if (_done)
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('完成'),
          ),
        if (_error == null && !_done)
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('隐藏（上传继续）'),
          ),
      ],
    );
  }
}

