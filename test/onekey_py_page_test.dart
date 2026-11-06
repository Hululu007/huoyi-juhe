import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/onekey_py_page.dart';

void main() {
  testWidgets('一键写PY页：有网址输入框、站名输入框与生成按钮', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: OneKeyPyPage()),
    );
    await tester.pump();
    expect(find.text('网站地址'), findsOneWidget);
    expect(find.text('站名（可选，不填按域名自动取）'), findsOneWidget);
    expect(find.text('生成并导入'), findsOneWidget);
    expect(find.text('一键写PY'), findsOneWidget);
  });

  testWidgets('空网址点生成：报“请先输入网站地址”，不调 Python 桥', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: OneKeyPyPage()),
    );
    await tester.pump();
    await tester.tap(find.text('生成并导入'));
    await tester.pump();
    expect(find.text('请先输入网站地址'), findsOneWidget);
  });
}
