import 'dart:async';

import 'package:flutter/material.dart';

import '../services/idj_plugin_store.dart';
import '../services/source_registry.dart';
import '../widgets/plugin_zone_view.dart';
import '../widgets/series_detail/moyi_detail_theme.dart';

/// 插件管理页（「我的」→ 插件管理，用户 2026-11-27 新布局令）：
/// 插件市场与已装插件管理全套在此一处——市场区段（订阅列表、
/// 逐个安装、后台静默自动更新，行为随 [PluginMarketSection] 原样）、
/// 已装插件列表（启用/停用、长按或行尾按钮卸载）、右上角「+」
/// 添加本地插件包 / 远程插件源。
///
/// 选站弹窗的插件区只保留显示（已装插件站能看、能点、能播），
/// 不再承担市场与管理职能，管理入口只此一处。
///
/// 成人插件门禁与市场同口径：修为未到第 1 档（元婴 3000）时，
/// 成人插件在已装列表里整行不显示。
/// 失败提示一律走 [idjPluginUserErrorText] 中文口径，不露异常原文。
class PluginManagePage extends StatefulWidget {
  const PluginManagePage({super.key, this.store});

  /// 插件仓库注入缝：不传用登记表的共用实例；测试 / 预览传假的。
  final IdjPluginStore? store;

  @override
  State<PluginManagePage> createState() => _PluginManagePageState();
}

class _PluginManagePageState extends State<PluginManagePage> {
  IdjPluginStore get _store =>
      widget.store ?? SourceRegistry.instance.idjStore;

  List<IdjInstalledPlugin>? _installed;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadInstalled());
  }

  Future<void> _loadInstalled() async {
    try {
      final installed = await _store.listInstalled();
      if (!mounted) return;
      setState(() {
        _installed = installed;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      debugPrint('已装插件列表加载失败：$error');
      _showSnack(idjPluginUserErrorText(error, '已装插件加载失败，请稍后重试'));
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> _setEnabled(IdjInstalledPlugin plugin, bool enabled) async {
    try {
      await _store.setEnabled(plugin.entry.pluginId, enabled);
    } catch (error) {
      debugPrint('插件启停失败（${plugin.entry.pluginId}）：$error');
      _showSnack(idjPluginUserErrorText(error, '操作失败，请稍后重试'));
    }
    await _loadInstalled();
  }

  Future<void> _uninstall(IdjInstalledPlugin plugin) async {
    final confirmed = await confirmUninstallPlugin(context, plugin.entry.name);
    if (!confirmed || !mounted) return;
    try {
      await _store.uninstall(plugin.entry.pluginId);
    } catch (error) {
      debugPrint('卸载插件失败（${plugin.entry.pluginId}）：$error');
      _showSnack(idjPluginUserErrorText(error, '卸载失败，请稍后重试'));
      return;
    }
    await _loadInstalled();
    _showSnack('已卸载插件「${plugin.entry.name}」');
  }

  @override
  Widget build(BuildContext context) {
    final gateOpen = idjAdultGateOpen(currentCultivationXp());
    final visibleInstalled = [
      for (final plugin in _installed ?? const <IdjInstalledPlugin>[])
        if (!(plugin.entry.adult || (plugin.manifest?.adult ?? false)) ||
            gateOpen)
          plugin,
    ];
    return Scaffold(
      backgroundColor: moyiSheetFill,
      appBar: AppBar(
        title: const Text('插件管理'),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            key: const ValueKey('plugin-manage-add'),
            icon: const Icon(Icons.add, color: moyiCyan),
            tooltip: '添加插件',
            onPressed: () => showPluginAddSheet(
              context,
              store: _store,
              onChanged: () => unawaited(_loadInstalled()),
            ),
          ),
        ],
      ),
      body: ListView(
        key: const ValueKey('plugin-manage-list'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          PluginMarketSection(
            store: _store,
            onChanged: () => unawaited(_loadInstalled()),
          ),
          const SizedBox(height: 20),
          const Text(
            '已安装插件',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          if (_loading && _installed == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '正在加载已装插件…',
                style: TextStyle(fontSize: 13, color: moyiMutedOnDark),
              ),
            ),
          if (_installed != null && visibleInstalled.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '还没有安装插件，在上方市场里点安装即可',
                style: TextStyle(fontSize: 13, color: moyiMutedOnDark),
              ),
            ),
          for (final plugin in visibleInstalled) _installedRow(plugin),
        ],
      ),
    );
  }

  Widget _installedRow(IdjInstalledPlugin plugin) {
    final entry = plugin.entry;
    final typeLabel = switch (entry.type) {
      'video' => '视频',
      'shortdrama' => '短剧',
      'comic' => '漫画',
      'live' => '直播',
      _ => entry.type,
    };
    final subtitle = plugin.damaged
        ? '已损坏 · ${plugin.damageReason}'
        : 'v${entry.version} · $typeLabel';
    return ListTile(
      key: ValueKey('plugin-installed-row-${entry.pluginId}'),
      contentPadding: EdgeInsets.zero,
      title: Text(
        entry.name,
        style: const TextStyle(fontSize: 14, color: Colors.white),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          fontSize: 12,
          color: plugin.damaged ? Colors.redAccent : moyiMutedOnDark,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            key: ValueKey('plugin-installed-toggle-${entry.pluginId}'),
            value: entry.enabled,
            onChanged: (value) => unawaited(_setEnabled(plugin, value)),
          ),
          IconButton(
            key: ValueKey('plugin-installed-uninstall-${entry.pluginId}'),
            icon: const Icon(
              Icons.delete_outline,
              color: moyiMutedOnDark,
              size: 20,
            ),
            tooltip: '卸载插件',
            onPressed: () => unawaited(_uninstall(plugin)),
          ),
        ],
      ),
      onLongPress: () => unawaited(_uninstall(plugin)),
    );
  }
}
