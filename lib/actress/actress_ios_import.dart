import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'actress_database.dart';
import 'actress_mytv_bind.dart';
import 'actress_sql_import.dart';
import 'actress_sql_import_section.dart';

/// iOS 演员库的 .sql 导入入口（2026-11-26 用户令，仅 iOS 接线）。
///
/// iOS 没有安卓的共享目录直读：演员库唯一数据来源是用户选
/// .sql / .sql.gz 文件导入、落进应用私有目录的那份库（绑定解析
/// 见 [ActressMytvBind._resolveIos]）。本组件只在 iOS 出现（调用
/// 方按平台门挂载），安卓侧不挂、行为零变化。
///
/// 流程：系统文档选择器选文件（file_selector，iOS 走系统面板、
/// 文件进沙盒）→ 先把文件拷进私有收件文件（选择器给的路径是
/// 安全作用域临时路径，导入是长任务，先落地再流式读）→ 跑
/// [ActressSqlImporter]（校验通过才换库、自动备份 .bak、失败
/// 原库不动）→ 成功后回调页面既有的重读路径刷新列表。
class ActressIosImportTile extends StatefulWidget {
  const ActressIosImportTile({super.key, required this.onImported});

  /// 导入走到换库（成功或换库失败）后调：页面重读数据库恢复
  /// 连接并刷新列表（走“重新加载数据库”同路）。
  final Future<void> Function() onImported;

  @override
  State<ActressIosImportTile> createState() => _ActressIosImportTileState();
}

class _ActressIosImportTileState extends State<ActressIosImportTile> {
  var _running = false;
  var _cancelled = false;
  ActressSqlImportProgress? _progress;
  String? _error;
  ActressSqlImportResult? _lastResult;

  Future<void> _startImport() async {
    if (_running) return;
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: '女优库数据', extensions: ['sql', 'gz']),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _running = true;
      _cancelled = false;
      _error = null;
      _lastResult = null;
      _progress = null;
    });
    File? inbox;
    try {
      final dbPath = await ActressMytvBind.instance.iosDbPath();
      // 收件文件与库同目录（私有目录内），导入完即删。
      inbox = File(
        path.join(
          path.dirname(dbPath),
          'inbox_${DateTime.now().microsecondsSinceEpoch}_${picked.name}',
        ),
      );
      final sink = inbox.openWrite();
      try {
        await sink.addStream(picked.openRead());
      } finally {
        await sink.close();
      }
      final result = await ActressSqlImporter().importFile(
        sqlPath: inbox.path,
        dbPath: dbPath,
        closeDatabase: () => SqfliteActressDatabase.instance.close(),
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
        isCancelled: () => _cancelled,
      );
      if (!mounted) return;
      setState(() {
        _running = false;
        _progress = null;
        if (result.ok) {
          _lastResult = result;
          _error = null;
        } else {
          _lastResult = null;
          _error = result.error ?? '导入失败';
        }
      });
      // 换库成功要重读新库；换库失败也要重读恢复连接（导入器
      // 已经关过主库连接）。校验不过/取消时 needsReload=false，
      // 主库没动，不重读。
      if (result.needsReload) await widget.onImported();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
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
    return ActressSqlImportSection(
      // iOS 私有落点恒可用，不存在“先绑定”这一步。
      bound: true,
      running: _running,
      progress: _progress,
      error: _error,
      lastResult: _lastResult,
      onImport: _startImport,
      onCancel: () => _cancelled = true,
    );
  }
}
