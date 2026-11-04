import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/source_management_page.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

SourceEntry _entry(
  String id,
  String name,
  SourceKind kind, {
  String contentType = 'video',
  bool builtin = false,
}) {
  return SourceEntry(
    id: id,
    name: name,
    kind: kind,
    extra: {
      'contentType': contentType,
      if (builtin) 'builtin': true,
    },
  );
}

void main() {
  test('技术分组：顺序与归位，预置内置站不进技术组，旧组名不存在', () {
    final groups = managementTechGroups([
      _entry('m1', '我的 MacCMS 站', SourceKind.customMaccms),
      _entry('r1', '我的远程 JSON 站', SourceKind.remoteJson),
      _entry('j1', '我的 JS 站', SourceKind.jsImport),
      _entry(
        'p1',
        '我的 Python 小说站',
        SourceKind.pyImport,
        contentType: 'novel',
      ),
      _entry('jar1', '我的 Jar 站', SourceKind.jarImport),
      _entry('x1', '我的 XBPQ 规则', SourceKind.xbpqImport),
      _entry(
        'l1',
        '我的阅读书源',
        SourceKind.legadoImport,
        contentType: 'novel',
      ),
      _entry('b1', '预置内置 Jar', SourceKind.jarImport, builtin: true),
    ]);
    expect(
      groups.map((g) => g.title),
      ['JSON 网页源', 'JS 内容源', 'Python 内容源', 'Jar 内容源', 'XBPQ', '阅读书源'],
    );
    expect(groups[0].entries.map((e) => e.id), ['m1', 'r1']);
    expect(groups[1].entries.map((e) => e.id), ['j1']);
    expect(groups[2].entries.map((e) => e.id), ['p1']);
    expect(groups[3].entries.map((e) => e.id), ['jar1']);
    expect(groups[4].entries.map((e) => e.id), ['x1']);
    expect(groups[5].entries.map((e) => e.id), ['l1']);
    // 旧的按类型分组名不在新分组里。
    expect(
      groups.map((g) => g.title),
      isNot(contains('影视源')),
    );
    expect(groups.map((g) => g.title), isNot(contains('书源')));
  });

  testWidgets('站源管理页：滚动到技术组可见行与直播源计数', (tester) async {
    SharedPreferences.setMockInitialValues({
      'juhe_custom_sources': jsonEncode([
        {
          'id': 'p1',
          'name': '我的 Python 小说站',
          'kind': 'pyImport',
          'enabled': true,
          'extra': {'contentType': 'novel'},
        },
        {
          'id': 'l1',
          'name': '我的阅读书源',
          'kind': 'legadoImport',
          'enabled': true,
          'extra': {'contentType': 'novel'},
        },
      ]),
    });
    await tester.pumpWidget(
      const MaterialApp(home: SourceManagementPage()),
    );
    await tester.pump(const Duration(milliseconds: 200));
    // ListView 懒加载：滚到目标组再断言。
    await tester.scrollUntilVisible(
      find.text('Python 内容源'),
      500,
    );
    expect(find.text('我的 Python 小说站'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('阅读书源'), 500);
    expect(find.text('我的阅读书源'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('直播源'), 500);
    expect(find.textContaining('个直播源'), findsOneWidget);
  });
}
