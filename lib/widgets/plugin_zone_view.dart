import 'dart:async';

import 'package:flutter/material.dart';

import '../services/cultivation.dart';
import '../services/file_text_picker.dart';
import '../services/idj_plugin_store.dart';
import 'series_detail/moyi_detail_theme.dart';
import 'site_grid_dialog.dart';

/// 插件区组件（选站弹窗第三区）：已装插件的站网格由弹窗本体渲染，
/// 本文件提供市场区段（订阅列表 + 安装）、右上角「+」的添加
/// 面板（本地插件包 / 远程插件源）、卸载确认与已装条目构建。
///
/// 更新口径（用户 2026-11-27 令）：插件第一次由用户手动安装后，
/// 之后的新版由仓库在市场加载时后台静默自动装上——市场与已装
/// 列表不显示任何「更新 / 可更新 / 有新版本」字样或角标。
/// 卸载有两处长按入口：选站弹窗插件区的已装站网格（弹窗本体），
/// 与下方市场卡（已装条目长按弹同一确认框）。卸载清已装账
/// （包、索引、站点注册）并留一条「已卸载」记录（仓库持久化）：
/// 市场条目自此隐藏，远程版本高于卸载时版本才重新出现、可
/// 安装；装回后记录清除（四态见仓库 marketEntryHiddenAfterUninstall）。
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
    // 异常原文不上界面：已定义的人话失败直接用，其余给中文兜底。
    debugPrint('本地插件包安装失败：$error');
    message = idjPluginUserErrorText(error, '安装失败，请稍后重试');
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
    debugPrint('添加远程插件源失败：$error');
    message = idjPluginUserErrorText(error, '添加插件源失败，请检查地址后重试');
  }
  if (!context.mounted) return;
  if (succeeded) onChanged();
  _showSnack(context, message);
}

/// 插件市场区段：订阅分组（内置源在前）+ 逐条安装按钮 +
/// 已装状态。打开时重拉订阅（内容不持久化）；失败留旧列表记错误。
/// 列表先按现状上屏，随后在后台静默自动更新已装插件（见
/// [IdjPluginStore.autoUpdateFromSubscriptions]），装好后只刷新
/// 卡片状态，不弹提示、不显示更新字样。
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
  Map<String, String> _uninstalledVersions = {};
  String? _busyPluginId;
  bool _loading = true;
  bool _autoUpdating = false;

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
      final uninstalled = await widget.store.readUninstalledVersions();
      if (!mounted) return;
      setState(() {
        _subscriptions = subscriptions;
        _installedById = {
          for (final plugin in installed) plugin.entry.pluginId: plugin,
        };
        _uninstalledVersions = uninstalled;
        _loading = false;
      });
      // 现状先上屏，自动更新在后台跑，不拖慢进页。
      unawaited(_autoUpdate(subscriptions));
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      debugPrint('插件市场加载失败：$error');
      _showSnack(context, idjPluginUserErrorText(error, '插件市场加载失败，请稍后重试'));
    }
  }

  /// 后台静默自动更新：把订阅里版本更高的已装插件装上。结束时
  /// 无条件重读已装映射刷新卡片状态（本区段可能被重挂载、先行
  /// 的另一轮已经装好的结果也要带回本实例），装到新版时再通知
  /// 弹窗网格对账；全程不弹提示、不出现更新字样。失败由仓库
  /// 逐个记日志保旧版，这里整体异常同样只记日志。
  Future<void> _autoUpdate(List<IdjSubscription> subscriptions) async {
    if (_autoUpdating) return;
    _autoUpdating = true;
    try {
      final updated = await widget.store.autoUpdateFromSubscriptions(
        subscriptions,
      );
      if (!mounted) return;
      final installed = await widget.store.listInstalled();
      final uninstalled = await widget.store.readUninstalledVersions();
      if (!mounted) return;
      setState(() {
        _installedById = {
          for (final plugin in installed) plugin.entry.pluginId: plugin,
        };
        _uninstalledVersions = uninstalled;
      });
      if (updated.isNotEmpty) widget.onChanged();
    } catch (error) {
      debugPrint('插件自动更新失败：$error');
    } finally {
      _autoUpdating = false;
    }
  }

  Future<void> _install(IdjSubscriptionPlugin plugin) async {
    setState(() => _busyPluginId = plugin.id);
    try {
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
      }
      _showSnack(context, message);
    } catch (error) {
      debugPrint('插件安装失败（${plugin.id}）：$error');
      if (mounted) {
        _showSnack(context, idjPluginUserErrorText(error, '安装失败，请稍后重试'));
      }
    } finally {
      if (mounted) setState(() => _busyPluginId = null);
    }
  }

  /// 市场卡长按卸载（用户 2026-11-27 令，与选站弹窗插件区站网格
  /// 长按同一入口口径）：弹共用确认框，确认后走仓库卸载——包、
  /// 索引、站点注册清干净，并留「已卸载」记录；本卡随列表重拉
  /// 消失（远程升版后才重新出现，见仓库四态口径）。
  Future<void> _uninstallFromCard(IdjSubscriptionPlugin plugin) async {
    final confirmed = await confirmUninstallPlugin(context, plugin.name);
    if (!confirmed || !mounted) return;
    try {
      await widget.store.uninstall(plugin.id);
    } catch (error) {
      debugPrint('卸载插件失败（${plugin.id}）：$error');
      if (mounted) {
        _showSnack(context, idjPluginUserErrorText(error, '卸载失败，请稍后重试'));
      }
      return;
    }
    if (!mounted) return;
    widget.onChanged();
    await _load();
    if (!mounted) return;
    _showSnack(context, '已卸载插件「${plugin.name}」');
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
    if (confirmed != true || !mounted) return;
    try {
      await widget.store.removeSubscription(subscription.url);
    } catch (error) {
      // 原先这段没有兜底：删源失败是未捕获异步错误。原文进日志，
      // 界面给中文提示，列表保持原样。
      debugPrint('删除插件源失败：$error');
      if (mounted) _showSnack(context, '删除插件源失败，请稍后重试');
      return;
    }
    if (!mounted) return;
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
        if ((!plugin.adult || gateOpen) &&
            // 四态「已卸载隐藏」：没装着、且有已卸载记录、且远程
            // 版本不高于卸载时版本 → 整条不显示。已装条目不走
            // 这条（装回时记录已在仓库清掉）。
            (_installedById.containsKey(plugin.id) ||
                !IdjPluginStore.marketEntryHiddenAfterUninstall(
                  remoteVersion: plugin.version,
                  uninstalledVersion: _uninstalledVersions[plugin.id],
                )))
          plugin,
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
        if (visiblePlugins.isNotEmpty) _pluginGrid(visiblePlugins),
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

  /// 市场条目三列网格（用户 2026-11-27 令，与选站弹窗站卡网格同
  /// 列数口径：宽屏 4 列、手机宽 3 列）。旧的单列长条行（ListTile
  /// 尾随大按钮）已撤：卡内依次是首字图标块、站名、版本/状态、
  /// 安装动作，动作收在卡边界内，不再有行外溢出的按钮。
  /// 门禁过滤在组表时已完成（visiblePlugins），网格按过滤后的
  /// 列表紧凑排布，不留空位。
  Widget _pluginGrid(List<IdjSubscriptionPlugin> plugins) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 500 ? 4 : 3;
        const spacing = 8.0;
        final tileWidth = (width - spacing * (columns - 1)) / columns;
        // 卡高：16:9 图标块 + 站名（两行）+ 状态一行 + 动作区，
        // 与站卡网格的卡高口径接近，两个网格上下对齐不跳。
        final extent = tileWidth * 9 / 16 + 104;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 10,
            crossAxisSpacing: spacing,
            mainAxisExtent: extent,
          ),
          itemCount: plugins.length,
          itemBuilder: (context, index) => _pluginCard(plugins[index]),
        );
      },
    );
  }

  Widget _pluginCard(IdjSubscriptionPlugin plugin) {
    final installed = _installedById[plugin.id];
    final busy = _busyPluginId == plugin.id;
    final firstChar = plugin.name.isEmpty
        ? '?'
        : plugin.name.characters.first;
    // 状态行 + 动作：未装/损坏/已装/安装中四种。已装就是已装——
    // 订阅里版本更高也不摆「更新」（新版由自动更新在后台静默
    // 装上，用户 2026-11-27 令），状态只留已装版本号。
    final String status;
    final Widget action;
    if (busy) {
      status = '安装中…';
      action = const SizedBox(
        height: 30,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    } else if (installed == null) {
      status = 'v${plugin.version}';
      action = _cardActionButton(plugin, '安装');
    } else if (installed.damaged) {
      status = '已损坏 · v${installed.entry.version}';
      action = _cardActionButton(plugin, '重装');
    } else {
      status = 'v${installed.entry.version}';
      action = const SizedBox(
        height: 30,
        child: Center(
          child: Text(
            '已安装',
            style: TextStyle(fontSize: 12, color: moyiMutedOnDark),
          ),
        ),
      );
    }
    final card = Container(
      key: ValueKey('plugin-market-row-${plugin.id}'),
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
                    plugin.name,
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
                    style: const TextStyle(
                      fontSize: 11,
                      color: moyiMutedOnDark,
                    ),
                  ),
                  const Spacer(),
                  action,
                ],
              ),
            ),
          ),
        ],
      ),
    );
    // 已装条目长按卸载（与站网格长按同一确认框）；未装与安装中
    // 的卡不挂长按。手势包在卡外层，不拦卡内的安装/重装按钮点按。
    if (installed == null || busy) return card;
    return GestureDetector(
      onLongPress: () => _uninstallFromCard(plugin),
      child: card,
    );
  }

  Widget _cardActionButton(IdjSubscriptionPlugin plugin, String label) {
    return SizedBox(
      height: 30,
      width: double.infinity,
      child: FilledButton(
        key: ValueKey('plugin-install-${plugin.id}'),
        onPressed: () => _install(plugin),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          minimumSize: const Size(0, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: const TextStyle(fontSize: 13),
        ),
        child: Text(label),
      ),
    );
  }
}
