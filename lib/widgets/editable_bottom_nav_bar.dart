import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/bottom_nav_prefs.dart';

/// 一个底栏页签的展示定义（图标 + 标签）。演员库的锁/人形图标由
/// 外部按门禁状态选好后传入，本控件不读任何业务服务。
@immutable
class BottomNavTabDef {
  const BottomNavTabDef({
    required this.id,
    required this.icon,
    required this.label,
  });

  final String id;
  final IconData icon;
  final String label;
}

/// 页签 id → 展示定义。演员库未解锁时是锁图标（页签常驻显示，
/// 门禁只管图标与页面内容，不管页签显隐）。
BottomNavTabDef bottomNavTabDef(String id, {required bool actressUnlocked}) {
  return switch (id) {
    'game' => const BottomNavTabDef(
      id: 'game',
      icon: LucideIcons.gamepad,
      label: '游戏',
    ),
    'home' => const BottomNavTabDef(
      id: 'home',
      icon: LucideIcons.house,
      label: '首页',
    ),
    'drama' => const BottomNavTabDef(
      id: 'drama',
      icon: LucideIcons.clapperboard,
      label: '短剧',
    ),
    'actress' => BottomNavTabDef(
      id: 'actress',
      icon: actressUnlocked ? LucideIcons.users : LucideIcons.lock,
      label: '演员库',
    ),
    'live' => const BottomNavTabDef(
      id: 'live',
      icon: LucideIcons.tv,
      label: '直播',
    ),
    'library' => const BottomNavTabDef(
      id: 'library',
      icon: LucideIcons.library_big,
      label: '书架',
    ),
    'mine' => const BottomNavTabDef(
      id: 'mine',
      icon: LucideIcons.circle_user_round,
      label: '我的',
    ),
    _ => BottomNavTabDef(id: id, icon: LucideIcons.circle, label: id),
  };
}

/// 全部页签的展示定义（按给定 id 序列）。
List<BottomNavTabDef> bottomNavTabDefs(
  Iterable<String> ids, {
  required bool actressUnlocked,
}) => <BottomNavTabDef>[
  for (final id in ids) bottomNavTabDef(id, actressUnlocked: actressUnlocked),
];

/// 可编辑底栏内容：替代原 NavigationBar 本体，外观对齐原
/// NavigationBarTheme 口径（高 64、图标 22、标签 11sp 选中 w700 /
/// 未选 w500、选中图标下圆角 16 指示药丸）。
///
/// 普通态：点按回调 onSelect(id)，长按任意页签回调 onEnterEdit()。
/// 编辑态：点按不切换页；每页签右上角红色减号角标（点它回调
/// onHide(id)）；页签可长按拖动，悬停到别的页签时即时回调
/// onMove(draggedId, targetVisibleIndex) 做活交换。
/// 页签一律 Expanded 等分整行，增减自动均匀补位。
class EditableBottomNavBar extends StatelessWidget {
  const EditableBottomNavBar({
    super.key,
    required this.tabs,
    required this.selectedId,
    required this.editing,
    required this.selectedColor,
    required this.unselectedColor,
    required this.indicatorColor,
    required this.onSelect,
    required this.onEnterEdit,
    required this.onHide,
    required this.onMove,
    this.selectedIconColor,
    this.selectedLabelColor,
    this.unselectedLabelColor,
  });

  final List<BottomNavTabDef> tabs;

  /// 当前页对应的页签 id；不在 [tabs] 里时无选中态（不崩）。
  final String? selectedId;

  final bool editing;
  final Color selectedColor;
  final Color unselectedColor;
  final Color indicatorColor;

  /// 选中图标色（缺省同 [selectedColor]；墨水屏下图标压在黑色
  /// 药丸上要反白，与标签色不同，单独传入）。
  final Color? selectedIconColor;

  /// 选中标签色（缺省同 [selectedColor]）。
  final Color? selectedLabelColor;

  /// 未选标签色（缺省同 [unselectedColor]）。
  final Color? unselectedLabelColor;

  final void Function(String id) onSelect;
  final VoidCallback onEnterEdit;
  final void Function(String id) onHide;
  final void Function(String draggedId, int targetVisibleIndex) onMove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            Expanded(child: _buildTab(context, tabs[i], i)),
        ],
      ),
    );
  }

  Widget _buildTab(BuildContext context, BottomNavTabDef def, int index) {
    final content = _TabContent(
      key: Key('bottom-nav-tab-${def.id}'),
      def: def,
      selected: def.id == selectedId,
      editing: editing,
      selectedIconColor: selectedIconColor ?? selectedColor,
      selectedLabelColor: selectedLabelColor ?? selectedColor,
      unselectedColor: unselectedColor,
      unselectedLabelColor: unselectedLabelColor ?? unselectedColor,
      indicatorColor: indicatorColor,
      onHide: editing ? () => onHide(def.id) : null,
    );
    if (!editing) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onSelect(def.id),
        onLongPress: onEnterEdit,
        child: content,
      );
    }
    return DragTarget<String>(
      onMove: (details) {
        if (details.data != def.id) onMove(details.data, index);
      },
      builder: (context, candidate, rejected) {
        return LongPressDraggable<String>(
          data: def.id,
          feedback: Material(
            color: Colors.transparent,
            child: _DragFeedback(def: def, color: selectedColor),
          ),
          childWhenDragging: Opacity(opacity: 0.35, child: content),
          child: content,
        );
      },
    );
  }
}

class _TabContent extends StatelessWidget {
  const _TabContent({
    super.key,
    required this.def,
    required this.selected,
    required this.editing,
    required this.selectedIconColor,
    required this.selectedLabelColor,
    required this.unselectedColor,
    required this.unselectedLabelColor,
    required this.indicatorColor,
    required this.onHide,
  });

  final BottomNavTabDef def;
  final bool selected;
  final bool editing;
  final Color selectedIconColor;
  final Color selectedLabelColor;
  final Color unselectedColor;
  final Color unselectedLabelColor;
  final Color indicatorColor;
  final VoidCallback? onHide;

  @override
  Widget build(BuildContext context) {
    final iconColor = selected ? selectedIconColor : unselectedColor;
    final labelColor = selected ? selectedLabelColor : unselectedLabelColor;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: selected ? indicatorColor : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(def.icon, size: 22, color: iconColor),
              ),
              const SizedBox(height: 2),
              Text(
                def.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: labelColor,
                ),
              ),
            ],
          ),
        ),
        if (editing && onHide != null)
          Positioned(
            top: 2,
            right: 6,
            child: GestureDetector(
              key: Key('bottom-nav-hide-${def.id}'),
              behavior: HitTestBehavior.opaque,
              onTap: onHide,
              child: Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.remove,
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 拖动中的反馈小片：图标 + 标签。
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.def, required this.color});

  final BottomNavTabDef def;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(def.icon, size: 22, color: color),
          const SizedBox(width: 6),
          Text(
            def.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// 供 main.dart 的页索引映射引用（与 kBottomNavDefaultOrder 同序）。
const List<String> kBottomNavPageTabIds = kBottomNavDefaultOrder;
