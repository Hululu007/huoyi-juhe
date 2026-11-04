import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/one_click_py.dart';
import 'source_management_page.dart';

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
