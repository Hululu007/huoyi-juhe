import 'dart:async';

import 'package:flutter/material.dart';

import '../services/live_sources.dart';
import '../services/source_registry.dart';
import '../services/file_text_picker.dart';
import 'site_browse_page.dart';

/// 站源管理的一级技术分组：按技术分，空组也保留（页里显示“暂无…”）。
/// 预置内置站（extra['builtin'] == true）不在此表里，页里另起 jar 内置组；
/// 混合技术组不按类型再拆组，行内类型标区分。
List<({String title, String emptyTitle, List<SourceEntry> entries})>
managementTechGroups(List<SourceEntry> custom) {
  final own = custom.where((e) => e.extra['builtin'] != true).toList();
  List<SourceEntry> byKind(SourceKind kind) =>
      own.where((e) => e.kind == kind).toList();
  List<SourceEntry> jsonSources() => own
      .where(
        (e) =>
            e.kind == SourceKind.customMaccms ||
            e.kind == SourceKind.remoteJson,
      )
      .toList();
  return [
    (
      title: 'JSON 网页源',
      emptyTitle: '暂无 JSON 网页源',
      entries: jsonSources(),
    ),
    (
      title: 'JS 内容源',
      emptyTitle: '暂无 JS 内容源',
      entries: byKind(SourceKind.jsImport),
    ),
    (
      title: 'Python 内容源',
      emptyTitle: '暂无 Python 内容源',
      entries: byKind(SourceKind.pyImport),
    ),
    (
      title: 'Jar 内容源',
      emptyTitle: '暂无 Jar 内容源',
      entries: byKind(SourceKind.jarImport),
    ),
    (
      title: 'XBPQ',
      emptyTitle: '暂无 XBPQ 规则',
      entries: byKind(SourceKind.xbpqImport),
    ),
    (
      title: '阅读书源',
      emptyTitle: '暂无阅读书源',
      entries: byKind(SourceKind.legadoImport),
    ),
  ];
}

class SourceManagementPage extends StatefulWidget {
  const SourceManagementPage({super.key});

  @override
  State<SourceManagementPage> createState() => _SourceManagementPageState();
}

class _SourceManagementPageState extends State<SourceManagementPage> {
  bool _loading = true;
  final Map<String, String?> _checkResults = {};
  final Set<String> _checking = {};
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    SourceRegistry.instance.load().then((_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  Future<void> _refresh() async {
    await SourceRegistry.instance.load();
    if (mounted) setState(() {});
  }

  Future<void> _check(String siteId) async {
    if (_checking.contains(siteId)) return;
    setState(() {
      _checking.add(siteId);
      _checkResults.remove(siteId);
    });
    final error = await SourceRegistry.instance.checkSite(siteId);
    if (!mounted) return;
    setState(() {
      _checking.remove(siteId);
      _checkResults[siteId] = error;
    });
  }

  Future<void> _addDialog() async {
    final nameController = TextEditingController();
    final addressController = TextEditingController();
    var kind = SourceKind.customMaccms;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('添加站源'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: '名称（可空，默认用地址）',
                  ),
                ),
                TextField(
                  controller: addressController,
                  decoration: const InputDecoration(
                    labelText: '地址',
                    hintText: 'MacCMS 站点地址或远程 JSON 配置地址',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButton<SourceKind>(
                  value: kind,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(
                      value: SourceKind.customMaccms,
                      child: Text('MacCMS 站点'),
                    ),
                    DropdownMenuItem(
                      value: SourceKind.remoteJson,
                      child: Text('远程 JSON 配置'),
                    ),
                    DropdownMenuItem(
                      value: SourceKind.legadoImport,
                      child: Text('远程阅读书源 JSON'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => kind = value);
                  },
                ),
                const Text(
                  'MacCMS 站点按通用模板解析，个别模板可能不全；'
                  '远程 JSON 配置展开为影视站；远程阅读书源 JSON 展开为小说源。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    if (result != true || !mounted) return;
    try {
      if (kind == SourceKind.customMaccms) {
        await SourceRegistry.instance.addCustomMaccms(
          nameController.text,
          addressController.text,
        );
      } else if (kind == SourceKind.legadoImport) {
        await SourceRegistry.instance.addLegadoRemote(
          addressController.text,
        );
      } else {
        await SourceRegistry.instance.addRemoteJson(
          nameController.text,
          addressController.text,
        );
      }
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _addImportDialog() async {
    final nameController = TextEditingController();
    final sourceController = TextEditingController();
    final jarUrlController = TextEditingController();
    final classController = TextEditingController();
    final md5Controller = TextEditingController();
    final extController = TextEditingController();
    var kind = SourceKind.pyImport;
    var contentType = ContentType.mixed;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('导入蜘蛛'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: '名称'),
                ),
                DropdownButton<SourceKind>(
                  value: kind,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(
                      value: SourceKind.pyImport,
                      child: Text('Python（选择 .py 文件，引擎直跑）'),
                    ),
                    DropdownMenuItem(
                      value: SourceKind.jarImport,
                      child: Text('Jar（填 jar 地址与类名）'),
                    ),
                    DropdownMenuItem(
                      value: SourceKind.jsImport,
                      child: Text('JS（粘贴源码，引擎直跑）'),
                    ),
                    DropdownMenuItem(
                      value: SourceKind.xbpqImport,
                      child: Text('XBPQ（粘贴规则 JSON，声明式解析）'),
                    ),
                    DropdownMenuItem(
                      value: SourceKind.legadoImport,
                      child: Text('阅读书源（粘贴 JSON，可含多个源）'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => kind = value);
                  },
                ),
                DropdownButton<ContentType>(
                  value: contentType,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(
                      value: ContentType.mixed,
                      child: Text('类型：综合（影视与阅读都出现）'),
                    ),
                    DropdownMenuItem(
                      value: ContentType.video,
                      child: Text('类型：影视'),
                    ),
                    DropdownMenuItem(
                      value: ContentType.novel,
                      child: Text('类型：小说'),
                    ),
                    DropdownMenuItem(
                      value: ContentType.comic,
                      child: Text('类型：漫画'),
                    ),
                    DropdownMenuItem(
                      value: ContentType.audio,
                      child: Text('类型：听书'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => contentType = value);
                    }
                  },
                ),
                if (kind == SourceKind.pyImport) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final picked = await pickTextFile(
                          label: 'Python',
                          extensions: ['py'],
                        );
                        if (picked == null) return;
                        setDialogState(
                          () => sourceController.text = picked.content,
                        );
                      },
                      icon: const Icon(Icons.folder_open),
                      label: const Text('选择 .py 文件'),
                    ),
                  ),
                  TextField(
                    controller: sourceController,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      labelText: '蜘蛛源码',
                      hintText: '选择 .py 文件后源码显示在这里（含 class Spider），也可直接粘贴',
                    ),
                  ),
                ],
                if (kind == SourceKind.jarImport) ...[
                  TextField(
                    controller: jarUrlController,
                    decoration: const InputDecoration(labelText: 'jar 地址'),
                  ),
                  TextField(
                    controller: classController,
                    decoration: const InputDecoration(
                      labelText: '类名（可空，自动枚举首个可实例化类）',
                    ),
                  ),
                  TextField(
                    controller: md5Controller,
                    decoration: const InputDecoration(
                      labelText: 'jar md5（可空）',
                    ),
                  ),
                  TextField(
                    controller: extController,
                    decoration: const InputDecoration(labelText: 'ext（可空）'),
                  ),
                ],
                if (kind == SourceKind.jsImport)
                  TextField(
                    controller: sourceController,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      labelText: '蜘蛛源码',
                      hintText: '粘贴 .js 文件全文，含 homeContent 等方法',
                    ),
                  ),
                if (kind == SourceKind.xbpqImport)
                  TextField(
                    controller: sourceController,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      labelText: 'XBPQ 规则',
                      hintText: '粘贴规则 JSON 全文，含主页地址、分类、数组等字段',
                    ),
                  ),
                if (kind == SourceKind.legadoImport)
                  TextField(
                    controller: sourceController,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      labelText: '阅读书源 JSON',
                      hintText: '粘贴单个书源或书源数组，站名取源里自带的名字',
                    ),
                  ),
                const Text(
                  '引擎仅支持 Android；其他平台导入后暂不可播放。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    if (result != true || !mounted) return;
    try {
      if (kind == SourceKind.pyImport) {
        await SourceRegistry.instance.addPyImport(
          nameController.text,
          sourceController.text,
          contentType: contentType,
        );
      } else if (kind == SourceKind.jarImport) {
        await SourceRegistry.instance.addJarImport(
          nameController.text,
          jarUrlController.text,
          classController.text,
          md5Controller.text,
          extController.text,
          contentType: contentType,
        );
      } else if (kind == SourceKind.xbpqImport) {
        await SourceRegistry.instance.addXbpqImport(
          nameController.text,
          sourceController.text,
          contentType: contentType,
        );
      } else if (kind == SourceKind.legadoImport) {
        await SourceRegistry.instance.addLegadoImport(
          sourceController.text,
          contentType: contentType,
        );
      } else {
        await SourceRegistry.instance.addJsImport(
          nameController.text,
          sourceController.text,
          contentType: contentType,
        );
      }
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final registry = SourceRegistry.instance;
    final builtin = registry.builtinEntries();
    final builtinJar = registry.custom
        .where((entry) => entry.extra['builtin'] == true)
        .toList();
    final custom = registry.custom
        .where((entry) => entry.extra['builtin'] != true)
        .toList();
    // 一级分组按技术（见 managementTechGroups）；混合技术组不按类型
    // 再拆组，每行副标题里已有类型标（影视/小说/漫画/听书/综合）区分；
    // 阅读区与换源仍按类型过滤，那是行为，不随分组显示变。
    final techGroups = managementTechGroups(custom);
    final liveNames = LiveSources.builtin.map((s) => s.name).join('、');
    return Scaffold(
      appBar: AppBar(title: const Text('站源管理')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                _groupTitle('内置短剧'),
                for (final entry in builtin)
                  _builtinTile(entry),
                for (final group in techGroups) ...[
                  _groupTitle(group.title),
                  if (group.entries.isEmpty)
                    ListTile(title: Text(group.emptyTitle)),
                  for (final entry in group.entries) _customTile(entry),
                ],
                _groupTitle('直播源'),
                ListTile(
                  title: const Text('直播源汇总'),
                  subtitle: Text(
                    '${LiveSources.builtin.length} 个直播源：$liveNames',
                  ),
                ),
                _groupTitle('jar 内置'),
                if (builtinJar.isEmpty)
                  const ListTile(title: Text('暂无 jar 内置站源')),
                for (final entry in builtinJar) _customTile(entry),
                _groupTitle('内容源'),
                const ListTile(
                  title: Text('小说 / 听书 / 漫画内容源'),
                  subtitle: Text(
                    '各组按技术分，行内带类型标（影视/小说/漫画/听书/综合）区分；'
                    '阅读区与换源仍按类型过滤',
                  ),
                ),
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: OutlinedButton(
                    onPressed: _addDialog,
                    child: const Text('添加 MacCMS / 远程 JSON 站源'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: OutlinedButton(
                    onPressed: _addImportDialog,
                    child: const Text('导入 Python / Jar / JS / XBPQ'),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _groupTitle(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      title,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
  );

  Widget _builtinTile(SourceEntry entry) {
    final checking = _checking.contains(entry.id);
    final checkError = _checkResults[entry.id];
    final clientExists =
        SourceRegistry.instance.hasDramaContentClient(entry.id) ||
        entry.id == 'original';
    return ListTile(
      title: Text(entry.name),
      subtitle: Text(
        checkError == null
            ? (entry.enabled ? '已启用' : '已关闭，不出现在站点列表与全局搜索')
            : '检测失败：$checkError',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (clientExists)
            TextButton(
              onPressed: checking ? null : () => _check(entry.id),
              child: Text(checking ? '检测中…' : '检测'),
            ),
          Switch(
            value: entry.enabled,
            onChanged: (value) async {
              await SourceRegistry.instance.setBuiltinEnabled(
                entry.id,
                value,
              );
              await _refresh();
            },
          ),
        ],
      ),
    );
  }

  /// 可浏览的导入源：有内容客户端的 legado/py/jar/js/xbpq 导入源；
  /// 预置内置站不走这里（影视与午夜页已有它们的浏览入口）。
  bool _browsable(SourceEntry entry) {
    if (entry.extra['builtin'] == true) return false;
    return entry.kind == SourceKind.legadoImport ||
        entry.kind == SourceKind.pyImport ||
        entry.kind == SourceKind.jarImport ||
        entry.kind == SourceKind.jsImport ||
        entry.kind == SourceKind.xbpqImport;
  }

  Widget _customTile(SourceEntry entry) {
    final checking = _checking.contains(entry.id);
    final checkError = _checkResults[entry.id];
    final playable = entry.kind == SourceKind.customMaccms;
    // 折叠：默认只露一行类型标，点行或点箭头才展开地址/详情等多行。
    final expanded = _expanded.contains(entry.id);
    final lines = [
      '${entry.kind.label} · ${entry.contentType.label}',
      if (entry.address.isNotEmpty) entry.address,
      if (entry.detail.isNotEmpty) entry.detail,
      if (entry.extra['downloadPath'] is String &&
          (entry.extra['downloadPath'] as String).isNotEmpty)
        '下载文件：${entry.extra['downloadPath']}',
      if (checkError != null) '检测失败：$checkError',
    ];
    void toggleExpanded() {
      setState(() {
        if (expanded) {
          _expanded.remove(entry.id);
        } else {
          _expanded.add(entry.id);
        }
      });
    }

    return ListTile(
      title: Text(entry.name),
      subtitle: Text(expanded ? lines.join('\n') : lines.first),
      isThreeLine: expanded,
      onTap: toggleExpanded,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
            ),
            tooltip: expanded ? '收起' : '展开',
            onPressed: toggleExpanded,
          ),
          if (_browsable(entry))
            TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SiteBrowsePage(
                    siteId: entry.id,
                    siteName: entry.name,
                  ),
                ),
              ),
              child: const Text('浏览'),
            ),
          PopupMenuButton<ContentType>(
            icon: const Icon(Icons.category_outlined),
            tooltip: '改类型',
            onSelected: (type) async {
              await SourceRegistry.instance.setCustomContentType(
                entry.id,
                type,
              );
              await _refresh();
            },
            itemBuilder: (_) => [
              for (final type in ContentType.values)
                PopupMenuItem(
                  value: type,
                  child: Text(
                    type == entry.contentType
                        ? '${type.label}（当前）'
                        : type.label,
                  ),
                ),
            ],
          ),
          if (playable)
            TextButton(
              onPressed: checking ? null : () => _check(entry.id),
              child: Text(checking ? '检测中…' : '检测'),
            ),
          Switch(
            value: entry.enabled,
            onChanged: (value) async {
              await SourceRegistry.instance.setCustomEnabled(
                entry.id,
                value,
              );
              await _refresh();
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await SourceRegistry.instance.removeCustom(entry.id);
              await _refresh();
            },
          ),
        ],
      ),
    );
  }
}
