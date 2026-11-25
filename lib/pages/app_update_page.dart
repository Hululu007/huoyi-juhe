import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/app_update.dart';
import '../widgets/series_detail/moyi_detail_theme.dart';
import '../widgets/settings/settings_widgets.dart';

/// 软件更新页（魔蚁同步批 B8）：当前版本/最新版本两行，手动
/// 检查不受 24 小时节流；有更新时安卓可框内下载安装、非安卓
/// 打开发布页；强制更新显示红字与窗口日期。
class AppUpdatePage extends StatefulWidget {
  const AppUpdatePage({super.key, this.checker, this.bridge});

  final AppUpdateChecker? checker;
  final AppUpdateBridge? bridge;

  @override
  State<AppUpdatePage> createState() => _AppUpdatePageState();
}

class _AppUpdatePageState extends State<AppUpdatePage> {
  late final AppUpdateChecker _checker = widget.checker ?? AppUpdateChecker.instance;
  late final AppUpdateBridge _bridge = widget.bridge ?? AppUpdateBridge.instance;

  AppVersion? _current;
  AppReleaseInfo? _latest;
  bool _checked = false;
  bool _busy = false;
  bool _downloading = false;
  int _received = 0;
  int _total = -1;
  String? _error;
  ResumableDownloader? _downloader;

  bool get _isAndroid {
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _loadCurrent();
  }

  Future<void> _loadCurrent() async {
    final version = await _checker.currentVersion();
    if (!mounted) return;
    setState(() => _current = version);
  }

  Future<void> _check() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final latest = await _checker.fetchLatest();
      if (!mounted) return;
      setState(() {
        _latest = latest;
        _checked = true;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checked = true;
        _busy = false;
        _error = '检查更新失败：$e';
      });
    }
  }

  Future<void> _downloadAndInstall() async {
    final latest = _latest;
    if (latest == null || _downloading) return;
    setState(() {
      _downloading = true;
      _error = null;
      _received = 0;
      _total = latest.apkSize ?? -1;
    });
    _downloader = ResumableDownloader();
    try {
      final file = await _checker.downloadApk(
        latest,
        downloader: _downloader,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            if (total > 0) _total = total;
          });
        },
      );
      final failure = await _bridge.installApk(file.path);
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = failure == null
            ? null
            : (failure.code == 'install_permission'
                  ? '请先允许本应用安装未知应用，然后回来重新点安装'
                  : failure.message);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _openReleasePage() async {
    final url = _latest?.htmlUrl ?? appUpdateReleasesPageUrl;
    final ok = await _bridge.openUrl(url);
    if (!mounted) return;
    if (!ok) setState(() => _error = '打不开浏览器，请手动前往发布页下载');
  }

  @override
  void dispose() {
    _downloader?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final latest = _latest;
    final hasUpdate =
        current != null && latest != null && latest.version > current;
    final force = hasUpdate
        ? isForceUpdate(
            current: current,
            latest: latest,
            now: DateTime.now(),
          )
        : false;
    final window = latest == null ? null : parseForceWindow(latest.notes);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: settingsAppBar(context, title: '软件更新'),
      body: MoyiPageBackground(
        child: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  SettingsGroupCard(
                    children: [
                      SettingsRow(
                        icon: LucideIcons.smartphone,
                        iconTile: true,
                        title: '当前版本',
                        subtitle: current == null
                            ? '读取中…'
                            : '${current.toString()}（构建 ${current.build}）',
                      ),
                      SettingsRow(
                        icon: LucideIcons.download,
                        iconTile: true,
                        title: '最新版本',
                        subtitle: !_checked
                            ? '尚未检查'
                            : latest == null
                            ? '未获取到'
                            : '${latest.version}（${latest.tag}）',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: _busy || _downloading ? null : _check,
                        icon: const Icon(LucideIcons.refresh_cw, size: 18),
                        label: Text(_busy ? '检查中…' : '检查更新'),
                      ),
                      if (hasUpdate && _isAndroid && latest.hasApk)
                        FilledButton.icon(
                          onPressed: _downloading ? null : _downloadAndInstall,
                          icon: const Icon(LucideIcons.download, size: 18),
                          label: Text(
                            _downloading ? '下载中…' : '下载并安装 ${latest.version}',
                          ),
                        ),
                      if (hasUpdate && (!_isAndroid || !latest.hasApk))
                        FilledButton.icon(
                          onPressed: _openReleasePage,
                          icon: const Icon(LucideIcons.globe, size: 18),
                          label: const Text('打开发布页下载'),
                        ),
                    ],
                  ),
                  if (_checked && !hasUpdate && _error == null) ...[
                    const SizedBox(height: 12),
                    const Text(
                      '已是最新版本',
                      style: TextStyle(color: moyiMutedOnDark, fontSize: 13),
                    ),
                  ],
                  if (force) ...[
                    const SizedBox(height: 12),
                    Text(
                      '强制更新：请尽快完成更新，否则旧版本将无法继续使用。'
                      '${window?.after != null || window?.until != null ? '（${window?.after?.toString().split(' ').first ?? '…'} 至 ${window?.until?.toString().split(' ').first ?? '…'}）' : ''}',
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  if (hasUpdate && latest.notes.trim().isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const SettingsSectionHeader(title: '更新说明'),
                    Text(
                      latest.notes.trim(),
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
                  if (_downloading || _received > 0) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: _total > 0 ? _received / _total : null,
                      color: moyiGold,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _total > 0
                          ? '已下载 $_received / $_total 字节'
                          : '已下载 $_received 字节',
                      style: const TextStyle(
                        color: moyiMutedOnDark,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
