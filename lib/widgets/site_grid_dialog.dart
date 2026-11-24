import 'package:flutter/material.dart';

import '../services/cultivation.dart';
import '../services/source_registry.dart';
import 'series_detail/moyi_detail_theme.dart';

/// 站点在哪个区：builtin 内置区 / import 导入区。
///
/// 修仙版不要插件系统（用户 2026-11-24 20:25 令），弹窗只有这两区，
/// 没有插件区、没有插件相关代码。
enum SiteGridZone { builtin, import }

extension SiteGridZoneLabel on SiteGridZone {
  String get label => switch (this) {
    SiteGridZone.builtin => '内置区',
    SiteGridZone.import => '导入区',
  };
}

/// 区内分组：短剧 / 视频 / 午夜。按站自带的类型字段分，分不出的按
/// 站表归属老实归类（调用方给），弹窗内不猜。
enum SiteGridGroup { shortDrama, video, midnight }

extension SiteGridGroupLabel on SiteGridGroup {
  String get label => switch (this) {
    SiteGridGroup.shortDrama => '短剧',
    SiteGridGroup.video => '视频',
    SiteGridGroup.midnight => '午夜',
  };
}

/// 切换站点弹窗的一行：站 id、显示名、所在区、区内分组。
typedef SiteGridEntry =
    ({
      String id,
      String name,
      SiteGridZone zone,
      SiteGridGroup group,
    });

/// 当前站回落（纯函数，可单测）：当前站还在可见表里就留着；不在了
/// （弹窗里删/藏了当前站）就回落到可见表首站；表空了回 null，调用方
/// 保留旧站、不留野 id。
String? resolveCurrentSiteId(String? currentId, List<String> visibleIds) {
  if (currentId != null && visibleIds.contains(currentId)) return currentId;
  return visibleIds.isEmpty ? null : visibleIds.first;
}

/// 长按删/藏的执行入口（三个调用点共用）：导入站走修仙版自己的
/// [SourceRegistry.removeCustom] 真删除（删登记；Python 导入站同时
/// 删除本地文件副本；jar 站只释放、不删文件）；内置站只隐藏不删除，
/// 走已有的 [SourceRegistry.setBuiltinEnabled]（开关在「站源管理」
/// 里可再打开恢复）。行 id 先归一化成核心站 id 再记隐藏：种子行
/// `seed_x` / jar 行 `jar:zakatv:ZakaXxx` 与裸站行 `x` 是同一站，
/// 站源管理里的开关管的也是裸 id，归一化后两边才对得上。
/// 返回 true 表示删/藏成了，弹窗把该行摘掉；false 则行留着。
Future<bool> deleteSiteGridEntry(SiteGridEntry entry) async {
  if (entry.zone == SiteGridZone.import) {
    await SourceRegistry.instance.removeCustom(entry.id);
    return true;
  }
  await SourceRegistry.instance.setBuiltinEnabled(
    adultSiteIdForUnifiedId(entry.id),
    false,
  );
  return true;
}

/// 切换站点弹窗：居中弹窗（非底部弹层），站点按四列网格排列，
/// 点一项即选中并关闭，返回该站 id；点空白或返回则返回 null。
/// 站多时网格在弹窗内滚动（最高占屏高六成），站少时弹窗按内容收缩。
///
/// 两区：区签栏（内置区 / 导入区，带站数）在顶栏下方，点签或左右滑
/// 切区；区内再按短剧 / 视频 / 午夜分组（组标题「名 + 空格 + 数」）。
/// 搜索框只过滤活动区内的站。长按站名删/藏（见 [deleteSiteGridEntry]，
/// 确认框由弹窗内弹，导入站删、内置站藏）。
Future<String?> showSiteGridDialog({
  required BuildContext context,
  required List<SiteGridEntry> sites,
  String? selectedId,
  SiteGridZone initialZone = SiteGridZone.builtin,
  Future<bool> Function(SiteGridEntry entry)? onDeleteSite,

  /// 导入区空时的提示：默认指去「站源管理」导入。影视/午夜切换器
  /// 的统一表自 2026-11-24 起含用户导入站（见 `videoZoneSiteEntries`），
  /// 导入一个视频站就会出现在这里，两个调用点不再覆盖短提示。
  String emptyImportHint = '导入区还没有站，去「站源管理」导入一个',
}) async {
  if (sites.isEmpty) return null;
  final screenHeight = MediaQuery.of(context).size.height;
  return showDialog<String>(
    context: context,
    builder: (dialogContext) {
      return SiteGridDialog(
        sites: sites,
        selectedId: selectedId,
        initialZone: initialZone,
        onDeleteSite: onDeleteSite,
        emptyImportHint: emptyImportHint,
        maxHeight: screenHeight * 0.6,
      );
    },
  );
}

class SiteGridDialog extends StatefulWidget {
  const SiteGridDialog({
    super.key,
    required this.sites,
    this.selectedId,
    this.initialZone = SiteGridZone.builtin,
    this.onDeleteSite,
    this.emptyImportHint = '导入区还没有站，去「站源管理」导入一个',
    this.maxHeight = 500,
  });

  final List<SiteGridEntry> sites;
  final String? selectedId;
  final SiteGridZone initialZone;
  final Future<bool> Function(SiteGridEntry entry)? onDeleteSite;
  final String emptyImportHint;
  final double maxHeight;

  @override
  State<SiteGridDialog> createState() => _SiteGridDialogState();
}

class _SiteGridDialogState extends State<SiteGridDialog> {
  final _searchController = TextEditingController();
  late List<SiteGridEntry> _entries;
  late int _zoneIndex;
  int _flipDirection = 1;
  String _query = '';

  /// 区号 → 区：0 内置区，1 导入区。
  static const _zones = [SiteGridZone.builtin, SiteGridZone.import];

  List<SiteGridEntry> _zoneEntries(int zone) => [
    for (final entry in _entries)
      if (entry.zone == _zones[zone]) entry,
  ];

  int _zoneEntryCount(int zone) => _zoneEntries(zone).length;

  @override
  void initState() {
    super.initState();
    _entries = List.of(widget.sites);
    _zoneIndex = _zones.indexOf(widget.initialZone);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 切区：点区签或左右滑触发；记下翻页方向给滑动动画用。
  void _setZone(int index) {
    if (index == _zoneIndex || index < 0 || index > 1) return;
    _flipDirection = index > _zoneIndex ? 1 : -1;
    setState(() => _zoneIndex = index);
  }

  /// 长按删/藏：先弹确认框（导入站删、内置站藏），确认后调调用方
  /// 的执行入口；成了就把该行从列表摘掉。
  Future<void> _confirmDelete(SiteGridEntry entry) async {
    final handler = widget.onDeleteSite;
    if (handler == null) return;
    final isImport = entry.zone == SiteGridZone.import;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (confirmContext) => AlertDialog(
        key: const ValueKey('site-grid-delete-confirm'),
        backgroundColor: moyiSheetFill,
        title: Text(
          isImport ? '删除导入站' : '隐藏内置站',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        content: Text(
          isImport
              ? '确定删除「${entry.name}」吗？删除后从站点列表移除；Python 导入站同时删除本地文件副本。操作不可恢复。'
              : '「${entry.name}」只隐藏、不删除，可在「站源管理」里重新打开。',
          style: const TextStyle(fontSize: 14, color: moyiBodyOnDark),
        ),
        actions: [
          TextButton(
            key: const ValueKey('site-grid-delete-confirm-cancel'),
            onPressed: () => Navigator.pop(confirmContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('site-grid-delete-confirm-ok'),
            onPressed: () => Navigator.pop(confirmContext, true),
            child: Text(
              isImport ? '删除' : '隐藏',
              style: TextStyle(
                color: isImport ? Colors.redAccent : moyiCyan,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final done = await handler(entry);
    if (!mounted || !done) return;
    setState(() {
      _entries.removeWhere((item) => item.id == entry.id);
    });
  }

  bool _canDelete(SiteGridEntry entry) => widget.onDeleteSite != null;

  @override
  Widget build(BuildContext context) {
    const selectedColor = moyiCyan;
    final searching = _query.isNotEmpty;
    // 搜索只过滤活动区内的站，不跨区拉别的区的站进来。
    final zoneEntries = _zoneEntries(_zoneIndex);
    final filtered = searching
        ? zoneEntries
              .where(
                (entry) => entry.name.toLowerCase().contains(_query),
              )
              .toList()
        : zoneEntries;
    // 区内分组：短剧 → 视频 → 午夜固定顺序；搜索时不显示组标题。
    final visibleGroups = <SiteGridGroup>[];
    for (final group in SiteGridGroup.values) {
      if (filtered.any((entry) => entry.group == group)) {
        visibleGroups.add(group);
      }
    }
    return Dialog(
      key: const ValueKey('site-grid-dialog'),
      backgroundColor: moyiSheetFill,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '切换站点',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('site-grid-search'),
                controller: _searchController,
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: '搜索站点名称',
                  hintStyle: const TextStyle(color: moyiMutedOnDark),
                  prefixIcon: const Icon(
                    Icons.search,
                    color: moyiMutedOnDark,
                  ),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(
                            Icons.clear,
                            color: moyiMutedOnDark,
                          ),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: moyiDarkCardFill,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
              ),
              if (widget.onDeleteSite != null) ...[
                const SizedBox(height: 8),
                const Text(
                  '长按站点可删除或隐藏',
                  style: TextStyle(fontSize: 12, color: moyiMutedOnDark),
                ),
              ],
              const SizedBox(height: 8),
              _zoneTabs(),
              const SizedBox(height: 8),
              Flexible(
                child: GestureDetector(
                  // 左右滑切区：左滑进下一区（内置→导入），右滑回上一区；
                  // 到头再滑不翻。
                  onHorizontalDragEnd: (details) {
                    final velocity = details.primaryVelocity ?? 0;
                    if (velocity < -80) {
                      _setZone(_zoneIndex + 1);
                    } else if (velocity > 80) {
                      _setZone(_zoneIndex - 1);
                    }
                  },
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    // 翻页滑动：新区从行进方向那侧滑进来、旧区向反方向
                    // 滑出去（AnimatedSwitcher 对出场子项反向跑同一
                    // builder）。前翻（_flipDirection=1）新区从右侧滑入，
                    // 后翻从左侧滑入；时长 280ms 不变。不要 3D 旋转。
                    transitionBuilder: (child, animation) => SlideTransition(
                      position:
                          Tween<Offset>(
                            begin: Offset(_flipDirection.toDouble(), 0),
                            end: Offset.zero,
                          ).animate(animation),
                      child: child,
                    ),
                    child: KeyedSubtree(
                      key: ValueKey('site-grid-zone-$_zoneIndex'),
                      child: _listBody(
                        filtered,
                        visibleGroups,
                        searching,
                        selectedColor,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 区签栏：内置区 / 导入区（带站数），在翻页区外面——翻页时区签
  /// 与搜索框都不动，只有下面的列表翻。
  Widget _zoneTabs() {
    const keys = ['site-grid-zone-builtin', 'site-grid-zone-import'];
    Widget tab(int index) {
      final zone = _zones[index];
      final selected = _zoneIndex == index;
      final count = _zoneEntryCount(index);
      return Expanded(
        child: InkWell(
          key: ValueKey(keys[index]),
          borderRadius: BorderRadius.circular(10),
          onTap: () => _setZone(index),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: selected ? moyiCyan : moyiDarkCardFill,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Text(
              '${zone.label}（$count）',
              style: TextStyle(
                fontSize: 13,
                color: selected ? Colors.white : moyiBodyOnDark,
                fontWeight: selected ? FontWeight.w600 : null,
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        tab(0),
        const SizedBox(width: 8),
        tab(1),
      ],
    );
  }

  /// 列表区本体（翻页两区共用）：空态 / 分组网格。
  Widget _listBody(
    List<SiteGridEntry> filtered,
    List<SiteGridGroup> visibleGroups,
    bool searching,
    Color selectedColor,
  ) {
    if (filtered.isEmpty) {
      final emptyText = searching
          ? '没有匹配的站点'
          : _zoneIndex == 1
          ? widget.emptyImportHint
          : '没有匹配的站点';
      return Center(
        child: Text(
          emptyText,
          style: const TextStyle(fontSize: 14, color: moyiMutedOnDark),
        ),
      );
    }
    return ListView(
      shrinkWrap: true,
      children: [
        for (final group in visibleGroups) ...[
          if (!searching)
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Text(
                // 组标题纯文本「名 + 空格 + 数」，不用括号。
                '${group.label} ${filtered.where((entry) => entry.group == group).length}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.4,
            ),
            itemCount: filtered
                .where((entry) => entry.group == group)
                .length,
            itemBuilder: (ctx, index) {
              final entry = filtered
                  .where((item) => item.group == group)
                  .toList()[index];
              return _tile(entry, selectedColor);
            },
          ),
        ],
      ],
    );
  }

  Widget _tile(SiteGridEntry entry, Color selectedColor) {
    final selected = entry.id == widget.selectedId;
    return InkWell(
      key: ValueKey('site-grid-row-${entry.id}'),
      onTap: () => Navigator.pop(context, entry.id),
      onLongPress: _canDelete(entry) ? () => _confirmDelete(entry) : null,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? selectedColor : moyiDarkCardBorder,
            width: selected ? 2 : 1,
          ),
          color: selected ? selectedColor.withValues(alpha: 0.12) : null,
        ),
        child: Text(
          entry.name,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : null,
            color: selected ? selectedColor : moyiBodyOnDark,
          ),
        ),
      ),
    );
  }
}
