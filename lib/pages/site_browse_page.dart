import 'package:flutter/material.dart';

import '../services/drama_site_content.dart';
import '../services/drama_sites.dart';
import '../services/source_registry.dart';
import '../widgets/home/drama_site_grid.dart';

/// 分类回退：没分类就只留“全部”。
List<DramaSiteCategory> browseCategories(List<DramaSiteCategory> raw) {
  if (raw.isEmpty) return const [DramaSiteCategory('all', '全部')];
  return raw;
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
  });

  final String siteId;
  final String siteName;

  /// 测试注入的客户端；为空时走登记表取客户端。
  final DramaSiteContentClient? client;

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
      appBar: AppBar(title: Text(widget.siteName)),
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
                        ),
                      ],
                    );
                  },
                ),
    );
  }

  Widget _categoryChips() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          for (final cat in _categories)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(cat.displayName),
                selected: _selectedId == cat.id,
                onSelected: (_) {
                  setState(() => _selectedId = cat.id);
                },
              ),
            ),
        ],
      ),
    );
  }
}
