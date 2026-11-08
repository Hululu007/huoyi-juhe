import 'package:flutter/material.dart';

import '../services/drama_site_content.dart';
import '../services/drama_sites.dart';
import '../services/m3u_export_db.dart';
import '../services/source_registry.dart';
import '../widgets/home/drama_site_grid.dart';

/// 分类回退：没分类就只留“全部”。
List<DramaSiteCategory> browseCategories(List<DramaSiteCategory> raw) {
  if (raw.isEmpty) return const [DramaSiteCategory('all', '全部')];
  return raw;
}

/// 是不是多级分类：至少一个分类的父级真实存在（父级 id 在表里）。
/// 父级指向不存在 id 的孤儿不算层级，按顶级处理。
bool browseHasHierarchy(List<DramaSiteCategory> categories) {
  final ids = {for (final c in categories) c.id};
  return categories.any(
    (c) => c.parentId.isNotEmpty && ids.contains(c.parentId),
  );
}

/// 顶级分类：没父级，或父级不在表里（孤儿按顶级处理，不丢数据）。
List<DramaSiteCategory> browseRoots(List<DramaSiteCategory> categories) {
  final ids = {for (final c in categories) c.id};
  return [
    for (final c in categories)
      if (c.parentId.isEmpty || !ids.contains(c.parentId)) c,
  ];
}

/// 某一级的直接子分类。
List<DramaSiteCategory> browseChildren(
  List<DramaSiteCategory> categories,
  String parentId,
) {
  return [for (final c in categories) if (c.parentId == parentId) c];
}

/// 从顶级到选中分类的路径（含选中本身）；选中不在表里时为空。
/// 跟着 parentId 往上走，环与断链都截断，不死循环。
List<String> browsePath(List<DramaSiteCategory> categories, String selectedId) {
  final byId = {for (final c in categories) c.id: c};
  if (!byId.containsKey(selectedId)) return const [];
  final reversed = <String>[];
  final seen = <String>{};
  var current = selectedId;
  while (true) {
    if (!seen.add(current)) break;
    reversed.add(current);
    final parent = byId[current]?.parentId ?? '';
    if (parent.isEmpty || !byId.containsKey(parent)) break;
    current = parent;
  }
  return reversed.reversed.toList();
}

/// 通用浏览页：站源管理里导入源的发现入口。
/// 先取分类（失败时只留“全部”并把错误摆出来，不闪退），分类横排切换，
/// 下方复用 DramaSiteGrid（点卡片按内容分流：小说进阅读页、漫画进图片
/// 浏览页、听书进听书页、视频进播放页）。
class SiteBrowsePage extends StatefulWidget {
  const SiteBrowsePage({
    super.key,
    required this.siteId,
    required this.siteName,
    this.client,
    this.dbSink,
    this.initialCategoryId,
  });

  final String siteId;
  final String siteName;

  /// 测试注入的客户端；为空时走登记表取客户端。
  final DramaSiteContentClient? client;

  /// 测试注入的库；为空时用真实 Hive 库（预爬取与浏览存库都走它）。
  final M3uExportDbSink? dbSink;

  /// 打开即选中的分类 id（如详情页标签点按解析出的分类）：
  /// 在分类表里找得到就选中它，找不到（或取分类失败）仍按默认
  /// 逻辑选，页面照常出内容，不留白页。
  final String? initialCategoryId;

  @override
  State<SiteBrowsePage> createState() => _SiteBrowsePageState();
}

class _SiteBrowsePageState extends State<SiteBrowsePage> {
  bool _loading = true;
  DramaSiteContentClient? _client;
  List<DramaSiteCategory> _categories = const [];
  String _selectedId = 'all';
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var client = widget.client;
    client ??= await SourceRegistry.instance.clientFor(widget.siteId);
    if (!mounted) return;
    if (client == null) {
      setState(() {
        _loading = false;
        _error = '该站源当前不可用';
      });
      return;
    }
    final resolved = client;
    try {
      final cats = await resolved.categories();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _client = resolved;
        _categories = browseCategories(cats);
        // 指定分类优先：详情页标签点按带进来的分类 id 在表里就
        // 直接选中（走该分类的 catalog 接口）；不在表里才走默认。
        if (widget.initialCategoryId != null &&
            widget.initialCategoryId!.isNotEmpty &&
            _categories.any((c) => c.id == widget.initialCategoryId)) {
          _selectedId = widget.initialCategoryId!;
        } else if (browseHasHierarchy(_categories) &&
            _selectedId == 'all' &&
            !_categories.any((c) => c.id == 'all')) {
          // 多级分类初次打开默认选中第一个顶级（而不是留在一个不存在
          // 的 all 上导致首屏空白）；平铺分类保持原样不动。
          final roots = browseRoots(_categories);
          if (roots.isNotEmpty) _selectedId = roots.first.id;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _client = resolved;
        _categories = browseCategories(const []);
        _error = '取分类失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.siteName),
        actions: [
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _client == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error ?? '该站源当前不可用'),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    return CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(child: _categoryChips()),
                        if (_error != null)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          ),
                        DramaSiteGrid(
                          key: ValueKey(
                            'browse-${widget.siteId}-$_selectedId',
                          ),
                          siteId: widget.siteId,
                          categoryId: _selectedId,
                          gridWidth: constraints.maxWidth,
                          client: _client,
                          autoSaveToDb: true,
                          browseCategory: _categories.firstWhere(
                            (c) => c.id == _selectedId,
                            orElse: () =>
                                DramaSiteCategory(_selectedId, _selectedId),
                          ),
                          dbSink:
                              widget.dbSink ?? HiveM3uExportDb.instance,
                        ),
                      ],
                    );
                  },
                ),
    );
  }

  Widget _chipRow(
    List<DramaSiteCategory> cats,
    String? selectedId, {
    bool shortLabel = false,
  }) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          for (final cat in cats)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(shortLabel ? cat.name : cat.displayName),
                selected: selectedId == cat.id,
                onSelected: (_) {
                  setState(() => _selectedId = cat.id);
                },
              ),
            ),
        ],
      ),
    );
  }

  /// 分类条：平铺分类保持原来的一行；多级分类改成下钻：
  /// 每级一行（顶级行、选中路径上每级的子行、选中项的子行），
  /// 点顶级只展开子行、点叶子才切网格，路径上的行保留可回点。
  Widget _categoryChips() {
    final cats = _categories;
    if (!browseHasHierarchy(cats)) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: _chipRow(cats, _selectedId),
      );
    }
    final path = browsePath(cats, _selectedId);
    final rows = <Widget>[];
    for (var level = 0; level <= path.length; level++) {
      final siblings = level == 0
          ? browseRoots(cats)
          : browseChildren(cats, path[level - 1]);
      if (siblings.isEmpty) break;
      final selected = level < path.length ? path[level] : null;
      rows.add(_chipRow(siblings, selected, shortLabel: true));
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }
}
