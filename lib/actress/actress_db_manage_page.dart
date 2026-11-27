import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'actress_database.dart';
import 'actress_db_import.dart';
import 'actress_db_source.dart';
import 'actress_mytv_bind.dart';
import 'actress_neon.dart';
import 'actress_sql_import.dart';

/// 统一数据库管理页（2026-11-27 双库批，全树唯一一份）：两个
/// 入口共用——「我的」页的「数据库导入」行、演员库顶栏数据库
/// 管理弹层里的「数据库管理页（导入/切换）」项。
///
/// 页内：导入按钮（.db / .sql / .sql.gz，流程见
/// [ActressDbImportService]）+ 两张库卡（外置库 / 导入库）。
/// 每卡显状态（未绑定或不存在 / 已就绪）、作品数（数不出来显
/// 「—」不报错）、文件大小、修改时间、「当前使用中」标记；
/// 操作：切换到此库（就绪且非当前时可点）、删除导入库（仅
/// imported 卡有，外置库永不给删）、外置卡带绑定/授权入口
/// （与顶栏弹层同款流程，直接调 [ActressMytvBind] 的方法）。
///
/// 红线：本页不写外置库；导入失败不毁任何现有可用库（服务层
/// 保证）；切换只改选择存值，读库层靠路径+文件戳机制失效旧
/// 连接（见 actress_db_source.dart 类注释）。
class ActressDbManagePage extends StatefulWidget {
  const ActressDbManagePage({
    super.key,
    this.source,
    this.importService,
    this.onLibraryChanged,
  });

  /// 来源层（测试注入假件；默认单例）。
  final ActressDbSource? source;

  /// 导入服务（测试注入假件；默认真服务，校验走真探测）。
  final ActressDbImportService? importService;

  /// 库发生变化（导入成功/切换/删除）后调：默认关主库连接并
  /// 强制重读一次，让演员库各读库入口立刻换到新库。测试可注入
  /// 空实现。
  final Future<void> Function()? onLibraryChanged;

  @override
  State<ActressDbManagePage> createState() => _ActressDbManagePageState();
}

class _ActressDbManagePageState extends State<ActressDbManagePage> {
  ActressDbSource get _source => widget.source ?? ActressDbSource.instance;

  late final ActressDbImportService _importService =
      widget.importService ?? ActressDbImportService(source: _source);

  ActressDbSourceStatus? _status;
  final _works = <ActressDbSlot, int?>{};
  var _loading = true;
  var _importing = false;
  var _cancelled = false;
  ActressSqlImportProgress? _progress;
  String? _message;
  String? _error;

  @override
  void initState() {
    super.initState();
    _source.revision.addListener(_onRevision);
    _refresh();
  }

  @override
  void dispose() {
    _source.revision.removeListener(_onRevision);
    super.dispose();
  }

  void _onRevision() {
    if (mounted) _refresh();
  }

  Future<void> _refresh() async {
    final status = await _source.status();
    if (!mounted) return;
    setState(() {
      _status = status;
      _loading = false;
    });
    for (final slot in ActressDbSlot.values) {
      final count = await _source.countWorks(status.infoOf(slot));
      if (!mounted) return;
      setState(() => _works[slot] = count);
    }
  }

  Future<void> _notifyLibraryChanged() async {
    final hook = widget.onLibraryChanged;
    if (hook != null) {
      await hook();
      return;
    }
    try {
      await SqfliteActressDatabase.instance.reloadIfChanged(force: true);
    } catch (_) {
      // 重读失败不挡管理页：读库层下次打开会按生效路径再试。
    }
  }

  Future<void> _switchTo(ActressDbSlot slot) async {
    await _source.setSelection(slot);
    await _notifyLibraryChanged();
    if (!mounted) return;
    setState(() {
      _message = slot == ActressDbSlot.imported
          ? '已切换到导入库'
          : '已切换到外置库';
      _error = null;
    });
    await _refresh();
  }

  Future<void> _deleteImported() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Neon.surface,
        title: const Text('删除导入库', style: TextStyle(color: Neon.text)),
        content: const Text(
          '删除后导入库就没有了；当前正在用导入库时会自动回落到外置库。外置库不受影响。',
          style: TextStyle(color: Neon.textDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('dual-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除', style: TextStyle(color: Neon.pink)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _source.deleteImported();
    await _notifyLibraryChanged();
    if (!mounted) return;
    setState(() {
      _message = '导入库已删除';
      _error = null;
    });
    await _refresh();
  }

  Future<void> _startImport() async {
    if (_importing) return;
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: '女优库数据', extensions: ['db', 'sql', 'gz']),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _importing = true;
      _cancelled = false;
      _message = null;
      _error = null;
      _progress = null;
    });
    File? inbox;
    try {
      // 先拷进私有收件文件再导（与 iOS tile 同款：选择器给的
      // 路径是临时作用域路径，导入是长任务，先落地）。
      inbox = await _importService.inboxFileFor(picked.name);
      final sink = inbox.openWrite();
      try {
        await sink.addStream(picked.openRead());
      } finally {
        await sink.close();
      }
      final outcome = await _importService.importLocalFile(
        localPath: inbox.path,
        closeDatabase: () => SqfliteActressDatabase.instance.close(),
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
        isCancelled: () => _cancelled,
      );
      if (!mounted) return;
      setState(() {
        _importing = false;
        _progress = null;
        if (outcome.ok) {
          _message = outcome.videos > 0
              ? '导入成功：${outcome.videos} 部作品'
                    '${outcome.warnings.isEmpty ? '' : '\n${outcome.warnings.join('\n')}'}'
              : '导入成功';
          _error = null;
        } else {
          _error = outcome.error ?? '导入失败';
        }
      });
      if (outcome.needsReload) await _notifyLibraryChanged();
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _importing = false;
        _progress = null;
        _error = '导入失败：${e.toString().split('\n').first}';
      });
    } finally {
      try {
        if (inbox != null && await inbox.exists()) await inbox.delete();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Neon.bg,
        foregroundColor: Neon.text,
        title: const Text('数据库管理', style: TextStyle(fontSize: 17)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _importSection(),
            if (_message != null) ...[
              const SizedBox(height: 10),
              Text(
                _message!,
                key: const ValueKey('dual-message'),
                style: const TextStyle(color: Neon.cyan, fontSize: 13),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                key: const ValueKey('dual-error'),
                style: const TextStyle(color: Neon.pink, fontSize: 13),
              ),
            ],
            const SizedBox(height: 16),
            if (_loading || status == null)
              const Padding(
                padding: EdgeInsets.only(top: 24),
                child: Center(
                  child: Text(
                    '正在读取数据库状态…',
                    style: TextStyle(color: Neon.textDim),
                  ),
                ),
              )
            else ...[
              _slotCard(
                slot: ActressDbSlot.external,
                title: '外置库',
                subtitle: 'MYTV/db/女优库.db（只读，不会被改动）',
                status: status,
              ),
              const SizedBox(height: 12),
              _slotCard(
                slot: ActressDbSlot.imported,
                title: '导入库',
                subtitle: '通过本页导入的 .db / .sql 落成的库',
                status: status,
              ),
              if (status.fellBack) ...[
                const SizedBox(height: 10),
                const Text(
                  '当前选择的是导入库，但导入库不存在，已回落到外置库。',
                  key: ValueKey('dual-fallback-note'),
                  style: TextStyle(color: Neon.textDim, fontSize: 12),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _importSection() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Neon.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Neon.violet.withValues(alpha: .45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '导入数据库',
            style: TextStyle(
              color: Neon.text,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '选 .db、.sql 或 .sql.gz 文件，导入后落成「导入库」，'
            '不改动外置库；导入失败时现有库原样不动。',
            style: TextStyle(color: Neon.textDim, fontSize: 12),
          ),
          if (_importing) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: (_progress?.fraction ?? 0).clamp(0, 1),
              color: Neon.cyan,
              backgroundColor: Neon.surfaceHigh,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _progress == null
                        ? '正在导入…'
                        : '${_progress!.phase}…已处理 ${_progress!.statements} 条',
                    style: const TextStyle(
                      color: Neon.textDim,
                      fontSize: 12,
                    ),
                  ),
                ),
                TextButton(
                  key: const ValueKey('dual-import-cancel'),
                  onPressed: () => _cancelled = true,
                  child: const Text('取消'),
                ),
              ],
            ),
          ] else
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const ValueKey('dual-import-button'),
                onPressed: _startImport,
                icon: const Icon(Icons.file_upload_rounded, size: 18),
                label: const Text('选择文件导入'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _slotCard({
    required ActressDbSlot slot,
    required String title,
    required String subtitle,
    required ActressDbSourceStatus status,
  }) {
    final info = status.infoOf(slot);
    final isCurrent = status.isEffective(slot);
    final works = _works[slot];
    return Container(
      key: ValueKey('dual-card-${slot.wire}'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Neon.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCurrent
              ? Neon.cyan.withValues(alpha: .7)
              : Neon.violet.withValues(alpha: .45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.storage_rounded, color: Neon.textDim, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Neon.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (isCurrent)
                Container(
                  key: ValueKey('dual-current-${slot.wire}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Neon.cyan.withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '当前使用中',
                    style: TextStyle(color: Neon.cyan, fontSize: 11),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: const TextStyle(color: Neon.textFaint, fontSize: 11),
          ),
          const SizedBox(height: 8),
          Text(
            '状态：${info.statusText}'
            ' · 作品数：${works ?? '—'}'
            ' · 大小：${info.exists ? _formatSize(info.sizeBytes) : '—'}'
            ' · 修改时间：${info.modified == null ? '—' : _formatTime(info.modified!)}',
            style: const TextStyle(color: Neon.textDim, fontSize: 12),
          ),
          if (info.dbPath.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              info.dbPath,
              style: const TextStyle(color: Neon.textFaint, fontSize: 11),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              if (info.exists && !isCurrent)
                OutlinedButton(
                  key: ValueKey('dual-switch-${slot.wire}'),
                  onPressed: () => _switchTo(slot),
                  child: const Text('切换到此库'),
                ),
              if (slot == ActressDbSlot.imported && info.exists)
                OutlinedButton(
                  key: const ValueKey('dual-delete-imported'),
                  onPressed: _deleteImported,
                  child: const Text(
                    '删除导入库',
                    style: TextStyle(color: Neon.pink),
                  ),
                ),
              if (slot == ActressDbSlot.external && Platform.isAndroid) ...[
                OutlinedButton(
                  key: const ValueKey('dual-grant-folder'),
                  onPressed: () async {
                    final granted =
                        await ActressMytvBind.instance.grantFolderAccess();
                    if (!mounted) return;
                    setState(() {
                      _message = granted
                          ? '已取得文件夹授权，正在重新读取'
                          : '没有选择文件夹，或系统选择器打不开';
                      _error = null;
                    });
                    if (granted) {
                      await ActressMytvBind.instance.ensureBound(
                        refresh: true,
                      );
                      await _notifyLibraryChanged();
                    }
                    await _refresh();
                  },
                  child: const Text('授权文件夹读取'),
                ),
                OutlinedButton(
                  key: const ValueKey('dual-grant-file'),
                  onPressed: () async {
                    final granted =
                        await ActressMytvBind.instance.grantFileAccess();
                    if (!mounted) return;
                    setState(() {
                      _message = granted
                          ? '已取得文件授权，正在重新读取'
                          : '没有选择文件，或系统选择器打不开';
                      _error = null;
                    });
                    if (granted) {
                      await ActressMytvBind.instance.ensureBound(
                        refresh: true,
                      );
                      await _notifyLibraryChanged();
                    }
                    await _refresh();
                  },
                  child: const Text('授权单个数据库文件'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String _formatTime(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}
