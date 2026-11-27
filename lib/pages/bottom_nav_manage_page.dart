import 'dart:async';

import 'package:flutter/material.dart';

import '../services/bottom_nav_prefs.dart';
import '../services/cultivation.dart';
import '../widgets/editable_bottom_nav_bar.dart';
import '../widgets/series_detail/moyi_detail_theme.dart';
import '../widgets/settings/settings_widgets.dart';

/// 底部导航管理页：调底栏页签的顺序之外的显隐（排序在底栏长按
/// 编辑态里拖），隐藏的页签在这里恢复，另有恢复默认布局。
///
/// 演员库行上的「未解锁」只是标注：演员库的门禁管的是页签图标
/// （锁/人形）与页面内容（上锁页），不管页签显隐——未解锁时页签
/// 照常显示，隐藏/恢复也照常可用。
class BottomNavManagePage extends StatefulWidget {
  const BottomNavManagePage({super.key, this.prefs, this.actressUnlocked});

  /// 可注入（测试用）；缺省用全局单例。
  final BottomNavPrefs? prefs;

  /// 可注入（测试用）；缺省读修仙快照。
  final bool? actressUnlocked;

  @override
  State<BottomNavManagePage> createState() => _BottomNavManagePageState();
}

class _BottomNavManagePageState extends State<BottomNavManagePage> {
  BottomNavPrefs get _prefs => widget.prefs ?? BottomNavPrefs.instance;

  bool get _actressUnlocked =>
      widget.actressUnlocked ??
      CultivationService.instance.snapshot.unlockedVideo;

  @override
  void initState() {
    super.initState();
    _prefs.addListener(_onPrefsChanged);
    unawaited(_prefs.load());
  }

  @override
  void dispose() {
    _prefs.removeListener(_onPrefsChanged);
    super.dispose();
  }

  void _onPrefsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _hide(String id) async {
    final ok = await _prefs.hide(id);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('至少保留一个页签')),
      );
    }
  }

  Future<void> _confirmReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('恢复默认布局'),
        content: const Text('底栏页签将回到默认顺序，隐藏的页签全部恢复显示。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _prefs.reset();
  }

  Widget _tabRow(BottomNavTabDef def, {required bool hidden}) {
    final isActressLocked = def.id == 'actress' && !_actressUnlocked;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(def.icon, size: 22, color: Colors.white),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  def.label,
                  style: const TextStyle(
                    fontSize: 15,
                    color: Colors.white,
                  ),
                ),
                if (isActressLocked)
                  const Text(
                    '未解锁 · 到元婴期开放',
                    style: TextStyle(fontSize: 12, color: moyiMutedOnDark),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: () =>
                hidden ? _prefs.restore(def.id) : _hide(def.id),
            child: Text(hidden ? '恢复' : '隐藏'),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: moyiMutedOnDark,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _prefs.state;
    final visible = visibleBottomNavIds(state);
    final hiddenIds = <String>[
      for (final id in state.order)
        if (state.hidden.contains(id)) id,
    ];
    return SettingsScaffold(
      title: '底部导航管理',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _sectionTitle('当前显示'),
          SettingsGroupCard(
            children: [
              for (final id in visible)
                _tabRow(
                  bottomNavTabDef(id, actressUnlocked: _actressUnlocked),
                  hidden: false,
                ),
            ],
          ),
          _sectionTitle('已隐藏'),
          SettingsGroupCard(
            children: [
              if (hiddenIds.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Text(
                    '暂无隐藏的页签',
                    style: TextStyle(fontSize: 13, color: moyiMutedOnDark),
                  ),
                )
              else
                for (final id in hiddenIds)
                  _tabRow(
                    bottomNavTabDef(id, actressUnlocked: _actressUnlocked),
                    hidden: true,
                  ),
            ],
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: _confirmReset,
            child: const Text('恢复默认布局'),
          ),
        ],
      ),
    );
  }
}
