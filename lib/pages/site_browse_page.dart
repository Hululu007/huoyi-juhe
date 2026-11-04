import 'package:flutter/material.dart';

import '../services/drama_site_content.dart';
import '../services/drama_sites.dart';
import '../services/m3u_export.dart';
import '../services/m3u_export_db.dart';
import '../services/midnight_gate.dart';
import '../services/site_identity.dart';
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
    this.dbSink,
  });

  final String siteId;
  final String siteName;

  /// 测试注入的客户端；为空时走登记表取客户端。
  final DramaSiteContentClient? client;

  /// 测试注入的库；为空时用真实 Hive 库（预爬取与浏览存库都走它）。
  final M3uExportDbSink? dbSink;

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

  /// 一键启动预爬取：把本站全部分类（每分类最多 20 页）爬进本地库，
  /// 与一键写 PY 页的“导出到本地库”同一条链路，只是不带下载。
  Future<void> _preCrawl() async {
    final client = _client;
    if (client == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该站源当前不可用')),
      );
      return;
    }
    await MidnightGate.ensureLoaded();
    if (!mounted) return;
    final gateOpen = MidnightGate.activated.value;
    final custom = SourceRegistry.instance.customById(widget.siteId);
    final cancellation = LocalDbExportCancellation();
    LocalDbExportProgress? progress;
    LocalDbExportResult? result;
    Object? error;
    var started = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setState) {
            if (!started) {
              started = true;
              Future(() async {
                try {
                  result = await exportSiteToLocalDb(
                    siteId: widget.siteId,
                    siteName: widget.siteName,
                    client: client,
                    dbSink: widget.dbSink ?? HiveM3uExportDb.instance,
                    gateOpen: gateOpen,
                    allowNonM3u8: widget.siteId == 'hongguo',
                    siteAddress: custom?.address ?? '',
                    addressIsSiteAddress: custom != null &&
                        addressIsSiteAddressForKind(custom.kind.name),
                    cancellation: cancellation,
                    onProgress: (p) {
                      progress = p;
                      if (dialogCtx.mounted) setState(() {});
                    },
                  );
                } catch (e) {
                  error = e;
                }
                if (dialogCtx.mounted) setState(() {});
              });
            }
            final running = result == null && error == null;
            final lines = <String>[];
            if (running) {
              if (progress == null) {
                lines.add('正在读取分类…');
              } else {
                lines.add(
                  '正在预爬取：${progress!.categoryName} '
                  '（${progress!.categoriesDone}/${progress!.categoriesTotal} 个分类）',
                );
                lines.add(
                  '成功 ${progress!.successCount} 条，跳过 ${progress!.skippedCount} 条',
                );
              }
            } else if (error != null) {
              lines.add('预爬取失败：$error');
            } else if (result!.cancelled) {
              lines.add('已取消，未写入本地库。');
            } else {
              lines.add(
                '成功 ${result!.successCount} 条，跳过 ${result!.skippedCount} 条。',
              );
              if (result!.duplicateCount > 0) {
                lines.add('重复 ${result!.duplicateCount} 条已去重。');
              }
              if (result!.emptyCategories.isNotEmpty) {
                lines.add(
                  '以下分类没有可用地址：${result!.emptyCategories.join('、')}',
                );
              }
              if (result!.truncatedCategories.isNotEmpty) {
                lines.add(
                  '以下分类达到 20 页上限，可能未爬全：'
                  '${result!.truncatedCategories.join('、')}',
                );
              }
              if (result!.dbError != null) {
                lines.add('本地库写入失败：${result!.dbError}。');
              } else {
                lines.add(
                  '已写入本地库 ${result!.dbVideoCount} 条'
                  '（存放在手机根目录“火蚁聚合”文件夹）。',
                );
              }
              if (result!.successCount > 0) {
                lines.add('地址为预爬取时刻的快照，带签名的地址过期会失效，不是永久有效。');
              }
            }
            return AlertDialog(
              title: Text('预爬取本站：${widget.siteName}'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in lines) ...[
                    Text(line),
                    const SizedBox(height: 4),
                  ],
                  if (running) ...[
                    const SizedBox(height: 8),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
              actions: [
                if (running)
                  TextButton(
                    onPressed: cancellation.cancel,
                    child: const Text('取消'),
                  ),
                if (!running)
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('关闭'),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.siteName),
        actions: [
          IconButton(
            key: const Key('precrawl-button'),
            icon: const Icon(Icons.download),
            tooltip: '预爬取本站',
            onPressed: _client == null ? null : _preCrawl,
          ),
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
