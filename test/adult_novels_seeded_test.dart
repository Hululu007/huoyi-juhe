import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/adult_novels_page.dart';
import 'package:fqapp/services/midnight_gate.dart';

/// 单独成文件：登记表单例一旦加载就不再重读，种子用例须在文件内第一个
/// 触登记表的测试里跑，否则会被前面用例的空登记表污染。
void main() {
  setUp(() {
    final seeded = jsonEncode([
      {
        'id': 'legado-adult-novel',
        'name': '🔞成人小说源',
        'kind': 'legadoImport',
        'address': '',
        'detail': '{}',
        'enabled': true,
        'extra': {'contentType': 'novel'},
      },
    ]);
    SharedPreferences.setMockInitialValues({'juhe_custom_sources': seeded});
  });

  tearDown(() {
    MidnightGate.activated.value = false;
  });

  testWidgets('门禁已开、有成人源但取不到数：失败静默为空，不闪退', (tester) async {
    // 取数走现网（测试环境无网）失败后仍为空态。
    MidnightGate.activated.value = true;
    await tester.pumpWidget(const MaterialApp(home: AdultNovelsPage()));
    await tester.pumpAndSettle();
    expect(find.text('暂无成人小说'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
