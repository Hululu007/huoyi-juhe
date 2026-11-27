/// 115 离线任务页（网盘页 115 卡片的「离线任务」入口，仅登录后可用）。
///
/// 进页自动拉一次任务列表 + 配额，支持手动刷新（右上角按钮 +
/// 下拉刷新）。数据层三个函数（任务/配额/搜索）都可注入假件，
/// 生产缺省走引擎单例：任务与配额走引擎的 115 离线客户端，
/// 点已完成任务先按任务名搜文件、搜到就拼条目走现有的
/// openDramaSiteItem 浏览/播放链。
///
/// 状态推导只认 Pan115OfflineTask 的真实字段（done / percent）：
/// done →「已完成」；percent 在 (0,1) →「下载中 x%」；其余
/// （percent 为 0 且未完成）→「等待中」。接口没有失败态字段，
/// 这里不假造失败状态。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/drama_site_content.dart';
import '../services/drama_site_play.dart';
import 'cloud_115_offline.dart';
import 'cloud_drive_engine.dart';
import 'cloud_drive_factory.dart';
import 'cloud_drive_types.dart';
import 'cloud_providers.dart';

typedef Pan115TasksLoader = Future<List<Pan115OfflineTask>> Function();
typedef Pan115QuotaLoader = Future<({int total, int used})?> Function();
typedef Pan115FileSearcher =
    Future<List<CloudDriveFile>> Function(String keyword);
typedef Pan115FileOpener =
    Future<void> Function(BuildContext context, CloudDriveFile file);

/// 任务状态文案（只由 done/percent 推导，见文件头）。
String pan115OfflineTaskStatusLabel(Pan115OfflineTask task) {
  if (task.done) return '已完成';
  if (task.percent > 0) {
    final pct = (task.percent * 100).floor().clamp(0, 99);
    return '下载中 $pct%';
  }
  return '等待中';
}

class CloudPan115OfflinePage extends StatefulWidget {
  const CloudPan115OfflinePage({
    super.key,
    this.loadTasks,
    this.loadQuota,
    this.searchFiles,
    this.openFile,
  });

  /// 注入接缝（组件测试用）；为空走引擎单例的生产实现。
  final Pan115TasksLoader? loadTasks;
  final Pan115QuotaLoader? loadQuota;
  final Pan115FileSearcher? searchFiles;
  final Pan115FileOpener? openFile;

  static Future<List<Pan115OfflineTask>> _defaultLoadTasks() async {
    final engine = await CloudDriveFactory.engine();
    return engine.pan115OfflineClient()?.listTasks() ?? const [];
  }

  static Future<({int total, int used})?> _defaultLoadQuota() async {
    final engine = await CloudDriveFactory.engine();
    return engine.pan115OfflineClient()?.quota();
  }

  static Future<List<CloudDriveFile>> _defaultSearch(String keyword) async {
    final engine = await CloudDriveFactory.engine();
    return engine.searchPan115Files(keyword);
  }

  static Future<void> _defaultOpen(
    BuildContext context,
    CloudDriveFile file,
  ) {
    return openDramaSiteItem(
      context,
      'cloud:pan115',
      DramaSiteItem(
        id: CloudDriveEngine.dramaId('pan115', file.id),
        title: file.name,
        cover: file.thumbnailUrl,
      ),
    );
  }

  @override
  State<CloudPan115OfflinePage> createState() =>
      _CloudPan115OfflinePageState();
}

class _CloudPan115OfflinePageState extends State<CloudPan115OfflinePage> {
  List<Pan115OfflineTask>? _tasks;
  ({int total, int used})? _quota;
  String? _error;
  bool _refreshing = false;
  bool _opening = false;

  Pan115TasksLoader get _loadTasks =>
      widget.loadTasks ?? CloudPan115OfflinePage._defaultLoadTasks;
  Pan115QuotaLoader get _loadQuota =>
      widget.loadQuota ?? CloudPan115OfflinePage._defaultLoadQuota;
  Pan115FileSearcher get _search =>
      widget.searchFiles ?? CloudPan115OfflinePage._defaultSearch;
  Pan115FileOpener get _open =>
      widget.openFile ?? CloudPan115OfflinePage._defaultOpen;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    if (mounted && _tasks == null) setState(() {});
    List<Pan115OfflineTask>? tasks;
    String? error;
    try {
      tasks = await _loadTasks();
    } catch (e) {
      error = e is CloudDriveException
          ? e.message
          : '离线任务加载失败，请检查网络后重试';
    }
    // 配额拉不到不挡任务列表：回 null 整行不显（页面口径）。
    ({int total, int used})? quota;
    try {
      quota = await _loadQuota();
    } catch (_) {
      quota = null;
    }
    _refreshing = false;
    if (!mounted) return;
    setState(() {
      if (tasks != null) _tasks = tasks;
      _error = error;
      _quota = quota;
    });
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// 点任务：未完成只提示当前状态、不做别的；已完成先按任务
  /// 名搜文件，搜到（第一个非文件夹结果）走现有浏览/播放链，
  /// 搜不到提示去网盘目录的离线下载文件夹里找。
  Future<void> _onTaskTap(Pan115OfflineTask task) async {
    if (!task.done) {
      _snack('这个任务还没下载完（${pan115OfflineTaskStatusLabel(task)}）');
      return;
    }
    if (_opening) return;
    _opening = true;
    try {
      final files = await _search(task.name);
      if (!mounted) return;
      CloudDriveFile? target;
      for (final file in files) {
        if (!file.isFolder) {
          target = file;
          break;
        }
      }
      if (target == null) {
        _snack('没在网盘里搜到这个文件，去网盘目录的离线下载文件夹里找找');
        return;
      }
      await _open(context, target);
    } catch (e) {
      _snack(
        e is CloudDriveException ? e.message : '搜索网盘文件失败，请稍后重试',
      );
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('115 离线任务'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () => unawaited(_refresh()),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final tasks = _tasks;
    if (tasks == null && _error == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tasks == null && _error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('离线任务加载失败：$_error'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => unawaited(_refresh()),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    final rows = tasks ?? const <Pan115OfflineTask>[];
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null) ...[
            Text(
              '刷新失败：$_error（下面是上次拉到的列表）',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 8),
          ],
          if (_quota != null)
            Padding(
              key: const ValueKey('pan115-offline-quota'),
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '离线配额：已用 ${_quota!.used} / 共 ${_quota!.total}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 32),
              child: Center(child: Text('暂无离线任务')),
            ),
          for (var i = 0; i < rows.length; i++)
            Card(
              key: ValueKey('pan115-offline-task-$i'),
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                title: Text(
                  rows[i].name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(pan115OfflineTaskStatusLabel(rows[i])),
                trailing: rows[i].done
                    ? const Icon(Icons.play_circle_outline)
                    : null,
                onTap: () => unawaited(_onTaskTap(rows[i])),
              ),
            ),
        ],
      ),
    );
  }
}
