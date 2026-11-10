import 'dart:async';

import 'package:flutter/material.dart';

import '../services/live_sources.dart';
import '../services/source_registry.dart';
import '../services/file_text_picker.dart';
import '../widgets/series_detail/moyi_detail_theme.dart';
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

/// 导入/添加弹窗里的输入框：深紫半透明底 + 白字 + 提示字白 55% + 可见描边。
InputDecoration _moyiDialogField({
  required String labelText,
  String? hintText,
}) => InputDecoration(
  labelText: labelText,
  hintText: hintText,
  labelStyle: const TextStyle(color: moyiMutedOnDark),
  hintStyle: const TextStyle(color: moyiMutedOnDark),
  filled: true,
  fillColor: moyiDarkCardFill,
  border: const OutlineInputBorder(
    borderSide: BorderSide(color: moyiDarkCardBorder),
  ),
  enabledBorder: const OutlineInputBorder(
    borderSide: BorderSide(color: moyiDarkCardBorder),
  ),
  focusedBorder: const OutlineInputBorder(
    borderSide: BorderSide(color: moyiGold),
  ),
);

class SourceManagementPage extends StatefulWidget {
  const SourceManagementPage({super.key});

  @override
  State<SourceManagementPage> createState() => _SourceManagementPageState();
}

class _SourceManagementPageState extends State<SourceManagementPage> {
  bool _loading = true;
  final Map<String, String?> _checkResults = {};
  final Set<String> _checking = {};
  int? _liveChannelCount;

  @override
  void initState() {
    super.initState();
    SourceRegistry.instance.load().then((_) {
      if (mounted) setState(() => _loading = false);
    });
    unawaited(_loadLiveChannelCount());
  }

  /// 欲火直播内置频道表的条数：只作展示，读不到就只显示直播源个数。
  Future<void> _loadLiveChannelCount() async {
    try {
      final source = LiveSources.byId('yuhuo_live');
      if (source == null) return;
      final channels = await LiveSources.loadBuiltinListChannels(source);
      if (!mounted) return;
      setState(() => _liveChannelCount = channels.length);
    } catch (_) {
      // 读不到频道表不影响站源管理，静默只显示源个数。
    }
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
          backgroundColor: moyiSheetFill,
          title: const Text(
            '添加站源',
            style: TextStyle(color: Colors.white),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: '名称（可空，默认用地址）',
                    labelStyle: TextStyle(color: moyiMutedOnDark),
                    hintStyle: TextStyle(color: moyiMutedOnDark),
                    filled: true,
                    fillColor: moyiDarkCardFill,
                    border: OutlineInputBorder(
                      borderSide: BorderSide(color: moyiDarkCardBorder),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: moyiDarkCardBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: moyiGold),
                    ),
                  ),
                ),
                TextField(
                  controller: addressController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: '地址',
                    hintText: 'MacCMS 站点地址或远程 JSON 配置地址',
                    labelStyle: TextStyle(color: moyiMutedOnDark),
                    hintStyle: TextStyle(color: moyiMutedOnDark),
                    filled: true,
                    fillColor: moyiDarkCardFill,
                    border: OutlineInputBorder(
                      borderSide: BorderSide(color: moyiDarkCardBorder),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: moyiDarkCardBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: moyiGold),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButton<SourceKind>(
                  value: kind,
                  isExpanded: true,
                  dropdownColor: moyiSheetFill,
                  style: const TextStyle(color: Colors.white),
                  items: const [
                    DropdownMenuItem(
                      value: SourceKind.customMaccms,
                      child: Text(
                        'MacCMS 站点',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                    DropdownMenuItem(
                      value: SourceKind.remoteJson,
                      child: Text(
                        '远程 JSON 配置',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                    DropdownMenuItem(
                      value: SourceKind.legadoImport,
                      child: Text(
                        '远程阅读书源 JSON',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => kind = value);
                  },
                ),
                const Text(
                  'MacCMS 站点按通用模板解析，个别模板可能不全；'
                  '远程 JSON 配置展开为影视站；远程阅读书源 JSON 展开为小说源。',
                  style: TextStyle(fontSize: 12, color: moyiMutedOnDark),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              style: TextButton.styleFrom(foregroundColor: moyiGold),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: TextButton.styleFrom(foregroundColor: moyiGold),
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
          backgroundColor: moyiSheetFill,
          title: const Text(
            '导入蜘蛛',
            style: TextStyle(color: Colors.white),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: '名称',
                    labelStyle: TextStyle(color: moyiMutedOnDark),
                    hintStyle: TextStyle(color: moyiMutedOnDark),
                    filled: true,
                    fillColor: moyiDarkCardFill,
                    border: OutlineInputBorder(
                      borderSide: BorderSide(color: moyiDarkCardBorder),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: moyiDarkCardBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: moyiGold),
                    ),
                  ),
                ),
                DropdownButton<SourceKind>(
                  value: kind,
                  isExpanded: true,
                  dropdownColor: moyiSheetFill,
                  style: const TextStyle(color: Colors.white),
                  items: const [
                    DropdownMenuItem(
                      value: SourceKind.pyImport,
                      child: Text(
                        'Python（选择 .py 文件，引擎直跑）',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                    DropdownMenuItem(
                      value: SourceKind.jarImport,
                      child: Text(
                        'Jar（填 jar 地址与类名）',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                    DropdownMenuItem(
                      value: SourceKind.jsImport,
                      child: Text(
                        'JS（粘贴源码，引擎直跑）',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                    DropdownMenuItem(
                      value: SourceKind.xbpqImport,
                      child: Text(
                        'XBPQ（粘贴规则 JSON，声明式解析）',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                    DropdownMenuItem(
                      value: SourceKind.legadoImport,
                      child: Text(
                        '阅读书源（粘贴 JSON，可含多个源）',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => kind = value);
                  },
                ),
                DropdownButton<ContentType>(
                  value: contentType,
                  isExpanded: true,
                  dropdownColor: moyiSheetFill,
                  style: const TextStyle(color: Colors.white),
                  items: const [
                    DropdownMenuItem(
                      value: ContentType.mixed,
                      child: Text(
                        '类型：综合（影视与阅读都出现）',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                    DropdownMenuItem(
                      value: ContentType.video,
                      child: Text(
                        '类型：影视',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                    DropdownMenuItem(
                      value: ContentType.novel,
                      child: Text(
                        '类型：小说',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                    DropdownMenuItem(
                      value: ContentType.comic,
                      child: Text(
                        '类型：漫画',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                    DropdownMenuItem(
                      value: ContentType.audio,
                      child: Text(
                        '类型：听书',
                        style: TextStyle(color: Colors.white),
                      ),
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
                      style: OutlinedButton.styleFrom(
                        foregroundColor: moyiGold,
                        side: const BorderSide(color: moyiDarkCardBorder),
                      ),
                      icon: const Icon(Icons.folder_open),
                      label: const Text('选择 .py 文件'),
                    ),
                  ),
                  TextField(
                    controller: sourceController,
                    maxLines: 8,
                    style: const TextStyle(color: Colors.white),
                    decoration: _moyiDialogField(
                      labelText: '蜘蛛源码',
                      hintText:
                          '选择 .py 文件后源码显示在这里（含 class Spider），也可直接粘贴',
                    ),
                  ),
                ],
                if (kind == SourceKind.jarImport) ...[
                  TextField(
                    controller: jarUrlController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _moyiDialogField(labelText: 'jar 地址'),
                  ),
                  TextField(
                    controller: classController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _moyiDialogField(
                      labelText: '类名（可空，自动枚举首个可实例化类）',
                    ),
                  ),
                  TextField(
                    controller: md5Controller,
                    style: const TextStyle(color: Colors.white),
                    decoration: _moyiDialogField(labelText: 'jar md5（可空）'),
                  ),
                  TextField(
                    controller: extController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _moyiDialogField(labelText: 'ext（可空）'),
                  ),
                ],
                if (kind == SourceKind.jsImport)
                  TextField(
                    controller: sourceController,
                    maxLines: 8,
                    style: const TextStyle(color: Colors.white),
                    decoration: _moyiDialogField(
                      labelText: '蜘蛛源码',
                      hintText: '粘贴 .js 文件全文，含 homeContent 等方法',
                    ),
                  ),
                if (kind == SourceKind.xbpqImport)
                  TextField(
                    controller: sourceController,
                    maxLines: 8,
                    style: const TextStyle(color: Colors.white),
                    decoration: _moyiDialogField(
                      labelText: 'XBPQ 规则',
                      hintText: '粘贴规则 JSON 全文，含主页地址、分类、数组等字段',
                    ),
                  ),
                if (kind == SourceKind.legadoImport)
                  TextField(
                    controller: sourceController,
                    maxLines: 8,
                    style: const TextStyle(color: Colors.white),
                    decoration: _moyiDialogField(
                      labelText: '阅读书源 JSON',
                      hintText: '粘贴单个书源或书源数组，站名取源里自带的名字',
                    ),
                  ),
                const Text(
                  '引擎仅支持 Android；其他平台导入后暂不可播放。',
                  style: TextStyle(fontSize: 12, color: moyiMutedOnDark),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              style: TextButton.styleFrom(foregroundColor: moyiGold),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: TextButton.styleFrom(foregroundColor: moyiGold),
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
    return MoyiPageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('站源管理'),
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          foregroundColor: Colors.white,
        ),
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
                      _rowCard(
                        ListTile(
                          title: Text(
                            group.emptyTitle,
                            style: const TextStyle(color: moyiMutedOnDark),
                          ),
                        ),
                      ),
                    for (final entry in group.entries) _customTile(entry),
                  ],
                  _groupTitle('直播源'),
                  _rowCard(
                    ListTile(
                      title: const Text(
                        '直播源汇总',
                        style: TextStyle(color: moyiBodyOnDark),
                      ),
                      subtitle: Text(
                        _liveChannelCount == null
                            ? '${LiveSources.builtin.length} 个直播源：$liveNames'
                            : '${LiveSources.builtin.length} 个直播源：$liveNames'
                                  '，其中欲火直播频道表 $_liveChannelCount 条',
                        style: const TextStyle(color: moyiMutedOnDark),
                      ),
                    ),
                  ),
                  _groupTitle('jar 内置'),
                  if (builtinJar.isEmpty)
                    _rowCard(
                      const ListTile(
                        title: Text(
                          '暂无 jar 内置站源',
                          style: TextStyle(color: moyiMutedOnDark),
                        ),
                      ),
                    ),
                  for (final entry in builtinJar) _customTile(entry),
                  _groupTitle('内容源'),
                  _rowCard(
                    const ListTile(
                      title: Text(
                        '小说 / 听书 / 漫画内容源',
                        style: TextStyle(color: moyiBodyOnDark),
                      ),
                      subtitle: Text(
                        '各组按技术分，行内带类型标（影视/小说/漫画/听书/综合）区分；'
                        '阅读区与换源仍按类型过滤',
                        style: TextStyle(color: moyiMutedOnDark),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: OutlinedButton(
                      onPressed: _addDialog,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: moyiGold,
                        side: const BorderSide(color: moyiDarkCardBorder),
                      ),
                      child: const Text('添加 MacCMS / 远程 JSON 站源'),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    child: OutlinedButton(
                      onPressed: _addImportDialog,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: moyiGold,
                        side: const BorderSide(color: moyiDarkCardBorder),
                      ),
                      child: const Text('导入 Python / Jar / JS / XBPQ'),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  /// 深底上的站源行：深紫半透明卡底 + 紫描边（与搜索页同款）。
  ///
  /// 卡里再包一层透明 Material：ListTile 的墨水溅画在最近的 Material
  /// 祖先上，没有这层会被外面的 DecoratedBox 底色盖住（Flutter 断言）。
  Widget _rowCard(Widget child) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    decoration: BoxDecoration(
      color: moyiDarkCardFill,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: moyiDarkCardBorder),
    ),
    child: Material(
      type: MaterialType.transparency,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: child,
    ),
  );

  /// 金色开关：开态金 track + 白 thumb，未开态白 12% track（深底可读，
  /// 与原来主题金开关同色，不断开关逻辑）。
  Widget _goldSwitch({
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => Switch(
    value: value,
    onChanged: onChanged,
    activeTrackColor: moyiGold,
    activeThumbColor: Colors.white,
    inactiveTrackColor: Colors.white.withValues(alpha: 0.12),
    inactiveThumbColor: Colors.white,
    trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
  );

  Widget _groupTitle(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
    ),
  );

  Widget _builtinTile(SourceEntry entry) {
    final checking = _checking.contains(entry.id);
    final checkError = _checkResults[entry.id];
    final clientExists =
        SourceRegistry.instance.hasDramaContentClient(entry.id) ||
        entry.id == 'original';
    return _rowCard(
      ListTile(
        title: Text(
          entry.name,
          style: const TextStyle(color: moyiBodyOnDark),
        ),
        subtitle: Text(
          checkError == null
              ? (entry.enabled ? '已启用' : '已关闭，不出现在站点列表与全局搜索')
              : '检测失败：$checkError',
          style: const TextStyle(color: moyiMutedOnDark),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (clientExists)
              TextButton(
                onPressed: checking ? null : () => _check(entry.id),
                style: TextButton.styleFrom(foregroundColor: moyiGold),
                child: Text(checking ? '检测中…' : '检测'),
              ),
            _goldSwitch(
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
    return _rowCard(
      ListTile(
        title: Text(
          entry.name,
          style: const TextStyle(color: moyiBodyOnDark),
        ),
        subtitle: Text(
          [
            '${entry.kind.label} · ${entry.contentType.label}',
            if (entry.address.isNotEmpty) entry.address,
            if (entry.detail.isNotEmpty) entry.detail,
            if (entry.extra['downloadPath'] is String &&
                (entry.extra['downloadPath'] as String).isNotEmpty)
              '下载文件：${entry.extra['downloadPath']}',
            if (checkError != null) '检测失败：$checkError',
          ].join('\n'),
          style: const TextStyle(color: moyiMutedOnDark),
        ),
        isThreeLine: true,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                style: TextButton.styleFrom(foregroundColor: moyiGold),
                child: const Text('浏览'),
              ),
            PopupMenuButton<ContentType>(
              icon: const Icon(
                Icons.category_outlined,
                color: moyiMutedOnDark,
              ),
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
                style: TextButton.styleFrom(foregroundColor: moyiGold),
                child: Text(checking ? '检测中…' : '检测'),
              ),
            _goldSwitch(
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
              icon: const Icon(
                Icons.delete_outline,
                color: moyiMutedOnDark,
              ),
              onPressed: () async {
                await SourceRegistry.instance.removeCustom(entry.id);
                await _refresh();
              },
            ),
          ],
        ),
      ),
    );
  }
}
