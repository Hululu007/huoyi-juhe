import 'dart:async';

import 'package:flutter/material.dart';

import '../services/cultivation.dart';
import '../services/idj_plugin_store.dart';
import '../services/site_health.dart';
import '../services/site_thumb_cache.dart';
import '../services/source_registry.dart';
import 'plugin_zone_view.dart';
import 'series_detail/moyi_detail_theme.dart';
import 'site_thumb_image.dart';

/// 站点在哪个区：builtin 内置区 / import 导入区 / plugin 插件区。
///
/// 插件区是用户 2026-11-26 新令（推翻 2026-11-24「不要插件系统」
/// 的旧令）：安卓与 iOS 同一界面结构，选站由两区变三区。
/// 2026-11-27 新布局令：插件区在本弹窗里只保留显示——已装插件站
/// 能看、能点、能播；插件市场与已装插件管理（安装、卸载、启停、
/// 添加本地包/远程源）全套在「我的」页内嵌插件管理区段
/// （mine_plugin_section.dart，2026-11-27 20:16 令改为内嵌折叠
/// 展开），弹窗里不再有市场区段与添加按钮。旧调用点不传
/// `enablePluginZone` 时仍是两区，行为不变。
enum SiteGridZone { builtin, import, plugin }

extension SiteGridZoneLabel on SiteGridZone {
  String get label => switch (this) {
    SiteGridZone.builtin => '内置区',
    SiteGridZone.import => '导入区',
    SiteGridZone.plugin => '插件区',
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
  if (entry.zone == SiteGridZone.plugin) {
    // 插件条目的卸载在「我的 → 插件管理」页走 IdjPluginStore
    // （删包 + 摘站），弹窗里不挂长按；这里只作兜底：摘掉登记行，
    // 包由插件管理页处理。
    await SourceRegistry.instance.removeCustom(entry.id);
    return true;
  }
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
/// 区签栏（内置区 / 导入区，启用插件区时加插件区，带站数）在顶栏
/// 下方，点签或左右滑切区；区内再按短剧 / 视频 / 午夜分组（组标题
/// 「名 + 空格 + 数」）。搜索框只过滤活动区内的站。长按站名删/藏
/// （见 [deleteSiteGridEntry]，确认框由弹窗内弹，导入站删、内置站
/// 藏）；插件站不在弹窗里挂长按——卸载去「我的 → 插件管理」。
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

  /// 站点透视（魔蚁同步批 C1）的注入缝：不传用真实单例
  /// （SiteThumbCache.instance + 首页取封面）；测试 / 预览传假的。
  SiteThumbCache? thumbCache,
  SiteThumbFetcher? thumbFetcher,
  Widget Function(String url)? thumbImageBuilder,

  /// 插件区开关：三个生产调用点（片库影视 / 短剧 / 午夜）传 true，
  /// 弹窗变三区，插件区只显示已装插件站（市场与管理在「我的 →
  /// 插件管理」页）；其余调用点默认两区。
  bool enablePluginZone = false,

  /// 插件仓库注入缝：不传用登记表的共用实例；测试 / 预览传假的。
  IdjPluginStore? pluginStore,
}) async {
  if (sites.isEmpty && !enablePluginZone) return null;
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
        thumbCache: thumbCache,
        thumbFetcher: thumbFetcher,
        thumbImageBuilder: thumbImageBuilder,
        enablePluginZone: enablePluginZone,
        pluginStore: pluginStore,
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
    this.thumbCache,
    this.thumbFetcher,
    this.thumbImageBuilder,
    this.enablePluginZone = false,
    this.pluginStore,
  });

  final List<SiteGridEntry> sites;
  final String? selectedId;
  final SiteGridZone initialZone;
  final Future<bool> Function(SiteGridEntry entry)? onDeleteSite;
  final String emptyImportHint;
  final double maxHeight;

  /// 站点透视注入缝（见 [showSiteGridDialog] 同名参数）。
  final SiteThumbCache? thumbCache;
  final SiteThumbFetcher? thumbFetcher;
  final Widget Function(String url)? thumbImageBuilder;

  /// 插件区开关与仓库注入缝（见 [showSiteGridDialog] 同名参数）。
  final bool enablePluginZone;
  final IdjPluginStore? pluginStore;

  @override
  State<SiteGridDialog> createState() => _SiteGridDialogState();
}

class _SiteGridDialogState extends State<SiteGridDialog> {
  final _searchController = TextEditingController();
  late List<SiteGridEntry> _entries;
  late int _zoneIndex;
  int _flipDirection = 1;
  String _query = '';

  /// 区号 → 区：0 内置区，1 导入区；启用插件区时 2 是插件区。
  List<SiteGridZone> get _zones => widget.enablePluginZone
      ? const [SiteGridZone.builtin, SiteGridZone.import, SiteGridZone.plugin]
      : const [SiteGridZone.builtin, SiteGridZone.import];

  /// 插件仓库：注入缝优先，否则用登记表的共用实例。
  IdjPluginStore get _pluginStore =>
      widget.pluginStore ?? SourceRegistry.instance.idjStore;

  SiteGridZone get _currentZone => _zones[_zoneIndex];

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
    if (_zoneIndex < 0) _zoneIndex = 0;
    if (widget.enablePluginZone) {
      // 插件区条目以插件仓库为事实来源：进弹窗按已装清单对账一次，
      // 装/卸在别处发生过时这里也是最新的。
      unawaited(_reloadPluginEntries());
    }
    // 健康学习（A3）：进弹窗先把偏好与记录表加载进来，到了之后
    // 靠 revision / pickerSort 监听重画状态点与排序。
    unawaited(SiteHealthPrefs.instance.load());
    unawaited(SiteHealthStore.instance.load());
    SiteHealthStore.instance.revision.addListener(_onHealthChanged);
    SiteHealthPrefs.instance.pickerSort.addListener(_onHealthChanged);
  }

  @override
  void dispose() {
    SiteHealthStore.instance.revision.removeListener(_onHealthChanged);
    SiteHealthPrefs.instance.pickerSort.removeListener(_onHealthChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onHealthChanged() {
    if (mounted) setState(() {});
  }

  /// 切区：点区签或左右滑触发；记下翻页方向给滑动动画用。
  void _setZone(int index) {
    if (index == _zoneIndex || index < 0 || index >= _zones.length) return;
    _flipDirection = index > _zoneIndex ? 1 : -1;
    setState(() => _zoneIndex = index);
  }

  /// 按插件仓库的已装清单重算插件区条目（保留调用方给的分组，
  /// 如短剧选择器里插件站的短剧组）。
  Future<void> _reloadPluginEntries() async {
    try {
      await SourceRegistry.instance.syncIdjPluginSites();
      final installed = await _pluginStore.listInstalled();
      if (!mounted) return;
      final oldGroups = <String, SiteGridGroup>{
        for (final entry in _entries)
          if (entry.zone == SiteGridZone.plugin) entry.id: entry.group,
      };
      final fresh = [
        for (final entry in pluginZoneEntriesFromInstalled(
          installed,
          currentCultivationXp(),
        ))
          (
            id: entry.id,
            name: entry.name,
            zone: entry.zone,
            group: oldGroups[entry.id] ?? entry.group,
          ),
      ];
      setState(() {
        _entries = [
          for (final entry in _entries)
            if (entry.zone != SiteGridZone.plugin) entry,
          ...fresh,
        ];
      });
    } catch (_) {
      // 对账失败不打断选站：插件区保持调用方给的条目。
    }
  }

  /// 长按删/藏：先弹确认框（导入站删、内置站藏），确认后调调用方
  /// 的执行入口；成了就把该行从列表摘掉。插件站不走这里——弹窗
  /// 插件区只留显示，卸载在「我的 → 插件管理」页（见 _canDelete）。
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

  /// 插件站永不挂长按（管理只留「我的 → 插件管理」一处）；其余站
  /// 有删/藏执行入口时才挂。
  bool _canDelete(SiteGridEntry entry) =>
      entry.zone != SiteGridZone.plugin && widget.onDeleteSite != null;

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
              const Row(
                children: [
                  Text(
                    '切换站点',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  Spacer(),
                ],
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
                      child: _currentZone == SiteGridZone.plugin
                          ? _pluginZoneBody(
                              filtered,
                              visibleGroups,
                              searching,
                              selectedColor,
                            )
                          : _listBody(
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

  /// 区签栏：内置区 / 导入区（启用插件区时加插件区，带站数），
  /// 在翻页区外面——翻页时区签与搜索框都不动，只有下面的列表翻。
  Widget _zoneTabs() {
    const keys = [
      'site-grid-zone-builtin',
      'site-grid-zone-import',
      'site-grid-zone-plugin',
    ];
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
        for (var i = 0; i < _zones.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          tab(i),
        ],
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
          : _zones[_zoneIndex] == SiteGridZone.import
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
      children: _groupSections(
        filtered,
        visibleGroups,
        searching,
        selectedColor,
      ),
    );
  }

  /// 插件区本体（只留显示）：只有已装插件的站网格，点卡即选中。
  /// 市场与管理已搬到「我的 → 插件管理」页，这里不挂市场区段、
  /// 添加按钮与长按卸载。一个插件都没装时显示空态文案指路。
  Widget _pluginZoneBody(
    List<SiteGridEntry> filtered,
    List<SiteGridGroup> visibleGroups,
    bool searching,
    Color selectedColor,
  ) {
    if (filtered.isEmpty) {
      return Center(
        child: Text(
          searching ? '没有匹配的站点' : '还没有插件站，去「我的 → 插件管理」安装',
          style: const TextStyle(fontSize: 14, color: moyiMutedOnDark),
        ),
      );
    }
    return ListView(
      shrinkWrap: true,
      children: _groupSections(
        filtered,
        visibleGroups,
        searching,
        selectedColor,
      ),
    );
  }

  /// 分组网格区段（内置/导入两区与插件区共用）：组标题 + 站卡网格。
  List<Widget> _groupSections(
    List<SiteGridEntry> filtered,
    List<SiteGridGroup> visibleGroups,
    bool searching,
    Color selectedColor,
  ) {
    // 选站弹窗按健康排序（A3，设置里默认关）：组内按健康分降序、
    // 同分保原序；总开关关时分数恒中性，自然退化回原顺序。
    final healthSort =
        SiteHealthPrefs.instance.enabled.value &&
        SiteHealthPrefs.instance.pickerSort.value;
    List<SiteGridEntry> groupEntries(SiteGridGroup group) {
      final entries = [
        for (final entry in filtered)
          if (entry.group == group) entry,
      ];
      if (!healthSort) return entries;
      return stableHealthSort(
        entries,
        (entry) => SiteHealthStore.instance.scoreOf(entry.id),
      );
    }

    return [
      for (final group in visibleGroups) ...[
        if (!searching)
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text(
              // 组标题纯文本「名 + 空格 + 数」，不用括号。
              '${group.label} ${groupEntries(group).length}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final columns = width >= 500 ? 4 : 3;
            const spacing = 8.0;
            final tileWidth = (width - spacing * (columns - 1)) / columns;
            // 卡高：16:9 封面区 + 站名区（间距 4 + 两行站名约 34）。
            final extent = tileWidth * 9 / 16 + 42;
            final entries = groupEntries(group);
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: 10,
                crossAxisSpacing: spacing,
                mainAxisExtent: extent,
              ),
              itemCount: entries.length,
              itemBuilder: (ctx, index) =>
                  _tile(entries[index], selectedColor),
            );
          },
        ),
      ],
    ];
  }

  /// 站卡（站点透视 C1 + 健康点 A3）：上 16:9 封面区（站内随机
  /// 视频封面，可见才懒加载；取不到回落首字块、卡片不塌），下站名。
  /// 健康点只在该站已有学习记录时画（没学过的站不铺灰点）。
  /// 成人站的境界门禁在调用方组表时已过滤（未解锁根本不入表），
  /// 这里不取、不露未解锁站的封面。
  Widget _tile(SiteGridEntry entry, Color selectedColor) {
    final selected = entry.id == widget.selectedId;
    final firstChar = entry.name.isEmpty ? '?' : entry.name.characters.first;
    final tier = SiteHealthPrefs.instance.enabled.value
        ? SiteHealthStore.instance.tierOf(entry.id)
        : null;
    return InkWell(
      key: ValueKey('site-grid-row-${entry.id}'),
      onTap: () => Navigator.pop(context, entry.id),
      onLongPress: _canDelete(entry) ? () => _confirmDelete(entry) : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? selectedColor : moyiDarkCardBorder,
            width: selected ? 2 : 1,
          ),
          color: selected ? selectedColor.withValues(alpha: 0.12) : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  SiteThumbImage(
                    siteId: entry.id,
                    // 没传取数缝时不拉缩图（只显示回落块）：与魔蚁
                    // 同口径——只有片库 / 影视调用方传缓存 + 取数
                    // 函数才启用透视，其余弹窗与测试零副作用。
                    cache: widget.thumbCache,
                    fetcher: widget.thumbFetcher,
                    imageBuilder: widget.thumbImageBuilder,
                    fallback: Container(
                      color: moyiDarkCardFill,
                      alignment: Alignment.center,
                      child: Text(
                        firstChar,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  if (tier != null)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Container(
                        key: ValueKey('site-grid-health-dot-${entry.id}'),
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: _healthTierColor(tier),
                          shape: BoxShape.circle,
                          border: Border.all(color: moyiSheetFill, width: 1.5),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                entry.name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: entry.name.length > 12
                      ? 9.5
                      : entry.name.length > 8
                      ? 10.5
                      : 12,
                  fontWeight: selected ? FontWeight.w600 : null,
                  color: selected ? selectedColor : moyiBodyOnDark,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Color _healthTierColor(SiteHealthTier tier) => switch (tier) {
    SiteHealthTier.good => const Color(0xFF2EAF4F),
    SiteHealthTier.fair => const Color(0xFFE3A008),
    SiteHealthTier.bad => const Color(0xFFD64541),
    SiteHealthTier.unknown => const Color(0xFF9E9E9E),
  };
}
