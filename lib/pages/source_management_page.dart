import 'package:flutter/material.dart';

import '../services/drama_site_content.dart';
import '../services/source_registry.dart';

class SourceManagementPage extends StatefulWidget {
  const SourceManagementPage({super.key});

  @override
  State<SourceManagementPage> createState() => _SourceManagementPageState();
}

class _SourceManagementPageState extends State<SourceManagementPage> {
  bool _loading = true;
  final Map<String, String?> _checkResults = {};
  final Set<String> _checking = {};

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
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => kind = value);
                  },
                ),
                const Text(
                  'MacCMS 站点按通用模板解析，个别模板可能不全；'
                  '远程 JSON 配置只登记站点清单，内容接入随影视页签补。',
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
    final fileController = TextEditingController();
    var kind = SourceKind.pyImport;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('导入记录'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: '名称'),
                ),
                TextField(
                  controller: fileController,
                  decoration: const InputDecoration(labelText: '文件名'),
                ),
                DropdownButton<SourceKind>(
                  value: kind,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(
                      value: SourceKind.pyImport,
                      child: Text('Python'),
                    ),
                    DropdownMenuItem(
                      value: SourceKind.jsImport,
                      child: Text('JS'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => kind = value);
                  },
                ),
                const Text(
                  '只登记导入记录；Python 与 JS 执行引擎尚未接入，'
                  '登记的站暂不可播放。',
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
      await SourceRegistry.instance.addImportRecord(
        nameController.text,
        fileController.text,
        kind,
      );
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
    final custom = registry.custom;
    return Scaffold(
      appBar: AppBar(title: const Text('站源管理')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                _groupTitle('内置短剧'),
                for (final entry in builtin)
                  _builtinTile(entry),
                _groupTitle('自定义'),
                if (custom.isEmpty)
                  const ListTile(title: Text('暂无自定义站源')),
                for (final entry in custom) _customTile(entry),
                _groupTitle('内置影视'),
                const ListTile(
                  title: Text('暂无内置影视站源'),
                  subtitle: Text('影视页签接入后补'),
                ),
                _groupTitle('内容源'),
                const ListTile(
                  title: Text('小说 / 听书 / 漫画内容源'),
                  subtitle: Text('随阅读区统一改造补，见午夜区与阅读统一批'),
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
                    child: const Text('登记 Python / JS 导入'),
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
        dramaSiteContentClient(entry.id) != null ||
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

  Widget _customTile(SourceEntry entry) {
    final checking = _checking.contains(entry.id);
    final checkError = _checkResults[entry.id];
    final playable = entry.kind == SourceKind.customMaccms;
    return ListTile(
      title: Text(entry.name),
      subtitle: Text(
        [
          entry.kind.label,
          if (entry.address.isNotEmpty) entry.address,
          if (entry.detail.isNotEmpty) entry.detail,
          if (checkError != null) '检测失败：$checkError',
        ].join('\n'),
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
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
