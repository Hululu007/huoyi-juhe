import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../actress/actress_db_manage_page.dart';
import '../../pages/cached_books_page.dart';
import '../../pages/cached_dramas_page.dart';
import '../../pages/library_backup_page.dart';
import '../home/home_design.dart';
import '../home/home_shelf.dart';
import '../home/home_sheet.dart';
import '../series_detail/moyi_detail_theme.dart';

/// 我的 页底部的入口列表：离线缓存 / 备份与导入 / 数据库导入。
/// 插件管理不在此列——已按用户 2026-11-27 20:16 令内嵌到本页
/// 今日阅读原位置（mine_plugin_section.dart，原地折叠展开），
/// 选站弹窗插件区只留显示。应用设置在标题栏齿轮。
class MineEntries extends StatelessWidget {
  const MineEntries({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: homeSectionGap),
      child: Column(
        children: [
          Divider(
            height: 1,
            thickness: 0.6,
            color: palette.eink ? palette.line : moyiDarkCardBorder,
          ),
          MineEntryRow(
            icon: LucideIcons.hard_drive_download,
            label: '离线缓存',
            onTap: () => _showCacheChoices(context),
          ),
          MineEntryRow(
            icon: LucideIcons.archive_restore,
            label: '备份与导入',
            onTap: () => _push(context, const LibraryBackupPage()),
          ),
          MineEntryRow(
            icon: LucideIcons.database,
            label: '数据库导入',
            onTap: () => _push(context, const ActressDbManagePage()),
          ),
        ],
      ),
    );
  }
}

void _push(BuildContext context, Widget page) =>
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));

/// 小说离线缓存和短剧离线缓存是两套存储，各自有管理页；这里只做分流。
Future<void> _showCacheChoices(BuildContext context) async {
  await showHomeSheet<void>(
    context: context,
    title: '离线缓存',
    contentPadding: EdgeInsets.zero,
    children: [
      MineEntryRow(
        icon: LucideIcons.book_open,
        label: '小说离线缓存',
        onTap: () {
          Navigator.pop(context);
          _push(context, const CachedBooksPage());
        },
      ),
      MineEntryRow(
        icon: LucideIcons.clapperboard,
        label: '短剧离线缓存',
        onTap: () {
          Navigator.pop(context);
          _push(context, const CachedDramasPage());
        },
      ),
      const SizedBox(height: 8),
    ],
  );
}

class MineEntryRow extends StatelessWidget {
  final IconData icon;
  final String label;

  /// 行尾小字（有就显示在标题与箭头之间，如登录状态），没有不占位。
  final String? trailing;
  final VoidCallback onTap;

  const MineEntryRow({
    super.key,
    required this.icon,
    required this.label,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return HomePressable(
      onTap: onTap,
      borderRadius: BorderRadius.zero,
      semanticLabel: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: Row(
            children: [
              Icon(
                icon,
                size: 19,
                color: palette.eink ? palette.ink : Colors.white,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.3,
                    color: palette.eink ? palette.ink : Colors.white,
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    trailing!,
                    style: TextStyle(
                      fontSize: 13,
                      color: palette.eink ? palette.muted : moyiMutedOnDark,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
              const SizedBox(width: 4),
              Icon(
                LucideIcons.chevron_right,
                size: 16,
                color: palette.eink ? palette.muted : moyiMutedOnDark,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
