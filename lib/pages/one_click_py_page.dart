import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:path_provider/path_provider.dart';

import '../services/drama_site_content.dart';
import '../services/drama_sites.dart';
import '../services/jar_bridge.dart';
import '../services/m3u_export.dart';
import '../services/m3u_export_db.dart';
import '../services/m3u_export_download.dart';
import '../services/midnight_gate.dart';
import '../services/one_click_py.dart';
import '../services/public_folder.dart';
import '../services/site_identity.dart';
import '../services/source_registry.dart';
import 'source_management_page.dart';

class _M3uExportTarget {
  const _M3uExportTarget({
    required this.siteId,
    required this.label,
    required this.subtitle,
    required this.allowNonM3u8,
    required this.resolveClient,
    this.siteAddress = '',
    this.addressIsSiteAddress = false,
  });

  final String siteId;
  final String label;
  final String subtitle;
  final bool allowNonM3u8;
  final Future<DramaSiteContentClient?> Function() resolveClient;

  /// 登记条目的地址与它是不是内容站地址（见 site_identity）：
  /// 选站列表按归一键去重、导出写库按归一键合一都认这两个字段。
  final String siteAddress;
  final bool addressIsSiteAddress;
}

class OneClickPyPage extends StatefulWidget {
  const OneClickPyPage({super.key});

  @override
  State<OneClickPyPage> createState() => _OneClickPyPageState();
}

class _OneClickPyPageState extends State<OneClickPyPage> {
  final _urlController = TextEditingController();
  final _nameController = TextEditingController();
  final _filterController = TextEditingController();
  final _historyStore = OneClickHistoryStore();

  var _adult = false;
  OneClickContent? _contentOverride;
  var _busy = false;
  var _identifying = false;
  OneClickIdentification? _identification;
  String? _identifiedUrl;
  OneClickGenerateResult? _result;
  String? _error;
  String? _pySource;
  var _history = const <OneClickHistoryEntry>[];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final entries = await _historyStore.load();
    if (!mounted) {
      return;
    }
    setState(() {
      _history = entries;
    });
  }

  Future<void> _identify() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _error = '请先输入网址';
      });
      return;
    }
    setState(() {
      _identifying = true;
      _error = null;
    });
    try {
      final identification = await identifySite(url, history: _history);
      if (!mounted) {
        return;
      }
      final previousUrl = _identifiedUrl;
      final currentUrl = normalizeSiteUrl(url);
      setState(() {
        _identification = identification;
        _identifiedUrl = currentUrl;
        if (_nameController.text.trim().isEmpty ||
            previousUrl != currentUrl) {
          _nameController.text = identification.siteName;
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error is StateError ? error.message : error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _identifying = false;
        });
      }
    }
  }

  Future<void> _generate() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _error = '请先输入网址';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _pySource = null;
    });
    try {
      final result = await generateAndImport(
        url: url,
        name: _nameController.text,
        adult: _adult,
        contentType: _contentOverride,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _result = result;
        _pySource = result.pySource;
        _identification = result.identification;
      });
      await _loadHistory();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error is StateError ? error.message : error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _openHistory() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final filtered = filterHistory(_history, _filterController.text);
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
              ),
              child: SizedBox(
                height: MediaQuery.of(sheetContext).size.height * 0.7,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: TextField(
                        controller: _filterController,
                        decoration: const InputDecoration(
                          labelText: '关键字过滤',
                          hintText: '按网站名称或网址过滤',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => setSheetState(() {}),
                      ),
                    ),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(child: Text('没有历史记录'))
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final entry = filtered[index];
                                return ListTile(
                                  title: Text(entry.name),
                                  subtitle: Text(
                                    '${entry.url} · ${entry.templateCode}',
                                  ),
                                  onTap: () {
                                    _urlController.text = entry.url;
                                    Navigator.pop(sheetContext);
                                  },
                                  trailing: IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    tooltip: '删除这条记录',
                                    onPressed: () async {
                                      await _historyStore.remove(entry.url);
                                      await _loadHistory();
                                      setSheetState(() {});
                                    },
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    _filterController.clear();
  }

  Future<void> _exportM3u() async {
    await SourceRegistry.instance.load();
    await MidnightGate.ensureLoaded();
    final gateOpen = MidnightGate.activated.value;
    final entries = filterM3uExportSites(
      SourceRegistry.instance.custom,
      gateOpen,
      includeJar: JarBridge.supported,
    );
    String subtitleFor(SourceKind kind) => switch (kind) {
      SourceKind.jarImport => 'jar 站',
      SourceKind.pyImport => 'py 站',
      SourceKind.customMaccms => '采集站',
      SourceKind.jsImport => 'JS 站',
      SourceKind.xbpqImport => '规则站',
      SourceKind.legadoImport => '书源站',
      _ => '登记站',
    };
    // 选站列表按归一键去重：同一站点多入口只列一行（内置行在前，
    // 后来的同站登记行被折掉），导出时不再对同一站重复爬第二份。
    final targets = dedupeByCanonicalKey(
      <_M3uExportTarget>[
        for (final builtin in m3uExportBuiltinTargets(
          dramaSites,
          SourceRegistry.instance.isBuiltinEnabled,
          gateOpen,
        ))
          _M3uExportTarget(
            siteId: builtin.siteId,
            label: builtin.label,
            subtitle: builtin.siteId == 'hongguo'
                ? '网页线 + 360p 兜底，非 m3u8 直链会注明条数'
                : '内置站',
            allowNonM3u8: builtin.allowNonM3u8,
            resolveClient: () =>
                SourceRegistry.instance.clientFor(builtin.siteId),
          ),
        for (final entry in entries)
          _M3uExportTarget(
            siteId: entry.id,
            label: entry.name,
            subtitle: subtitleFor(entry.kind),
            allowNonM3u8: false,
            resolveClient: () => SourceRegistry.instance.clientFor(entry.id),
            siteAddress: entry.address,
            addressIsSiteAddress:
                addressIsSiteAddressForKind(entry.kind.name),
          ),
      ],
      (target) => canonicalSiteKey(
        siteId: target.siteId,
        address: target.siteAddress,
        addressIsSiteAddress: target.addressIsSiteAddress,
      ),
    );
    if (!mounted) return;
    final picked = await showDialog<_M3uExportTarget>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选一个站点导出 m3u'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: targets.length,
            itemBuilder: (ctx, index) {
              final target = targets[index];
              return ListTile(
                title: Text(target.label),
                subtitle: Text(target.subtitle),
                onTap: () => Navigator.pop(ctx, target),
              );
            },
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final client = await picked.resolveClient();
    if (!mounted) return;
    if (client == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该站当前不可用（已关闭或导入副本缺失）')),
      );
      return;
    }
    final (downloadOptions, aborted) = await _pickDownloadOptions(client);
    if (aborted) return;
    await _runM3uExport(picked, client, gateOpen, downloadOptions);
  }

  Future<(M3uExportDownloadOptions?, bool)> _pickDownloadOptions(
    DramaSiteContentClient client,
  ) async {
    if (!mounted) return (null, true);
    final scope = await showDialog<M3uExportDownloadScope>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('下载到本地吗？（默认只导地址）'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, M3uExportDownloadScope.none),
            child: const Text('只导出地址，不下载'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, M3uExportDownloadScope.site),
            child: const Text('下载整站'),
          ),
          SimpleDialogOption(
            onPressed: () =>
                Navigator.pop(ctx, M3uExportDownloadScope.category),
            child: const Text('按分类下载'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, M3uExportDownloadScope.video),
            child: const Text('按单视频下载'),
          ),
        ],
      ),
    );
    if (scope == null || !mounted) return (null, true);
    if (scope == M3uExportDownloadScope.none) return (null, false);
    List<DramaSiteCategory> categories;
    try {
      categories = await client.categories();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('读取分类失败：$e')),
        );
      }
      return (null, true);
    }
    if (!mounted) return (null, true);
    final category = await showDialog<DramaSiteCategory>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选一个分类'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: categories.length,
            itemBuilder: (ctx, index) {
              final item = categories[index];
              return ListTile(
                title: Text(item.name),
                onTap: () => Navigator.pop(ctx, item),
              );
            },
          ),
        ),
      ),
    );
    if (category == null || !mounted) return (null, true);
    String? videoId;
    if (scope == M3uExportDownloadScope.video) {
      DramaSiteCatalogPage firstPage;
      try {
        firstPage = await client.catalog(category.id, 1);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('读取分类内容失败：$e')),
          );
        }
        return (null, true);
      }
      if (firstPage.items.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('该分类第一页没有视频')),
          );
        }
        return (null, true);
      }
      if (!mounted) return (null, true);
      final video = await showDialog<DramaSiteItem>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('选一个视频（仅第一页）'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: firstPage.items.length,
              itemBuilder: (ctx, index) {
                final item = firstPage.items[index];
                return ListTile(
                  title: Text(item.title),
                  onTap: () => Navigator.pop(ctx, item),
                );
              },
            ),
          ),
        ),
      );
      if (video == null) return (null, true);
      videoId = video.id;
    }
    return (
      M3uExportDownloadOptions(
        scope: scope,
        categoryId: scope == M3uExportDownloadScope.site ? null : category.id,
        videoId: videoId,
        downloader: HttpVideoDownloader(),
        directoryResolver: getApplicationSupportDirectory,
      ),
      false,
    );
  }

  Future<void> _runM3uExport(
    _M3uExportTarget target,
    DramaSiteContentClient client,
    bool gateOpen,
    M3uExportDownloadOptions? downloadOptions,
  ) async {
    final cancellation = M3uExportCancellation();
    M3uExportProgress? progress;
    M3uExportResult? result;
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
                  result = await exportSiteM3u(
                    siteId: target.siteId,
                    siteName: target.label,
                    client: client,
                    dbSink: HiveM3uExportDb.instance,
                    downloadOptions: downloadOptions,
                    gateOpen: gateOpen,
                    allowNonM3u8: target.allowNonM3u8,
                    siteAddress: target.siteAddress,
                    addressIsSiteAddress: target.addressIsSiteAddress,
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
                  '正在导出：${progress!.categoryName} '
                  '（${progress!.categoriesDone}/${progress!.categoriesTotal} 个分类）',
                );
                lines.add(
                  '成功 ${progress!.successCount} 条，跳过 ${progress!.skippedCount} 条',
                );
                if (progress!.downloadTotal > 0) {
                  lines.add(
                    '正在下载：${progress!.downloadTitle} '
                    '（${progress!.downloadDone}/${progress!.downloadTotal} 片）',
                  );
                }
              }
            } else if (error != null) {
              lines.add('导出失败：$error');
            } else if (result!.cancelled) {
              lines.add('已取消，未保存文件。');
            } else {
              lines.add(
                '成功 ${result!.successCount} 条，跳过 ${result!.skippedCount} 条。',
              );
              if (result!.nonM3u8Count > 0) {
                lines.add(
                  '其中非 m3u8 直链 ${result!.nonM3u8Count} 条'
                  '（红果中继解密形态，不是普通 m3u8）。',
                );
              }
              if (result!.duplicateCount > 0) {
                lines.add('重复 ${result!.duplicateCount} 条已去重。');
              }
              if (result!.emptyCategories.isNotEmpty) {
                lines.add(
                  '以下分类没有可用 m3u8：${result!.emptyCategories.join('、')}',
                );
              }
              if (result!.truncatedCategories.isNotEmpty) {
                lines.add(
                  '以下分类达到 20 页上限，可能未爬全：'
                  '${result!.truncatedCategories.join('、')}',
                );
              }
              lines.add('已保存到下载文件夹：${result!.downloadPath}');
              if (result!.dbError != null) {
                lines.add('数据库同步失败：${result!.dbError}（m3u 文件已保存）。');
              } else {
                lines.add(
                  '已同步写入本地数据库 ${result!.dbVideoCount} 条'
                  '（存放在手机根目录“火蚁聚合”文件夹）。',
                );
              }
              if (downloadOptions != null) {
                lines.add(
                  '已下载到本地 ${result!.downloadedCount} 条，'
                  '下载失败 ${result!.downloadFailedCount} 条'
                  '（失败的仍用在线地址）。',
                );
                if (result!.downloadBasePath != null) {
                  lines.add('本地文件在：${result!.downloadBasePath}');
                }
              }
              if (result!.successCount > 0) {
                lines.add('地址为导出时刻的快照，带签名的地址过期会失效，不是永久有效。');
              }
            }
            return AlertDialog(
              title: Text('导出 m3u：${target.label}'),
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
                if (!running &&
                    (result?.dbError?.contains('火蚁聚合文件夹') ?? false))
                  TextButton(
                    onPressed: PublicFolder.requestAllFilesAccess,
                    child: const Text('去开启全部文件访问权限'),
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
    final identification = _identification;
    return Scaffold(
      appBar: AppBar(title: const Text('一键写PY')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _urlController,
            decoration: InputDecoration(
              labelText: '网址',
              hintText: '站点首页或分类、详情页地址',
              border: const OutlineInputBorder(),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: _identifying ? null : _identify,
                    child: _identifying
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('识别'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.history),
                    tooltip: '历史记录',
                    onPressed: _openHistory,
                  ),
                ],
              ),
            ),
            onChanged: (_) {
              if (_identifiedUrl != null &&
                  _identifiedUrl != _urlController.text.trim()) {
                setState(() {
                  _identification = null;
                  _identifiedUrl = null;
                });
              }
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: '站名',
              hintText: '识别后按 host 自动填，可改',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text('成人站'),
            subtitle: const Text('开则显示名加 🔞 前缀，走午夜门禁'),
            value: _adult,
            onChanged: (value) => setState(() => _adult = value),
          ),
          DropdownButtonFormField<OneClickContent?>(
            initialValue: _contentOverride,
            decoration: const InputDecoration(
              labelText: '内容类型',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem<OneClickContent?>(
                value: null,
                child: Text('自动（按模板）'),
              ),
              for (final content in OneClickContent.values)
                DropdownMenuItem<OneClickContent?>(
                  value: content,
                  child: Text(content.label),
                ),
            ],
            onChanged: (value) => setState(() => _contentOverride = value),
          ),
          if (identification != null && identification.template.code == 'T5')
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('该模板小说与漫画共用，默认小说，可在上方切换。'),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _generate,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('生成并导入'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _exportM3u,
            child: const Text('导出 m3u'),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              '选红果或一个已导入的 py/jar 站，把全部分类视频的可播地址导出到下载文件夹。py/jar 站只收 m3u8，红果站写解析到的直链并注明非 m3u8 条数；取不到的跳过并报数；午夜未开时成人站不显示。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          if (identification != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      identification.trialMode
                          ? '模板：试套用（按 T1、T3、T5、T6、T9 顺序自检）'
                          : '模板：${identification.template.code} '
                              '${identification.template.name} · '
                              '${identification.template.levelLabel}',
                    ),
                    const SizedBox(height: 4),
                    Text(
                      identification.trialMode
                          ? '未命中已知模板，生成时逐项自检，验过才导入，不过如实报套不上。'
                          : identification.template.note,
                    ),
                    if (identification.fallbackNote != null) ...[
                      const SizedBox(height: 4),
                      Text(identification.fallbackNote!),
                    ],
                  ],
                ),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
          if (_result != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('已导入站点：${_result!.displayName}'),
                    const SizedBox(height: 4),
                    const Text('已出现在站点切换与影视页，不用手动导入。'),
                    if (_result!.downloadPath != null) ...[
                      const SizedBox(height: 4),
                      Text('下载文件夹原文件：${_result!.downloadPath}'),
                    ],
                    const SizedBox(height: 4),
                    const Text('删除请到站源管理，删除后下载文件夹原文件保留。'),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SourceManagementPage(),
                          ),
                        );
                      },
                      child: const Text('去站源管理查看'),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_pySource != null) ...[
            const SizedBox(height: 16),
            ExpansionTile(
              title: const Text('查看生成的 py'),
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.copy),
                      label: const Text('复制'),
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: _pySource!),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制')),
                          );
                        }
                      },
                    ),
                  ],
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest,
                  child: SelectableText(
                    _pySource!,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
