import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/onekey_py_service.dart';
import 'source_management_page.dart';

/// 设置 → 一键写PY：输网址，自动探测并生成 py，自动导进站源管理。
///
/// 匹配顺序：①域名精确匹配已知站（模板库）；②CMS 特征探测
/// （苹果 CMS → TVBox 接口 → MacCMS → WordPress → Next.js）；
/// ③通用网页嗅探兜底。探测与模板填充在 Python 工具里做，
/// 生成完调站源登记自动导入，不用手动导文件。
class OneKeyPyPage extends StatefulWidget {
  const OneKeyPyPage({super.key});

  @override
  State<OneKeyPyPage> createState() => _OneKeyPyPageState();
}

class _OneKeyPyPageState extends State<OneKeyPyPage> {
  final _urlController = TextEditingController();
  final _nameController = TextEditingController();
  bool _generating = false;
  OneKeyPyResult? _result;
  String? _matchedTemplate;

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  String _templateLabel(String templateId) {
    return switch (templateId) {
      'apple_cms_v10' => '苹果 CMS JSON',
      'tvbox_api' => 'TVBox 共享接口',
      'maccms_html' => 'MacCMS 网页',
      'wordpress' => 'WordPress',
      'nextjs' => 'Next.js',
      'generic_html' => '通用网页嗅探',
      _ => templateId.isEmpty ? '自动探测' : templateId,
    };
  }

  Future<void> _generate() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _result = const OneKeyPyResult(ok: false, message: '请先输入网站地址');
      });
      return;
    }
    setState(() {
      _generating = true;
      _result = null;
      _matchedTemplate = null;
    });
    final matched = await OneKeyPyService.instance.matchDomainTemplate(url);
    if (!mounted) return;
    setState(() => _matchedTemplate = matched);
    final result = await OneKeyPyService.instance.generate(
      url,
      name: _nameController.text,
    );
    if (!mounted) return;
    setState(() {
      _generating = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('一键写PY')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: '网站地址',
              hintText: '例如 https://example.com',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: '站名（可选，不填按域名自动取）',
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _generate(),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _generating ? null : _generate,
            icon: _generating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.wand_sparkles),
            label: Text(_generating ? '正在探测生成…' : '生成并导入'),
          ),
          if (_matchedTemplate != null) ...[
            const SizedBox(height: 12),
            Text(
              '域名已匹配模板：${_templateLabel(_matchedTemplate!)}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
          if (result != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          result.ok
                              ? LucideIcons.circle_check
                              : LucideIcons.circle_alert,
                          color: result.ok ? Colors.green : Colors.red,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            result.ok ? result.message : '生成失败',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ],
                    ),
                    if (result.ok) ...[
                      const SizedBox(height: 8),
                      Text('站名：${result.siteName}'),
                      Text('匹配模板：${_templateLabel(result.templateId)}'),
                      if (result.api.isNotEmpty) Text('接口：${result.api}'),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SourceManagementPage(),
                            ),
                          );
                        },
                        icon: const Icon(LucideIcons.list),
                        label: const Text('去站源管理查看'),
                      ),
                    ] else ...[
                      const SizedBox(height: 8),
                      Text(result.message),
                    ],
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            '说明：先按域名匹配已知站模板，匹配不上再按苹果 CMS → TVBox 接口 → MacCMS → WordPress → Next.js 的顺序探测，都没中走通用网页嗅探。生成完自动导进站源管理，不用手动导文件。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
