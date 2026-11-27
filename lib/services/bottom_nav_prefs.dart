import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 底部导航页签偏好（顺序 + 隐藏集）：与修仙体系的键互不相关，
/// 只管移动壳底栏 7 个页签的排列与显隐。页索引语义在 main.dart
/// 里由「页签 id ↔ 页索引」映射承担，本服务只认 id。

/// 页签 id 全集与默认顺序，下标与 LazyIndexedStack 子页一一对应：
/// 0 游戏、1 首页、2 短剧、3 演员库、4 直播、5 书架、6 我的。
const List<String> kBottomNavDefaultOrder = <String>[
  'game',
  'home',
  'drama',
  'actress',
  'live',
  'library',
  'mine',
];

const String kBottomNavOrderKey = 'bottom_nav_order_v1';
const String kBottomNavHiddenKey = 'bottom_nav_hidden_v1';

/// 底栏状态：[order] 是全量顺序（恒含全部已知 id），[hidden] 是
/// 被隐藏的 id 集合。可见页签 = order 中不在 hidden 里的子序列。
@immutable
class BottomNavState {
  const BottomNavState({required this.order, required this.hidden});

  final List<String> order;
  final Set<String> hidden;

  static const BottomNavState defaults = BottomNavState(
    order: kBottomNavDefaultOrder,
    hidden: <String>{},
  );

  @override
  bool operator ==(Object other) =>
      other is BottomNavState &&
      listEquals(other.order, order) &&
      setEquals(other.hidden, hidden);

  @override
  int get hashCode => Object.hash(Object.hashAll(order), Object.hashAllUnordered(hidden));
}

/// 把存量（可能缺项、含未知 id）规整成合法状态：未知 id 丢弃，
/// 缺失的默认 id 按默认相对顺序补到末尾。无存量即默认态。
BottomNavState resolveBottomNavState(
  List<String>? storedOrder,
  List<String>? storedHidden,
) {
  if (storedOrder == null && storedHidden == null) {
    return BottomNavState.defaults;
  }
  final known = kBottomNavDefaultOrder.toSet();
  final order = <String>[];
  for (final id in storedOrder ?? const <String>[]) {
    if (known.contains(id) && !order.contains(id)) order.add(id);
  }
  for (final id in kBottomNavDefaultOrder) {
    if (!order.contains(id)) order.add(id);
  }
  final hidden = <String>{
    for (final id in storedHidden ?? const <String>[])
      if (known.contains(id)) id,
  };
  return BottomNavState(order: order, hidden: hidden);
}

/// 可见页签 id 序列（order 中不在 hidden 里的子序列）。
List<String> visibleBottomNavIds(BottomNavState state) => <String>[
  for (final id in state.order)
    if (!state.hidden.contains(id)) id,
];

/// 底部导航偏好单例：每次变更先落盘再通知监听者。
class BottomNavPrefs extends ChangeNotifier {
  BottomNavPrefs({Future<SharedPreferences> Function()? prefsFactory})
    : _prefsFactory = prefsFactory ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _prefsFactory;

  static final BottomNavPrefs instance = BottomNavPrefs();

  BottomNavState _state = BottomNavState.defaults;
  bool _loaded = false;

  BottomNavState get state => _state;
  bool get loaded => _loaded;

  List<String> get visibleIds => visibleBottomNavIds(_state);

  /// 读盘规整状态；重复调用安全（已加载直接返回当前状态）。
  Future<BottomNavState> load() async {
    if (_loaded) return _state;
    final prefs = await _prefsFactory();
    _state = resolveBottomNavState(
      prefs.getStringList(kBottomNavOrderKey),
      prefs.getStringList(kBottomNavHiddenKey),
    );
    _loaded = true;
    notifyListeners();
    return _state;
  }

  Future<void> _persist() async {
    final prefs = await _prefsFactory();
    await prefs.setStringList(kBottomNavOrderKey, _state.order);
    // 隐藏集按全量 order 的相对顺序落盘，读回稳定。
    await prefs.setStringList(kBottomNavHiddenKey, <String>[
      for (final id in _state.order)
        if (_state.hidden.contains(id)) id,
    ]);
  }

  /// 在可见序列里把 [id] 移到 [newVisibleIndex]：合并回全量
  /// order 时隐藏 id 占住原来的槽位、相对位置不变，可见槽位按
  /// 移动后的可见序列依次填回。
  Future<void> move(String id, int newVisibleIndex) async {
    final visible = visibleIds;
    final from = visible.indexOf(id);
    if (from < 0) return;
    final target = newVisibleIndex.clamp(0, visible.length - 1);
    if (target == from) return;
    final newVisible = [...visible]
      ..removeAt(from)
      ..insert(target, id);
    final visibleSet = visible.toSet();
    var cursor = 0;
    final newOrder = <String>[
      for (final slot in _state.order)
        visibleSet.contains(slot) ? newVisible[cursor++] : slot,
    ];
    _state = BottomNavState(order: newOrder, hidden: _state.hidden);
    await _persist();
    notifyListeners();
  }

  /// 隐藏页签。[id] 是最后一个可见页签时守卫拦下：返回 false
  /// 且不落盘、不改状态。
  Future<bool> hide(String id) async {
    final visible = visibleIds;
    if (!visible.contains(id)) return false;
    if (visible.length <= 1) return false;
    _state = BottomNavState(
      order: _state.order,
      hidden: {..._state.hidden, id},
    );
    await _persist();
    notifyListeners();
    return true;
  }

  /// 恢复页签：从隐藏集移除，回到它在 order 里的原位置。
  Future<void> restore(String id) async {
    if (!_state.hidden.contains(id)) return;
    _state = BottomNavState(
      order: _state.order,
      hidden: {..._state.hidden}..remove(id),
    );
    await _persist();
    notifyListeners();
  }

  /// 恢复默认布局：清掉两个键，状态回默认。
  Future<void> reset() async {
    final prefs = await _prefsFactory();
    await prefs.remove(kBottomNavOrderKey);
    await prefs.remove(kBottomNavHiddenKey);
    _state = BottomNavState.defaults;
    notifyListeners();
  }
}
