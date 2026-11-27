import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/bottom_nav_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('无键时是默认态：默认顺序、无隐藏、可见为全量', () async {
    final prefs = BottomNavPrefs();
    final state = await prefs.load();
    expect(state.order, kBottomNavDefaultOrder);
    expect(state.hidden, isEmpty);
    expect(prefs.visibleIds, kBottomNavDefaultOrder);
  });

  test('order/hidden 落盘后新实例重载一致', () async {
    final prefs = BottomNavPrefs();
    await prefs.load();
    await prefs.hide('live');
    await prefs.move('mine', 0);
    final raw = await SharedPreferences.getInstance();
    expect(raw.getStringList(kBottomNavHiddenKey), ['live']);

    final reloaded = BottomNavPrefs();
    final state = await reloaded.load();
    expect(state, prefs.state);
    expect(reloaded.visibleIds, isNot(contains('live')));
    expect(reloaded.visibleIds.first, 'mine');
  });

  test('hide/restore 往返：恢复回到 order 里的原位置', () async {
    final prefs = BottomNavPrefs();
    await prefs.load();
    expect(await prefs.hide('drama'), isTrue);
    expect(prefs.visibleIds, [
      'game',
      'home',
      'actress',
      'live',
      'library',
      'mine',
    ]);
    await prefs.restore('drama');
    expect(prefs.visibleIds, kBottomNavDefaultOrder);
    expect(prefs.state.order, kBottomNavDefaultOrder);
    expect(prefs.state.hidden, isEmpty);
  });

  test('reset 回默认并清掉两键', () async {
    final prefs = BottomNavPrefs();
    await prefs.load();
    await prefs.hide('home');
    await prefs.move('live', 0);
    await prefs.reset();
    expect(prefs.state, BottomNavState.defaults);
    final raw = await SharedPreferences.getInstance();
    expect(raw.getStringList(kBottomNavOrderKey), isNull);
    expect(raw.getStringList(kBottomNavHiddenKey), isNull);
  });

  test('hide 最后一个可见页签被守卫拦住且不落盘', () async {
    final prefs = BottomNavPrefs();
    await prefs.load();
    for (final id in ['game', 'drama', 'actress', 'live', 'library', 'mine']) {
      expect(await prefs.hide(id), isTrue);
    }
    expect(prefs.visibleIds, ['home']);
    expect(await prefs.hide('home'), isFalse);
    expect(prefs.visibleIds, ['home']);
    final raw = await SharedPreferences.getInstance();
    expect(raw.getStringList(kBottomNavHiddenKey), hasLength(6));
  });

  test('resolve 合并：缺失 id 补末尾、未知 id 丢弃', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kBottomNavOrderKey: ['home', 'unknown_id', 'game'],
      kBottomNavHiddenKey: ['nope', 'live'],
    });
    final prefs = BottomNavPrefs();
    final state = await prefs.load();
    expect(state.order, [
      'home',
      'game',
      'drama',
      'actress',
      'live',
      'library',
      'mine',
    ]);
    expect(state.hidden, {'live'});
    expect(prefs.visibleIds, [
      'home',
      'game',
      'drama',
      'actress',
      'library',
      'mine',
    ]);
  });

  test('move 带隐藏项：可见项重排，隐藏项相对位置不变', () async {
    final prefs = BottomNavPrefs();
    await prefs.load();
    await prefs.hide('drama');
    await prefs.move('mine', 0);
    // 可见序列 [game, home, actress, live, library, mine] 把 mine
    // 移到首位后按旧槽位填回，drama 仍占第 3 个槽位。
    expect(prefs.state.order, [
      'mine',
      'game',
      'drama',
      'home',
      'actress',
      'live',
      'library',
    ]);
    expect(prefs.state.order.indexOf('drama'), 2);
    expect(prefs.visibleIds, [
      'mine',
      'game',
      'home',
      'actress',
      'live',
      'library',
    ]);
  });

  test('move 到末尾与越界下标夹紧', () async {
    final prefs = BottomNavPrefs();
    await prefs.load();
    await prefs.move('game', 99);
    expect(prefs.visibleIds.last, 'game');
    await prefs.move('game', -5);
    expect(prefs.visibleIds.first, 'game');
  });
}
