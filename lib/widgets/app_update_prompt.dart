import 'dart:io';

import 'package:flutter/material.dart';

import '../services/app_update.dart';
import 'series_detail/moyi_detail_theme.dart';

/// 启动更新弹窗（魔蚁同步批 B8）：标题「发现新版本 X」，正文
/// 当前→最新 + 更新说明全文；安卓框内下载带进度、装系统安装器；
/// 非安卓主按钮打开发布页。强制更新时没有「稍后再说」、点框外
/// 关不掉、正文带红字；普通更新点「稍后再说」只跳过本版。
Future<void> showAppUpdatePrompt(
  BuildContext context, {
  required AppVersion current,
  required AppReleaseInfo latest,
  AppUpdateChecker? checker,
  AppUpdateBridge? bridge,
}) {
  final force = isForceUpdate(
    current: current,
    latest: latest,
    now: DateTime.now(),
  );
  return showDialog<void>(
    context: context,
    barrierDismissible: !force,
    builder: (dialogContext) => _AppUpdateDialog(
      current: current,
      latest: latest,
      force: force,
      checker: checker ?? AppUpdateChecker.instance,
      bridge: bridge ?? AppUpdateBridge.instance,
    ),
  );
}

class _AppUpdateDialog extends StatefulWidget {
  const _AppUpdateDialog({
    required this.current,
    required this.latest,
    required this.force,
    required this.checker,
    required this.bridge,
  });

  final AppVersion current;
  final AppReleaseInfo latest;
  final bool force;
  final AppUpdateChecker checker;
  final AppUpdateBridge bridge;

  @override
  State<_AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<_AppUpdateDialog> {
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

  Future<void> _downloadAndInstall() async {
    setState(() {
      _downloading = true;
      _error = null;
      _received = 0;
      _total = widget.latest.apkSize ?? -1;
    });
    _downloader = ResumableDownloader();
    try {
      final file = await widget.checker.downloadApk(
        widget.latest,
        downloader: _downloader,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            if (total > 0) _total = total;
          });
        },
      );
      final failure = await widget.bridge.installApk(file.path);
      if (!mounted) return;
      if (failure == null) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _downloading = false;
        _error = failure.code == 'install_permission'
            ? '请先允许本应用安装未知应用，然后回来重新点安装'
            : failure.message;
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
    final ok = await widget.bridge.openUrl(widget.latest.htmlUrl);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _error = '打不开浏览器，请手动前往发布页下载');
    }
  }

  @override
  void dispose() {
    _downloader?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final latest = widget.latest;
    return AlertDialog(
      backgroundColor: moyiSheetFill,
      title: Text(
        '发现新版本 ${latest.version}',
        style: const TextStyle(color: Colors.white),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前版本 ${widget.current} → 最新版本 ${latest.version}',
              style: const TextStyle(color: moyiMutedOnDark, fontSize: 13),
            ),
            if (widget.force) ...[
              const SizedBox(height: 8),
              const Text(
                '强制更新：请尽快完成更新，否则旧版本将无法继续使用。',
                style: TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
            ],
            if (latest.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                latest.notes.trim(),
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ],
            if (_downloading || _received > 0) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: _total > 0 ? _received / _total : null,
                color: moyiGold,
              ),
              const SizedBox(height: 6),
              Text(
                _total > 0
                    ? '已下载 $_received / $_total 字节'
                    : '已下载 $_received 字节',
                style: const TextStyle(color: moyiMutedOnDark, fontSize: 12),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!widget.force)
          TextButton(
            onPressed: _downloading
                ? null
                : () async {
                    await widget.checker.dismiss(latest.version);
                    if (context.mounted) Navigator.of(context).pop();
                  },
            child: const Text('稍后再说'),
          ),
        FilledButton(
          onPressed: _downloading
              ? null
              : (_isAndroid && latest.hasApk
                    ? _downloadAndInstall
                    : _openReleasePage),
          child: Text(
            _downloading
                ? '下载中…'
                : (_isAndroid && latest.hasApk ? '下载并安装' : '打开发布页'),
          ),
        ),
      ],
    );
  }
}
