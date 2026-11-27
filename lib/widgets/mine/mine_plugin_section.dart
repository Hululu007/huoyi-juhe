import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/idj_plugin_store.dart';
import '../../services/source_registry.dart';
import '../home/home_shelf.dart';
import '../plugin_zone_view.dart';
import '../series_detail/moyi_detail_theme.dart';

/// 「我的」页内嵌插件管理（用户 2026-11-27 20:16 令）：落在今日
/// 阅读原来的位置（修仙档案卡正下方），不再点行跳独立管理页——
/// 插件市场与已安装两段都在原地折叠/展开：收起时每段只露三排
/// （三列网格的三排），点「展开全部」看全、再点收回。功能口径与
/// 原插件管理页一字不差：市场安装、后台静默自动更新（不显更新
/// 字样）、已装启停、长按或卡尾按钮卸载（同一确认框）、右上角
/// 「+」加本地包 / 远程源、远程地址不显示、成人插件未到元婴
/// （3000 修为）时整条不显示、卸载留记录四态。选站弹窗插件区
/// 不受影响（只显示）。
///
/// 失败提示一律走 [idjPluginUserErrorText] 中文口径，不露原文。
class MinePluginSection extends StatefulWidget {
  const MinePluginSection({super.key, this.store});

  /// 插件仓库注入缝：不传用登记表的共用实例；测试 / 预览传假的。
  final IdjPluginStore? store;

  @override
  State<MinePluginSection> createState() => _MinePluginSectionState();
}

class _MinePluginSectionState extends State<MinePluginSection> {
  IdjPluginStore get _store =>
      widget.store ?? SourceRegistry.instance.idjStore;

  List<IdjInstalledPlugin>? _installed;
  bool _loading = true;
  bool _installedExpanded = false;

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
    return Column(
      key: const ValueKey('mine-plugin-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            homeGutter,
            homeSectionGap,
            homeGutter - 8,
            4,
          ),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '插件管理',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 19,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    color: Colors.white,
                  ),
                ),
              ),
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
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
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
              if (visibleInstalled.isNotEmpty)
                _installedGrid(visibleInstalled),
            ],
          ),
        ),
      ],
    );
  }

  /// 已装插件三列网格（与市场卡同列数/同卡形）：收起只露三排，
  /// 超过三排时网格下方给「展开全部 / 收起」开关，原地展开收回。
  /// 卡内依次是首字块、站名、版本/状态、启停开关 + 卸载按钮；
  /// 长按整卡同样弹卸载确认（与原管理页行口径一致）。
  Widget _installedGrid(List<IdjInstalledPlugin> plugins) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 500 ? 4 : 3;
        const spacing = 8.0;
        final tileWidth = (width - spacing * (columns - 1)) / columns;
        final extent = tileWidth * 9 / 16 + 112;
        final cap = columns * 3;
        final shown = _installedExpanded
            ? plugins.length
            : (plugins.length < cap ? plugins.length : cap);
        return Column(
          children: [
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: 10,
                crossAxisSpacing: spacing,
                mainAxisExtent: extent,
              ),
              itemCount: shown,
              itemBuilder: (context, index) =>
                  _installedCard(plugins[index]),
            ),
            if (plugins.length > cap)
              Center(
                child: TextButton(
                  key: const ValueKey('plugin-installed-expand'),
                  onPressed: () => setState(
                    () => _installedExpanded = !_installedExpanded,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_installedExpanded ? '收起' : '展开全部'),
                      Icon(
                        _installedExpanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 18,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _installedCard(IdjInstalledPlugin plugin) {
    final entry = plugin.entry;
    final typeLabel = switch (entry.type) {
      'video' => '视频',
      'shortdrama' => '短剧',
      'comic' => '漫画',
      'live' => '直播',
      _ => entry.type,
    };
    final status = plugin.damaged
        ? '已损坏 · ${plugin.damageReason}'
        : 'v${entry.version} · $typeLabel';
    final firstChar = entry.name.isEmpty ? '?' : entry.name.characters.first;
    final card = Container(
      key: ValueKey('plugin-installed-row-${entry.pluginId}'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: moyiDarkCardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              color: moyiDarkCardFill,
              alignment: Alignment.center,
              child: Text(
                firstChar,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.white,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: plugin.damaged
                          ? Colors.redAccent
                          : moyiMutedOnDark,
                    ),
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      // 开关本体比三列小卡的内宽大，收进固定盒等比
                      // 缩小（点击仍走开关本体，命中坐标随盒缩放）。
                      SizedBox(
                        width: 44,
                        height: 30,
                        child: FittedBox(
                          child: Switch(
                            key: ValueKey(
                              'plugin-installed-toggle-${entry.pluginId}',
                            ),
                            value: entry.enabled,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            onChanged: (value) =>
                                unawaited(_setEnabled(plugin, value)),
                          ),
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        key: ValueKey(
                          'plugin-installed-uninstall-${entry.pluginId}',
                        ),
                        icon: const Icon(
                          Icons.delete_outline,
                          color: moyiMutedOnDark,
                          size: 20,
                        ),
                        tooltip: '卸载插件',
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        padding: EdgeInsets.zero,
                        onPressed: () => unawaited(_uninstall(plugin)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return GestureDetector(
      onLongPress: () => unawaited(_uninstall(plugin)),
      child: card,
    );
  }
}
