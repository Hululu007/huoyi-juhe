import 'package:flutter/material.dart';

import 'actress_sql_import.dart';

/// 演员库设置弹窗里的“导入数据库”区（2026-11-25 用户令）。
///
/// 与弹窗里其它区同一版式（圆点 + 标题 + 说明 + 右侧按钮）。
/// 三种状态都由调用方喂进来，本 widget 只按值画画：
/// 空闲（未绑定时按钮置灰）、导入中（进度条 + 已导入条数 + 取消）、
/// 导完（成功数 / 失败原因）。预览测试直接拿它拍图，不用搭整页。
class ActressSqlImportSection extends StatelessWidget {
  const ActressSqlImportSection({
    super.key,
    required this.bound,
    required this.running,
    required this.progress,
    required this.error,
    required this.lastResult,
    required this.onImport,
    required this.onCancel,
  });

  /// true = MYTV 已绑定、有主库路径可替换；false = 先绑定 MYTV。
  final bool bound;

  /// true = 正在导入（进度条 + 取消按钮）。
  final bool running;

  /// 导入进度（running 时才有值）。
  final ActressSqlImportProgress? progress;

  /// 上次导入的失败原因（成功后为空）。
  final String? error;

  /// 上次导入成功的结果（失败后为空）。
  final ActressSqlImportResult? lastResult;

  /// 点“导入数据库”。
  final VoidCallback? onImport;

  /// 点“取消”（导入中才有）。
  final VoidCallback? onCancel;

  String _progressText() {
    final p = progress;
    if (p == null) return '正在导入…';
    if (p.phase == '正在校验') return '正在校验导入的数据库…';
    final percent = (p.fraction * 100).toStringAsFixed(0);
    return '正在导入…已导入 ${p.statements} 条（$percent%）';
  }

  String _resultText() {
    final r = lastResult;
    if (r == null || !r.ok) return '';
    final text =
        '已导入：${r.videos} 部作品 · ${r.actresses} 人'
        ' · 封面 ${r.covers} · 头像 ${r.avatars}';
    if (r.warnings.isEmpty) return text;
    return '$text\n${r.warnings.join('\n')}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme;
    final body = StringBuffer();
    if (bound) {
      body.write('从 .sql / .sql.gz 文件导入，替换当前女优库。');
      body.write('导入前自动备份原库（女优库.db.bak），失败原库不动。');
    } else {
      body.write('先绑定 MYTV 再导入数据库。');
    }
    final resultText = _resultText();
    if (resultText.isNotEmpty) body.write('\n$resultText');
    if (error != null && error!.isNotEmpty) body.write('\n导入失败：$error');

    return Padding(
      key: const ValueKey('actress-sql-import'),
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: running
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.circle, size: 8),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('导入数据库（.sql）', style: textStyle.titleSmall),
                const SizedBox(height: 2),
                Text(
                  body.toString(),
                  style: textStyle.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (running) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: (progress?.fraction ?? 0).clamp(0, 1),
                  ),
                  const SizedBox(height: 4),
                  Text(_progressText(), style: textStyle.bodySmall),
                ],
              ],
            ),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            children: [
              if (running)
                TextButton(
                  key: const ValueKey('actress-sql-import-cancel'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: onCancel,
                  child: const Text('取消'),
                )
              else
                TextButton(
                  key: const ValueKey('actress-sql-import-button'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: bound ? onImport : null,
                  child: const Text('导入数据库'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
