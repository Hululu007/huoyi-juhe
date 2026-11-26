import 'package:flutter/material.dart';

import '../services/cultivation.dart';
import '../services/file_text_picker.dart';
import '../services/idj_plugin_store.dart';
import 'series_detail/moyi_detail_theme.dart';
import 'site_grid_dialog.dart';

/// 插件区组件（选站弹窗第三区）：已装插件的站网格由弹窗本体渲染，
/// 本文件提供市场区段（订阅列表 + 安装/更新）、右上角「+」的添加
/// 面板（本地插件包 / 远程插件源）、卸载确认与已装条目构建。
///
/// 远程地址口径（用户 2026-11-26 令）：订阅地址绑定在程序里、
/// 界面永不显示地址原文——内置源只显示「官方插件源」，用户源只
/// 显示订阅自带名；条目里的包地址同样不展示。
///
/// 境界门禁（插件区分发面）：成人插件在修为未到第 1 档
/// （元婴 3000）时整行不显示——市场条目与已装网格都不出现。
/// 装好后的插件站在统一站表里与用户导入站同等待遇（既有体系对
/// 导入成人站本就不分档），门禁只挂在插件区这一层。

/// 成人插件门禁是否已开（第 1 档，3000 修为）。
bool idjAdultGateOpen(int xp) => adultTierUnlocked(0, xp);

/// 当前修为（界面判门禁用；服务未初始化时快照为初始值）。
int currentCultivationXp() => CultivationService.instance.snapshot.totalXp;

/// 已装插件 → 插件区站网格条目：只列启用、未损坏、能当站点用的
/// （video / shortdrama）；成人插件未解锁时整行不出现。
/// comic / live 已装但不进网格（本批未接内容链，市场行里如实标注）。
List<SiteGridEntry> pluginZoneEntriesFromInstalled(
  List<IdjInstalledPlugin> installed,
  int xp,
) {
  final gateOpen = idjAdultGateOpen(xp);
  return [
    for (final plugin in installed)
      if (!plugin.damaged &&
          plugin.entry.enabled &&
          plugin.entry.siteKey.isNotEmpty &&
          (plugin.manifest?.type == 'video' ||
              plugin.manifest?.type == 'shortdrama') &&
          (!(plugin.manifest?.adult ?? false) || gateOpen))
        (
          id: plugin.entry.siteKey,
          name: plugin.entry.name,
          zone: SiteGridZone.plugin,
          group: SiteGridGroup.video,
        ),
  ];
}

/// 卸载确认框（插件区长按与市场共用）：说清后果——站从列表移除、
/// 运行数据保留、重装可恢复。
Future<bool> confirmUninstallPlugin(BuildContext context, String name) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (confirmContext) => AlertDialog(
      key: const ValueKey('plugin-uninstall-confirm'),
      backgroundColor: moyiSheetFill,
      title: const Text(
        '卸载插件',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      content: Text(
        '确定卸载「$name」吗？卸载后该站从站点列表移除；插件的本地数据会保留，重装后可恢复。',
        style: const TextStyle(fontSize: 14, color: moyiBodyOnDark),
      ),
      actions: [
        TextButton(
          key: const ValueKey('plugin-uninstall-cancel'),
          onPressed: () => Navigator.pop(confirmContext, false),
          child: const Text('取消'),
        ),
        TextButton(
          key: const ValueKey('plugin-uninstall-ok'),
          onPressed: () => Navigator.pop(confirmContext, true),
          child: const Text('卸载', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );
  return confirmed == true;
}

void _showSnack(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
  );
}

/// 右上角「+」的添加面板：添加本地插件包 / 添加远程插件源。
/// 完成后经 [onChanged] 通知弹窗刷新插件区。
Future<void> showPluginAddSheet(
  BuildContext context, {
  required IdjPluginStore store,
  required VoidCallback onChanged,
}) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: moyiSheetFill,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const ValueKey('plugin-add-local'),
            leading: const Icon(Icons.file_open, color: moyiCyan),
            title: const Text(
              '添加本地插件包',
              style: TextStyle(color: Colors.white, fontSize: 15),
            ),
            subtitle: const Text(
              '选择 .idjplugin 文件安装',
              style: TextStyle(color: moyiMutedOnDark, fontSize: 12),
            ),
            onTap: () => Navigator.pop(sheetContext, 'local'),
          ),
          ListTile(
            key: const ValueKey('plugin-add-remote'),
            leading: const Icon(Icons.cloud_download, color: moyiCyan),
            title: const Text(
              '添加远程插件源',
              style: TextStyle(color: Colors.white, fontSize: 15),
            ),
            subtitle: const Text(
              '粘贴插件源地址，里面的插件会出现在插件市场里',
              style: TextStyle(color: moyiMutedOnDark, fontSize: 12),
            ),
            onTap: () => Navigator.pop(sheetContext, 'remote'),
          ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  if (action == 'local') {
    await _addLocalPlugin(context, store: store, onChanged: onChanged);
  } else if (action == 'remote') {
    await _addRemoteSubscription(context, store: store, onChanged: onChanged);
  }
}

Future<void> _addLocalPlugin(
  BuildContext context, {
  required IdjPluginStore store,
  required VoidCallback onChanged,
}) async {
  final picked = await pickTextFile(
    label: '插件包',
    extensions: ['idjplugin'],
  );
  if (picked == null || !context.mounted) return;
  var succeeded = false;
  String message;
  try {
    final installed = await store.installBundleText(picked.content);
    succeeded = true;
    final typeNote =
        (installed.manifest?.type == 'comic' ||
            installed.manifest?.type == 'live')
        ? '（该类型暂未接站点链）'
        : '';
    message = '已安装插件「${installed.entry.name}」$typeNote';
  } catch (error) {
    message = error.toString();
  }
  if (!context.mounted) return;
  if (succeeded) onChanged();
  _showSnack(context, message);
}

Future<void> _addRemoteSubscription(
  BuildContext context, {
  required IdjPluginStore store,
  required VoidCallback onChanged,
}) async {
  final controller = TextEditingController();
  final url = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('plugin-add-remote-dialog'),
      backgroundColor: moyiSheetFill,
      title: const Text(
        '添加远程插件源',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      content: TextField(
        key: const ValueKey('plugin-add-remote-field'),
        controller: controller,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        decoration: const InputDecoration(
          hintText: '粘贴插件源地址（https）',
          hintStyle: TextStyle(color: moyiMutedOnDark),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        TextButton(
          key: const ValueKey('plugin-add-remote-submit'),
          onPressed: () =>
              Navigator.pop(dialogContext, controller.text.trim()),
          child: const Text('添加'),
        ),
      ],
    ),
  );
  if (url == null || url.isEmpty || !context.mounted) return;
  var succeeded = false;
  String message;
  try {
    final subscription = await store.addSubscription(url);
    succeeded = true;
    message = '已添加插件源「${subscription.displayName}」';
  } catch (error) {
    message = error.toString();
  }
  if (!context.mounted) return;
  if (succeeded) onChanged();
  _showSnack(context, message);
}

/// 插件市场区段：订阅分组（内置源在前）+ 逐条安装/更新按钮 +
/// 已装状态。打开时重拉订阅（内容不持久化）；失败留旧列表记错误。
class PluginMarketSection extends StatefulWidget {
  const PluginMarketSection({
    super.key,
    required this.store,
    required this.onChanged,
  });

  final IdjPluginStore store;

  /// 装/卸/订阅变化后通知弹窗刷新插件区网格。
  final VoidCallback onChanged;

  @override
  State<PluginMarketSection> createState() => _PluginMarketSectionState();
}

class _PluginMarketSectionState extends State<PluginMarketSection> {
  List<IdjSubscription>? _subscriptions;
  Map<String, IdjInstalledPlugin> _installedById = {};
  String? _busyPluginId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final subscriptions = await widget.store.loadSubscriptions();
      final installed = await widget.store.listInstalled();
      if (!mounted) return;
      setState(() {
        _subscriptions = subscriptions;
        _installedById = {
          for (final plugin in installed) plugin.entry.pluginId: plugin,
        };
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showSnack(context, '插件市场加载失败：$error');
    }
  }

  Future<void> _install(IdjSubscriptionPlugin plugin) async {
    setState(() => _busyPluginId = plugin.id);
    try {
      final oldManifest = await widget.store.readInstalledManifest(plugin.id);
      final installed = await widget.store.installFromSubscriptionPlugin(
        plugin,
      );
      widget.onChanged();
      await _load();
      if (!mounted) return;
      var message = '已安装插件「${installed.entry.name}」';
      final manifest = installed.manifest;
      if (manifest != null &&
          (manifest.type == 'comic' || manifest.type == 'live')) {
        message += '（该类型暂未接站点链）';
      } else if (oldManifest != null && manifest != null) {
        final diff = IdjPluginStore.permissionDiff(oldManifest, manifest);
        if (!diff.isEmpty) {
          message += '；${diff.describe().join('；')}';
        }
      }
      _showSnack(context, message);
    } catch (error) {
      if (mounted) _showSnack(context, error.toString());
    } finally {
      if (mounted) setState(() => _busyPluginId = null);
    }
  }

  Future<void> _confirmRemoveSubscription(IdjSubscription subscription) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: moyiSheetFill,
        title: const Text(
          '删除插件源',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        content: Text(
          '删除插件源「${subscription.displayName}」？已经装好的插件不受影响。',
          style: const TextStyle(fontSize: 14, color: moyiBodyOnDark),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(
              '删除',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.store.removeSubscription(subscription.url);
    widget.onChanged();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final xp = currentCultivationXp();
    final gateOpen = idjAdultGateOpen(xp);
    return Column(
      key: const ValueKey('plugin-market-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '插件市场',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const Spacer(),
            IconButton(
              key: const ValueKey('plugin-market-refresh'),
              icon: const Icon(Icons.refresh, color: moyiMutedOnDark, size: 20),
              onPressed: _loading ? null : _load,
            ),
          ],
        ),
        if (_loading && _subscriptions == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '正在加载插件市场…',
              style: TextStyle(fontSize: 13, color: moyiMutedOnDark),
            ),
          ),
        if (_subscriptions != null)
          for (final subscription in _subscriptions!)
            _subscriptionBlock(subscription, gateOpen),
      ],
    );
  }

  Widget _subscriptionBlock(IdjSubscription subscription, bool gateOpen) {
    final visiblePlugins = [
      for (final plugin in subscription.plugins)
        if (!plugin.adult || gateOpen) plugin,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onLongPress: subscription.isBuiltIn
              ? null
              : () => _confirmRemoveSubscription(subscription),
          child: Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Text(
              subscription.displayName,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: moyiCyan,
              ),
            ),
          ),
        ),
        if (subscription.error.isNotEmpty && subscription.plugins.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '这个插件源暂时拉不到，检查网络后重试',
                    style: TextStyle(fontSize: 13, color: moyiMutedOnDark),
                  ),
                ),
                TextButton(
                  key: const ValueKey('plugin-market-retry'),
                  onPressed: _load,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        for (final plugin in visiblePlugins) _pluginRow(plugin),
        for (final cms in subscription.cms)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              cms.name,
              style: const TextStyle(fontSize: 14, color: moyiBodyOnDark),
            ),
            trailing: const Text(
              '采集站 · 暂不支持',
              style: TextStyle(fontSize: 12, color: moyiMutedOnDark),
            ),
          ),
      ],
    );
  }

  Widget _pluginRow(IdjSubscriptionPlugin plugin) {
    final installed = _installedById[plugin.id];
    final busy = _busyPluginId == plugin.id;
    final Widget action;
    if (busy) {
      action = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (installed == null) {
      action = FilledButton(
        key: ValueKey('plugin-install-${plugin.id}'),
        onPressed: () => _install(plugin),
        child: const Text('安装'),
      );
    } else if (installed.damaged) {
      action = FilledButton(
        key: ValueKey('plugin-install-${plugin.id}'),
        onPressed: () => _install(plugin),
        child: const Text('重装'),
      );
    } else if (IdjPluginManifest.compareVersions(
          plugin.version,
          installed.entry.version,
        ) >
        0) {
      action = FilledButton(
        key: ValueKey('plugin-install-${plugin.id}'),
        onPressed: () => _install(plugin),
        child: const Text('更新'),
      );
    } else {
      action = const Text(
        '已安装',
        style: TextStyle(fontSize: 13, color: moyiMutedOnDark),
      );
    }
    return ListTile(
      key: ValueKey('plugin-market-row-${plugin.id}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(
        '${plugin.name} ${plugin.version}',
        style: const TextStyle(fontSize: 14, color: Colors.white),
      ),
      subtitle: plugin.description.isEmpty
          ? null
          : Text(
              plugin.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: moyiMutedOnDark),
            ),
      trailing: action,
    );
  }
}
