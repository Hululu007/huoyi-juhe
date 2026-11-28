import 'package:flutter/material.dart';

import 'actress_neon.dart';

/// 统一导入口的选文件页（2026-11-28 统一导入口批）：数据库
/// 管理页唯一的导入入口点开就是这一页——列 MYTV/db 里全部
/// 可导文件（名字＋大小），点哪份导哪份，导哪种库由软件按
/// 内容自动认（见 services/unified_import.dart），用户不用
/// 选、也不用分清这是哪个库。
///
/// 页尾一行次要入口「选择其他文件」：文件不在 MYTV/db 里时
/// 从这里走系统选择器（只适合小文件，选择器会把文件整份读
/// 进内存，大文件请放进 MYTV/db）。点它时本页以
/// [pickOtherFile] 作为结果返回，调用方据此走选择器流程。
class UnifiedImportListPage extends StatelessWidget {
  const UnifiedImportListPage({super.key, required this.files});

  /// MYTV/db 候选文件（名字＋真实路径＋大小），调用方已按名
  /// 排序；可为空（目录里没文件时只剩页尾次要入口）。
  final List<({String name, String path, int sizeBytes})> files;

  /// 「选择其他文件」行的返回标记（与文件记录区分）。
  static const pickOtherFile = '__pick_other_file__';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Neon.bg,
        foregroundColor: Neon.text,
        title: const Text('导入数据库', style: TextStyle(fontSize: 17)),
      ),
      body: SafeArea(
        child: ListView(
          key: const ValueKey('unified-import-list'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            const Text(
              '下面是 MYTV/db 里的文件，点哪份就导哪份。'
              '不用分清是哪个库——软件会按文件内容自动认出是'
              '站点库、女优库、磁力库还是三库合并文件，'
              '认不出的会当场告诉你、不会乱导。',
              style: TextStyle(color: Neon.textDim, fontSize: 12.5),
            ),
            const SizedBox(height: 12),
            if (files.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'MYTV/db 里暂时没有可导入的文件（.db、.sql 或 .sql.gz）。'
                  '先把文件放进 MYTV/db 再回来，或者用下面「选择其他文件」。',
                  key: ValueKey('unified-import-empty'),
                  style: TextStyle(color: Neon.textDim, fontSize: 12.5),
                ),
              )
            else
              for (final file in files)
                Padding(
                  key: ValueKey('unified-import-file-${file.name}'),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: Neon.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: Neon.violet.withValues(alpha: .45),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      leading: const Icon(
                        Icons.storage_rounded,
                        color: Neon.textDim,
                        size: 20,
                      ),
                      title: Text(
                        file.name,
                        style: const TextStyle(
                          color: Neon.text,
                          fontSize: 13.5,
                        ),
                      ),
                      subtitle: Text(
                        formatUnifiedImportSize(file.sizeBytes),
                        style: const TextStyle(
                          color: Neon.textFaint,
                          fontSize: 11.5,
                        ),
                      ),
                      trailing: const Icon(
                        Icons.chevron_right,
                        color: Neon.textDim,
                        size: 20,
                      ),
                      onTap: () => Navigator.of(context).pop(file),
                    ),
                  ),
                ),
            const SizedBox(height: 8),
            Material(
              color: Neon.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Neon.violet.withValues(alpha: .3)),
              ),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                key: const ValueKey('unified-import-pick-other'),
                leading: const Icon(
                  Icons.file_upload_rounded,
                  color: Neon.textDim,
                  size: 20,
                ),
                title: const Text(
                  '选择其他文件',
                  style: TextStyle(color: Neon.text, fontSize: 13.5),
                ),
                subtitle: const Text(
                  '文件不在 MYTV/db 里时用；只适合小文件（大文件请放进 MYTV/db）',
                  style: TextStyle(color: Neon.textFaint, fontSize: 11.5),
                ),
                onTap: () => Navigator.of(context).pop(pickOtherFile),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 文件大小中文格式（与管理页同款口径）。
String formatUnifiedImportSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
